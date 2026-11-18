import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

/// Raw microphone audio: the phone's own noise suppression and gain would change the voice
/// being cloned, so both are off.
const kMicConfig = RecordConfig(
  encoder: AudioEncoder.pcm16bits,
  sampleRate: 16000,
  numChannels: 1,
  noiseSuppress: false,
  autoGain: false,
  echoCancel: false,
);

abstract class MicSource {
  Future<bool> hasPermission();

  /// 16 kHz mono samples in -1..1.
  Future<Stream<Float32List>> start();
  Future<void> stop();
}

/// Little-endian 16-bit PCM bytes to float samples. A sample split across chunks is carried over.
Stream<Float32List> pcm16ToFloat(Stream<Uint8List> bytes) async* {
  int? carry;
  await for (final chunk in bytes) {
    final joined = carry == null
        ? chunk
        : (Uint8List(chunk.length + 1)
            ..[0] = carry
            ..setRange(1, chunk.length + 1, chunk));
    final whole = joined.length ~/ 2;
    carry = joined.length.isOdd ? joined.last : null;
    if (whole == 0) continue;
    final data = ByteData.sublistView(joined, 0, whole * 2);
    final out = Float32List(whole);
    for (var i = 0; i < whole; i++) {
      out[i] = data.getInt16(i * 2, Endian.little) / 32768;
    }
    yield out;
  }
}

class RecordMicSource implements MicSource {
  RecordMicSource([AudioRecorder? recorder]) : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<Stream<Float32List>> start() async => pcm16ToFloat(await _recorder.startStream(kMicConfig));

  @override
  Future<void> stop() async {
    await _recorder.stop();
  }
}
