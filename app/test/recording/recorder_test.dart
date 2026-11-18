import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:fauxnetic/recording/recorder.dart';

Uint8List le16(List<int> samples) {
  final b = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    b.setInt16(i * 2, samples[i], Endian.little);
  }
  return b.buffer.asUint8List();
}

void main() {
  test('pcm16 bytes become float samples', () async {
    final out = await pcm16ToFloat(Stream.value(le16([0, 16384, -32768, 32767]))).toList();
    expect(out.single, [0, 0.5, -1, closeTo(1, 1e-4)]);
  });

  test('a sample split across chunks is joined', () async {
    final bytes = le16([1000, -2000, 3000]);
    final chunks = [bytes.sublist(0, 3), bytes.sublist(3, 5), bytes.sublist(5)];
    final out = await pcm16ToFloat(Stream.fromIterable(chunks)).toList();
    final all = out.expand((c) => c).toList();
    expect(all.length, 3);
    expect(all[0], closeTo(1000 / 32768, 1e-6));
    expect(all[1], closeTo(-2000 / 32768, 1e-6));
    expect(all[2], closeTo(3000 / 32768, 1e-6));
  });

  test('mic config is raw 16 kHz mono pcm', () {
    expect(kMicConfig.encoder, AudioEncoder.pcm16bits);
    expect(kMicConfig.sampleRate, 16000);
    expect(kMicConfig.numChannels, 1);
    expect(kMicConfig.noiseSuppress, isFalse);
    expect(kMicConfig.autoGain, isFalse);
    expect(kMicConfig.echoCancel, isFalse);
  });
}
