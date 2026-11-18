import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../recording/reference_builder.dart';
import '../recording/scripts.dart';
import '../recording/takes.dart';
import '../storage/temp_sweeper.dart';
import '../storage/vault.dart';
import 'person.dart';

class PersonInvalid implements Exception {
  const PersonInvalid(this.message);
  final String message;
  @override
  String toString() => message;
}

class ConsentRequired implements Exception {
  const ConsentRequired(this.personName);
  final String personName;
  @override
  String toString() => 'Confirm consent for $personName before using their voice.';
}

/// People, their encrypted per-mood references, and (through [TakeStore]) their raw takes.
class PeopleRepo {
  PeopleRepo(this.dir, this._vault, this._temp, this._takes);

  final Directory dir;
  final Vault _vault;
  final TempSweeper _temp;
  final TakeStore _takes;
  final _random = Random.secure();
  Future<void> _tail = Future.value();

  File get _index => File('${dir.path}/people.json');

  Future<T> _locked<T>(Future<T> Function() fn) {
    final result = _tail.then((_) => fn());
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<List<Person>> all() async {
    if (!await _index.exists()) return [];
    final raw = jsonDecode(utf8.decode(await _vault.decryptFile(_index))) as List<Object?>;
    return raw.map((e) => Person.fromJson(e! as Map<String, Object?>)).toList();
  }

  Future<void> _save(List<Person> people) =>
      _vault.encryptBytes(utf8.encode(jsonEncode(people.map((p) => p.toJson()).toList())), _index);

  String _newId() => List.generate(8, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

  /// Someone recorded live has consented by reading the script aloud; a person from a file
  /// needs [confirmConsent] before their voice can be used.
  ///
  /// The person is deleted [keepFor] after [now] (default: the 24-hour maximum).
  Future<Person> create(
    String name,
    PersonSource source, {
    DateTime? now,
    Duration keepFor = const Duration(hours: 24),
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw const PersonInvalid('Give this person a name.');
    final recorded = source == PersonSource.recorded;
    final at = (now ?? DateTime.now()).toUtc();
    final p = Person(
      id: _newId(),
      name: trimmed,
      source: source,
      consentConfirmedAt: recorded ? at : null,
      consentBasis: recorded ? ConsentBasis.readAloud : null,
      createdAt: at,
      expiresAt: at.add(keepFor),
    );
    await _locked(() async => _save([...await all(), p]));
    return p;
  }

  /// People saved before voices expired get their clock started now: a full [keepFor] from [now].
  Future<int> stampMissing(DateTime now, Duration keepFor) => _locked(() async {
    final people = await all();
    final n = people.where((p) => p.expiresAt == null).length;
    if (n > 0) {
      await _save([
        for (final p in people) p.expiresAt == null ? p.copyWith(createdAt: now, expiresAt: now.add(keepFor)) : p,
      ]);
    }
    return n;
  });

  /// A shorter keep-for moves delete times earlier (to createdAt + [keepFor]); it never moves one later.
  Future<int> shorten(Duration keepFor) => _locked(() async {
    final people = await all();
    var n = 0;
    final out = <Person>[];
    for (final p in people) {
      final created = p.createdAt, expires = p.expiresAt;
      if (created != null && expires != null && created.add(keepFor).isBefore(expires)) {
        out.add(p.copyWith(expiresAt: created.add(keepFor)));
        n++;
      } else {
        out.add(p);
      }
    }
    if (n > 0) await _save(out);
    return n;
  });

  Future<Person> _update(String id, Person Function(Person p) change, {Future<void> Function(Person old)? after}) =>
      _locked(() async {
        final people = await all();
        final i = people.indexWhere((p) => p.id == id);
        if (i < 0) throw const PersonInvalid('This person is no longer on the phone.');
        final old = people[i];
        people[i] = change(old);
        await _save(people);
        await after?.call(old);
        return people[i];
      });

  /// Attaches [ref] as the voice for [mood], deleting the reference it replaces.
  Future<Person> setVoice(String id, Mood mood, VoiceRef ref) => _update(
    id,
    (p) => p.copyWith(voices: {...p.voices, mood: ref}),
    after: (old) async {
      final previous = old.voices[mood];
      if (previous != null && previous.clipFile != ref.clipFile) await _deleteFile(previous.clipFile);
    },
  );

  /// Remembers the voice model picked for this voice on the Speak screen.
  Future<Person> setModel(String id, String model) => _update(id, (p) => p.copyWith(model: model));

  /// Sets the transcript of [mood]'s voice and marks its end checked, only while that voice is
  /// still [clipFile] (it may have been replaced while it was being checked).
  Future<Person> setVoiceText(String id, Mood mood, {required String clipFile, required String refText}) =>
      _update(id, (p) {
        final r = p.voices[mood];
        if (r == null || r.clipFile != clipFile) return p;
        return p.copyWith(
          voices: {
            ...p.voices,
            mood: VoiceRef(clipFile: clipFile, refText: refText, seconds: r.seconds),
          },
        );
      });

  Future<Person> confirmConsent(String id, {required bool ownVoice, required bool spokenConsent}) async {
    if (!ownVoice && !spokenConsent) {
      throw ArgumentError('Consent needs either "own voice" or "spoken consent".');
    }
    return _update(
      id,
      (p) => p.copyWith(
        consentConfirmedAt: DateTime.now().toUtc(),
        consentBasis: ownVoice ? ConsentBasis.ownVoice : ConsentBasis.spokenConsent,
      ),
    );
  }

  /// The reference for [mood] (or the conversational fallback) decrypted into a temp WAV; the
  /// caller must release it through the TempSweeper. The only place a voice is decrypted, so it
  /// is also the consent gate.
  Future<File> decryptedRef(Person p, Mood mood) async {
    if (!p.hasConsent) throw ConsentRequired(p.name);
    return _vault.decryptToTemp(File('${dir.path}/${p.refFor(mood).clipFile}'), _temp, '.wav');
  }

  Future<void> _deleteFile(String rel) async {
    final f = File('${dir.path}/$rel');
    if (await f.exists()) await f.delete();
  }

  /// Deletes reference files no person points to (one built while its person expired or a crash).
  Future<int> sweepOrphanRefs() => _locked(() async {
    final folder = Directory('${dir.path}/refs');
    if (!await folder.exists()) return 0;
    final known = {
      for (final p in await all())
        for (final r in p.voices.values) '${dir.path}/${r.clipFile}',
    };
    var n = 0;
    await for (final e in folder.list()) {
      if (e is File && !known.contains(e.path)) {
        await e.delete();
        n++;
      }
    }
    return n;
  });

  /// Removes the person, every mood reference and every raw take.
  Future<void> delete(String id) => _locked(() async {
    final people = await all();
    for (final p in people.where((p) => p.id == id)) {
      for (final r in p.voices.values) {
        await _deleteFile(r.clipFile);
      }
    }
    await _takes.deleteForPerson(id);
    await _save(people.where((p) => p.id != id).toList());
  });
}
