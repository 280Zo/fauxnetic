import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/audio/sonic.dart';

Float32List sine(double hz, double seconds, int rate, {double amp = 0.5}) =>
    Float32List.fromList([for (var i = 0; i < (seconds * rate).round(); i++) amp * sin(2 * pi * hz * i / rate)]);

/// Frequency from zero crossings over the middle 80 % (Sonic's edges ramp).
double frequency(Float32List x, int rate) {
  final a = (x.length * 0.1).round(), b = (x.length * 0.9).round();
  var crossings = 0;
  for (var i = a + 1; i < b; i++) {
    if ((x[i - 1] < 0) != (x[i] < 0)) crossings++;
  }
  return crossings / 2 / ((b - a) / rate);
}

void main() {
  test('speed changes length, not pitch', () {
    final out = sonicProcess(sine(200, 1, 24000), 24000, speed: 1.25);
    expect(out.length / 24000, closeTo(0.8, 0.8 * 0.02));
    expect(frequency(out, 24000), closeTo(200, 6));
  });

  test('pitch changes frequency, not length', () {
    final f = pow(2, 3 / 12).toDouble();
    final out = sonicProcess(sine(200, 1, 24000), 24000, pitch: f);
    expect(out.length / 24000, closeTo(1, 0.02));
    expect(frequency(out, 24000), closeTo(200 * f, 200 * f * 0.03));
  });

  test('slower and lower together', () {
    final f = pow(2, -2 / 12).toDouble();
    final out = sonicProcess(sine(220, 1, 24000), 24000, speed: 0.8, pitch: f);
    expect(out.length / 24000, closeTo(1.25, 1.25 * 0.02));
    expect(frequency(out, 24000), closeTo(220 * f, 220 * f * 0.03));
  });

  test('works at 48 kHz', () {
    final out = sonicProcess(sine(200, 1, 48000), 48000, speed: 0.8);
    expect(out.length / 48000, closeTo(1.25, 1.25 * 0.02));
    expect(frequency(out, 48000), closeTo(200, 6));
  });

  test('no change returns the same audio', () {
    final x = sine(200, 0.5, 24000);
    expect(sonicProcess(x, 24000), x);
  });
}
