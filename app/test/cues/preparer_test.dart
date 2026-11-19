import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../support/keys.dart';
import '../support/people.dart';

import 'package:fauxnetic/audio/wav.dart';
import 'package:fauxnetic/cues/cue.dart';
import 'package:fauxnetic/cues/cue_repo.dart';
import 'package:fauxnetic/cues/preparer.dart';
import 'package:fauxnetic/cues/speed_book.dart';
import 'package:fauxnetic/engine/crispasr_engine.dart';
import 'package:fauxnetic/engine/voice_engine.dart';
import 'package:fauxnetic/people/people_repo.dart';
import 'package:fauxnetic/people/person.dart';
import 'package:fauxnetic/recording/scripts.dart';
import 'package:fauxnetic/recording/takes.dart';
import 'package:fauxnetic/storage/temp_sweeper.dart';
import 'package:fauxnetic/storage/vault.dart';

import '../support/fake_engine.dart';
import '../support/recording_fakes.dart' show until;

class FakeKeeper implements BackgroundKeeper {
  final events = <String>[];
  @override
  Future<void> start({String title = '', String text = ''}) async => events.add('start');
  @override
  Future<void> stop() async => events.add('stop');
}

void main() {
  late Directory dir;
  late Vault vault;
  late TempSweeper temp;
  late CueRepo cues;
  late PeopleRepo people;
  late Person sam;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('cues');
    vault = Vault(FixedKeyStore());
    temp = TempSweeper(dir);
    cues = CueRepo(dir, vault);
    people = PeopleRepo(dir, vault, temp, TakeStore(dir, vault));
    sam = await readyPerson(people, vault);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Preparer preparer(VoiceEngine e, [FakeKeeper? k]) => Preparer(e, cues, people, k ?? FakeKeeper());

  test('items prepare in order', () async {
    final e = FakeEngine();
    await cues.add(sam.id, 'First.');
    await cues.add(sam.id, 'Second.');
    await preparer(e).runUntilEmpty();
    expect(e.spoken, ['First.', 'Second.']);
    expect((await cues.all()).map((c) => c.status), [CueStatus.ready, CueStatus.ready]);
    expect(e.loads, 1);
  });

  group('lines wait for their model (background downloads, 2026-11-18)', () {
    test('lines wait while Qwen is missing', () async {
      final e = FakeEngine();
      await cues.add(sam.id, 'First.', model: 'qwen');
      await Preparer(e, cues, people, FakeKeeper(), ready: (m) async => m != 'qwen').runUntilEmpty();
      expect(e.prepared, isEmpty);
      expect((await cues.all()).single.status, CueStatus.queued, reason: 'waiting, not failed');
    });

    test('a line for a model that is on the phone runs while Qwen is missing', () async {
      final e = FakeEngine();
      await cues.add(sam.id, 'Qwen line.', model: 'qwen');
      await cues.add(sam.id, 'Pocket line.', model: 'pocket');
      await Preparer(e, cues, people, FakeKeeper(), ready: (m) async => m == 'pocket').runUntilEmpty();
      expect(e.spoken, ['Pocket line.']);
    });

    test('a model that arrives during the last check still gets its lines made', () async {
      // Review: runUntilEmpty during a run returned that run, which then ended with the line queued.
      final e = FakeEngine();
      var here = false;
      late Preparer p;
      p = Preparer(
        e,
        cues,
        people,
        FakeKeeper(),
        ready: (m) async {
          if (!here) {
            here = true;
            unawaited(p.runUntilEmpty()); // the download's onDone, mid-check
            return false;
          }
          return true;
        },
      );
      await cues.add(sam.id, 'First.', model: 'qwen');
      await p.runUntilEmpty();
      expect(e.spoken, ['First.'], reason: 'the same run goes round again');
    });

    test('waiting lines run once their model arrives', () async {
      final e = FakeEngine();
      var here = false;
      final p = Preparer(e, cues, people, FakeKeeper(), ready: (m) async => here);
      await cues.add(sam.id, 'First.', model: 'qwen');
      await p.runUntilEmpty();
      expect(e.spoken, isEmpty);
      here = true;
      await p.runUntilEmpty();
      expect(e.spoken, ['First.']);
    });
  });

  test('prepared clip is stored encrypted and decrypts to a WAV', () async {
    await cues.add(sam.id, 'First.');
    await preparer(FakeEngine()).runUntilEmpty();
    final c = (await cues.all()).single;
    final stored = File('${dir.path}/${c.clipFile}').readAsBytesSync();
    expect(String.fromCharCodes(stored.take(4)), isNot('RIFF'));
    final tmp = await cues.decryptedClip(c, temp);
    expect(wavSeconds(tmp.readAsBytesSync()), closeTo(1.0, 1e-9));
    await temp.release(tmp);
  });

  test('generated lines are stored trimmed', () async {
    final e = FakeEngine()
      ..audio = (_) => Float32List.fromList([
        ...List.filled(24000, 0.0),
        ...List.generate(24000, (i) => 0.3 * sin(2 * pi * 200 * i / 24000)),
        ...List.filled(12000, 0.0),
      ]);
    await cues.add(sam.id, 'First.');
    await preparer(e).runUntilEmpty();
    final tmp = await cues.decryptedClip((await cues.all()).single, temp);
    expect(wavSeconds(tmp.readAsBytesSync()), closeTo(1.6, 0.03), reason: '1 s of speech plus 0.3 s each side');
    await temp.release(tmp);
  });

  test('a breath and long quiet before a generated line are dropped', () async {
    List<double> at(double s, double db) =>
        List.generate((s * 24000).round(), (i) => pow(10, db / 20) * sqrt2 * sin(2 * pi * 200 * i / 24000));
    final e = FakeEngine()
      ..audio = (_) => Float32List.fromList([...at(0.3, -49), ...at(0.2, -42), ...at(2.5, -62), ...at(1, -26)]);
    await cues.add(sam.id, 'Haha.');
    await preparer(e).runUntilEmpty();
    final tmp = await cues.decryptedClip((await cues.all()).single, temp);
    expect(wavSeconds(tmp.readAsBytesSync()), closeTo(1.3, 0.05), reason: '0.3 s, then the speech');
    await temp.release(tmp);
  });

  test('a line that is all quiet is stored as generated', () async {
    final e = FakeEngine()..audio = (_) => Float32List(24000);
    await cues.add(sam.id, 'First.');
    await preparer(e).runUntilEmpty();
    final tmp = await cues.decryptedClip((await cues.all()).single, temp);
    expect(wavSeconds(tmp.readAsBytesSync()), closeTo(1.0, 1e-9));
    await temp.release(tmp);
  });

  test('played line can be replayed', () async {
    await cues.add(sam.id, 'First.');
    await preparer(FakeEngine()).runUntilEmpty();
    await cues.markPlayed((await cues.all()).single.id);
    final c = (await cues.all()).single;
    expect(c.status, CueStatus.played);
    final tmp = await cues.decryptedClip(c, temp);
    expect(wavSeconds(tmp.readAsBytesSync()), closeTo(1.0, 1e-9));
    await temp.release(tmp);
  });

  test('played lines are wiped by retention', () async {
    await cues.add(sam.id, 'First.');
    await preparer(FakeEngine()).runUntilEmpty();
    await cues.markPlayed((await cues.all()).single.id);
    final c = (await cues.all()).single;
    expect(await cues.enforceRetention(c.readyAt!.add(const Duration(hours: 24))), 1);
    expect(File('${dir.path}/${c.clipFile}').existsSync(), isFalse);
  });

  test('new lines get a nonzero seed', () async {
    final seeds = {for (var i = 0; i < 5; i++) (await cues.add(sam.id, 'Line $i.')).seed};
    expect(seeds.every((s) => s >= 1), isTrue);
    expect(seeds.length, greaterThan(1), reason: 'seeds are random, not fixed');
  });

  test('try again keeps the earlier take', () async {
    await cues.add(sam.id, 'First.');
    await preparer(FakeEngine()).runUntilEmpty();
    final c = (await cues.all()).single;
    final clip = File('${dir.path}/${c.clipFile}');
    await cues.regenerate(c.id, 777);
    final again = (await cues.all()).single;
    expect(again.status, CueStatus.queued);
    expect(again.seed, 777);
    expect(again.attempts, 0);
    expect(again.clips, hasLength(1));
    expect(again.readyAt, c.readyAt, reason: 'takes expire 24 h after the first one');
    expect(clip.existsSync(), isTrue);
    await preparer(FakeEngine()).runUntilEmpty();
    final two = (await cues.all()).single;
    expect(two.status, CueStatus.ready);
    expect(two.clips.map((k) => k.seed), [c.seed, 777]);
    expect(two.current, 1, reason: 'the new take is shown');
    expect(two.clipFile, isNot(c.clipFile));
    expect(two.readyAt, c.readyAt);
  });

  test("a line's delete time is capped by its person", () async {
    final now = DateTime.now().toUtc();
    final soon = await people.create('Kid', PersonSource.recorded, now: now, keepFor: const Duration(hours: 1));
    final kid = await addTestVoice(people, vault, soon, Mood.conversational);
    await cues.add(kid.id, 'First.');
    await Preparer(FakeEngine(), cues, people, FakeKeeper(), keepFor: () => const Duration(hours: 24)).runUntilEmpty();
    final first = (await cues.all()).single;
    expect(first.expiresAt, kid.expiresAt, reason: 'a line never outlives its voice');
    await cues.regenerate(first.id, 5);
    await Preparer(FakeEngine(), cues, people, FakeKeeper(), keepFor: () => const Duration(hours: 24)).runUntilEmpty();
    expect((await cues.all()).single.expiresAt, first.expiresAt, reason: 'try again keeps the first delete time');
  });

  test('a line without a short-lived person gets keep-for from now', () async {
    await cues.add(sam.id, 'First.');
    final before = DateTime.now().toUtc();
    await Preparer(FakeEngine(), cues, people, FakeKeeper(), keepFor: () => const Duration(hours: 1)).runUntilEmpty();
    final c = (await cues.all()).single;
    expect(c.expiresAt!.difference(before).inMinutes, inInclusiveRange(59, 60));
  });

  test("lines of people who no longer exist are removed with their takes", () async {
    await cues.add(sam.id, 'Kept.');
    await cues.add('gone', 'Typed for someone deleted.');
    await preparer(FakeEngine()).runUntilEmpty();
    final orphan = (await cues.all()).firstWhere((c) => c.personId == 'gone');
    expect(orphan.status, CueStatus.failed, reason: 'their person is missing');
    expect(await cues.removeOrphans({sam.id}), 1);
    expect((await cues.all()).map((c) => c.personId), [sam.id]);
  });

  test('each take records the engine that made it', () async {
    var engine = 'Qwen3-TTS';
    final p = Preparer(FakeEngine(), cues, people, FakeKeeper(), engineLabel: () => engine);
    await cues.add(sam.id, 'Hello.');
    await p.runUntilEmpty();
    final first = (await cues.all()).single;
    engine = 'OmniVoice';
    await cues.regenerate(first.id, 5);
    await p.runUntilEmpty();
    final c = (await cues.all()).single;
    expect(c.clips.map((k) => k.engine), ['Qwen3-TTS', 'OmniVoice']);
    expect(CueItem.fromJson(c.toJson()).clips.last.engine, 'OmniVoice');
    expect(CueClip.fromJson({'file': 'f', 'seed': 1}).engine, isNull, reason: 'older takes read');
  });

  test('each line and take is made with the model picked when it was asked for', () async {
    final engine = FakeEngine();
    final p = Preparer(engine, cues, people, FakeKeeper());
    final a = await cues.add(sam.id, 'First.', model: 'voxcpm');
    await cues.add(sam.id, 'Second.', model: 'qwen');
    await cues.add(sam.id, 'Old line.');
    await p.runUntilEmpty();
    expect(engine.models, ['voxcpm', 'qwen', null], reason: 'lines from before keep the current pick');
    await cues.regenerate(a.id, 5, model: 'pocket');
    await p.runUntilEmpty();
    expect(engine.models.last, 'pocket');
    final stored = (await cues.all()).firstWhere((c) => c.id == a.id);
    expect(CueItem.fromJson(stored.toJson()).model, 'pocket');
  });

  test('a line is loading, then making; only making is timed and recorded for its model', () async {
    final engine = FakeEngine();
    final speeds = SpeedBook(File('${dir.path}/speeds.json'));
    await speeds.load();
    var now = DateTime.utc(2026, 11, 16, 12);
    final p = Preparer(engine, cues, people, FakeKeeper(), speeds: speeds, clock: () => now);
    final c = await cues.add(sam.id, 'One two three four.', model: 'pocket');
    final seen = <String>[];
    engine.onPrepare = () async {
      seen.add('${p.phaseOf(c.id)}');
      now = now.add(const Duration(seconds: 30)); // loading a model isn't counted
    };
    engine.onSpeak = () async {
      seen.add('${p.phaseOf(c.id)} ${p.startedAt(c.id)}');
      now = now.add(const Duration(seconds: 8));
    };
    await p.runUntilEmpty();
    expect(seen, ['PrepPhase.loading', 'PrepPhase.making ${DateTime.utc(2026, 11, 16, 12, 0, 30)}']);
    expect(speeds.secondsPerWord('pocket'), 2.0, reason: '8 s for 4 words');
    expect(p.phaseOf(c.id), isNull, reason: 'done');
  });

  group('stopping the line being made', () {
    test('removing it cancels the engine and the queue goes on', () async {
      final engine = FakeEngine();
      final p = Preparer(engine, cues, people, FakeKeeper());
      final a = await cues.add(sam.id, 'Long line.');
      await cues.add(sam.id, 'Next line.');
      var first = true;
      engine.onSpeak = () async {
        if (!first) return;
        first = false;
        await cues.remove(a.id);
        await p.cancelIfGone();
        await engine.held.future;
      };
      await p.runUntilEmpty();
      expect(engine.cancels, 1);
      expect(engine.spoken, ['Next line.']);
      final left = await cues.all();
      expect(left.map((c) => c.text), ['Next line.']);
      expect(left.single.status, CueStatus.ready);
    });

    test('a cancel between lines does nothing', () async {
      final engine = FakeEngine();
      final p = Preparer(engine, cues, people, FakeKeeper());
      await p.cancelIfGone();
      await cues.add(sam.id, 'One.');
      await p.runUntilEmpty();
      await p.cancelIfGone();
      expect(engine.cancels, 0);
    });

    test('a cancel while its model is loading stops it too', () async {
      final engine = FakeEngine();
      final p = Preparer(engine, cues, people, FakeKeeper());
      final a = await cues.add(sam.id, 'Loading line.');
      engine.onPrepare = () async {
        await cues.remove(a.id);
        await p.cancelIfGone();
        await engine.held.future;
      };
      await p.runUntilEmpty();
      expect(engine.cancels, 1);
      expect(engine.spoken, isEmpty);
      expect(await cues.all(), isEmpty);
    });

    test('a line still there is not cancelled', () async {
      final engine = FakeEngine();
      final p = Preparer(engine, cues, people, FakeKeeper());
      await cues.add(sam.id, 'Keep me.');
      engine.onSpeak = () => p.cancelIfGone();
      await p.runUntilEmpty();
      expect(engine.cancels, 0);
      expect((await cues.all()).single.status, CueStatus.ready);
    });

    test('two quick removes cancel once and carry on', () async {
      final engine = FakeEngine();
      final speeds = SpeedBook(File('${dir.path}/speeds.json'));
      await speeds.load();
      final p = Preparer(engine, cues, people, FakeKeeper(), speeds: speeds);
      final a = await cues.add(sam.id, 'Long line.');
      engine.onSpeak = () async {
        await cues.remove(a.id);
        await Future.wait([p.cancelIfGone(), p.cancelIfGone()]);
        await engine.held.future;
      };
      await p.runUntilEmpty();
      expect(engine.cancels, 1);
      expect(speeds.secondsPerWord('qwen'), isNull, reason: 'a stopped line records no speed');
    });

    test('unload stops the line being made and sends it back to the queue', () async {
      final engine = FakeEngine();
      final p = Preparer(engine, cues, people, FakeKeeper());
      await cues.add(sam.id, 'Interrupted.');
      final unloaded = Completer<void>();
      engine.onSpeak = () async {
        unawaited(p.unload().then(unloaded.complete));
        await engine.held.future;
      };
      await p.runUntilEmpty();
      await unloaded.future;
      expect(engine.cancels, 1);
      expect(engine.disposed, 1);
      final c = (await cues.all()).single;
      expect(c.status, CueStatus.queued);
      expect(c.attempts, 0, reason: 'a stop is not a failed try');
    });
  });

  group('loading a model ahead', () {
    test('unloads the old model first, then opens the new one with the voice', () async {
      final engine = FakeEngine();
      final p = Preparer(engine, cues, people, FakeKeeper());
      await cues.add(sam.id, 'Made with Qwen.');
      await p.runUntilEmpty();
      expect(p.loadedModel, 'qwen');
      await p.loadModel(sam, Mood.conversational, 'pocket');
      expect(engine.cancels, 1, reason: 'the old model is unloaded before the new one loads');
      expect(engine.models.last, 'pocket');
      expect(engine.prepared.last, '${sam.id} conversational');
      expect(p.loadedModel, 'pocket');
    });

    test('a load keeps the app awake, and lets it sleep after', () async {
      // A54, 2026-11-17: Android froze the app and its engine 38 s after the owner left the screen
      // during a VoxCPM load; the load then never moved.
      final keeper = FakeKeeper();
      final p = Preparer(FakeEngine(), cues, people, keeper);
      await p.loadModel(sam, Mood.conversational, 'pocket');
      expect(keeper.events, ['start', 'stop']);
    });

    test('a failed load lets the app sleep too', () async {
      final keeper = FakeKeeper();
      final engine = FakeEngine()..onPrepare = () async => throw const EngineError(EngineErrorKind.outOfMemory, 'x');
      final p = Preparer(engine, cues, people, keeper);
      await expectLater(p.loadModel(sam, Mood.conversational, 'pocket'), throwsA(isA<EngineError>()));
      expect(keeper.events, ['start', 'stop']);
    });

    test('the model already loaded is not loaded again', () async {
      final engine = FakeEngine();
      final p = Preparer(engine, cues, people, FakeKeeper());
      await p.loadModel(sam, Mood.conversational, 'qwen');
      final before = engine.prepared.length;
      await p.loadModel(sam, Mood.conversational, 'qwen');
      expect(engine.prepared.length, before);
      expect(engine.cancels, 0, reason: 'nothing to unload the first time');
    });

    test('stopping a load ends the engine, but never a line being made', () async {
      final engine = FakeEngine();
      final p = Preparer(engine, cues, people, FakeKeeper());
      await p.stopLoading();
      expect(engine.cancels, 1, reason: 'nothing being made: the load is stopped');
      await cues.add(sam.id, 'Busy.');
      final gate = Completer<void>();
      engine.onSpeak = () => gate.future;
      final run = p.runUntilEmpty();
      await until(() => engine.seeds.isNotEmpty);
      await p.stopLoading();
      expect(engine.cancels, 1, reason: 'a line being made is left alone');
      gate.complete();
      await run;
    });

    test('a line being made is not cut off by a load', () async {
      final engine = FakeEngine();
      final p = Preparer(engine, cues, people, FakeKeeper());
      await cues.add(sam.id, 'Keep making me.');
      final gate = Completer<void>();
      engine.onSpeak = () => gate.future;
      final run = p.runUntilEmpty();
      await until(() => engine.seeds.isNotEmpty);
      final load = p.loadModel(sam, Mood.conversational, 'pocket');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(engine.cancels, 0);
      gate.complete();
      await run;
      await load;
      expect((await cues.all()).single.status, CueStatus.ready);
      expect(p.loadedModel, 'pocket');
    });
  });

  test('a failed line records no speed', () async {
    final engine = FakeEngine(failures: {'Broken.': const EngineError(EngineErrorKind.synthesisFailed, 'x')});
    final speeds = SpeedBook(File('${dir.path}/speeds.json'));
    await speeds.load();
    await cues.add(sam.id, 'Broken.');
    await Preparer(engine, cues, people, FakeKeeper(), speeds: speeds).runUntilEmpty();
    expect(speeds.secondsPerWord('qwen'), isNull);
  });

  test('lines shorten with the setting', () async {
    await cues.add(sam.id, 'First.');
    await preparer(FakeEngine()).runUntilEmpty();
    final c = (await cues.all()).single;
    expect(await cues.shorten(const Duration(hours: 1)), 1);
    expect((await cues.all()).single.expiresAt, c.readyAt!.add(const Duration(hours: 1)));
    expect(await cues.shorten(const Duration(hours: 24)), 0);
  });

  test('retention and remove wipe every take', () async {
    await cues.add(sam.id, 'First.');
    await cues.add(sam.id, 'Second.');
    await preparer(FakeEngine()).runUntilEmpty();
    for (final c in await cues.all()) {
      await cues.regenerate(c.id, 5);
    }
    await preparer(FakeEngine()).runUntilEmpty();
    final [a, b] = await cues.all();
    final files = [
      for (final c in [a, b])
        for (final k in c.clips) File('${dir.path}/${k.file}'),
    ];
    expect(files, hasLength(4));
    expect(files.every((f) => f.existsSync()), isTrue);
    await cues.remove(a.id);
    expect(files.take(2).any((f) => f.existsSync()), isFalse);
    expect(await cues.enforceRetention(b.readyAt!.add(const Duration(hours: 24))), 1);
    expect(files.any((f) => f.existsSync()), isFalse);
  });

  test('a line waiting on try again still expires with its first take', () async {
    await cues.add(sam.id, 'First.');
    await preparer(FakeEngine()).runUntilEmpty();
    final c = (await cues.all()).single;
    await cues.regenerate(c.id, 5);
    expect(await cues.enforceRetention(c.readyAt!.add(const Duration(hours: 24))), 1);
    expect(File('${dir.path}/${c.clipFile}').existsSync(), isFalse);
  });

  test('selecting a take changes the clip', () async {
    await cues.add(sam.id, 'First.');
    await preparer(FakeEngine()).runUntilEmpty();
    final first = (await cues.all()).single;
    await cues.regenerate(first.id, 5);
    await preparer(FakeEngine()).runUntilEmpty();
    await cues.select(first.id, 0);
    expect((await cues.all()).single.clipFile, first.clipFile);
    await cues.select(first.id, 9);
    expect((await cues.all()).single.current, 0, reason: 'out of range is ignored');
  });

  test('preparer passes the seed to the engine', () async {
    final e = FakeEngine();
    final c = await cues.add(sam.id, 'Seeded.');
    await preparer(e).runUntilEmpty();
    expect(e.seeds, [c.seed]);
  });

  test('preparer passes the mood to the engine', () async {
    final e = FakeEngine();
    await cues.add(sam.id, 'Hey!', mood: Mood.excited);
    await cues.add(sam.id, 'Plain.');
    await preparer(e).runUntilEmpty();
    expect(e.prepared, ['${sam.id} excited', '${sam.id} conversational']);
    expect((await cues.all()).first.mood, Mood.excited);
  });

  test('clear wipes all clips', () async {
    await cues.add(sam.id, 'First.');
    await cues.add(sam.id, 'Second.');
    await preparer(FakeEngine()).runUntilEmpty();
    await cues.clear();
    expect(await cues.all(), isEmpty);
    expect(Directory('${dir.path}/cues').listSync(), isEmpty);
  });

  test('retention wipes expired ready clips', () async {
    await cues.add(sam.id, 'First.');
    await preparer(FakeEngine()).runUntilEmpty();
    final c = (await cues.all()).single;
    expect(await cues.enforceRetention(c.readyAt!.add(const Duration(hours: 23))), 0);
    expect(await cues.enforceRetention(c.readyAt!.add(const Duration(hours: 24))), 1);
    expect(await cues.all(), isEmpty);
    expect(File('${dir.path}/${c.clipFile}').existsSync(), isFalse);
  });

  test('restart requeues preparing items', () async {
    final a = await cues.add(sam.id, 'First.');
    final b = await cues.add(sam.id, 'Second.');
    await cues.update(a.copyWith(status: CueStatus.preparing, attempts: 1));
    await cues.update(b.copyWith(status: CueStatus.preparing, attempts: 2));
    await cues.recoverAfterRestart();
    final all = await cues.all();
    expect(all[0].status, CueStatus.queued);
    expect(all[1].status, CueStatus.failed);
    expect(all[1].error, kFailedTwiceMessage);
  });

  test('launch removes clips no line refers to', () async {
    await cues.add(sam.id, 'Kept.');
    await preparer(FakeEngine()).runUntilEmpty();
    final kept = File('${dir.path}/${(await cues.all()).single.clipFile}');
    final orphan = File('${dir.path}/cues/deadbeef-0.bin')..writeAsBytesSync([1, 2, 3]);
    await startupCleanup(cues, temp, DateTime.now().toUtc());
    expect(orphan.existsSync(), isFalse, reason: 'a crash between writing a clip and indexing it');
    expect(kept.existsSync(), isTrue);
  });

  test('launch sweeps temp files', () async {
    await (await temp.create('.wav')).writeAsString('left over');
    final report = await startupCleanup(cues, temp, DateTime.now().toUtc());
    expect(report.tempFilesRemoved, 1);
    expect(temp.dir.listSync(), isEmpty);
  });

  test('engine crash marks item failed with memory message', () async {
    final e = FakeEngine(failures: {'First.': const EngineError(EngineErrorKind.outOfMemory, kOutOfMemoryMessage)});
    await cues.add(sam.id, 'First.');
    await cues.add(sam.id, 'Second.');
    await preparer(e).runUntilEmpty();
    final all = await cues.all();
    expect(all[0].status, CueStatus.failed);
    expect(all[0].error, 'The phone ran out of memory while preparing this line. Close other apps and retry.');
    expect(all[1].status, CueStatus.ready);
  });

  test('deleted person fails the item', () async {
    await cues.add('gone', 'First.');
    await preparer(FakeEngine()).runUntilEmpty();
    expect((await cues.all()).single.error, 'This person was deleted.');
  });

  test('keeper runs only while there is work', () async {
    final k = FakeKeeper();
    await preparer(FakeEngine(), k).runUntilEmpty();
    expect(k.events, isEmpty);
    await cues.add(sam.id, 'First.');
    await preparer(FakeEngine(), k).runUntilEmpty();
    expect(k.events, ['start', 'stop']);
  });

  test('concurrent changes are not lost', () async {
    final first = await cues.add(sam.id, 'Zero.');
    await Future.wait([
      cues.add(sam.id, 'One.'),
      cues.update(first.copyWith(status: CueStatus.preparing, attempts: 1)),
      cues.add(sam.id, 'Two.'),
      cues.add(sam.id, 'Three.'),
    ]);
    final all = await cues.all();
    expect(all.map((c) => c.text).toSet(), {'Zero.', 'One.', 'Two.', 'Three.'});
    expect(all.firstWhere((c) => c.text == 'Zero.').status, CueStatus.preparing);
  });

  test('removing a line while it prepares discards its clip', () async {
    final c = await cues.add(sam.id, 'First.');
    final working = c.copyWith(status: CueStatus.preparing, attempts: 1);
    await cues.update(working);
    await cues.remove(c.id);
    final stored = await cues.storeClip(working, [1, 2, 3], DateTime.now().toUtc());
    expect(stored, isNull);
    expect(await cues.all(), isEmpty);
    expect(Directory('${dir.path}/cues').existsSync() ? Directory('${dir.path}/cues').listSync() : [], isEmpty);
  });

  test('unexpected error fails the line and the queue continues', () async {
    final e = FakeEngine(failures: {'First.': StateError('native call failed')});
    await cues.add(sam.id, 'First.');
    await cues.add(sam.id, 'Second.');
    await preparer(e).runUntilEmpty();
    final all = await cues.all();
    expect(all[0].status, CueStatus.failed);
    expect(all[0].error, 'Preparing this line failed. Tap to retry.');
    expect(all[1].status, CueStatus.ready);
  });

  test('after a memory crash the next line loads the engine again', () async {
    final e = FakeEngine(failures: {'First.': const EngineError(EngineErrorKind.outOfMemory, kOutOfMemoryMessage)});
    await cues.add(sam.id, 'First.');
    await cues.add(sam.id, 'Second.');
    await preparer(e).runUntilEmpty();
    expect(e.loads, 2);
    expect((await cues.all())[1].status, CueStatus.ready);
  });

  test('failed twice message points at memory', () {
    expect(kFailedTwiceMessage, contains('memory'));
  });

  test('removing a person\'s lines wipes their clips', () async {
    await cues.add(sam.id, 'First.');
    await cues.add('other', 'Keep me.');
    await preparer(FakeEngine()).runUntilEmpty();
    final samClip = File('${dir.path}/${(await cues.all()).first.clipFile}');
    await cues.removeForPerson(sam.id);
    expect((await cues.all()).map((c) => c.text), ['Keep me.']);
    expect(samClip.existsSync(), isFalse);
  });

  test('startup sweeps orphaned tmp files', () async {
    File('${dir.path}/clips/x.bin.tmp')
      ..createSync(recursive: true)
      ..writeAsStringSync('x');
    File('${dir.path}/cues/y.bin.tmp')
      ..createSync(recursive: true)
      ..writeAsStringSync('y');
    await startupCleanup(cues, temp, DateTime.now().toUtc());
    expect(File('${dir.path}/clips/x.bin.tmp').existsSync(), isFalse);
    expect(File('${dir.path}/cues/y.bin.tmp').existsSync(), isFalse);
  });

  test('cue index is encrypted at rest', () async {
    await cues.add(sam.id, 'Read me the verification code please.');
    final raw = String.fromCharCodes(File('${dir.path}/cues.json').readAsBytesSync());
    expect(raw.contains('verification'), isFalse);
  });

  test('retry requeues a failed item', () async {
    final e = FakeEngine(failures: {'First.': const EngineError(EngineErrorKind.synthesisFailed, 'x')});
    final c = await cues.add(sam.id, 'First.');
    await preparer(e).runUntilEmpty();
    await cues.retry(c.id);
    final again = (await cues.all()).single;
    expect(again.status, CueStatus.queued);
    expect(again.error, isNull);
  });

  test('a take records the seed that made it, after a retry too', () async {
    // Review 2026-11-17: the take kept the first seed even when a retry made the audio.
    final e = FakeEngine()..retriedTo = 4242;
    await cues.add(sam.id, 'First.');
    await preparer(e).runUntilEmpty();
    expect((await cues.all()).single.clips.single.seed, 4242);
  });

  test('retry gives the line a new seed', () async {
    // Review 2026-11-17: Qwen gives the same result for the same seed, so a retry on the old seed
    // fails the same way.
    final e = FakeEngine(failures: {'First.': const EngineError(EngineErrorKind.synthesisFailed, 'x')});
    final c = await cues.add(sam.id, 'First.');
    await preparer(e).runUntilEmpty();
    await cues.retry(c.id);
    expect((await cues.all()).single.seed, isNot(c.seed));
  });
}
