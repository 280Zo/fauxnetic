import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/audio/render.dart';
import 'package:fauxnetic/audio/take_adjust.dart';

Float32List tone(double seconds, int rate, {double amp = 0.5}) =>
    Float32List.fromList([for (var i = 0; i < (seconds * rate).round(); i++) amp * sin(2 * pi * 220 * i / rate)]);

Float32List join(List<Float32List> parts) {
  final out = Float32List(parts.fold(0, (n, p) => n + p.length));
  var o = 0;
  for (final p in parts) {
    out.setAll(o, p);
    o += p.length;
  }
  return out;
}

Float32List silence(double seconds, int rate) => Float32List((seconds * rate).round());

double dbfs(Float32List x) => 20 * log(sqrt(x.fold<double>(0, (s, v) => s + v * v) / x.length)) / ln10;

void main() {
  const r = 24000;

  test('scalePauses doubles a gap', () {
    final x = join([tone(0.4, r), silence(0.3, r), tone(0.4, r)]);
    final out = scalePauses(x, r, 2);
    expect((out.length - x.length) / r, closeTo(0.3, 0.02));
  });

  test('scalePauses never shortens below 80 ms', () {
    final x = join([tone(0.4, r), silence(0.12, r), tone(0.4, r)]);
    final out = scalePauses(x, r, 0.5);
    expect((x.length - out.length) / r, lessThanOrEqualTo(0.04 + 0.005));
  });

  test('scalePauses works at 48 kHz', () {
    const r48 = 48000;
    final x = join([tone(0.4, r48), silence(0.3, r48), tone(0.4, r48)]);
    expect((scalePauses(x, r48, 2).length - x.length) / r48, closeTo(0.3, 0.02));
  });

  test('no pauses, pauses setting is a no-op', () {
    final x = tone(1, r);
    expect(scalePauses(x, r, 2).length, x.length);
  });

  test('normalize brings a quiet take to -20 dBFS', () {
    final out = normalizeSpeech(tone(1, r, amp: 0.01), r);
    expect(dbfs(out), closeTo(-20, 1));
  });

  test('never clips', () {
    final out = renderTake(tone(1, r, amp: 1), r, const TakeAdjust(gainDb: 6));
    expect(out.fold<double>(0, (m, v) => max(m, v.abs())), lessThanOrEqualTo(0.98));
  });

  test('volume up is heard even when the peaks are already high', () {
    // Speech-like: a quiet body with short loud peaks, so evening out loudness leaves little headroom.
    final x = Float32List.fromList([
      for (var i = 0; i < r; i++) 0.1 * sin(2 * pi * 220 * i / r) + (i % 2400 < 24 ? 0.8 : 0.0),
    ]);
    final base = renderTake(x, r, TakeAdjust.defaults);
    final louder = renderTake(x, r, const TakeAdjust(gainDb: 6));
    expect(dbfs(louder) - dbfs(base), greaterThan(4));
    expect(louder.fold<double>(0, (m, v) => max(m, v.abs())), lessThanOrEqualTo(0.98));
  });

  test('default settings only normalize', () {
    final x = join([tone(0.4, r, amp: 0.05), silence(0.3, r), tone(0.4, r, amp: 0.05)]);
    expect(renderTake(x, r, TakeAdjust.defaults), normalizeSpeech(x, r));
  });

  test('volume changes level by its decibels', () {
    final x = tone(1, r, amp: 0.05);
    final base = renderTake(x, r, const TakeAdjust(normalize: false));
    final quieter = renderTake(x, r, const TakeAdjust(normalize: false, gainDb: -6));
    expect(dbfs(quieter) - dbfs(base), closeTo(-6, 0.1));
  });

  test('speed setting shortens the take', () {
    final x = tone(1, r);
    final out = renderTake(x, r, const TakeAdjust(speed: 1.25, normalize: false));
    expect(out.length / r, closeTo(0.8, 0.02));
  });
}
