import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/cues/speed_book.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('speeds');
    file = File('${dir.path}/speeds.json');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('records and averages per model, and keeps it across launches', () async {
    final b = SpeedBook(file);
    await b.load();
    expect(b.secondsPerWord('voxcpm'), isNull, reason: 'never timed here');
    await b.record('voxcpm', 10, 30);
    expect(b.secondsPerWord('voxcpm'), 3.0);
    await b.record('voxcpm', 10, 10);
    expect(b.secondsPerWord('voxcpm'), 2.0, reason: 'half old, half new');
    expect(b.secondsPerWord('qwen'), isNull);
    final again = SpeedBook(file);
    await again.load();
    expect(again.secondsPerWord('voxcpm'), 2.0);
  });

  test('a corrupt file is ignored', () async {
    file.writeAsStringSync('{not json');
    final b = SpeedBook(file);
    await b.load();
    expect(b.secondsPerWord('qwen'), isNull);
    await b.record('qwen', 4, 8);
    expect(b.secondsPerWord('qwen'), 2.0);
  });

  test('a line with no words records nothing', () async {
    final b = SpeedBook(file);
    await b.load();
    await b.record('qwen', 0, 8);
    expect(b.secondsPerWord('qwen'), isNull);
  });
}
