import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/audio/resample.dart';
import 'package:fauxnetic/audio/wav.dart';

Float32List sine(double hz, int rate, double seconds, [double amp = 0.3]) =>
    Float32List.fromList(List.generate((seconds * rate).round(), (i) => amp * sin(2 * pi * hz * i / rate)));

int crossings(Float32List x) {
  var n = 0;
  for (var i = 1; i < x.length; i++) {
    if ((x[i - 1] < 0) != (x[i] < 0)) n++;
  }
  return n;
}

double peak(Float32List x) => x.sublist(200, x.length - 200).map((s) => s.abs()).reduce(max);

void main() {
  test('48 kHz to 16 kHz keeps a 1 kHz tone at its pitch and level', () {
    final out = resample(sine(1000, 48000, 1), 48000, 16000);
    expect(out.length, 16000);
    expect(crossings(out), closeTo(2000, 4));
    expect(peak(out), closeTo(0.3, 0.01));
  });

  test('downsampling removes tones above the new Nyquist instead of folding them back', () {
    final out = resample(sine(12000, 48000, 1), 48000, 16000);
    expect(peak(out), lessThan(0.01));
  });

  test('44.1 kHz to 16 kHz has the right length', () {
    expect(resample(Float32List(44100 * 2), 44100, 16000).length, 32000);
  });

  test('same rate returns a copy', () {
    final x = sine(440, 16000, 0.1);
    final out = resample(x, 16000, 16000);
    expect(out, x);
    expect(identical(out, x), isFalse);
  });

  test('16-bit little-endian PCM becomes float samples', () {
    final b = ByteData(6)
      ..setInt16(0, 0, Endian.little)
      ..setInt16(2, 16384, Endian.little)
      ..setInt16(4, -32768, Endian.little);
    expect(pcm16Samples(b.buffer.asUint8List()), [0, 0.5, -1]);
    expect(pcm16Samples(Uint8List(3)).length, 1, reason: 'a trailing odd byte is ignored');
  });
}
