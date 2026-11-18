import 'dart:math' as math;

import '../engine/spoken_numbers.dart';

/// Below this share of the loudest frame, a frame is silence.
const _quiet = 0.1;

/// Silent runs this short (frames of [estimateWordStarts]) are inside a word, not a pause.
const _shortGap = 4;

/// When each of [words] starts in a clip [seconds] long, estimated from [levels] (the clip's peak
/// level per equal frame, loudest 1; 20 ms frames work well). The words share the clip's speech by
/// their spoken length (numbers as their words); silence before, between and after them is
/// skipped, so a pause holds the next word back. A clip with no speech spreads them evenly.
List<double> estimateWordStarts(List<String> words, List<double> levels, double seconds) {
  if (words.isEmpty) return const [];
  final n = levels.length;
  final voiced = [for (final l in levels) l >= _quiet];
  // Close short gaps between voiced frames.
  var i = 0;
  while (i < n) {
    if (voiced[i]) {
      i++;
      continue;
    }
    var j = i;
    while (j < n && !voiced[j]) {
      j++;
    }
    if (i > 0 && j < n && j - i < _shortGap) {
      for (var k = i; k < j; k++) {
        voiced[k] = true;
      }
    }
    i = j;
  }
  final speech = [
    for (var k = 0; k < n; k++)
      if (voiced[k]) k,
  ];
  final frames = speech.isEmpty ? [for (var k = 0; k < n; k++) k] : speech;
  final weights = [for (final w in words) math.max(2, _letters(spokenNumbers(w)))];
  final total = weights.fold<int>(0, (a, b) => a + b);
  final starts = <double>[];
  var before = 0;
  for (final w in weights) {
    final at = frames.isEmpty ? 0 : frames[math.min(frames.length - 1, before * frames.length ~/ total)];
    starts.add(n == 0 ? 0 : at * seconds / n);
    before += w;
  }
  return starts;
}

int _letters(String s) => RegExp('[A-Za-z]').allMatches(s).length;

/// The word being spoken at [t] seconds: the last of [starts] at or before it, -1 before the first.
int activeWord(List<double> starts, double t) {
  var a = -1;
  for (var k = 0; k < starts.length && starts[k] <= t; k++) {
    a = k;
  }
  return a;
}
