import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/recording/scripts.dart';
import 'package:fauxnetic/recording/takes.dart';
import 'package:fauxnetic/storage/vault.dart';

import '../support/keys.dart';

Float32List pcm(double seconds) =>
    Float32List.fromList(List.generate((seconds * 16000).round(), (i) => ((i % 80) - 40) / 100));

void main() {
  late Directory dir;
  late TakeStore takes;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('takes');
    takes = TakeStore(dir, Vault(FixedKeyStore()));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('takes are stored encrypted', () async {
    final t = await takes.save(
      'p1',
      Mood.conversational,
      pcm(2),
      text: 'A rather distinctive sentence.',
      fromScript: true,
      score: 0.9,
    );
    expect(t.seconds, closeTo(2, 1e-3));
    final clip = File('${dir.path}/${t.file}').readAsBytesSync();
    expect(String.fromCharCodes(clip.sublist(0, 4)), isNot('RIFF'));
    final index = String.fromCharCodes(File('${dir.path}/takes.json').readAsBytesSync());
    expect(index.contains('distinctive'), isFalse);
    final back = await takes.samples(t);
    expect(back.length, 32000);
    expect(back[41], closeTo(pcm(2)[41], 1e-4));
  });

  test('takes come back per person in recording order', () async {
    await takes.save('p1', Mood.conversational, pcm(1), text: 'One.', fromScript: true, score: 0.5);
    await takes.save('p2', Mood.excited, pcm(1), text: 'Other.', fromScript: true, score: 0.5);
    await takes.save('p1', Mood.excited, pcm(1), text: 'Two.', fromScript: false, score: 0.7);
    final mine = await takes.forPerson('p1');
    expect(mine.map((t) => t.text), ['One.', 'Two.']);
    expect(mine.last.mood, Mood.excited);
    expect(mine.last.fromScript, isFalse);
    expect(mine.last.score, 0.7);
  });

  test('an answer\'s words can be fixed, keeping its audio', () async {
    final t = await takes.save(
      'p1',
      Mood.conversational,
      pcm(1),
      text: 'I have to worry.',
      fromScript: false,
      score: 0.5,
    );
    final fixed = await takes.setText(t, "I don't have to worry.");
    expect(fixed.text, "I don't have to worry.");
    expect(fixed.file, t.file);
    final back = (await takes.forPerson('p1')).single;
    expect(back.text, "I don't have to worry.");
    expect(back.seconds, t.seconds);
  });

  test('delete removes takes', () async {
    final a = await takes.save('p1', Mood.conversational, pcm(1), text: 'One.', fromScript: true, score: 0.5);
    final b = await takes.save('p2', Mood.conversational, pcm(1), text: 'Keep.', fromScript: true, score: 0.5);
    await takes.deleteForPerson('p1');
    expect(await takes.forPerson('p1'), isEmpty);
    expect(File('${dir.path}/${a.file}').existsSync(), isFalse);
    expect((await takes.forPerson('p2')).single.id, b.id);
    expect(File('${dir.path}/${b.file}').existsSync(), isTrue);
  });

  test('launch removes takes whose person is gone and files no take refers to', () async {
    final gone = await takes.save('p-gone', Mood.conversational, pcm(1), text: 'Gone.', fromScript: true, score: 1);
    final kept = await takes.save('p1', Mood.conversational, pcm(1), text: 'Kept.', fromScript: true, score: 1);
    final stray = File('${dir.path}/takes/stray.bin')..writeAsBytesSync([1]);
    expect(await takes.sweepOrphans({'p1'}), 2);
    expect(await takes.forPerson('p-gone'), isEmpty);
    expect(File('${dir.path}/${gone.file}').existsSync(), isFalse);
    expect(stray.existsSync(), isFalse);
    expect((await takes.forPerson('p1')).single.id, kept.id);
    expect(File('${dir.path}/${kept.file}').existsSync(), isTrue);
  });

  test('concurrent saves are not lost', () async {
    await Future.wait([
      for (var i = 0; i < 5; i++)
        takes.save('p1', Mood.conversational, pcm(0.2), text: 'Line $i.', fromScript: true, score: 0.5),
    ]);
    expect((await takes.forPerson('p1')).length, 5);
  });
}
