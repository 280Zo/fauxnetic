import 'dart:async';
import 'dart:typed_data';

import 'package:fauxnetic/engine/voice_engine.dart';
import 'package:fauxnetic/people/person.dart';
import 'package:fauxnetic/recording/scripts.dart';

/// Test engine: returns a short tone per call, or throws the scripted error for a given text.
class FakeEngine implements VoiceEngine {
  FakeEngine({this.failures = const {}});

  /// Text -> error thrown when that text is spoken (once per entry if [failOnce]).
  final Map<String, Object> failures;
  bool failOnce = false;
  final spoken = <String>[];

  /// One entry per prepare call: "personId mood".
  final prepared = <String>[];

  /// The model asked for in each prepare call (null: the current pick).
  final models = <String?>[];
  var loads = 0;

  @override
  int get sampleRate => 24000;

  @override
  Future<void> load() async => loads++;

  @override
  Future<void> prepare(Person p, Mood m, {String? model}) async {
    prepared.add('${p.id} ${m.name}');
    models.add(model);
    await onPrepare?.call();
    openModel = await modelFor(model);
  }

  @override
  String? openModel;

  /// Models that "aren't downloaded": a line asking for one is made with Qwen.
  final missing = <String>{};

  @override
  Future<String> modelFor(String? model) async => model == null || missing.contains(model) ? 'qwen' : model;

  /// Run inside prepare and speak, so a test can look at the state while a line is being made.
  Future<void> Function()? onPrepare;
  Future<void> Function()? onSpeak;

  /// Audio returned for a line; the default is one second of sawtooth.
  Float32List Function(String text)? audio;

  /// The seed of every speak call, in order.
  final seeds = <int>[];

  /// When set, the seed the "engine" ends up making a line with (as after a retry).
  int? retriedTo;

  @override
  int? lastSeed;

  @override
  Future<Float32List> speak(String text, {required int seed}) async {
    seeds.add(seed);
    lastSeed = retriedTo ?? seed;
    await onSpeak?.call();
    final f = failures[text];
    if (f != null) {
      if (failOnce) failures.remove(text);
      throw f;
    }
    spoken.add(text);
    return audio?.call(text) ?? Float32List.fromList(List.generate(24000, (i) => (i % 50) / 100.0));
  }

  var cancels = 0;

  /// Await [held] in onPrepare/onSpeak to keep a line "being made"; cancel fails it as cancelled.
  Completer<void> held = Completer<void>();

  @override
  Future<void> cancel() async {
    cancels++;
    if (held.isCompleted) return;
    // A cancel can come before anything awaits [held]; the error still reaches a later await.
    held.future.ignore();
    held.completeError(const EngineError(EngineErrorKind.cancelled, 'Stopped.'));
  }

  var disposed = 0;

  @override
  Future<void> dispose() async => disposed++;
}
