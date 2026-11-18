import 'dart:math' as math;
import 'dart:typed_data';

import 'sonic.dart';
import 'take_adjust.dart';
import 'word_timing.dart';

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

/// [pcm] as the take is played and shared with [a]: pauses scaled (and, above 1x, added after the
/// punctuation in [words], the line's text), then speed and pitch (Sonic), loudness evened out,
/// volume, and the peaks kept under [_ceiling].
Float32List renderTake(Float32List pcm, int rate, TakeAdjust a, {List<String> words = const []}) {
  var x = scalePauses(pcm, rate, a.pauses, words: words);
  if (a.speed != 1 || a.pitch != 0) {
    x = sonicProcess(x, rate, speed: a.speed, pitch: math.pow(2, a.pitch / 12).toDouble());
  }
  if (a.normalize) x = normalizeSpeech(x, rate);
  if (a.gainDb != 0) x = _scaled(x, math.pow(10, a.gainDb / 20).toDouble());
  return _peak(x) > _knee ? _limited(x) : x;
}

/// The soft limiter's knee: quieter samples pass untouched.
const _knee = 0.7;

/// Squeezes only the peaks above [_knee] smoothly toward [_ceiling], so a volume boost is heard
/// instead of the whole take being turned back down.
Float32List _limited(Float32List x) {
  const room = _ceiling - _knee;
  final out = Float32List(x.length);
  for (var i = 0; i < x.length; i++) {
    final v = x[i], m = v.abs();
    out[i] = m <= _knee ? v : (v.sign * (_knee + room * _tanh((m - _knee) / room)));
  }
  return out;
}

double _tanh(double v) {
  final e = math.exp(2 * v);
  return (e - 1) / (e + 1);
}

/// Pause added after a word ending in this mark, per 1x of Pauses above 1x (so at 2.5x a period
/// gets 0.6 s). Models often run sentences together (Qwen, 2026-11-18: one pause in 8 s).
double _addedPause(String word) {
  final w = word.replaceAll(RegExp(r'''["”’')\]]+$'''), '');
  if (w.endsWith('...') || w.endsWith('…') || w.endsWith('—') || w.endsWith('-')) return 0.3;
  if (w.endsWith('.') || w.endsWith('?') || w.endsWith('!')) return 0.4;
  if (w.endsWith(',') || w.endsWith(';') || w.endsWith(':')) return 0.2;
  return 0;
}

/// Each pause of at least 120 ms inside the speech, scaled by [factor] around its middle (never
/// below 80 ms); a lengthened pause repeats its own quiet, so the room sound carries on. Above 1x,
/// a pause is also added after each punctuation mark in [words] that has none: at the quietest
/// 40 ms near where the word after it starts (estimated as for the word highlight), faded in and out.
Float32List scalePauses(Float32List pcm, int rate, double factor, {List<String> words = const []}) {
  if (factor == 1) return pcm;
  final n = (_frame * rate).round();
  final db = _frameDb(pcm, n);
  final top = db.fold(-double.infinity, math.max);
  final loud = [for (final d in db) d - top > _quietDb];
  final first = loud.indexOf(true), last = loud.lastIndexOf(true);
  if (first < 0) return pcm;
  // Edits on the original: (start, end, replacement length); an insert has start == end.
  final edits = <(int, int, int)>[];
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
      edits.add((a, b, math.max((_shortestPause * rate).round(), (length * factor).round())));
    }
    i = j;
  }
  if (factor > 1 && words.length > 1) {
    final seconds = pcm.length / rate;
    final peaks = [for (final d in db) math.pow(10, (d - top) / 20).toDouble()];
    final starts = estimateWordStarts(words, peaks, seconds);
    for (var k = 0; k < words.length - 1; k++) {
      final add = _addedPause(words[k]) * (factor - 1);
      if (add == 0) continue;
      final t = starts[k + 1];
      if (edits.any((e) => (e.$1 / rate - 0.2) <= t && t <= (e.$2 / rate + 0.2))) continue;
      // Quietest 40 ms (2 frames) in [t - 0.2 s, t + 0.1 s].
      final lo = math.max(0, ((t - 0.2) / _frame).floor()), hi = math.min(db.length - 2, ((t + 0.1) / _frame).ceil());
      var best = lo;
      for (var f = lo; f <= hi; f++) {
        if (db[f] + db[f + 1] < db[best] + db[best + 1]) best = f;
      }
      final at = (best + 1) * n;
      edits.add((at, at, (add * rate).round()));
    }
  }
  if (edits.isEmpty) return pcm;
  edits.sort((x, y) => x.$1.compareTo(y.$1));
  final out = <double>[];
  var copied = 0;
  final fade = (0.01 * rate).round();
  for (final (a, b, target) in edits) {
    if (a < copied) continue;
    out.addAll(pcm.sublist(copied, a));
    final length = b - a;
    if (length == 0) {
      // Fade the sound out into the added silence and back in after it.
      for (var k = 0; k < math.min(fade, out.length); k++) {
        out[out.length - 1 - k] *= k / fade;
      }
      out.addAll(List<double>.filled(target, 0));
      final resume = out.length;
      out.addAll(pcm.sublist(a, math.min(pcm.length, a + fade)));
      for (var k = 0; k < out.length - resume; k++) {
        out[resume + k] *= k / fade;
      }
      copied = math.min(pcm.length, a + fade);
      continue;
    }
    final mid = a + length ~/ 2;
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

/// Level of each [n]-sample frame in dB.
List<double> _frameDb(Float32List pcm, int n) {
  final frames = pcm.length ~/ n;
  final db = List<double>.filled(frames, 0);
  for (var f = 0; f < frames; f++) {
    var s = 0.0;
    for (var k = f * n; k < (f + 1) * n; k++) {
      s += pcm[k] * pcm[k];
    }
    db[f] = 10 * math.log(s / n + 1e-12) / math.ln10;
  }
  return db;
}

List<bool> _loudFrames(Float32List pcm, int n) {
  final db = _frameDb(pcm, n);
  final top = db.fold(-double.infinity, math.max);
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
