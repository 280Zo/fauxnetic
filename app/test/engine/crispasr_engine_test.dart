import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../support/keys.dart';
import '../support/people.dart';

import 'package:fauxnetic/engine/crispasr_engine.dart';
import 'package:fauxnetic/engine/spoken_numbers.dart';
import 'package:fauxnetic/engine/voice_engine.dart';
import 'package:fauxnetic/models/model_store.dart';
import 'package:fauxnetic/people/people_repo.dart';
import 'package:fauxnetic/people/person.dart';
import 'package:fauxnetic/engine/tts_models.dart';
import 'package:fauxnetic/recording/scripts.dart';
import 'package:fauxnetic/recording/takes.dart';
import 'package:fauxnetic/storage/temp_sweeper.dart';
import 'package:fauxnetic/storage/vault.dart';

class RecordingWorker implements EngineWorker {
  final calls = <String>[];
  final seeds = <int>[];
  String? voicePath;
  bool voiceFileExistedDuringCall = false;

  /// When set, synthesize waits for it (a line that is still being spoken).
  Completer<void>? gate;

  @override
  Future<void> open(String model, String codec, String backend) async =>
      calls.add(backend == 'qwen3-tts' ? 'open $model $codec' : 'open $model $codec $backend');
  @override
  Future<void> setVoice(String path, String refText) async {
    calls.add('setVoice $refText');
    voicePath = path;
    voiceFileExistedDuringCall = File(path).existsSync();
  }

  /// The length cap passed with each synthesize.
  final caps = <int>[];

  /// Samples per seed; a seed missing here gives two samples.
  final lengths = <int, int>{};

  /// Seeds whose line fails with this error, like the engine reporting a stalled line.
  final failures = <int, EngineError>{};

  /// The text each synthesize was given.
  final texts = <String>[];

  @override
  Future<Float32List> synthesize(String text, int seed, {int maxFrames = 0}) async {
    seeds.add(seed);
    caps.add(maxFrames);
    texts.add(text);
    calls.add('synthesize $text');
    await gate?.future;
    final failure = failures[seed];
    if (failure != null) throw failure;
    calls.add('synthesized $text');
    final n = lengths[seed];
    return n == null ? Float32List.fromList([0.1, 0.2]) : Float32List(n);
  }

  @override
  Future<int> sampleRate() async => 24000;
  @override
  Future<void> close() async => calls.add('close');

  var kills = 0;

  /// Like the engine process being ended: a waiting line fails as cancelled.
  @override
  Future<void> kill() async {
    kills++;
    final g = gate;
    gate = null;
    if (g != null && !g.isCompleted) g.completeError(const EngineError(EngineErrorKind.cancelled, 'Stopped.'));
  }
}

/// A stalled line whose "ranaway" reply is already on its way when the line is cancelled.
class _LateStallWorker extends RecordingWorker {
  final inLine = Completer<void>();
  final reply = Completer<void>();

  @override
  Future<Float32List> synthesize(String text, int seed, {int maxFrames = 0}) async {
    seeds.add(seed);
    if (!inLine.isCompleted) inLine.complete();
    await reply.future;
    throw const EngineError(EngineErrorKind.ranAway, 'ranaway: stall');
  }

  @override
  Future<void> kill() async => kills++;
}

class _GatedVoiceWorker extends RecordingWorker {
  final inVoice = Completer<void>();
  final _release = Completer<void>();

  @override
  Future<void> setVoice(String path, String refText) async {
    inVoice.complete();
    await _release.future;
  }

  @override
  Future<void> kill() async {
    await super.kill();
    if (!_release.isCompleted) _release.completeError(const EngineError(EngineErrorKind.cancelled, 'Stopped.'));
  }
}

class DyingWorker extends RecordingWorker {
  @override
  Future<Float32List> synthesize(String text, int seed, {int maxFrames = 0}) async =>
      throw const EngineError(EngineErrorKind.outOfMemory, kOutOfMemoryMessage);
}

/// Runs inside the worker isolate in the isolate tests.
class EchoApi implements CrispasrApi {
  @override
  void open(String model, String codec, String backend) {}
  @override
  void setVoice(String path, String refText) {}
  @override
  Float32List synthesize(String text, int seed) => Float32List.fromList([text.length.toDouble()]);
  @override
  int get sampleRate => 24000;
  @override
  void close() {}
}

class DyingApi extends EchoApi {
  @override
  Float32List synthesize(String text, int seed) {
    Isolate.current.kill(priority: Isolate.immediate);
    return Float32List(0);
  }
}

