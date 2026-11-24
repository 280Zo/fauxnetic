import 'dart:io';
import 'dart:typed_data';

import 'package:crispasr/crispasr.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/models/model_store.dart';
import 'package:fauxnetic/recording/transcriber.dart';

class ThrowingAsr implements AsrApi {
  @override
  void open(String model) {}
  @override
  List<Segment> transcribe(Float32List pcm) => throw StateError('decoder exploded');
  @override
  void close() {}
}

class EchoAsr implements AsrApi {
  String? opened;
  @override
  void open(String model) => opened = model;
  @override
  List<Segment> transcribe(Float32List pcm) => [
    Segment(
      text: ' Hi there.',
      start: 0,
      end: 1,
      words: const [
        Word(text: ' Hi', start: 0.1, end: 0.3, p: 0.9),
        Word(text: ' there', start: 0.4, end: 0.7, p: 0.8),
        Word(text: '.', start: 0.7, end: 0.75, p: 0.95),
      ],
    ),
  ];
  @override
  void close() {}
}

class UnopenableAsr extends ThrowingAsr {
  @override
  void open(String model) => throw StateError('no such model');
}

AsrApi throwingFactory() => ThrowingAsr();
AsrApi unopenableFactory() => UnopenableAsr();
AsrApi echoFactory() => EchoAsr();

void main() {
  late ModelStore models;
  setUp(() => models = ModelStore(Directory.systemTemp.createTempSync('asr')));

  test('tokens are joined into words with their timing and lowest confidence', () {
    final words = wordsFromSegments(EchoAsr().transcribe(Float32List(0)));
    expect(words.map((w) => w.text), ['Hi', 'there.']);
    expect(words[1].start, 0.4);
    expect(words[1].end, 0.75);
    expect(words[1].confidence, 0.8);
  });

  test('segments without token timing are spread evenly', () {
    final words = wordsFromSegments([Segment(text: ' one two three four', start: 2, end: 4, noSpeechProb: 0.25)]);
    expect(words.map((w) => w.text), ['one', 'two', 'three', 'four']);
    expect(words.map((w) => w.start), [2, 2.5, 3, 3.5]);
    expect(words.last.end, 4);
    expect(words.every((w) => w.confidence == 0.75), isTrue);
  });

  // Owner, 2026-11-23 (harness/tools/whisper_beam_test.py): beam search cut base.en's errors on his
  // passages from 5.6% to 4.1% for 1.6x the time. The voice's transcript uses it; follow-along stays fast.
  test('the full transcript uses beam search, the live follow-along greedy', () {
    expect(transcribeOptionsFor(ModelRole.asrBase).strategy, 1);
    expect(transcribeOptionsFor(ModelRole.asrTiny).strategy, 0);
    for (final r in [ModelRole.asrBase, ModelRole.asrTiny]) {
      final o = transcribeOptionsFor(r);
      expect(o.language, 'en');
      expect(o.wordTimestamps, isTrue);
    }
    expect(asrFactoryFor(ModelRole.asrBase)(), isA<FfiAsrApi>().having((a) => a.options.strategy, 'strategy', 1));
    expect(asrFactoryFor(ModelRole.asrTiny)(), isA<FfiAsrApi>().having((a) => a.options.strategy, 'strategy', 0));
  });

  test('transcriber maps isolate failure to an error', () async {
    final t = WhisperTranscriber(models, ModelRole.asrTiny, factory: throwingFactory);
    await t.load();
    await expectLater(
      t.transcribe(Float32List(16000)),
      throwsA(isA<TranscriberError>().having((e) => e.message, 'message', kTranscribeFailedMessage)),
    );
    await t.dispose();
  });

  test('a model that will not open fails clearly every time', () async {
    final t = WhisperTranscriber(models, ModelRole.asrTiny, factory: unopenableFactory);
    for (var i = 0; i < 2; i++) {
      await expectLater(t.load(), throwsA(isA<TranscriberError>()));
    }
    await t.dispose();
  });

  test('transcriber round trip through the isolate', () async {
    final t = WhisperTranscriber(models, ModelRole.asrTiny, factory: echoFactory);
    final words = await t.transcribe(Float32List(16000));
    expect(words.map((w) => w.text), ['Hi', 'there.']);
    await t.dispose();
  });
}
