/// How one take is played and shared: speed, pitch (semitones), pause length, volume and whether its
/// loudness is evened out. Stored on the take; [defaults] leaves only loudness evened out.
class TakeAdjust {
  const TakeAdjust({this.speed = 1, this.pitch = 0, this.pauses = 1, this.gainDb = 0, this.normalize = true});

  /// Values limited to the panel's ranges.
  factory TakeAdjust.clamped({
    double speed = 1,
    double pitch = 0,
    double pauses = 1,
    double gainDb = 0,
    bool normalize = true,
  }) => TakeAdjust(
    speed: speed.clamp(minSpeed, maxSpeed).toDouble(),
    pitch: pitch.clamp(-maxPitch, maxPitch).toDouble(),
    pauses: pauses.clamp(minPauses, maxPauses).toDouble(),
    gainDb: gainDb.clamp(minGainDb, maxGainDb).toDouble(),
    normalize: normalize,
  );

  static const minSpeed = 0.75, maxSpeed = 1.5;
  static const maxPitch = 3.0;
  static const minPauses = 0.5, maxPauses = 2.5;

  /// Owner, 2026-11-18: "the volume needs a much higher max". The limiter keeps big boosts from
  /// clipping (they get louder and more compressed).
  static const minGainDb = -12.0, maxGainDb = 20.0;
  static const defaults = TakeAdjust();

  final double speed;
  final double pitch;
  final double pauses;
  final double gainDb;
  final bool normalize;

  bool get isDefault => this == defaults;

  TakeAdjust copyWith({double? speed, double? pitch, double? pauses, double? gainDb, bool? normalize}) =>
      TakeAdjust.clamped(
        speed: speed ?? this.speed,
        pitch: pitch ?? this.pitch,
        pauses: pauses ?? this.pauses,
        gainDb: gainDb ?? this.gainDb,
        normalize: normalize ?? this.normalize,
      );

  Map<String, Object?> toJson() => {
    'speed': speed,
    'pitch': pitch,
    'pauses': pauses,
    'gainDb': gainDb,
    'normalize': normalize,
  };

  factory TakeAdjust.fromJson(Map<String, Object?> j) {
    double d(String k, double fallback) => (j[k] as num?)?.toDouble() ?? fallback;
    return TakeAdjust.clamped(
      speed: d('speed', 1),
      pitch: d('pitch', 0),
      pauses: d('pauses', 1),
      gainDb: d('gainDb', 0),
      normalize: j['normalize'] as bool? ?? true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TakeAdjust &&
      other.speed == speed &&
      other.pitch == pitch &&
      other.pauses == pauses &&
      other.gainDb == gainDb &&
      other.normalize == normalize;

  @override
  int get hashCode => Object.hash(speed, pitch, pauses, gainDb, normalize);
}
