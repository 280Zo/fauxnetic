import 'dart:io';
import 'dart:typed_data';

import 'package:fauxnetic/audio/wav.dart';
import 'package:fauxnetic/people/people_repo.dart';
import 'package:fauxnetic/people/person.dart';
import 'package:fauxnetic/recording/reference_builder.dart';
import 'package:fauxnetic/recording/scripts.dart';
import 'package:fauxnetic/storage/vault.dart';

/// The plain WAV every test reference holds: 5 s at 24 kHz.
Uint8List testRefWav() => encodeWav(Float32List.fromList(List.generate(24000 * 5, (i) => (i % 100) / 200.0)), 24000);

/// Stores an encrypted reference for [mood] and attaches it to the person.
Future<Person> addTestVoice(PeopleRepo people, Vault vault, Person p, Mood mood, {String refText = 'Hello.'}) async {
  final rel = 'refs/test-${p.id}-${mood.name}.bin';
  await vault.encryptBytes(testRefWav(), File('${people.dir.path}/$rel'));
  return people.setVoice(p.id, mood, VoiceRef(clipFile: rel, refText: refText, seconds: 5));
}

/// A person recorded live (so consented) with a conversational voice.
Future<Person> readyPerson(PeopleRepo people, Vault vault, {String name = 'Sam', String refText = 'Hello.'}) async =>
    addTestVoice(
      people,
      vault,
      await people.create(name, PersonSource.recorded),
      Mood.conversational,
      refText: refText,
    );
