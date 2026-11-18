import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/storage/storage_report.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('storage'));
  tearDown(() => dir.deleteSync(recursive: true));

  void file(String rel, int bytes) => File('${dir.path}/$rel')
    ..createSync(recursive: true)
    ..writeAsBytesSync(List.filled(bytes, 1));

  test('storage adds up each kind', () async {
    file('support/refs/a.bin', 10);
    file('support/takes/b.bin', 20);
    file('support/cues/c.bin', 5);
    file('support/people.json', 99);
    file('support/models/m.gguf', 100);
    final r = await measureStorage(
      models: Directory('${dir.path}/support/models'),
      support: Directory('${dir.path}/support'),
    );
    expect([r.models, r.voices, r.lines], [100, 30, 5]);
  });

  test('missing folders count as empty', () async {
    final r = await measureStorage(models: Directory('${dir.path}/none'), support: Directory('${dir.path}/none'));
    expect([r.models, r.voices, r.lines], [0, 0, 0]);
  });

  test('sizes read like a phone shows them', () {
    expect(formatBytes(1400000000), '1.4 GB');
    expect(formatBytes(230000000), '230 MB');
    expect(formatBytes(12000), '12 KB');
    expect(formatBytes(0), '0 KB');
  });
}
