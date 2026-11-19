import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/cues/preparer.dart';
import 'package:fauxnetic/models/download_center.dart';
import 'package:fauxnetic/models/model_store.dart';
import 'package:fauxnetic/platform/network.dart';

PinnedModel file(String name, int size) =>
    PinnedModel(name: name, url: Uri.parse('https://example.test/$name'), size: size, sha256: '');

/// A store whose download the test drives: [emit] progress, [finish], or [fail].
class FakeStore extends ModelStore {
  FakeStore(this.files) : super(Directory.systemTemp, models: files);
  final List<PinnedModel> files;
  StreamController<DownloadProgress>? live;
  var downloads = 0, cancels = 0;

  /// Every download fails at once with this (a server that keeps failing).
  ModelStoreError? alwaysFail;

  @override
  Stream<DownloadProgress> download() {
    downloads++;
    final f = alwaysFail;
    if (f != null) return Stream.error(f);
    final s = StreamController<DownloadProgress>(onCancel: () => cancels++);
    live = s;
    return s.stream;
  }

  void emit(int received) => live!.add(DownloadProgress(files.first.name, received, files.first.size));
  Future<void> finish() => live!.close();
  void fail(ModelStoreError e) {
    live!.addError(e);
    unawaited(live!.close());
  }

  @override
  Future<List<PinnedModel>> missing() async => files;
  @override
  Future<int> bytesLeft() async => files.fold<int>(0, (n, f) => n + f.size);
}

class CountingKeeper implements BackgroundKeeper {
  var starts = 0, stops = 0;
  @override
  Future<void> start({String title = '', String text = ''}) async => starts++;
  @override
  Future<void> stop() async => stops++;
}

void main() {
  late Map<String, FakeStore> stores;
  late NetKind net;
  late CountingKeeper keeper;
  late List<String> done;
  late DownloadCenter center;

  final voice = [file('talker', 1000), file('codec', 400)];
  final pocket = [file('pocket', 100)];

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 40));

  setUp(() {
    stores = {};
    net = NetKind.unmetered;
    keeper = CountingKeeper();
    done = [];
    center = DownloadCenter(
      store: (files) => stores.putIfAbsent(files.first.name, () => FakeStore(files)),
      network: () async => net,
      keeper: keeper,
      poll: const Duration(milliseconds: 10),
      onDone: done.add,
    );
  });
  tearDown(() => center.dispose());

  test('downloads queued jobs one at a time, in order', () async {
    await center.enqueue('qwen', 'Voice model', voice);
    await center.enqueue('pocket', 'Pocket TTS', pocket);
    await settle();
    expect(center.job('qwen')!.state, JobState.downloading);
    expect(center.job('pocket')!.state, JobState.queued);
    expect(stores['pocket']!.downloads, 0, reason: 'not started yet');
    stores['talker']!.emit(500);
    await settle();
    expect(center.job('qwen')!.received, 500);
    expect(center.job('qwen')!.left, 900);
    await stores['talker']!.finish();
    await settle();
    expect(center.job('qwen')!.state, JobState.done);
    expect(center.job('pocket')!.state, JobState.downloading);
  });

  test('waits for Wi-Fi on a metered connection', () async {
    net = NetKind.metered;
    await center.enqueue('qwen', 'Voice model', voice);
    await settle();
    expect(center.job('qwen')!.state, JobState.waitingWifi);
    expect(stores['talker']!.downloads, 0);
    net = NetKind.unmetered;
    await settle();
    expect(center.job('qwen')!.state, JobState.downloading);
  });

  test('use mobile data lets that job run', () async {
    net = NetKind.metered;
    await center.enqueue('qwen', 'Voice model', voice);
    await settle();
    center.allowMobileData('qwen');
    await settle();
    expect(center.job('qwen')!.state, JobState.downloading);
  });

  test('an allowed job runs ahead of one waiting for Wi-Fi', () async {
    net = NetKind.metered;
    await center.enqueue('qwen', 'Voice model', voice);
    await center.enqueue('pocket', 'Pocket TTS', pocket);
    await settle();
    center.allowMobileData('pocket');
    await settle();
    expect(center.job('pocket')!.state, JobState.downloading);
    expect(center.job('qwen')!.state, JobState.waitingWifi);
    expect(center.current!.id, 'pocket');
  });

  test('switching to mobile data stops and keeps the part', () async {
    await center.enqueue('qwen', 'Voice model', voice);
    await settle();
    stores['talker']!.emit(300);
    await settle(); // the progress arrives before the switch
    net = NetKind.metered;
    await settle();
    expect(stores['talker']!.cancels, 1);
    expect(center.job('qwen')!.state, JobState.waitingWifi);
    expect(center.job('qwen')!.received, 300, reason: 'what arrived is kept');
  });

  test('a lost connection waits and continues by itself', () async {
    await center.enqueue('qwen', 'Voice model', voice);
    await settle();
    net = NetKind.none;
    stores['talker']!.fail(const ModelStoreError('interrupted', kind: ModelErrorKind.network));
    await settle();
    expect(center.job('qwen')!.state, JobState.waitingNetwork);
    net = NetKind.unmetered;
    await settle();
    expect(center.job('qwen')!.state, JobState.downloading);
    expect(stores['talker']!.downloads, 2);
  });

  test('a network error while still connected waits before trying again', () async {
    // Review: Wi-Fi without internet (a login page) retried in a tight loop.
    stores['talker'] = FakeStore(voice)..alwaysFail = const ModelStoreError('interrupted', kind: ModelErrorKind.network);
    await center.enqueue('qwen', 'Voice model', voice);
    await Future<void>.delayed(const Duration(milliseconds: 45));
    expect(stores['talker']!.downloads, inInclusiveRange(1, 6), reason: 'about one try per 10 ms poll, not hundreds');
    expect(center.job('qwen')!.state, isNot(JobState.failed));
  });

  test('a failure shows its message and retry runs it again', () async {
    await center.enqueue('qwen', 'Voice model', voice);
    await settle();
    stores['talker']!.fail(const ModelStoreError('talker did not match its checksum.'));
    await settle();
    expect(center.job('qwen')!.state, JobState.failed);
    expect(center.job('qwen')!.error, 'talker did not match its checksum.');
    await settle();
    expect(stores['talker']!.downloads, 1, reason: 'a failure is not retried by itself');
    center.retry('qwen');
    await settle();
    expect(center.job('qwen')!.state, JobState.downloading);
  });

  test('keep-alive is up only while transferring', () async {
    await center.enqueue('qwen', 'Voice model', voice);
    await settle();
    expect(keeper.starts, 1);
    net = NetKind.metered;
    await settle();
    expect(keeper.stops, 1, reason: 'no notification while waiting');
    await settle();
    expect(keeper.starts, 1);
    net = NetKind.unmetered;
    await settle();
    expect(keeper.starts, 2);
  });

  test('onDone fires once per job', () async {
    await center.enqueue('pocket', 'Pocket TTS', pocket);
    await settle();
    await stores['pocket']!.finish();
    await settle();
    await center.enqueue('pocket', 'Pocket TTS', pocket);
    await settle();
    expect(done, ['pocket']);
  });

  test('cancel stops a running job and removes it', () async {
    await center.enqueue('qwen', 'Voice model', voice);
    await settle();
    await center.cancel('qwen');
    expect(stores['talker']!.cancels, 1);
    expect(center.job('qwen'), isNull);
    expect(center.current, isNull);
  });
}
