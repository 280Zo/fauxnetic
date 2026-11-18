import 'dart:io';

/// Space on the phone, in bytes: the voice models, voices (references and recordings) and lines.
class StorageReport {
  const StorageReport({required this.models, required this.voices, required this.lines});
  final int models, voices, lines;
}

Future<int> _size(Directory d) async {
  if (!await d.exists()) return 0;
  var n = 0;
  await for (final e in d.list(recursive: true)) {
    if (e is File) n += await e.length();
  }
  return n;
}

Future<StorageReport> measureStorage({required Directory models, required Directory support}) async => StorageReport(
  models: await _size(models),
  voices: await _size(Directory('${support.path}/refs')) + await _size(Directory('${support.path}/takes')),
  lines: await _size(Directory('${support.path}/cues')),
);

/// "1.4 GB", "230 MB", "12 KB" (decimal units, as Android shows them).
String formatBytes(int b) {
  if (b >= 1000000000) return '${(b / 1000000000).toStringAsFixed(1)} GB';
  if (b >= 1000000) return '${(b / 1000000).round()} MB';
  return '${(b / 1000).round()} KB';
}
