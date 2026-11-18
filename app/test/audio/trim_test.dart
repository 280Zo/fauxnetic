import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/audio/trim.dart';

const rate = 24000;

Float32List clip({required double quietBefore, required double speech, required double quietAfter}) {
  final out = <double>[];
  out.addAll(List.filled((quietBefore * rate).round(), 0.0002));
  out.addAll(List.generate((speech * rate).round(), (i) => 0.3 * sin(2 * pi * 200 * i / rate)));
  out.addAll(List.filled((quietAfter * rate).round(), 0.0002));
  return Float32List.fromList(out);
}

/// Speech (a tone) for [seconds], with near-silence over each [gaps] range (start, end in seconds).
Float32List speechWithGaps(double seconds, List<(double, double)> gaps) => Float32List.fromList(
  List.generate((seconds * rate).round(), (i) {
    final t = i / rate;
    final quiet = gaps.any((g) => t >= g.$1 && t < g.$2);
    return quiet ? 0.0002 : 0.3 * sin(2 * pi * 200 * t);
  }),
);

void main() {
  group('cutting a long take', () {
    test('audio that fits is not cut', () {
      final pcm = speechWithGaps(10, const []);
      expect(cutInPause(pcm, rate, maxSeconds: 15), pcm.length);
    });

    test('the cut falls in the last pause before the limit', () {
      // Whisper's word times were up to a second off on the A54 (Testy, Meme, 2026-11-16), so the
      // cut comes from the audio: a gap between words, never inside one.
      final pcm = speechWithGaps(20, const [(11.0, 11.4), (13.5, 13.9)]);
      final at = cutInPause(pcm, rate, maxSeconds: 15) / rate;
      expect(at, inInclusiveRange(13.5, 13.9));
    });

    test('a pause right at the limit still counts', () {
      final pcm = speechWithGaps(20, const [(14.7, 15.2)]);
      final at = cutInPause(pcm, rate, maxSeconds: 15) / rate;
      expect(at, inInclusiveRange(14.7, 15.0));
    });

    test('with no pause the cut is still within the limit', () {
      final at = cutInPause(speechWithGaps(20, const []), rate, maxSeconds: 15) / rate;
      expect(at, inInclusiveRange(12, 15));
    });
  });

  test('leading and trailing quiet is trimmed to 0.3 s', () {
    final out = trimSilence(clip(quietBefore: 1.2, speech: 2, quietAfter: 0.8), rate);
    expect(out.length / rate, closeTo(2 + 0.3 + 0.3, 0.03));
  });

  test('a soft start below the threshold is kept', () {
    // 0.2 s of a breathy onset at about -56 dBFS, then the loud part of the word.
    final soft = List.generate((0.2 * rate).round(), (i) => 0.0022 * sin(2 * pi * 3000 * i / rate));
    final pcm = Float32List.fromList([
      ...List.filled(rate, 0.0),
      ...soft,
      ...clip(quietBefore: 0, speech: 1, quietAfter: 0),
    ]);
    final out = trimSilence(pcm, rate);
    expect(out.length / rate, greaterThanOrEqualTo(1.2), reason: 'the whole onset survives');
    expect(out.sublist(0, 10), everyElement(0.0), reason: 'and starts in silence, not mid-sound');
  });

  test('speech is untouched', () {
    final speech = clip(quietBefore: 0, speech: 2, quietAfter: 0);
    final out = trimSilence(speech, rate);
    expect(out.length, speech.length);
    expect(out[100], speech[100]);
  });

  test('a short lead-in is kept as it is', () {
    final out = trimSilence(clip(quietBefore: 0.25, speech: 1, quietAfter: 0), rate);
    expect(out.length / rate, closeTo(1.25, 0.03));
  });

  List<double> level(double seconds, double db, {double hz = 200}) {
    final a = pow(10, db / 20) * sqrt2;
    return List.generate((seconds * rate).round(), (i) => a * sin(2 * pi * hz * i / rate));
  }

  group('generated lines', () {
    // The owner's "haha" take (2026-11-15): a -52 dB floor, a breath, 2.4 s of quiet, a breath, then the laugh.
    test('isolated breaths and the quiet around them are dropped', () {
      final pcm = Float32List.fromList([
        ...level(0.25, -49),
        ...level(0.55, -58),
        ...level(0.2, -42),
        ...level(2.4, -62),
        ...level(0.05, -37), // measured: one 50 ms frame at -37 dB
        ...level(0.45, -65),
        ...level(0.5, -26),
        ...level(0.3, -60),
      ]);
      final out = trimGenerated(pcm, rate);
      expect(out.length / rate, closeTo(0.3 + 0.5 + 0.3, 0.05), reason: 'the laugh with 0.3 s each side');
    });

    test('a soft first word joined to the speech is kept', () {
      final pcm = Float32List.fromList([
        ...level(1, -70),
        ...level(0.3, -40), // "so", 14 dB under the rest
        ...level(0.1, -60),
        ...level(1, -25),
      ]);
      final out = trimGenerated(pcm, rate);
      expect(out.length / rate, closeTo(0.3 + 0.3 + 0.1 + 1, 0.05));
    });

    test('a breath after the line is dropped too', () {
      final pcm = Float32List.fromList([...level(1, -25), ...level(0.6, -65), ...level(0.15, -40), ...level(0.5, -65)]);
      expect(trimGenerated(pcm, rate).length / rate, closeTo(1 + 0.3, 0.05));
    });

    test('without a clear stretch of speech it trims like a recording', () {
      final pcm = Float32List.fromList([...level(1, -70), ...level(0.06, -25), ...level(1, -70)]);
      expect(trimGenerated(pcm, rate).length, trimSilence(pcm, rate).length);
      expect(trimGenerated(Float32List(rate), rate), isEmpty);
    });
  });

  test('all-quiet input becomes empty', () {
    expect(trimSilence(Float32List(rate), rate), isEmpty);
    expect(trimSilence(Float32List(0), rate), isEmpty);
  });
}
