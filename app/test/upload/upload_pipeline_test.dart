import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/models/model_store.dart';
import 'package:fauxnetic/people/people_repo.dart';
import 'package:fauxnetic/people/person.dart';
import 'package:fauxnetic/recording/reference_builder.dart';
import 'package:fauxnetic/recording/scripts.dart';
import 'package:fauxnetic/recording/takes.dart';
import 'package:fauxnetic/recording/transcriber.dart';
import 'package:fauxnetic/storage/temp_sweeper.dart';
import 'package:fauxnetic/storage/vault.dart';
import 'package:fauxnetic/upload/android_decoder.dart';
import 'package:fauxnetic/upload/upload_pipeline.dart';

import '../support/keys.dart';
import '../support/signals.dart';

Float32List secondsOf(double s) => Float32List.fromList(tone(s, -20));

/// 20 s of audio: speaker 1 talks 0-4 s and 10-14 s, speaker 0 talks 5-8 s, a cough at 9 s is unassigned.
Future<Float32List> twentySeconds(File f) async => Float32List.fromList(tone(20, -20));

class FakeNative implements UploadNative {
  @override
  Float32List denoise(Float32List pcm) => pcm;
  @override
  List<SpeechSpan> speech(Float32List pcm) => const [
    SpeechSpan(0, 4),
    SpeechSpan(5, 8),
    SpeechSpan(9, 9.4),
    SpeechSpan(10, 14),
  ];
  @override
  List<int> speakers(Float32List pcm, List<SpeechSpan> spans) => [1, 0, -1, 1];
  @override
  List<TimedWord> transcribe(Float32List pcm) => const [
    TimedWord('Hello', 0, 0.4, 0.95),
    TimedWord('there', 0.5, 0.9, 0.4),
  ];
  @override
  void close() {}
}

class SilentNative extends FakeNative {
  @override
  List<SpeechSpan> speech(Float32List pcm) => const [];
  @override
  List<int> speakers(Float32List pcm, List<SpeechSpan> spans) => const [];
}

class ShortNative extends FakeNative {
  @override
  List<SpeechSpan> speech(Float32List pcm) => const [SpeechSpan(0, 2)];
  @override
  List<int> speakers(Float32List pcm, List<SpeechSpan> spans) => const [0];
}

UploadNative fakeNative(UploadModels _) => FakeNative();
UploadNative silentNative(UploadModels _) => SilentNative();
UploadNative shortNative(UploadModels _) => ShortNative();

