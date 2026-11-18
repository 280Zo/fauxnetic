import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/audio/marking.dart';
import 'package:fauxnetic/audio/render.dart';
import 'package:fauxnetic/audio/take_adjust.dart';
import 'package:fauxnetic/audio/wav.dart';
import 'package:fauxnetic/cues/cue.dart';
import 'package:fauxnetic/cues/cue_repo.dart';
import 'package:fauxnetic/cues/take_renderer.dart';
import 'package:fauxnetic/storage/vault.dart';

import '../support/keys.dart';
import '../support/people.dart';

/// Adds 0.01 to every sample, so a marked take is recognisable; detect returns [score].
class FakeMarker implements Marker {
  FakeMarker(this.counter, {this.score = 0.97});
  final List<int> counter;
  final double score;

  @override
  Float32List embed(Float32List pcm) {
    counter.add(1);
    return Float32List.fromList([for (final v in pcm) v + 0.01]);
  }

  @override
  double detect(Float32List pcm) => score;
}

R sync<R>(R Function() f) => f();

/// A marker that can be made inside the background isolate (no captured state).
class SendableMarker implements Marker {
  @override
  Float32List embed(Float32List pcm) => pcm;
  @override
  double detect(Float32List pcm) => 0.97;
}

void main() {
  late Directory dir;
  late CueRepo cues;
  late CueItem line;
  late List<int> embeds;
  final now = DateTime.utc(2026, 11, 18, 12);

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('renderer');
    cues = CueRepo(dir, Vault(FixedKeyStore()));
    line = (await cues.storeClip(await cues.add('p1', 'Hi.'), testRefWav(), now))!;
    embeds = [];
  });
  tearDown(() => dir.deleteSync(recursive: true));

  TakeRenderer renderer({double score = 0.97}) => TakeRenderer(cues, () => FakeMarker(embeds, score: score), run: sync);

  test('wav is the rendered, marked take', () async {
    final out = wavSamples(await renderer().wav(line));
    final expected = renderTake(wavSamples(testRefWav()), 24000, TakeAdjust.defaults);
    expect(out.length, expected.length);
    expect(out[1234], closeTo(expected[1234] + 0.01, 2 / 32767));
  });

  test('renders in a real background isolate', () async {
    final out = await TakeRenderer(cues, SendableMarker.new).wav(line);
    expect(wavSeconds(out), closeTo(5, 0.1));
  });

  test('keeps the sample rate', () async {
    final wav48 = encodeWav(Float32List.fromList(List.generate(48000 * 2, (i) => (i % 100) / 200.0)), 48000);
    final l = (await cues.storeClip(await cues.add('p1', 'Two.'), wav48, now))!;
    expect(wavSampleRate(await renderer().wav(l)), 48000);
  });

  test('a failed mark check throws MarkMissing', () async {
    await expectLater(renderer(score: 0.5).wav(line), throwsA(isA<MarkMissing>()));
  });

  test('same take and settings render once', () async {
    final r = renderer();
    await r.wav(line);
    await r.wav(line);
    expect(embeds, hasLength(1));
  });

  test('another take or new settings render again', () async {
    final r = renderer();
    await r.wav(line);
    final changed = (await cues.setAdjust(line.id, 0, const TakeAdjust(speed: 1.25)))!;
    final out = await r.wav(changed);
    expect(embeds, hasLength(2));
    expect(wavSeconds(out), closeTo(4, 0.1), reason: 'the 5 s take at 1.25x');
  });
}
