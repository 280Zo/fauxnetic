import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/people/people_repo.dart';
import 'package:fauxnetic/people/person.dart';
import 'package:fauxnetic/recording/reference_builder.dart';
import 'package:fauxnetic/recording/scripts.dart';
import 'package:fauxnetic/recording/takes.dart';
import 'package:fauxnetic/storage/temp_sweeper.dart';
import 'package:fauxnetic/storage/vault.dart';

import '../support/keys.dart';
import '../support/people.dart';

void main() {
  late Directory dir;
  late Vault vault;
  late TakeStore takes;
  late PeopleRepo repo;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('people');
    vault = Vault(FixedKeyStore());
    takes = TakeStore(dir, vault);
    repo = PeopleRepo(dir, vault, TempSweeper(Directory('${dir.path}/tmp')), takes);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('a voice remembers its model', () async {
    final p = await repo.create('Sam', PersonSource.recorded);
    expect(p.model, isNull, reason: 'follows the default until picked');
    await repo.setModel(p.id, 'voxcpm');
    expect((await repo.all()).single.model, 'voxcpm');
    final json = (await repo.all()).single.toJson()..remove('model');
    expect(Person.fromJson(json).model, isNull, reason: 'people saved before it read');
  });

  test('recorded person has consent', () async {
    final p = await repo.create(' Sam ', PersonSource.recorded);
    expect(p.name, 'Sam');
    expect(p.hasConsent, isTrue);
    expect(p.consentBasis, ConsentBasis.readAloud);
    expect(p.ready, isFalse);
    expect((await repo.all()).single.id, p.id);
  });

  final t = DateTime.utc(2026, 11, 15, 12);

  test('new people get a delete time from the setting', () async {
    final p = await repo.create('Sam', PersonSource.recorded, now: t, keepFor: const Duration(hours: 1));
    expect(p.createdAt, t);
    expect(p.expiresAt, t.add(const Duration(hours: 1)));
    final back = (await repo.all()).single;
    expect([back.createdAt, back.expiresAt], [t, t.add(const Duration(hours: 1))]);
  });

  test('people saved before delete times get a full day from now', () async {
    // An index written by the previous version: no createdAt / expiresAt.
    final old = const Person(id: 'p', name: 'Sam', source: PersonSource.recorded).toJson()
      ..remove('createdAt')
      ..remove('expiresAt');
    await vault.encryptBytes(utf8.encode(jsonEncode([old])), File('${dir.path}/people.json'));
    expect((await repo.all()).single.expiresAt, isNull);
    final later = t.add(const Duration(hours: 3));
    expect(await repo.stampMissing(later, const Duration(hours: 24)), 1);
    final p = (await repo.all()).single;
    expect(p.createdAt, later);
    expect(p.expiresAt, later.add(const Duration(hours: 24)));
    expect(await repo.stampMissing(later.add(const Duration(hours: 1)), const Duration(hours: 24)), 0);
  });

  test('adding a voice never moves the delete time', () async {
    final p = await repo.create('Sam', PersonSource.recorded, now: t, keepFor: const Duration(hours: 24));
    final withVoice = await addTestVoice(repo, vault, p, Mood.excited, refText: 'Wow!');
    expect(withVoice.expiresAt, p.expiresAt);
  });

  test('shortening moves delete times earlier, lengthening never later', () async {
    await repo.create('Sam', PersonSource.recorded, now: t, keepFor: const Duration(hours: 24));
    expect(await repo.shorten(const Duration(hours: 1)), 1);
    expect((await repo.all()).single.expiresAt, t.add(const Duration(hours: 1)));
    expect(await repo.shorten(const Duration(hours: 24)), 0);
    expect((await repo.all()).single.expiresAt, t.add(const Duration(hours: 1)));
  });

  test('a voice made in the future counts as expired (clock moved back)', () {
    final now = t;
    const day = Duration(hours: 24);
    Person made(DateTime created, DateTime? e) =>
        Person(id: 'p', name: 'Sam', source: PersonSource.recorded, createdAt: created, expiresAt: e);
    expect(
      isPersonExpired(made(now.add(const Duration(hours: 6)), now.add(const Duration(hours: 30))), now, day),
      isTrue,
    );
    expect(isPersonExpired(made(now, now), now, day), isTrue);
    expect(isPersonExpired(made(now, now.add(const Duration(minutes: 1))), now, day), isFalse);
    expect(isPersonExpired(made(now, null), now, day), isFalse, reason: 'not stamped yet');
  });

  test('a shorter setting never deletes a young voice before its delete times are moved', () {
    // Settings switched to 1 h, but shorten() hasn't run yet: a 10-minute-old voice still says 24 h.
    final created = t.subtract(const Duration(minutes: 10));
    final p = Person(
      id: 'p',
      name: 'Sam',
      source: PersonSource.recorded,
      createdAt: created,
      expiresAt: created.add(const Duration(hours: 24)),
    );
    expect(isPersonExpired(p, t, const Duration(hours: 1)), isFalse);
    expect(isPersonExpired(p, created.add(const Duration(hours: 1)), const Duration(hours: 1)), isTrue);
  });

  test('reference files no person points to are swept', () async {
    final sam = await readyPerson(repo, vault);
    final kept = File('${dir.path}/${sam.refFor(Mood.conversational).clipFile}');
    final stray = File('${dir.path}/refs/stray.bin')..writeAsBytesSync([1]);
    expect(await repo.sweepOrphanRefs(), 1);
    expect(stray.existsSync(), isFalse);
    expect(kept.existsSync(), isTrue);
    await repo.delete(sam.id);
    expect(await repo.sweepOrphanRefs(), 0);
    expect(Directory('${dir.path}/refs').listSync(), isEmpty);
  });

  test('a name is required', () async {
    await expectLater(
      repo.create('  ', PersonSource.recorded),
      throwsA(isA<PersonInvalid>().having((e) => e.message, 'm', 'Give this person a name.')),
    );
    expect(await repo.all(), isEmpty);
  });

  test('upload person needs consent before decryptedRef', () async {
    var p = await repo.create('Sam', PersonSource.upload);
    expect(p.hasConsent, isFalse);
    p = await addTestVoice(repo, vault, p, Mood.conversational);
    await expectLater(repo.decryptedRef(p, Mood.conversational), throwsA(isA<ConsentRequired>()));
    await expectLater(repo.confirmConsent(p.id, ownVoice: false, spokenConsent: false), throwsArgumentError);
    p = await repo.confirmConsent(p.id, ownVoice: false, spokenConsent: true);
    expect(p.consentBasis, ConsentBasis.spokenConsent);
    final tmp = await repo.decryptedRef(p, Mood.conversational);
    expect(tmp.readAsBytesSync(), testRefWav());
  });

  test('decryptedRef uses the mood or falls back to conversational', () async {
    var p = await readyPerson(repo, vault);
    p = await addTestVoice(repo, vault, p, Mood.excited, refText: 'Wow!');
    expect(p.refFor(Mood.excited).refText, 'Wow!');
    expect((await repo.decryptedRef(p, Mood.worried)).existsSync(), isTrue);
  });

  test('setVoice replaces the old reference file', () async {
    final p = await readyPerson(repo, vault);
    final old = File('${dir.path}/${p.refFor(Mood.conversational).clipFile}');
    const replacement = 'refs/new.bin';
    await vault.encryptBytes(testRefWav(), File('${dir.path}/$replacement'));
    final updated = await repo.setVoice(
      p.id,
      Mood.conversational,
      const VoiceRef(clipFile: replacement, refText: 'Again.', seconds: 5),
    );
    expect(updated.refFor(Mood.conversational).clipFile, replacement);
    expect(old.existsSync(), isFalse);
  });

  test('delete removes takes and refs', () async {
    var p = await readyPerson(repo, vault);
    p = await addTestVoice(repo, vault, p, Mood.excited);
    await takes.save(p.id, Mood.conversational, Float32List(1600), text: 'Hi.', fromScript: true, score: 1);
    final other = await readyPerson(repo, vault, name: 'Ana');
    final refs = p.voices.values.map((r) => File('${dir.path}/${r.clipFile}')).toList();
    await repo.delete(p.id);
    expect((await repo.all()).map((x) => x.id), [other.id]);
    expect(refs.every((f) => !f.existsSync()), isTrue);
    expect(await takes.forPerson(p.id), isEmpty);
    expect(File('${dir.path}/${other.refFor(Mood.conversational).clipFile}').existsSync(), isTrue);
  });

  test('concurrent changes are not lost', () async {
    await Future.wait([
      for (final n in ['A', 'B', 'C']) repo.create(n, PersonSource.recorded),
    ]);
    final people = await repo.all();
    expect(people.map((p) => p.name).toSet(), {'A', 'B', 'C'});
    await Future.wait([for (final p in people) addTestVoice(repo, vault, p, Mood.conversational)]);
    expect((await repo.all()).every((p) => p.ready), isTrue);
  });

  test('index is encrypted at rest', () async {
    await readyPerson(repo, vault, name: 'Samantha Quill', refText: 'A very particular sentence.');
    final raw = String.fromCharCodes(File('${dir.path}/people.json').readAsBytesSync());
    expect(raw.contains('Samantha'), isFalse);
    expect(raw.contains('particular'), isFalse);
  });

  test('records persist across repo instances', () async {
    final p = await readyPerson(repo, vault);
    final again = PeopleRepo(dir, Vault(FixedKeyStore()), TempSweeper(dir), takes);
    expect((await again.all()).single.refFor(Mood.conversational).refText, p.refFor(Mood.conversational).refText);
  });

  test('changing an unknown person fails clearly', () async {
    await expectLater(repo.confirmConsent('nope', ownVoice: true, spokenConsent: false), throwsA(isA<PersonInvalid>()));
  });
}
