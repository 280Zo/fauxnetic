import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/audio/wav.dart';
import 'package:fauxnetic/recording/reference_builder.dart';
import 'package:fauxnetic/recording/scripts.dart';
import 'package:fauxnetic/recording/takes.dart';
import 'package:fauxnetic/storage/vault.dart';

import '../support/keys.dart';

Float32List tone(double seconds, [double hz = 300]) =>
    Float32List.fromList(List.generate((seconds * 16000).round(), (i) => 0.3 * sin(2 * pi * hz * i / 16000)));

void main() {
  late Directory dir;
  late Vault vault;
  late TakeStore takes;
  late ReferenceBuilder builder;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('refs');
    vault = Vault(FixedKeyStore());
    takes = TakeStore(dir, vault);
    builder = ReferenceBuilder(dir, vault, takes);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<void> add(String text, double seconds, double score, [Mood mood = Mood.conversational]) =>
      takes.save('p1', mood, tone(seconds), text: text, fromScript: true, score: score);

  test('reference is 8 to 15 s from best takes', () async {
    await add('Worst.', 4, 0.1);
    await add('Best.', 4, 0.9);
    await add('Good.', 4, 0.8);
    await add('Fine.', 4, 0.7);
    await add('Other mood.', 4, 1.0, Mood.excited);
    final ref = await builder.build(await takes.forPerson('p1'), Mood.conversational);
    expect(ref.seconds, inInclusiveRange(8, 15));
    expect(ref.refText.contains('Worst.'), isFalse);
    expect(ref.refText.contains('Other mood.'), isFalse);
    final wav = await vault.decryptFile(File('${dir.path}/${ref.clipFile}'));
    expect(wavSeconds(wav), closeTo(ref.seconds, 1e-3));
    expect(ref.seconds, closeTo(12 + 2 * 0.3, 1e-3), reason: 'three takes and two 0.3 s gaps');
    final rate = ByteData.sublistView(Uint8List.fromList(wav)).getUint32(24, Endian.little);
    expect(rate, 24000);
  });

  test('references are built from trimmed takes', () async {
    Float32List padded(double seconds) =>
        Float32List.fromList([...Float32List(16000), ...tone(seconds), ...Float32List(8000)]);
    await takes.save('p1', Mood.conversational, padded(4), text: 'One.', fromScript: true, score: 0.9);
    await takes.save('p1', Mood.conversational, padded(4), text: 'Two.', fromScript: true, score: 0.8);
    final ref = await builder.build(await takes.forPerson('p1'), Mood.conversational);
    expect(ref.seconds, closeTo(2 * (4 + 0.6) + 0.3, 0.05), reason: 'each take keeps 0.3 s of quiet a side');
  });

  test('pieces join in the order given, with their words and 0.3 s gaps', () async {
    final ref = await builder.buildJoined([(tone(10), 'The passage part.'), (tone(2), 'She sold the old car!')]);
    expect(ref.refText, 'The passage part. She sold the old car!');
    expect(ref.seconds, closeTo(12 + 0.3, 1e-3));
    final wav = await vault.decryptFile(File('${dir.path}/${ref.clipFile}'));
    expect(wavSeconds(wav), closeTo(ref.seconds, 1e-3));
  });

  test('joined pieces under 3 s throw NotEnoughSpeech', () async {
    await expectLater(builder.buildJoined([(tone(1), 'Hi.'), (tone(1), 'There.')]), throwsA(isA<NotEnoughSpeech>()));
  });

  test('transcript joins take texts in order', () async {
    await add('First line.', 3, 0.5);
    await add('Second line.', 3, 0.9);
    await add('Third line.', 3, 0.7);
    final ref = await builder.build(await takes.forPerson('p1'), Mood.conversational);
    expect(ref.refText, 'First line. Second line. Third line.');
  });

  test('a take that would pass 15 s is left out', () async {
    await add('Long.', 12, 0.9);
    await add('Too much.', 5, 0.8);
    await add('Fits.', 2, 0.7);
    final ref = await builder.build(await takes.forPerson('p1'), Mood.conversational);
    expect(ref.refText, 'Long. Fits.');
  });

  test('under 3 s throws NotEnoughSpeech', () async {
    await add('Short.', 2, 0.9);
    await expectLater(
      builder.build(await takes.forPerson('p1'), Mood.conversational),
      throwsA(isA<NotEnoughSpeech>().having((e) => e.seconds, 'seconds', closeTo(2, 1e-3))),
    );
    await expectLater(builder.build(const [], Mood.excited), throwsA(isA<NotEnoughSpeech>()));
  });

  test('resampling keeps a tone at its pitch and level', () {
    final out = resample16to24(tone(1, 1000));
    expect(out.length, 24000);
    // Zero crossings per second ≈ 2 × frequency.
    var crossings = 0;
    for (var i = 1; i < out.length; i++) {
      if ((out[i - 1] < 0) != (out[i] < 0)) crossings++;
    }
    expect(crossings, closeTo(2000, 4));
    final peak = out.sublist(100, out.length - 100).map((s) => s.abs()).reduce(max);
    expect(peak, closeTo(0.3, 0.01));
  });

  test('voice refs round trip through json', () {
    const r = VoiceRef(clipFile: 'refs/a.bin', refText: 'Hi.', seconds: 9.5);
    final back = VoiceRef.fromJson(r.toJson());
    expect([back.clipFile, back.refText, back.seconds], ['refs/a.bin', 'Hi.', 9.5]);
  });
}
