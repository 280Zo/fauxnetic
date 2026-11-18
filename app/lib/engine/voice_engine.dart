import 'dart:typed_data';

import '../people/person.dart';
import '../recording/scripts.dart';

/// [cancelled]: the line was stopped on purpose (it was removed); not a failure to show.
enum EngineErrorKind {
  outOfMemory,
  modelMissing,
  voiceRejected,
  synthesisFailed,
  cancelled,

  /// The engine stopped a Qwen line that had gone wrong (silent too long, or ran to its limit); the
  /// line is remade with another seed.
  ranAway,
}

class EngineError implements Exception {
  const EngineError(this.kind, this.message);
  final EngineErrorKind kind;
  final String message;
  @override
  String toString() => message;
}

abstract class VoiceEngine {
  /// Checks the models and starts the worker; cheap when already started.
  Future<void> load();

  /// Gets ready to speak as [p] in [m]: opens the talker once and sets the voice only when the
  /// reference changed. Waits for any line in progress. [model] (an id from kTtsModels) is the
  /// line's own model; null means the current pick.
  Future<void> prepare(Person p, Mood m, {String? model});

  /// [seed] (≥ 1) picks the sampling path: the same seed gives the same audio, another seed different audio.
  Future<Float32List> speak(String text, {required int seed});
  int get sampleRate;

  /// The seed that made the latest line: [speak]'s seed, or a retry's when that attempt went wrong.
  int? get lastSeed;

  /// Stops the line being made at once (it was removed): the call in progress fails with
  /// [EngineErrorKind.cancelled] and the next line starts a fresh engine. Does nothing when idle.
  Future<void> cancel();

  /// Id of the model that made (or is making) the latest line; null before the first.
  String? get openModel;

  /// The model a line asking for [model] will really be made with: the default when [model] is
  /// null or no longer downloaded.
  Future<String> modelFor(String? model);
  Future<void> dispose();
}
