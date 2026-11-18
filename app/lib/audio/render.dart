import 'dart:math' as math;
import 'dart:typed_data';

import 'sonic.dart';
import 'take_adjust.dart';

/// 20 ms frames; quieter than this below the loudest frame is silence (as the pause finder and
/// the word highlight).
const _frame = 0.02;
const _quietDb = -35.0;

/// Pauses this long or longer are the ones the Pauses setting scales.
const _minPause = 0.12;

/// A shortened pause never gets shorter than this, so words don't run together.
const _shortestPause = 0.08;

/// Speech is brought to this RMS (-20 dBFS) by "Even out loudness".
const _targetRms = 0.1;

/// Highest sample level after rendering.
const _ceiling = 0.98;

/// [pcm] as the take is played and shared with [a]: pauses scaled, then speed and pitch (Sonic),
/// loudness evened out, volume, and the peak kept under [_ceiling].
Float32List renderTake(Float32List pcm, int rate, TakeAdjust a) {
  var x = scalePauses(pcm, rate, a.pauses);
  if (a.speed != 1 || a.pitch != 0) {
    x = sonicProcess(x, rate, speed: a.speed, pitch: math.pow(2, a.pitch / 12).toDouble());
  }
  if (a.normalize) x = normalizeSpeech(x, rate);
  if (a.gainDb != 0) x = _scaled(x, math.pow(10, a.gainDb / 20).toDouble());
  final peak = _peak(x);
  return peak > _ceiling ? _scaled(x, _ceiling / peak) : x;
}

/// Each pause of at least 120 ms inside the speech, scaled by [factor] around its middle (never
/// below 80 ms). A lengthened pause repeats its own quiet, so the room sound carries on.
Float32List scalePauses(Float32List pcm, int rate, double factor) {
  if (factor == 1) return pcm;
  final n = (_frame * rate).round();
  final loud = _loudFrames(pcm, n);
  final first = loud.indexOf(true), last = loud.lastIndexOf(true);
  if (first < 0) return pcm;
  final out = <double>[];
  var copied = 0;
  var i = first;
  while (i <= last) {
    if (loud[i]) {
      i++;
      continue;
    }
    var j = i;
    while (j <= last && !loud[j]) {
      j++;
    }
    final a = i * n, b = j * n, length = b - a;
    if (length >= _minPause * rate) {
      final target = math.max((_shortestPause * rate).round(), (length * factor).round());
      final mid = a + length ~/ 2;
      out.addAll(pcm.sublist(copied, a));
      if (target >= length) {
        out.addAll(pcm.sublist(a, mid));
        for (var k = 0; k < target - length; k++) {
          out.add(pcm[a + k % length]);
        }
        out.addAll(pcm.sublist(mid, b));
      } else {
        final cut = length - target;
        out.addAll(pcm.sublist(a, mid - cut ~/ 2));
        out.addAll(pcm.sublist(mid - cut ~/ 2 + cut, b));
      }
      copied = b;
    }
    i = j;
  }
  out.addAll(pcm.sublist(copied));
  return Float32List.fromList(out);
}

/// [pcm] scaled so its speech (the frames within 35 dB of the loudest) has an RMS of -20 dBFS, and
/// scaled down again if that would push a peak past [_ceiling].
Float32List normalizeSpeech(Float32List pcm, int rate) {
  final n = (_frame * rate).round();
  final loud = _loudFrames(pcm, n);
  var sum = 0.0, count = 0;
  for (var f = 0; f < loud.length; f++) {
    if (!loud[f]) continue;
    for (var k = f * n; k < math.min(pcm.length, (f + 1) * n); k++) {
      sum += pcm[k] * pcm[k];
      count++;
    }
  }
  if (count == 0 || sum == 0) return pcm;
  var gain = _targetRms / math.sqrt(sum / count);
  final peak = _peak(pcm);
  if (peak * gain > _ceiling) gain = _ceiling / peak;
  return _scaled(pcm, gain);
}

List<bool> _loudFrames(Float32List pcm, int n) {
  final frames = pcm.length ~/ n;
  final db = List<double>.filled(frames, 0);
  var top = -double.infinity;
  for (var f = 0; f < frames; f++) {
    var s = 0.0;
    for (var k = f * n; k < (f + 1) * n; k++) {
      s += pcm[k] * pcm[k];
    }
    db[f] = 10 * math.log(s / n + 1e-12) / math.ln10;
    if (db[f] > top) top = db[f];
  }
  return [for (final d in db) d - top > _quietDb];
}

double _peak(Float32List x) {
  var p = 0.0;
  for (final v in x) {
    if (v.abs() > p) p = v.abs();
  }
  return p;
}

Float32List _scaled(Float32List x, double g) {
  final out = Float32List(x.length);
  for (var i = 0; i < x.length; i++) {
    out[i] = x[i] * g;
  }
  return out;
}
