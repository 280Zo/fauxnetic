import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/people/person.dart';
import 'package:fauxnetic/recording/reference_builder.dart';
import 'package:fauxnetic/recording/scripts.dart';

const conv = VoiceRef(clipFile: 'refs/c.bin', refText: 'Hello there.', seconds: 9);
const excited = VoiceRef(clipFile: 'refs/e.bin', refText: 'Wow!', seconds: 4);

Person person({
  PersonSource source = PersonSource.recorded,
  Map<Mood, VoiceRef> voices = const {},
  DateTime? consent,
}) => Person(id: 'a1', name: 'Sam', source: source, consentConfirmedAt: consent, voices: voices);

void main() {
  test('ready only with conversational voice', () {
    expect(person().ready, isFalse);
    expect(person(voices: {Mood.excited: excited}).ready, isFalse);
    expect(person(voices: {Mood.conversational: conv}).ready, isTrue);
  });

  test('refFor falls back to conversational', () {
    final p = person(voices: {Mood.conversational: conv, Mood.excited: excited});
    expect(p.refFor(Mood.excited), excited);
    expect(p.refFor(Mood.worried), conv);
    expect(p.recorded(Mood.excited), isTrue);
    expect(p.recorded(Mood.worried), isFalse);
    expect(() => person().refFor(Mood.conversational), throwsStateError);
  });

  test('consent follows the confirmation time', () {
    expect(person(source: PersonSource.upload).hasConsent, isFalse);
    expect(person(source: PersonSource.upload, consent: DateTime.utc(2026)).hasConsent, isTrue);
  });

  test('json round trip', () {
    final p = Person(
      id: 'a1',
      name: 'Sam',
      source: PersonSource.upload,
      consentConfirmedAt: DateTime.utc(2026, 11, 15, 12),
      consentBasis: ConsentBasis.spokenConsent,
      voices: const {Mood.conversational: conv, Mood.excited: excited},
    );
    final back = Person.fromJson(p.toJson());
    expect(back.toJson(), p.toJson());
    expect(back.voices[Mood.excited]!.refText, 'Wow!');
    expect(Person.fromJson({...p.toJson(), 'consentConfirmedAt': null}).hasConsent, isFalse);
  });
}
