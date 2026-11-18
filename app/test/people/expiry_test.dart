import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/cues/cue_repo.dart';
import 'package:fauxnetic/cues/preparer.dart';
import 'package:fauxnetic/people/expiry.dart';
import 'package:fauxnetic/people/people_repo.dart';
import 'package:fauxnetic/people/person.dart';
import 'package:fauxnetic/recording/scripts.dart';
import 'package:fauxnetic/recording/takes.dart';
import 'package:fauxnetic/storage/temp_sweeper.dart';
import 'package:fauxnetic/storage/vault.dart';

import '../support/fake_engine.dart';
import '../support/keys.dart';
import '../support/people.dart';

class _NoKeeper implements BackgroundKeeper {
  @override
  Future<void> start({String title = '', String text = ''}) async {}
  @override
  Future<void> stop() async {}
}

/// Holds each line until [release] completes.
class _GatedEngine extends FakeEngine {
  final release = Completer<void>();
  final started = Completer<void>();
  @override
  Future<Float32List> speak(String text, {required int seed}) async {
    if (!started.isCompleted) started.complete();
    await release.future;
    return super.speak(text, seed: seed);
  }
}

void main() {
  late Directory dir;
  late Vault vault;
  late TakeStore takes;
  late PeopleRepo people;
  late CueRepo cues;
  final t = DateTime.utc(2026, 11, 15, 12);
  const day = Duration(hours: 24);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('expiry');
    vault = Vault(FixedKeyStore());
    takes = TakeStore(dir, vault);
    people = PeopleRepo(dir, vault, TempSweeper(dir), takes);
    cues = CueRepo(dir, vault);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<void> delete(String id) async {
    await cues.removeForPerson(id);
    await people.delete(id);
  }

  test('launch deletes voices that expired while the app was closed', () async {
    var sam = await people.create('Sam', PersonSource.recorded, now: t, keepFor: const Duration(hours: 1));
    sam = await addTestVoice(people, vault, sam, Mood.conversational);
    await takes.save(sam.id, Mood.conversational, Float32List(16000), text: 'Hi.', fromScript: true, score: 1);
    await cues.add(sam.id, 'Hello.');
    final kid = await people.create('Kid', PersonSource.recorded, now: t, keepFor: day);
    final later = t.add(const Duration(hours: 2));
    expect(await expireVoices(people, delete, later, day), ['Sam']);
    expect((await people.all()).map((p) => p.id), [kid.id]);
    expect(await takes.forPerson(sam.id), isEmpty);
    expect(await cues.all(), isEmpty);
    expect(await expireVoices(people, delete, later, day), isEmpty, reason: 'nothing left to expire');
  });

  test('a line finishing after its voice expired leaves nothing', () async {
    final sam = await readyPerson(people, vault);
    await cues.add(sam.id, 'Hello.');
    final engine = _GatedEngine();
    final run = Preparer(engine, cues, people, _NoKeeper()).runUntilEmpty();
    await engine.started.future;
    await delete(sam.id);
    engine.release.complete();
    await run;
    expect(await cues.all(), isEmpty);
    final clips = Directory('${dir.path}/cues');
    expect(clips.existsSync() ? clips.listSync() : const [], isEmpty);
  });

  test('removing models waits for the line in progress and frees the engine', () async {
    final sam = await readyPerson(people, vault);
    await cues.add(sam.id, 'First.');
    await cues.add(sam.id, 'Second.');
    final engine = _GatedEngine();
    final preparer = Preparer(engine, cues, people, _NoKeeper());
    final run = preparer.runUntilEmpty();
    await engine.started.future;
    var unloaded = false;
    final unload = preparer.unload().then((_) => unloaded = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(unloaded, isFalse, reason: 'the line in progress finishes first');
    engine.release.complete();
    await Future.wait([run, unload]);
    expect(engine.spoken, ['First.'], reason: 'no new line starts once unloading began');
    expect(engine.disposed, 1);
    await preparer.runUntilEmpty();
    expect(engine.spoken, ['First.', 'Second.'], reason: 'work resumes after the models are back');
    expect(engine.loads, 2, reason: 'the engine is loaded again');
  });

  test('voices older than a duration are counted for the warning', () {
    Person at(Duration age) => Person(
      id: '$age',
      name: 'x',
      source: PersonSource.recorded,
      createdAt: t.subtract(age),
      expiresAt: t.subtract(age).add(day),
    );
    final all = [at(const Duration(minutes: 30)), at(const Duration(hours: 2)), at(const Duration(hours: 5))];
    expect(voicesOlderThan(all, const Duration(hours: 1), t), 2);
  });

  test('time left wording', () {
    expect(timeLeft(const Duration(hours: 5, minutes: 59)), 'deleted in 5 h');
    expect(timeLeft(const Duration(hours: 1)), 'deleted in 1 h');
    expect(timeLeft(const Duration(minutes: 40)), 'deleted in 40 min');
    expect(timeLeft(const Duration(minutes: 4, seconds: 1)), 'deleted in 5 min');
    expect(timeLeft(const Duration(seconds: 20)), 'deleted in 1 min');
    expect(timeLeft(Duration.zero), 'deleted in 1 min');
  });
}
