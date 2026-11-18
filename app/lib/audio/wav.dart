import 'dart:typed_data';

/// 16-bit PCM mono WAV from float samples in [-1, 1].
Uint8List encodeWav(Float32List samples, int sampleRate) {
  final data = samples.length * 2;
  final b = ByteData(44 + data);
  void tag(int o, String t) {
    for (var i = 0; i < 4; i++) {
      b.setUint8(o + i, t.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  b.setUint32(4, 36 + data, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, 1, Endian.little);
  b.setUint32(24, sampleRate, Endian.little);
  b.setUint32(28, sampleRate * 2, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  b.setUint32(40, data, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    final v = samples[i].clamp(-1.0, 1.0);
    b.setInt16(44 + i * 2, (v * 32767).truncate(), Endian.little);
  }
  return b.buffer.asUint8List();
}

/// Raw 16-bit little-endian mono PCM to float samples; a trailing odd byte is ignored.
Float32List pcm16Samples(Uint8List bytes) {
  final n = bytes.length ~/ 2;
  final b = ByteData.sublistView(bytes, 0, n * 2);
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    out[i] = b.getInt16(i * 2, Endian.little) / 32768;
  }
  return out;
}

/// Float samples of a 16-bit mono WAV written by [encodeWav].
Float32List wavSamples(List<int> wav) {
  final u = wav is Uint8List ? wav : Uint8List.fromList(wav);
  if (u.length < 44) throw const FormatException('not a WAV file');
  final n = (u.length - 44) ~/ 2;
  final b = ByteData.sublistView(u, 44);
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    out[i] = b.getInt16(i * 2, Endian.little) / 32767;
  }
  return out;
}

/// Peak level per bin of a 16-bit mono WAV written by [encodeWav], scaled so the loudest bin is 1.
List<double> wavPeaks(List<int> wav, int bins) {
  final u = wav is Uint8List ? wav : Uint8List.fromList(wav);
  final n = (u.length - 44) ~/ 2;
  if (n <= 0 || bins <= 0) return List.filled(bins, 0);
  final b = ByteData.sublistView(u, 44);
  final peaks = List<double>.filled(bins, 0);
  for (var i = 0; i < n; i++) {
    final bin = i * bins ~/ n;
    final v = b.getInt16(i * 2, Endian.little).abs() / 32767;
    if (v > peaks[bin]) peaks[bin] = v;
  }
  final top = peaks.reduce((a, c) => a > c ? a : c);
  return top == 0 ? peaks : peaks.map((p) => p / top).toList();
}

/// Sample rate of a RIFF/WAVE file, from its fmt chunk.
int wavSampleRate(List<int> bytes) {
  final u = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final b = ByteData.sublistView(u);
  var o = 12;
  while (o + 8 <= u.length) {
    final size = b.getUint32(o + 4, Endian.little);
    if (String.fromCharCodes(u.sublist(o, o + 4)) == 'fmt ' && o + 16 <= u.length) {
      return b.getUint32(o + 12, Endian.little);
    }
    o += 8 + size + (size.isOdd ? 1 : 0);
  }
  throw const FormatException('WAV without fmt chunk');
}

/// Duration of a RIFF/WAVE file, read from its fmt and data chunks.
double wavSeconds(List<int> bytes) {
  final u = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  if (u.length < 12) throw const FormatException('not a WAV file');
  final b = ByteData.sublistView(u);
  String tag(int o) => String.fromCharCodes(u.sublist(o, o + 4));
  if (tag(0) != 'RIFF' || tag(8) != 'WAVE') throw const FormatException('not a WAV file');
  int? byteRate;
  var o = 12;
  while (o + 8 <= u.length) {
    final id = tag(o);
    final size = b.getUint32(o + 4, Endian.little);
    if (id == 'fmt ' && o + 8 + 12 <= u.length) {
      byteRate = b.getUint32(o + 8 + 8, Endian.little);
    } else if (id == 'data') {
      if (byteRate == null || byteRate == 0) throw const FormatException('WAV data before fmt');
      final available = u.length - (o + 8);
      return (size < available ? size : available) / byteRate;
    }
    o += 8 + size + (size.isOdd ? 1 : 0);
  }
  throw const FormatException('WAV without data chunk');
}