void main() {
  late Directory dir;
  late PeopleRepo people;
  late TakeStore takes;
  late UploadPipeline pipeline;
  late File file;

  UploadPipeline make(
    UploadNative Function(UploadModels) native, {
    Future<Float32List> Function(File) decode = twentySeconds,
  }) => UploadPipeline(
    ModelStore(Directory('${dir.path}/models')),
    people,
    takes,
    ReferenceBuilder(dir, Vault(FixedKeyStore()), takes),
    decode: decode,
    native: native,
  );

  setUp(() {
    dir = Directory.systemTemp.createTempSync('upload');
    final vault = Vault(FixedKeyStore());
    takes = TakeStore(dir, vault);
    people = PeopleRepo(dir, vault, TempSweeper(dir), takes);
    pipeline = make(fakeNative);
    file = File('${dir.path}/clip.m4a')..writeAsBytesSync([0]);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('labels follow first appearance and unassigned speech is dropped', () async {
    final a = await pipeline.analyze(file);
    expect(a.voices.map((v) => v.label), ['Voice A', 'Voice B']);
    expect(a.voices[0].seconds, closeTo(8, 0.01), reason: 'speaker 1 talks first, 4 s + 4 s');
    expect(a.voices[1].seconds, closeTo(3, 0.01));
    expect(a.voices[0].sample.length, lessThanOrEqualTo(5 * 16000));
  });

  test('group voices directly', () {
    final pcm = secondsOf(6);
    final voices = groupVoices(pcm, const [SpeechSpan(0, 1), SpeechSpan(2, 3), SpeechSpan(4, 5)], [3, 0, 3]);
    expect(voices.map((v) => v.label), ['Voice A', 'Voice B']);
    expect(voices[0].seconds, closeTo(2, 0.01));
  });

  test('a file that cannot be decoded gives the read message', () async {
    final broken = make(fakeNative, decode: (_) async => throw const DecodeFailed('no audio track'));
    await expectLater(
      broken.analyze(file),
      throwsA(isA<UploadError>().having((e) => e.message, 'message', kUploadReadFailedMessage)),
    );
  });

  test('a file with no speech finds no voices', () async {
    expect((await make(silentNative).analyze(file)).voices, isEmpty);
  });

  test('the reference clip is at most 15 s and transcribed', () async {
    final v = (await pipeline.analyze(file)).voices.first;
    expect(v.clip.length / 16000, lessThanOrEqualTo(15));
    final words = await pipeline.transcribe(v);
    expect(words.map((w) => w.text), ['Hello', 'there']);
  });

  test('speech running past 15 s is cut in a pause, not inside a word', () {
    final pcm = secondsOf(20);
    pcm.fillRange((13.5 * 16000).round(), (13.9 * 16000).round(), 0);
    final v = groupVoices(pcm, const [SpeechSpan(0, 20)], [0]).single;
    expect(v.clip.length / 16000, inInclusiveRange(13.5, 13.9));
  });

  test('low-confidence words are flagged', () {
    expect(isUncertain(const TimedWord('there', 0, 1, 0.59)), isTrue);
    expect(isUncertain(const TimedWord('Hello', 0, 1, 0.6)), isFalse);
  });

  test('build requires consent', () async {
    final v = (await pipeline.analyze(file)).voices.first;
    await expectLater(
      pipeline.buildFromUpload('Sam', v, 'Hello there', ownVoice: false, spokenConsent: false),
      throwsArgumentError,
    );
    expect(await people.all(), isEmpty);
  });

  test('build creates a consented upload person with a conversational voice', () async {
    final v = (await pipeline.analyze(file)).voices.first;
    final p = await pipeline.buildFromUpload('Sam', v, ' Hello there ', ownVoice: false, spokenConsent: true);
    expect(p.source, PersonSource.upload);
    expect(p.hasConsent, isTrue);
    expect(p.consentBasis, ConsentBasis.spokenConsent);
    expect(p.ready, isTrue);
    expect(p.refFor(Mood.conversational).refText, 'Hello there');
    final saved = (await takes.forPerson(p.id)).single;
    expect(saved.fromScript, isFalse);
  });

  test('not enough speech is refused', () async {
    final short = make(shortNative);
    final v = (await short.analyze(file)).voices.single;
    await expectLater(
      short.buildFromUpload('Sam', v, 'Hi', ownVoice: true, spokenConsent: false),
      throwsA(
        isA<NotEnoughSpeechFrom>().having(
          (e) => e.toString(),
          'message',
          "There isn't enough clear speech from Sam in this file (need at least 3 seconds).",
        ),
      ),
    );
    expect(await people.all(), isEmpty);
  });

  test('empty words are refused', () async {
    final v = (await pipeline.analyze(file)).voices.first;
    await expectLater(
      pipeline.buildFromUpload('Sam', v, '  ', ownVoice: true, spokenConsent: false),
      throwsA(isA<PersonInvalid>()),
    );
    expect(await people.all(), isEmpty);
  });

  test('the picker accepts audio and video', () {
    expect(kUploadExtensions, ['m4a', 'mp3', 'wav', 'aac', 'ogg', 'opus', 'flac', 'mp4', 'mov', 'webm', '3gp']);
  });

  test('voice count copy', () {
    expect(voicesFoundCopy(1, 'Sam'), 'Any audio or video. One voice found.');
    expect(voicesFoundCopy(2, 'Sam'), "Any audio or video. Two voices found; tap the one that's Sam.");
    expect(voicesFoundCopy(12, 'Sam'), "Any audio or video. 12 voices found; tap the one that's Sam.");
  });
}
