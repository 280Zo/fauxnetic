import '../audio/take_adjust.dart';
import '../recording/scripts.dart';

enum CueStatus { queued, preparing, ready, played, failed }

const kRetention = Duration(hours: 24);

/// One generated take of a line: its encrypted clip (relative to the app support directory) and seed.
class CueClip {
  const CueClip(this.file, this.seed, {this.engine, this.madeAt, this.adjust = TakeAdjust.defaults});
  final String file;
  final int seed;

  /// The voice model that made this take ("Qwen3-TTS", "OmniVoice"); null for takes stored before engines.
  final String? engine;

  /// When the take was made (UTC); null for takes stored before 2026-11-18.
  final DateTime? madeAt;

  /// How this take is played and shared (speed, pitch, pauses, volume).
  final TakeAdjust adjust;

  CueClip withAdjust(TakeAdjust a) => CueClip(file, seed, engine: engine, madeAt: madeAt, adjust: a);

  Map<String, Object?> toJson() => {
    'file': file,
    'seed': seed,
    'engine': ?engine,
    if (madeAt != null) 'madeAt': madeAt!.toIso8601String(),
    if (!adjust.isDefault) 'adjust': adjust.toJson(),
  };
  factory CueClip.fromJson(Map<String, Object?> j) => CueClip(
    j['file']! as String,
    j['seed']! as int,
    engine: j['engine'] as String?,
    madeAt: j['madeAt'] is String ? DateTime.tryParse(j['madeAt']! as String) : null,
    adjust: j['adjust'] is Map
        ? TakeAdjust.fromJson((j['adjust']! as Map).cast<String, Object?>())
        : TakeAdjust.defaults,
  );
}

class CueItem {
  const CueItem({
    required this.id,
    required this.personId,
    required this.text,
    required this.status,
    this.mood = Mood.conversational,
    this.seed = 1,
    this.attempts = 0,
    this.readyAt,
    this.clips = const [],
    this.current = 0,
    this.error,
    this.expiresAt,
    this.model,
  });

  /// The voice model (an id from kTtsModels) for the next take, picked when it was asked for, so
  /// changing the picker while a line waits or is being made doesn't change it. Null for lines
  /// stored before it existed: those use the current pick.
  final String? model;

  /// When every take of the line is deleted; set with the first take and never moved later.
  /// Null for lines stored before delete times existed: those use [readyAt] + [kRetention].
  final DateTime? expiresAt;

  final String id;
  final String personId;
  final String text;
  final CueStatus status;

  /// Chosen when the line was added.
  final Mood mood;

  /// Sampling seed for the next take (≥ 1). "Re-generate" gives the line a new one, and so new audio.
  final int seed;
  final int attempts;

  /// When the first take was generated; every take of the line expires [kRetention] after it.
  final DateTime? readyAt;

  /// Every take, oldest first; "Re-generate" adds one.
  final List<CueClip> clips;

  /// Index into [clips] of the take that is shown, played and shared.
  final int current;
  final String? error;

  /// The take shown, or null before the first one is ready.
  String? get clipFile => clips.isEmpty ? null : clips[current.clamp(0, clips.length - 1)].file;

  /// Ready or played: a generated clip that can be played, replayed or shared.
  bool get hasClip => status == CueStatus.ready || status == CueStatus.played;

  CueItem copyWith({
    CueStatus? status,
    int? seed,
    int? attempts,
    DateTime? readyAt,
    List<CueClip>? clips,
    int? current,
    String? error,
    bool clearError = false,
    DateTime? expiresAt,
    String? model,
  }) => CueItem(
    expiresAt: expiresAt ?? this.expiresAt,
    model: model ?? this.model,
    id: id,
    personId: personId,
    text: text,
    status: status ?? this.status,
    mood: mood,
    seed: seed ?? this.seed,
    attempts: attempts ?? this.attempts,
    readyAt: readyAt ?? this.readyAt,
    clips: clips ?? this.clips,
    current: current ?? this.current,
    error: clearError ? null : (error ?? this.error),
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'personId': personId,
    'text': text,
    'status': status.name,
    'mood': mood.name,
    'seed': seed,
    'attempts': attempts,
    'readyAt': readyAt?.toUtc().toIso8601String(),
    'clips': [for (final c in clips) c.toJson()],
    'current': current,
    'error': error,
    'expiresAt': expiresAt?.toUtc().toIso8601String(),
    'model': ?model,
  };

  factory CueItem.fromJson(Map<String, Object?> j) {
    final seed = (j['seed'] as int?) ?? 1;
    final old = j['clipFile'] as String?;
    final clips = j['clips'] is List
        ? [for (final c in j['clips']! as List<Object?>) CueClip.fromJson(c! as Map<String, Object?>)]
        // Stored before every take was kept: one clip, made with the line's seed.
        : [if (old != null) CueClip(old, seed)];
    return CueItem(
      id: j['id']! as String,
      personId: j['personId']! as String,
      text: j['text']! as String,
      status: CueStatus.values.byName(j['status']! as String),
      // Lines from before moods (2a) have none; a bad index must not stop the app starting.
      mood: Mood.values.byName((j['mood'] as String?) ?? Mood.conversational.name),
      seed: seed,
      attempts: j['attempts']! as int,
      readyAt: j['readyAt'] == null ? null : DateTime.parse(j['readyAt']! as String),
      clips: clips,
      current: ((j['current'] as int?) ?? 0).clamp(0, clips.isEmpty ? 0 : clips.length - 1),
      error: j['error'] as String?,
      expiresAt: j['expiresAt'] == null ? null : DateTime.parse(j['expiresAt']! as String),
      model: j['model'] as String?,
    );
  }
}

/// Every take of a line is kept for 24 hours after the first was generated, whatever the line's
/// status (a line waiting on "Re-generate" still holds earlier takes). A ready time in the future
/// means the clock moved backwards; treat it as expired rather than letting a clip outlive its
/// 24 hours.
bool isExpired(CueItem c, DateTime now) {
  if (c.readyAt == null) return false;
  final age = now.difference(c.readyAt!);
  if (age.isNegative || age >= kRetention) return true;
  final e = c.expiresAt;
  return e != null && !now.isBefore(e);
}
