import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/people/people_repo.dart';
import 'package:fauxnetic/people/person.dart';
import 'package:fauxnetic/people/voice_end_repair.dart';
import 'package:fauxnetic/recording/reference_builder.dart';
import 'package:fauxnetic/recording/scripts.dart';
import 'package:fauxnetic/recording/takes.dart';
import 'package:fauxnetic/recording/transcriber.dart';
import 'package:fauxnetic/storage/temp_sweeper.dart';
import 'package:fauxnetic/storage/vault.dart';

import '../support/keys.dart';
import '../support/people.dart';
import '../support/recording_fakes.dart';

void main() {
  late Directory dir;
  late Vault vault;
  late TempSweeper temp;
  late PeopleRepo people;
  late FakeTranscriber whisper;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('repair');
    vault = Vault(FixedKeyStore());
    temp = TempSweeper(Directory('${dir.path}/cache'));
    people = PeopleRepo(dir, vault, temp, TakeStore(dir, vault));
    whisper = FakeTranscriber();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  /// A voice saved before the fix: not yet checked.
  Future<Person> legacy(String refText) async {
    final p = await readyPerson(people, vault, refText: refText);
    final r = p.refFor(Mood.conversational);
    return people.setVoice(
      p.id,
      Mood.conversational,
      VoiceRef(clipFile: r.clipFile, refText: r.refText, seconds: r.seconds, endChecked: false),
    );
  }

  Future<VoiceRef> refOf(Person p) async =>
      (await people.all()).firstWhere((x) => x.id == p.id).refFor(Mood.conversational);

  test('a transcript running past its audio takes the words heard (Testy)', () async {
    final p = await legacy('evilness, just excitement and');
    whisper.next = () => words('evilness, just');
    expect(await repairVoiceEnds(people, whisper, temp), 1);
    final r = await refOf(p);
    expect(r.refText, 'evilness, just');
    expect(r.endChecked, isTrue);
    expect(File('${dir.path}/${r.clipFile}').existsSync(), isTrue, reason: 'the audio is kept');
  });

  test('audio running past its transcript takes the words heard (Meme)', () async {
    final p = await legacy("he's already taken");
    whisper.next = () => words("he's already taken over.");
    expect(await repairVoiceEnds(people, whisper, temp), 1);
    expect((await refOf(p)).refText, "he's already taken over.");
  });

  test('a matching end keeps the transcript and is not checked again', () async {
    final p = await legacy('Thursday at the bus stop.');
    whisper.next = () => words('thursday at the bus stop');
    expect(await repairVoiceEnds(people, whisper, temp), 0);
    final r = await refOf(p);
    expect(r.refText, 'Thursday at the bus stop.', reason: 'case and punctuation do not count');
    expect(r.endChecked, isTrue);
    await repairVoiceEnds(people, whisper, temp);
    expect(whisper.calls, 1);
  });

  test('voices made after the fix are not checked', () async {
    await readyPerson(people, vault, refText: 'Hello.');
    expect(await repairVoiceEnds(people, whisper, temp), 0);
    expect(whisper.calls, 0);
  });

  test('a failed check leaves the voice to try again next launch', () async {
    final p = await legacy('just excitement and');
    whisper.error = const TranscriberError('worker died');
    expect(await repairVoiceEnds(people, whisper, temp), 0);
    final r = await refOf(p);
    expect(r.refText, 'just excitement and');
    expect(r.endChecked, isFalse);
  });

  test('an unreadable voice is skipped and the others are still checked', () async {
    final broken = await legacy('one two');
    File('${dir.path}/${broken.refFor(Mood.conversational).clipFile}').deleteSync();
    final other = await legacy('just excitement and');
    whisper.next = () => words('just');
    expect(await repairVoiceEnds(people, whisper, temp), 1);
    expect((await refOf(other)).refText, 'just');
    expect((await refOf(broken)).endChecked, isFalse);
  });

  test('nothing hearable leaves the words alone', () async {
    final p = await legacy('Hello.');
    whisper.next = () => const [];
    expect(await repairVoiceEnds(people, whisper, temp), 0);
    expect((await refOf(p)).refText, 'Hello.');
  });

  test('no decrypted copy is left behind', () async {
    await legacy('just excitement and');
    whisper.next = () => words('just');
    await repairVoiceEnds(people, whisper, temp);
    final cache = Directory('${dir.path}/cache');
    expect(cache.existsSync() ? cache.listSync(recursive: true).whereType<File>() : const [], isEmpty);
  });

  test('a voice replaced meanwhile is not overwritten', () async {
    final p = await legacy('old words');
    await people.setVoiceText(p.id, Mood.conversational, clipFile: 'refs/other.bin', refText: 'stale');
    expect((await refOf(p)).refText, 'old words');
  });

  test('voices saved before the check read as unchecked', () {
    final r = VoiceRef.fromJson({'clipFile': 'refs/a.bin', 'refText': 'Hi.', 'seconds': 5});
    expect(r.endChecked, isFalse);
    expect(VoiceRef.fromJson(const VoiceRef(clipFile: 'a', refText: 'b', seconds: 1).toJson()).endChecked, isTrue);
  });
}
