import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/storage/temp_sweeper.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('sweep'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('release deletes the temp file', () async {
    final t = TempSweeper(dir);
    final f = await t.create('.wav');
    await f.writeAsString('x');
    await t.release(f);
    expect(f.existsSync(), isFalse);
  });

  test('create gives distinct private files', () async {
    final t = TempSweeper(dir);
    final a = await t.create('.wav');
    final b = await t.create('.wav');
    expect(a.path, isNot(b.path));
    expect(a.parent.path, '${dir.path}/vault-tmp');
  });

  test('sweep removes leftover temp files and returns the count', () async {
    final t = TempSweeper(dir);
    for (var i = 0; i < 3; i++) {
      await (await t.create('.bin')).writeAsString('left over');
    }
    final keep = File('${dir.path}/keep.txt')..writeAsStringSync('not a temp file');
    expect(await TempSweeper(dir).sweep(), 3);
    expect(Directory('${dir.path}/vault-tmp').listSync(), isEmpty);
    expect(keep.existsSync(), isTrue);
  });

  test('release refuses files outside its directory', () async {
    final outside = File('${dir.path}/keep.txt')..writeAsStringSync('x');
    await expectLater(TempSweeper(dir).release(outside), throwsArgumentError);
    expect(outside.existsSync(), isTrue);
  });
}
