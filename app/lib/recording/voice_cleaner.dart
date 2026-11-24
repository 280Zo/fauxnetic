import 'dart:ffi';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crispasr/crispasr.dart';

/// Cleans one finished take (16 kHz mono) before it is checked and kept.
typedef TakeCleaner = Future<Float32List> Function(Float32List pcm16k);

const _frame = 320; // 20 ms at 16 kHz
const _speechWithinDb = 35.0;
const _targetDb = -20.0;
const _maxPeak = 0.9;

/// [pcm] scaled so its speech (20 ms frames within 35 dB of the loudest) has an RMS of -20 dBFS,
/// the owner's home takes' speech level, but never so far that a peak passes 0.9.
Float32List evenOutTake(Float32List pcm) {
  final frames = pcm.length ~/ _frame;
  final energy = List<double>.generate(frames, (f) {
    var s = 0.0;
    for (var i = f * _frame; i < (f + 1) * _frame; i++) {
      s += pcm[i] * pcm[i];
    }
    return s / _frame;
  });
  final top = energy.fold(0.0, max);
  if (top <= 0) return pcm;
  final floor = top * pow(10, -_speechWithinDb / 10);
  var sum = 0.0, count = 0;
  for (final e in energy) {
    if (e < floor) continue;
    sum += e;
    count++;
  }
  final peak = pcm.fold(0.0, (m, v) => max(m, v.abs()));
  final gain = min(pow(10, _targetDb / 20) / sqrt(sum / count), _maxPeak / peak);
  return Float32List.fromList([for (final v in pcm) v * gain]);
}

/// RNNoise (as uploads are cleaned), off the UI thread. Where the native cleaner is missing or
/// fails, the audio comes back as it was: a take is never lost to it.
Future<Float32List> rnnoiseDenoise(Float32List pcm16k) async {
  try {
    return await Isolate.run(() => enhanceAudioRnnoise(pcm16k, lib: DynamicLibrary.open('libcrispasr.so')));
  } catch (_) {
    return pcm16k;
  }
}

/// A finished take: RNNoise, then the loudness evened out.
Future<Float32List> rnnoiseCleaner(Float32List pcm16k) async => evenOutTake(await rnnoiseDenoise(pcm16k));

/// Cleans the microphone as it comes in, for the level bars (owner, 2026-11-23: with the cleaner
/// on, the bars still showed the noise). RNNoise starts afresh on each call and needs a moment to
/// learn the noise, so each chunk is cleaned with the second before it and only its own part is
/// kept. Results come back in order; a failure, or cleaning that falls behind, gives the chunk back
/// as it was.
class LiveDenoiser {
  LiveDenoiser(this._denoise);
  final Future<Float32List> Function(Float32List) _denoise;

  static const _context = 16000;
  static const _maxPending = 3;

  var _past = Float32List(0);
  var _pending = 0;
  Future<void> _tail = Future.value();

  Future<Float32List> add(Float32List chunk) {
    final window = Float32List(_past.length + chunk.length)
      ..setAll(0, _past)
      ..setAll(_past.length, chunk);
    _past = Float32List.fromList(window.length > _context ? window.sublist(window.length - _context) : window);
    if (_pending >= _maxPending) return Future.value(chunk);
    _pending++;
    final done = _tail.then((_) async {
      try {
        final out = await _denoise(window);
        return out.length >= chunk.length ? Float32List.sublistView(out, out.length - chunk.length) : chunk;
      } catch (_) {
        return chunk;
      } finally {
        _pending--;
      }
    });
    _tail = done;
    return done;
  }
}
