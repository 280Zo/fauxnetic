import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/recording/voice_cleaner.dart';

import '../support/signals.dart';

double _rmsDb(Float32List s) {
  var sum = 0.0;
  for (final v in s) {
    sum += v * v;
  }
  return 20 * log(sqrt(sum / s.length)) / ln10;
}

double _peak(Float32List s) => s.fold(0.0, (m, v) => max(m, v.abs()));

void main() {
  test('a quiet take is brought up so its speech is at -20 dBFS', () {
    final out = evenOutTake(Float32List.fromList(tone(2, -32)));
    expect(_rmsDb(out), closeTo(-20, 0.3));
  });

  test('a loud take is brought down', () {
    final out = evenOutTake(Float32List.fromList(tone(2, -12)));
    expect(_rmsDb(out), closeTo(-20, 0.3));
  });

  test('the pauses between words do not count as speech', () {
    // Speech at -30 between near-silent gaps: the speech, not the average, goes to -20.
    final out = evenOutTake(bursts(-30, -80));
    final word = Float32List.sublistView(out, 8000, 16000); // the first word, 0.5-1.0 s
    expect(_rmsDb(word), closeTo(-20, 0.5));
  });

  test('a take is never lifted into clipping', () {
    final pcm = Float32List.fromList(tone(2, -32))..[100] = 0.5;
    final out = evenOutTake(pcm);
    expect(_peak(out), lessThanOrEqualTo(0.9 + 1e-6));
    expect(out[100], closeTo(0.9, 1e-6), reason: 'lifted as far as the peak allows');
  });

  test('silence stays as it is', () {
    final pcm = Float32List(16000);
    expect(evenOutTake(pcm), pcm);
  });
}
