import '../recording/reference_builder.dart';
import '../recording/scripts.dart';

/// How the person's voice reached the phone.
enum PersonSource { recorded, upload }

/// What the consent rests on: reading the script aloud, or the owner's confirmation for a file.
enum ConsentBasis { readAloud, ownVoice, spokenConsent }

class Person {
  const Person({
    required this.id,
    required this.name,
    required this.source,
    this.consentConfirmedAt,
    this.consentBasis,
    this.voices = const {},
    this.createdAt,
    this.expiresAt,
    this.model,
  });

  /// The voice model picked for this voice on the Speak screen (an id from kTtsModels); null
  /// follows the default model in Settings.
  final String? model;

  final String id;
  final String name;
  final PersonSource source;

  /// UTC. Null only for people saved before voices expired, until [PeopleRepo.stampMissing] runs.
  final DateTime? createdAt;

  /// When the person, their voices, recordings and lines are deleted. Fixed when they are created;
  /// only a shorter keep-for setting moves it (earlier, never later).
  final DateTime? expiresAt;
  final DateTime? consentConfirmedAt;
  final ConsentBasis? consentBasis;
  final Map<Mood, VoiceRef> voices;

  bool get hasConsent => consentConfirmedAt != null;

  /// The conversational voice is the base every other mood falls back to.
  bool get ready => voices.containsKey(Mood.conversational);

  bool recorded(Mood m) => voices.containsKey(m);

  VoiceRef refFor(Mood m) =>
      voices[m] ?? voices[Mood.conversational] ?? (throw StateError('$name has no voice recorded yet.'));

  Person copyWith({
    DateTime? consentConfirmedAt,
    ConsentBasis? consentBasis,
    Map<Mood, VoiceRef>? voices,
    DateTime? createdAt,
    DateTime? expiresAt,
    String? model,
  }) => Person(
    id: id,
    name: name,
    source: source,
    model: model ?? this.model,
    consentConfirmedAt: consentConfirmedAt ?? this.consentConfirmedAt,
    consentBasis: consentBasis ?? this.consentBasis,
    voices: voices ?? this.voices,
    createdAt: createdAt ?? this.createdAt,
    expiresAt: expiresAt ?? this.expiresAt,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'source': source.name,
    'consentConfirmedAt': consentConfirmedAt?.toUtc().toIso8601String(),
    'consentBasis': consentBasis?.name,
    'voices': {for (final e in voices.entries) e.key.name: e.value.toJson()},
    'createdAt': createdAt?.toUtc().toIso8601String(),
    'expiresAt': expiresAt?.toUtc().toIso8601String(),
    'model': ?model,
  };

  factory Person.fromJson(Map<String, Object?> j) => Person(
    id: j['id']! as String,
    name: j['name']! as String,
    source: PersonSource.values.byName(j['source']! as String),
    consentConfirmedAt: j['consentConfirmedAt'] == null ? null : DateTime.parse(j['consentConfirmedAt']! as String),
    consentBasis: j['consentBasis'] == null ? null : ConsentBasis.values.byName(j['consentBasis']! as String),
    voices: {
      for (final e in ((j['voices'] as Map<String, Object?>?) ?? const {}).entries)
        Mood.values.byName(e.key): VoiceRef.fromJson(e.value! as Map<String, Object?>),
    },
    createdAt: j['createdAt'] == null ? null : DateTime.parse(j['createdAt']! as String),
    expiresAt: j['expiresAt'] == null ? null : DateTime.parse(j['expiresAt']! as String),
    model: j['model'] as String?,
  );
}

/// Due for deletion once [now] reaches the earlier of its delete time and createdAt + [keepFor], or
/// when [now] is before it was created (the clock moved backwards). Doesn't depend on whether a
/// shorter setting has been applied to the stored delete time yet. People not stamped yet are never
/// expired.
bool isPersonExpired(Person p, DateTime now, Duration keepFor) {
  final e = p.expiresAt, c = p.createdAt;
  if (e == null || c == null) return false;
  final byKeep = c.add(keepFor);
  final due = byKeep.isBefore(e) ? byKeep : e;
  return !now.isBefore(due) || now.isBefore(c);
}
