import 'dart:async';
import 'dart:typed_data';

import 'package:fauxnetic/recording/recorder.dart';
import 'package:fauxnetic/recording/transcriber.dart';

/// A microphone the test feeds by hand.
class FakeMic implements MicSource {
  bool allowed = true;
  StreamController<Float32List>? _ctrl;
  var starts = 0;
  var stops = 0;

  bool get live => _ctrl != null && !_ctrl!.isClosed;

  @override
  Future<bool> hasPermission() async => allowed;

  @override
  Future<Stream<Float32List>> start() async {
    starts++;
    _ctrl = StreamController<Float32List>();
    return _ctrl!.stream;
  }

  @override
  Future<void> stop() async {
    stops++;
    await _ctrl?.close();
  }

  /// Sends [pcm] in chunks ([chunk] samples, half a second by default) and lets listeners run.
  /// Stops early once the controller has stopped the microphone (auto-stop).
  Future<void> say(Float32List pcm, {int chunk = 8000}) async {
    for (var i = 0; i < pcm.length; i += chunk) {
      if (!live) return;
      _ctrl!.add(Float32List.sublistView(pcm, i, i + chunk > pcm.length ? pcm.length : i + chunk));
      await settle();
    }
  }

  /// [seconds] of silence, in 0.1 s chunks so quiet time is measured finely.
  Future<void> pause(double seconds) => say(Float32List((seconds * 16000).round()), chunk: 1600);

  void fail() => _ctrl!.addError(StateError('microphone revoked'));
}

/// A transcriber whose answer the test sets.
class FakeTranscriber implements Transcriber {
  List<TimedWord> Function() next = () => const [];

  /// When set, answers from the audio itself (for example, fewer words for a cut take).
  List<TimedWord> Function(Float32List pcm16k)? nextFor;
  Object? error;
  var calls = 0;

  /// Seconds of audio in each call.
  final heardSeconds = <double>[];

  @override
  Future<void> load() async {}

  @override
  Future<List<TimedWord>> transcribe(Float32List pcm16k) async {
    calls++;
    heardSeconds.add(pcm16k.length / 16000);
    final e = error;
    if (e != null) throw e;
    return nextFor?.call(pcm16k) ?? next();
  }

  @override
  Future<void> dispose() async {}
}

List<TimedWord> words(String text, {double confidence = 0.9}) => [
  for (final (i, w) in text.split(' ').indexed) TimedWord(w, i * 0.4, i * 0.4 + 0.3, confidence),
];

/// Waits (real time, up to 5 s) until [done] holds, for work that touches files.
Future<void> until(bool Function() done) async {
  final sw = Stopwatch()..start();
  while (!done()) {
    if (sw.elapsed > const Duration(seconds: 5)) throw StateError('condition never held');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