CrispasrApi echoFactory() => EchoApi();
CrispasrApi dyingFactory() => DyingApi();

void main() {
  late Directory dir;
  late Vault vault;
  late PeopleRepo people;
  late TempSweeper temp;
  late ModelStore models;
  late String accurate;

  PinnedModel pin(ModelRole role, String name, int size) =>
      PinnedModel(role: role, name: name, url: Uri.parse('https://x.test/$name'), size: size, sha256: '0' * 64);

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('engine');
    temp = TempSweeper(dir);
    vault = Vault(FixedKeyStore());
    people = PeopleRepo(dir, vault, temp, TakeStore(dir, vault));
    models = ModelStore(
      Directory('${dir.path}/models'),
      models: [pin(ModelRole.talker, 'talker.gguf', 4), pin(ModelRole.codec, 'codec.gguf', 3)],
    );
    Directory('${dir.path}/models').createSync();
    File('${dir.path}/models/talker.gguf').writeAsBytesSync([1, 2, 3, 4]);
    File('${dir.path}/models/codec.gguf').writeAsBytesSync([1, 2, 3]);
    accurate = 'open ${dir.path}/models/talker.gguf ${dir.path}/models/codec.gguf';
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Iterable<String> opens(RecordingWorker w) => w.calls.where((c) => c.startsWith('open'));
  Iterable<String> voices(RecordingWorker w) => w.calls.where((c) => c.startsWith('setVoice'));

  test('prepare requires consent', () async {
    final w = RecordingWorker();
    final e = CrispasrEngine(() async => w, models, people, temp);
    await e.load();
    final upload = await people.create('Sam', PersonSource.upload);
    final p = await addTestVoice(people, vault, upload, Mood.conversational);
    await expectLater(e.prepare(p, Mood.conversational), throwsA(isA<ConsentRequired>()));
    expect(voices(w), isEmpty);
  });

  test('prepare opens the talker, passes clip and transcript, then releases the temp clip', () async {
    final w = RecordingWorker();
    final e = CrispasrEngine(() async => w, models, people, temp);
    await e.load();
    expect(w.calls, isEmpty, reason: 'load only checks models and starts the worker');
    await e.prepare(await readyPerson(people, vault), Mood.conversational);
    expect(w.calls, [accurate, 'setVoice Hello.']);
    expect(e.sampleRate, 24000);
    expect(w.voiceFileExistedDuringCall, isTrue);
    expect(w.voicePath, startsWith(temp.dir.path));
    expect(File(w.voicePath!).existsSync(), isFalse);
  });

  test('same person and mood skips setVoice', () async {
    final w = RecordingWorker();
    final e = CrispasrEngine(() async => w, models, people, temp);
    final p = await readyPerson(people, vault);
    await e.prepare(p, Mood.conversational);
    await e.prepare(p, Mood.conversational);
    expect(opens(w).length, 1);
    expect(voices(w).length, 1);
  });

  test('mood without recording uses conversational', () async {
    final w = RecordingWorker();
    final e = CrispasrEngine(() async => w, models, people, temp);
    var p = await readyPerson(people, vault);
    p = await addTestVoice(people, vault, p, Mood.excited, refText: 'Wow!');
    await e.prepare(p, Mood.worried);
    await e.prepare(p, Mood.conversational);
    expect(voices(w), ['setVoice Hello.'], reason: 'worried falls back to the same conversational reference');
    await e.prepare(p, Mood.excited);
    expect(voices(w).last, 'setVoice Wow!');
  });

  test('a voice change waits for the current line', () async {
    final w = RecordingWorker()..gate = Completer<void>();
    final e = CrispasrEngine(() async => w, models, people, temp);
    var p = await readyPerson(people, vault);
    p = await addTestVoice(people, vault, p, Mood.excited, refText: 'Wow!');
    await e.prepare(p, Mood.conversational);
    final line = e.speak('First.', seed: 1);
    final switched = e.prepare(p, Mood.excited);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(voices(w), ['setVoice Hello.'], reason: 'the voice is not swapped mid-line');
    w.gate!.complete();
    await Future.wait([line, switched]);
    expect(w.calls.indexOf('setVoice Wow!'), greaterThan(w.calls.indexOf('synthesized First.')));
    expect(opens(w).length, 1, reason: 'one talker, opened once');
  });

  test('speak uses watermarked synthesize', () async {
    final w = RecordingWorker();
    final e = CrispasrEngine(() async => w, models, people, temp);
    await e.prepare(await readyPerson(people, vault), Mood.conversational);
    expect(await e.speak('Hi there.', seed: 1), Float32List.fromList([0.1, 0.2]));
    expect(w.calls.last, 'synthesized Hi there.');
  });

  test('speak passes the line seed to synthesis', () async {
    final w = RecordingWorker();
    final e = CrispasrEngine(() async => w, models, people, temp);
    await e.prepare(await readyPerson(people, vault), Mood.conversational);
    await e.speak('Hi.', seed: 99);
    expect(w.seeds, [99]);
  });

  test('speak before prepare is refused', () async {
    final e = CrispasrEngine(() async => RecordingWorker(), models, people, temp);
    await e.load();
    await expectLater(e.speak('Hi.', seed: 1), throwsA(isA<StateError>()));
  });

  test('load works with only the recording set (the voice model downloads in the background)', () async {
    File('${dir.path}/models/talker.gguf').deleteSync();
    File('${dir.path}/models/codec.gguf').deleteSync();
    await CrispasrEngine(() async => RecordingWorker(), models, people, temp).load();
  });

  test('prepare refuses a model whose files are missing', () async {
    File('${dir.path}/models/codec.gguf').deleteSync();
    final w = RecordingWorker();
    final e = CrispasrEngine(() async => w, models, people, temp);
    await e.load();
    await expectLater(
      e.prepare(await readyPerson(people, vault), Mood.conversational),
      throwsA(isA<EngineError>().having((x) => x.kind, 'kind', EngineErrorKind.modelMissing)),
    );
    expect(opens(w), isEmpty);
  });

  test('after a memory crash the engine spawns a fresh worker', () async {
    final spawned = <RecordingWorker>[];
    var dieNext = true;
    Future<EngineWorker> spawn() async {
      final w = dieNext ? DyingWorker() : RecordingWorker();
      dieNext = false;
      spawned.add(w);
      return w;
    }

    final e = CrispasrEngine(spawn, models, people, temp);
    final p = await readyPerson(people, vault);
    await e.prepare(p, Mood.conversational);
    await expectLater(
      e.speak('x', seed: 1),
      throwsA(isA<EngineError>().having((x) => x.kind, 'kind', EngineErrorKind.outOfMemory)),
    );
    await e.load();
    await e.prepare(p, Mood.conversational);
    expect(await e.speak('Hi.', seed: 1), Float32List.fromList([0.1, 0.2]));
    expect(spawned.length, 2);
    expect(spawned.last.calls.first, accurate, reason: 'the fresh worker opens its talker and voice again');
  });

  test('after dispose the next line starts a fresh worker', () async {
    final spawned = <RecordingWorker>[];
    Future<EngineWorker> spawn() async {
      final w = RecordingWorker();
      spawned.add(w);
      return w;
    }

    final e = CrispasrEngine(spawn, models, people, temp);
    final p = await readyPerson(people, vault);
    await e.prepare(p, Mood.conversational);
    await e.dispose();
    expect(spawned.single.calls.last, 'close');
    await e.prepare(p, Mood.conversational);
    expect(await e.speak('Hi.', seed: 1), Float32List.fromList([0.1, 0.2]));
    expect(spawned.length, 2);
    expect(spawned.last.calls.first, accurate, reason: 'the talker and voice are opened again');
  });

  test('switching models reopens with each model\'s files and backend, and back', () async {
    final w = RecordingWorker();
    var choice = 'qwen';
    final e = CrispasrEngine(() async => w, models, people, temp, model: () => ttsModel(choice));
    final p = await readyPerson(people, vault);
    await e.prepare(p, Mood.conversational);
    choice = 'voxcpm';
    await e.prepare(p, Mood.conversational);
    choice = 'pocket';
    await e.prepare(p, Mood.conversational);
    final m = '${dir.path}/models';
    expect(opens(w), [
      accurate,
      'open $m/voxcpm2-q8_0.gguf  voxcpm2-tts',
      'open $m/pocket-tts-english-q8_0.gguf  pocket-tts',
    ]);
    expect(voices(w).length, 3, reason: 'each new session needs the voice set again');
    await e.prepare(p, Mood.conversational);
    expect(opens(w).length, 3, reason: 'no reopen while the choice is unchanged');
    choice = 'qwen';
    await e.prepare(p, Mood.conversational);
    expect(opens(w).last, accurate);
  });

  test('the engine reports the model it has open, not the current pick', () async {
    final w = RecordingWorker();
    var choice = 'pocket';
    final e = CrispasrEngine(() async => w, models, people, temp, model: () => ttsModel(choice));
    expect(e.openModel, isNull);
    final p = await readyPerson(people, vault);
    await e.prepare(p, Mood.conversational);
    // Owner, 2026-11-16: switched the picker while a slow line was being made; it was labeled Qwen.
    choice = 'qwen';
    expect(e.openModel, 'pocket');
    await e.prepare(p, Mood.conversational);
    expect(e.openModel, 'qwen');
  });

  test('a line\'s own model wins over the current pick', () async {
    final w = RecordingWorker();
    final e = CrispasrEngine(() async => w, models, people, temp, model: () => ttsModel('qwen'));
    final p = await readyPerson(people, vault);
    await e.prepare(p, Mood.conversational, model: 'pocket');
    expect(e.openModel, 'pocket');
    await e.prepare(p, Mood.conversational);
    expect(e.openModel, 'qwen', reason: 'no model given: the current pick');
  });

  test('a line for a model that is no longer downloaded uses the default', () async {
    final w = RecordingWorker();
    final e = CrispasrEngine(
      () async => w,
      models,
      people,
      temp,
      model: () => ttsModel('qwen'),
      ready: (m) async => m.id != 'voxcpm',
    );
    final p = await readyPerson(people, vault);
    expect(await e.modelFor('voxcpm'), 'qwen', reason: 'says up front which model will be used');
    expect(await e.modelFor('pocket'), 'pocket');
    expect(await e.modelFor(null), 'qwen');
    await e.prepare(p, Mood.conversational, model: 'voxcpm');
    expect(e.openModel, 'qwen');
    await e.prepare(p, Mood.conversational, model: 'pocket');
    expect(e.openModel, 'pocket');
  });

  test('cancel kills the worker at once and the next line reopens', () async {
    final first = RecordingWorker()..gate = Completer<void>();
    final second = RecordingWorker();
    final workers = [first, second];
    final e = CrispasrEngine(() async => workers.removeAt(0), models, people, temp);
    final p = await readyPerson(people, vault);
    await e.prepare(p, Mood.conversational);
    final line = e.speak('A long line.', seed: 1);
    await Future<void>.delayed(Duration.zero);
    await e.cancel();
    await expectLater(line, throwsA(isA<EngineError>().having((x) => x.kind, 'kind', EngineErrorKind.cancelled)));
    expect(first.kills, 1);
    expect(e.openModel, isNull);
    await e.prepare(p, Mood.conversational);
    expect(opens(second), [accurate], reason: 'a fresh engine opens the model again');
    expect(voices(second), hasLength(1), reason: 'and sets the voice again');
  });

  test('a cancel while the voice is being set is not reported as a bad voice', () async {
    final w = _GatedVoiceWorker();
    final e = CrispasrEngine(() async => w, models, people, temp);
    final p = await readyPerson(people, vault);
    final prep = e.prepare(p, Mood.conversational);
    await w.inVoice.future;
    await e.cancel();
    await expectLater(prep, throwsA(isA<EngineError>().having((x) => x.kind, 'kind', EngineErrorKind.cancelled)));
  });

  test('cancel with nothing running does nothing harmful', () async {
    final w = RecordingWorker();
    final e = CrispasrEngine(() async => w, models, people, temp);
    await e.cancel();
    expect(w.kills, 0, reason: 'no worker yet');
  });

  group('stalled Qwen lines', () {
    // Owner, 2026-11-16/17: Qwen sometimes never ends a line (it opens with long silence). The engine
    // stops such a line and the app makes it again with another seed.
    const stall = EngineError(EngineErrorKind.ranAway, 'ranaway: stall');

    Future<(RecordingWorker, CrispasrEngine)> qwenEngine() async {
      final w = RecordingWorker();
      final e = CrispasrEngine(() async => w, models, people, temp);
      await e.prepare(await readyPerson(people, vault), Mood.conversational);
      return (w, e);
    }

    test('a stalled line is made again with the next seed', () async {
      final (w, e) = await qwenEngine();
      w.failures[5] = stall;
      w.lengths[retrySeed(5)] = 48000;
      final audio = await e.speak('Hello there.', seed: 5);
      expect(w.seeds, [5, retrySeed(5)]);
      expect(audio.length, 48000);
    });

    test('three stalls fail the line plainly', () async {
      final (w, e) = await qwenEngine();
      for (final s in [5, retrySeed(5), retrySeed(retrySeed(5))]) {
        w.failures[s] = stall;
      }
      await expectLater(
        e.speak('Hello there.', seed: 5),
        throwsA(
          isA<EngineError>()
              .having((x) => x.kind, 'kind', EngineErrorKind.synthesisFailed)
              .having((x) => x.message, 'message', kLineFailedMessage),
        ),
      );
      expect(w.seeds, hasLength(3));
    });

    test('a cancel during a retry is not retried', () async {
      final (w, e) = await qwenEngine();
      w.failures[5] = stall;
      w.failures[retrySeed(5)] = const EngineError(EngineErrorKind.cancelled, 'Stopped.');
      await expectLater(
        e.speak('Hello there.', seed: 5),
        throwsA(isA<EngineError>().having((x) => x.kind, 'kind', EngineErrorKind.cancelled)),
      );
      expect(w.seeds, hasLength(2));
    });

    test('a stall reply that lands after a cancel ends the line as cancelled', () async {
      // Review 2026-11-17: the next attempt found no engine and reported "out of memory".
      final w = _LateStallWorker();
      final e = CrispasrEngine(() async => w, models, people, temp);
      await e.prepare(await readyPerson(people, vault), Mood.conversational);
      final line = e.speak('Hello there.', seed: 5);
      await w.inLine.future;
      await e.cancel();
      w.reply.complete();
      await expectLater(line, throwsA(isA<EngineError>().having((x) => x.kind, 'kind', EngineErrorKind.cancelled)));
      expect(w.seeds, hasLength(1));
    });

    test('lastSeed is the seed that made the line', () async {
      final (w, e) = await qwenEngine();
      w.failures[5] = stall;
      await e.speak('Hello there.', seed: 5);
      expect(e.lastSeed, retrySeed(5));
    });

    test('an engine death is not retried', () async {
      final (w, e) = await qwenEngine();
      w.failures[5] = const EngineError(EngineErrorKind.outOfMemory, kOutOfMemoryMessage);
      await expectLater(
        e.speak('Hello there.', seed: 5),
        throwsA(isA<EngineError>().having((x) => x.kind, 'kind', EngineErrorKind.outOfMemory)),
      );
      expect(w.seeds, hasLength(1));
    });

    test('Qwen hears numbers written out and gets a spoken-length limit', () async {
      final (w, e) = await qwenEngine();
      await e.speak('Call 555-867-5309', seed: 5);
      const spoken = 'Call five five five, eight six seven, five three zero nine';
      expect(w.texts.single, spoken);
      expect(w.caps.single, qwenFrameLimit(spoken));
    });

    test('a card number gets room to be said', () {
      // 20 spoken words: 35 s of room for ~8 s of speech.
      expect(qwenFrameLimit(spokenNumbers('My card number is 4532 7189 0263 5547.')), 438);
      expect(qwenFrameLimit('Hi.'), 240, reason: "never below CrispASR's own floor");
    });

    test('other models get the text as typed and no limit', () async {
      final w = RecordingWorker();
      final e = CrispasrEngine(() async => w, models, people, temp, model: () => ttsModel('pocket'));
      await e.prepare(await readyPerson(people, vault), Mood.conversational);
      await e.speak('Call 555-867-5309', seed: 5);
      expect(w.texts.single, 'Call 555-867-5309');
      expect(w.caps.single, 0);
    });
  });

  test('a repaired transcript is sent again with the same audio', () async {
    final w = RecordingWorker();
    final e = CrispasrEngine(() async => w, models, people, temp);
    var p = await readyPerson(people, vault, refText: 'just excitement and');
    await e.prepare(p, Mood.conversational);
    final r = p.refFor(Mood.conversational);
    p = await people.setVoiceText(p.id, Mood.conversational, clipFile: r.clipFile, refText: 'just');
    await e.prepare(p, Mood.conversational);
    expect(voices(w).last, 'setVoice just');
  });

  test('isolate worker round trip', () async {
    final w = await IsolateWorker.spawn(echoFactory);
    await w.open('a', 'b', 'qwen3-tts');
    expect(await w.synthesize('four', 1), Float32List.fromList([4]));
    expect(await w.sampleRate(), 24000);
    await w.close();
  });

  test('isolate death maps to outOfMemory', () async {
    final w = await IsolateWorker.spawn(dyingFactory);
    await w.open('a', 'b', 'qwen3-tts');
    await expectLater(
      w.synthesize('x', 1),
      throwsA(isA<EngineError>().having((x) => x.kind, 'kind', EngineErrorKind.outOfMemory)),
    );
  });
}
