import 'dart:ffi';
import 'dart:typed_data';

import 'package:crispasr/crispasr.dart';

/// Puts the AI watermark into audio and measures it (0 to 1; above [kMarkDetected] it is found).
abstract class Marker {
  Float32List embed(Float32List pcm);
  double detect(Float32List pcm);
}

/// CrispASR's detector says "watermark present" above this.
const kMarkDetected = 0.65;

/// CrispASR's spread-spectrum watermark, the one every generated line already carries.
class CrispMarker implements Marker {
  final _lib = DynamicLibrary.open('libcrispasr.so');

  @override
  Float32List embed(Float32List pcm) => CrispasrWatermark.embed(pcm, lib: _lib);

  @override
  double detect(Float32List pcm) => CrispasrWatermark.detect(pcm, lib: _lib);
}

/// A take whose watermark couldn't be confirmed is not shared.
class MarkMissing implements Exception {
  const MarkMissing();
  static const message = "This take couldn't be marked as AI, so it wasn't shared.";
  @override
  String toString() => message;
}
