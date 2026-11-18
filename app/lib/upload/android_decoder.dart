import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../audio/resample.dart';
import '../audio/wav.dart';
import '../storage/temp_sweeper.dart';

const _channel = MethodChannel('fauxnetic/decode');

/// Only this much of an upload is decoded: plenty to find a voice, and a long podcast or video
/// can't run the phone out of memory.
const kUploadMaxSeconds = 300;

class DecodeFailed implements Exception {
  const DecodeFailed(this.reason);
  final String reason;
  @override
  String toString() => 'Decoding failed: $reason';
}

/// Decodes any audio or video with Android's own MediaExtractor and MediaCodec, from Kotlin.
///
/// CrispASR's NDK decoder can't be used: AMediaExtractor_setDataSource needs a thread attached to
/// the Java VM, and Dart isolates don't have one. The plain PCM exists only in the swept temp
/// folder while it is read.
class AndroidDecoder {
  AndroidDecoder(this._temp);
  final TempSweeper _temp;

  Future<Float32List> decode16k(File f) async {
    final out = await _temp.create('.pcm');
    try {
      final rate = await _channel.invokeMethod<int>('decodeToPcm16', {
        'path': f.path,
        'out': out.path,
        'maxSeconds': kUploadMaxSeconds,
      });
      if (rate == null || rate <= 0) throw const DecodeFailed('no sample rate');
      var bytes = await out.readAsBytes();
      final cap = rate * kUploadMaxSeconds * 2;
      if (bytes.length > cap) bytes = Uint8List.sublistView(bytes, 0, cap);
      return await Isolate.run(() => resample(pcm16Samples(bytes), rate, 16000));
    } on PlatformException catch (e) {
      throw DecodeFailed(e.message ?? e.code);
    } finally {
      await _temp.release(out);
    }
  }
}
