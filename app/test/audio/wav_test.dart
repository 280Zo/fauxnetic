import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/audio/wav.dart';

void main() {
  test('encode then measure', () {
    final wav = encodeWav(Float32List(24000 * 3), 24000);
    expect(wav.length, 44 + 24000 * 3 * 2);
    expect(wavSeconds(wav), closeTo(3.0, 1e-9));
  });

  test('reads the sample rate', () {
    expect(wavSampleRate(encodeWav(Float32List(10), 48000)), 48000);
    expect(wavSampleRate(encodeWav(Float32List(10), 24000)), 24000);
  });

  test('samples are clamped to 16-bit range', () {
    final wav = encodeWav(Float32List.fromList([2.0, -2.0, 0.5]), 16000);
    final data = ByteData.sublistView(wav, 44);
    expect(data.getInt16(0, Endian.little), 32767);
    expect(data.getInt16(2, Endian.little), -32767);
    expect(data.getInt16(4, Endian.little), 16383);
  });

  test('reads stereo 48 kHz headers', () {
    final b = BytesBuilder();
    final h = ByteData(44);
    void s(int o, String t) => t.codeUnits.asMap().forEach((i, c) => h.setUint8(o + i, c));
    s(0, 'RIFF');
    h.setUint32(4, 36 + 192000, Endian.little);
    s(8, 'WAVE');
    s(12, 'fmt ');
    h.setUint32(16, 16, Endian.little);
    h.setUint16(20, 1, Endian.little);
    h.setUint16(22, 2, Endian.little);
    h.setUint32(24, 48000, Endian.little);
    h.setUint32(28, 192000, Endian.little);
    h.setUint16(32, 4, Endian.little);
    h.setUint16(34, 16, Endian.little);
    s(36, 'data');
    h.setUint32(40, 192000, Endian.little);
    b.add(h.buffer.asUint8List());
    b.add(Uint8List(192000));
    expect(wavSeconds(b.toBytes()), closeTo(1.0, 1e-9));
  });

  test('peaks are normalized per bin', () {
    final s = Float32List(1000);
    for (var i = 500; i < 1000; i++) {
      s[i] = 0.5;
    }
    final peaks = wavPeaks(encodeWav(s, 1000), 4);
    expect(peaks.length, 4);
    expect(peaks[0], 0);
    expect(peaks[3], closeTo(1.0, 1e-6));
  });

  test('non-WAV input throws FormatException', () {
    expect(() => wavSeconds([0, 0, 0, 32, 102, 116, 121, 112]), throwsFormatException);
    expect(() => wavSeconds(<int>[]), throwsFormatException);
  });
}
