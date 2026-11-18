import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fauxnetic/models/model_store.dart';

final payload = List<int>.generate(5000, (i) => i % 251);

PinnedModel pin({String? sha, int? size}) => PinnedModel(
  name: 'm.gguf',
  url: Uri.parse('https://example.test/m.gguf'),
  size: size ?? payload.length,
  sha256: sha ?? sha256.convert(payload).toString(),
);

MockClient serving(List<int> bytes, {bool failMidway = false, void Function()? onRequest}) {
  return MockClient.streaming((request, body) async {
    onRequest?.call();
    final controller = StreamController<List<int>>();
    controller.add(bytes.sublist(0, bytes.length ~/ 2));
    if (failMidway) {
      controller.addError(const SocketException('connection reset'));
    } else {
      controller.add(bytes.sublist(bytes.length ~/ 2));
    }
    unawaited(controller.close());
    return http.StreamedResponse(controller.stream, 200, contentLength: bytes.length);
  });
}

Future<int> plenty() async => 10 * 1024 * 1024 * 1024;

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('models'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('verified download is kept', () async {
    final store = ModelStore(dir, client: serving(payload), freeBytes: plenty, models: [pin()]);
    final events = await store.download().toList();
    expect(events.last.received, payload.length);
    expect(await store.path(pin()).readAsBytes(), payload);
    expect(await store.allReady(), isTrue);
  });

  test('hash mismatch deletes file and throws ModelStoreError', () async {
    final bad = pin(sha: '0' * 64);
    final store = ModelStore(dir, client: serving(payload), freeBytes: plenty, models: [bad]);
    await expectLater(store.download().drain<void>(), throwsA(isA<ModelStoreError>()));
    expect(store.path(bad).existsSync(), isFalse);
    expect(dir.listSync(), isEmpty);
  });

  test('interrupted download leaves no model', () async {
    final store = ModelStore(dir, client: serving(payload, failMidway: true), freeBytes: plenty, models: [pin()]);
    await expectLater(store.download().drain<void>(), throwsA(isA<ModelStoreError>()));
    expect(store.path(pin()).existsSync(), isFalse);
    expect(dir.listSync(), isEmpty);
    expect(await store.allReady(), isFalse);
  });

  test('existing verified model is not re-downloaded', () async {
    await ModelStore(dir, client: serving(payload), freeBytes: plenty, models: [pin()]).download().drain<void>();
    var requests = 0;
    final again = ModelStore(
      dir,
      client: serving(payload, onRequest: () => requests++),
      freeBytes: plenty,
      models: [pin()],
    );
    await again.download().drain<void>();
    expect(requests, 0);
  });

  test('insufficient space reported', () async {
    final big = pin(size: 1300 * 1024 * 1024);
    final store = ModelStore(dir, client: serving(payload), freeBytes: () async => 1024 * 1024 * 1024, models: [big]);
    await expectLater(
      store.download().drain<void>(),
      throwsA(
        isA<ModelStoreError>().having(
          (e) => e.message,
          'message',
          'Not enough free storage: need 1.6 GB, have 1.1 GB.',
        ),
      ),
    );
  });

  test('stalled download times out with the interrupted message', () async {
    final stalled = MockClient.streaming((request, body) async {
      final c = StreamController<List<int>>();
      c.add(payload.sublist(0, 10));
      return http.StreamedResponse(c.stream, 200, contentLength: payload.length);
    });
    final store = ModelStore(
      dir,
      client: stalled,
      freeBytes: plenty,
      models: [pin()],
      stallTimeout: const Duration(milliseconds: 50),
    );
    await expectLater(
      store.download().drain<void>(),
      throwsA(isA<ModelStoreError>().having((e) => e.message, 'message', contains('interrupted'))),
    );
    expect(dir.listSync(), isEmpty);
  });

  test('stale part file is removed before free space is measured', () async {
    final part = File('${dir.path}/m.gguf.part')..writeAsBytesSync(List.filled(100, 1));
    var partGoneWhenMeasured = false;
    final store = ModelStore(
      dir,
      client: serving(payload),
      models: [pin()],
      freeBytes: () async {
        partGoneWhenMeasured = !part.existsSync();
        return 10 * 1024 * 1024 * 1024;
      },
    );
    await store.download().drain<void>();
    expect(partGoneWhenMeasured, isTrue);
  });

  test('leaving mid-download removes the part file', () async {
    final c = StreamController<List<int>>();
    final client = MockClient.streaming((request, body) async {
      c.add(payload.sublist(0, 10));
      return http.StreamedResponse(c.stream, 200, contentLength: payload.length);
    });
    final store = ModelStore(dir, client: client, freeBytes: plenty, models: [pin()]);
    final sub = store.download().listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await sub.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(File('${dir.path}/m.gguf.part').existsSync(), isFalse);
    await c.close();
  });

  test('freeBytesAt reads real free space', () {
    final free = freeBytesAt(Directory.systemTemp.path);
    expect(free, greaterThan(0));
    expect(free, lessThan(1 << 50));
  });

  test('pinned models are the six kept', () {
    final byRole = {for (final m in kModels) m.role: m};
    expect(kModels.length, 6);
    expect(byRole.length, 6);
    expect(kModels.any((m) => m.name.contains('q4_k')), isFalse, reason: 'one talker: the Q8 (Accurate) one');
    void check(ModelRole r, String name, int size, String sha) {
      expect(byRole[r]!.name, name);
      expect(byRole[r]!.size, size);
      expect(byRole[r]!.sha256, sha);
      expect(byRole[r]!.url.scheme, 'https');
    }

    check(
      ModelRole.talker,
      'qwen3-tts-12hz-0.6b-base-q8_0.gguf',
      985716544,
      '6162637048fff8ca7f7a16bebc8a62ea8181f4aec4f160894955dee5b87c1961',
    );
    check(
      ModelRole.codec,
      'qwen3-tts-tokenizer-12hz.gguf',
      358453280,
      '70dc95dbfdd9aa5d9d406236ff771d061bf17b0cda02a72513953355606e719b',
    );
    check(
      ModelRole.asrBase,
      'ggml-base.en-q5_1.bin',
      59721011,
      '4baf70dd0d7c4247ba2b81fafd9c01005ac77c2f9ef064e00dcf195d0e2fdd2f',
    );
    check(
      ModelRole.asrTiny,
      'ggml-tiny.en-q5_1.bin',
      32166155,
      'c77c5766f1cef09b6b7d47f21b546cbddd4157886b3b5d6d4f709e91e66c7c2b',
    );
    check(
      ModelRole.vad,
      'ggml-silero-v6.2.0.bin',
      885098,
      '2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987',
    );
    check(
      ModelRole.speaker,
      'wespeaker-resnet34-lm.gguf',
      23904352,
      '2461a2b9a07023a1689fbdb79bd2929dd8793b8bd1ecd9f6ca3b66b4c3668d26',
    );
  });

  test('removing one model deletes only its own files', () async {
    dir.createSync(recursive: true);
    final mine = File('${dir.path}/m.gguf')..writeAsBytesSync([1]);
    final part = File('${dir.path}/m.gguf.part')..writeAsBytesSync([1]);
    final core = File('${dir.path}/qwen3-tts-12hz-0.6b-base-q8_0.gguf')..writeAsBytesSync([1]);
    await ModelStore(dir, models: [pin()]).removeOwn();
    expect(mine.existsSync(), isFalse);
    expect(part.existsSync(), isFalse);
    expect(core.existsSync(), isTrue, reason: 'other models in the folder stay');
  });

  test('launch cleanup keeps optional voice models and drops OmniVoice and CosyVoice', () async {
    dir.createSync(recursive: true);
    final pocket = File('${dir.path}/pocket-tts-english-q8_0.gguf')..writeAsBytesSync([1]);
    final cosy = File('${dir.path}/cosyvoice3-llm-q4_k.gguf')..writeAsBytesSync([1]);
    final vibe = File('${dir.path}/vibevoice-1.5b-tts-q4_k.gguf')..writeAsBytesSync([1]);
    final omni = File('${dir.path}/omnivoice-q8_0.gguf')..writeAsBytesSync([1]);
    final old = File('${dir.path}/qwen3-tts-12hz-0.6b-base-q4_k.gguf')..writeAsBytesSync([1]);
    await ModelStore(dir, models: [pin()]).removeUnpinned();
    expect(pocket.existsSync(), isTrue);
    expect(cosy.existsSync(), isFalse, reason: 'the owner dropped CosyVoice');
    expect(vibe.existsSync(), isFalse, reason: 'the owner dropped VibeVoice (frees 1.9 GB)');
    expect(omni.existsSync(), isFalse, reason: 'the owner dropped OmniVoice');
    expect(old.existsSync(), isFalse);
  });

  test('unpinned model files are removed at launch', () async {
    dir.createSync(recursive: true);
    final kept = File('${dir.path}/m.gguf')..writeAsBytesSync([1]);
    final old = File('${dir.path}/qwen3-tts-12hz-0.6b-base-q4_k.gguf')..writeAsBytesSync([1, 2]);
    final store = ModelStore(dir, models: [pin()]);
    expect(await store.removeUnpinned(), 1);
    expect(kept.existsSync(), isTrue);
    expect(old.existsSync(), isFalse);
    expect(await ModelStore(Directory('${dir.path}/none'), models: [pin()]).removeUnpinned(), 0);
  });

  test('removeAll deletes every model file', () async {
    dir.createSync(recursive: true);
    File('${dir.path}/m.gguf').writeAsBytesSync([1]);
    File('${dir.path}/other.gguf.part').writeAsBytesSync([1]);
    final store = ModelStore(dir, models: [pin()]);
    await store.removeAll();
    expect(dir.existsSync() ? dir.listSync() : const [], isEmpty);
    expect(await store.allPresent(), isFalse);
    await ModelStore(Directory('${dir.path}/none'), models: [pin()]).removeAll();
  });

  test('missing lists only the models not present at their pinned size', () async {
    dir.createSync(recursive: true);
    File('${dir.path}/m.gguf').writeAsBytesSync(payload);
    final other = PinnedModel(name: 'n.gguf', url: Uri.parse('https://example.test/n.gguf'), size: 10, sha256: '');
    final store = ModelStore(dir, models: [pin(), other]);
    expect((await store.missing()).map((m) => m.name), ['n.gguf']);
  });

  test('pathFor returns the file for a role', () {
    final store = ModelStore(dir);
    expect(store.pathFor(ModelRole.vad).path, '${dir.path}/ggml-silero-v6.2.0.bin');
  });
}
