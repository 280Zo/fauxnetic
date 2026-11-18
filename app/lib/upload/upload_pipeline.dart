import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crispasr/crispasr.dart';

import '../audio/trim.dart';
import '../engine/crispasr_engine.dart' show kThreads;
import '../models/model_store.dart';
import '../people/people_repo.dart';
import '../people/person.dart';
import '../recording/reference_builder.dart';
import '../recording/scripts.dart';
import '../recording/takes.dart';
import '../recording/transcriber.dart';

const _rate = 16000;
const _sampleSeconds = 5;
const _gapSeconds = 0.3;
const kUploadReadFailedMessage = "This file couldn't be read. Try another audio or video file.";
const kCheckWordsMessage = 'Check the words before building the voice.';

/// What the file picker offers: common audio and video containers Android can decode.
const kUploadExtensions = ['m4a', 'mp3', 'wav', 'aac', 'ogg', 'opus', 'flac', 'mp4', 'mov', 'webm', '3gp'];

/// Below this, a transcribed word is shown for checking.
const kUncertainBelow = 0.6;

bool isUncertain(TimedWord w) => w.confidence < kUncertainBelow;

class SpeechSpan {
  const SpeechSpan(this.start, this.end);
  final double start;
  final double end;
  double get seconds => end - start;
}

/// One speaker found in the file.
class VoiceCluster {
  const VoiceCluster({required this.label, required this.seconds, required this.sample, required this.clip});

  /// `Voice A`, `Voice B`, … in order of first appearance.
  final String label;

  /// All of this speaker's speech in the file.
  final double seconds;

  /// The first few seconds, for the play button.
  final Float32List sample;

  /// Up to 15 s of their speech (16 kHz): transcribed, checked, and used as the reference.
  final Float32List clip;
}

class UploadAnalysis {
  const UploadAnalysis(this.voices);
  final List<VoiceCluster> voices;
}

class UploadError implements Exception {
  const UploadError(this.message);
  final String message;
  @override
  String toString() => message;
}

class NotEnoughSpeechFrom implements Exception {
  const NotEnoughSpeechFrom(this.name);
  final String name;
  @override
  String toString() => "There isn't enough clear speech from $name in this file (need at least 3 seconds).";
}

String _countWord(int n) =>
    const {2: 'Two', 3: 'Three', 4: 'Four', 5: 'Five', 6: 'Six', 7: 'Seven', 8: 'Eight', 9: 'Nine'}[n] ?? '$n';

String voicesFoundCopy(int n, String name) => n == 1
    ? 'Any audio or video. One voice found.'
    : "Any audio or video. ${_countWord(n)} voices found; tap the one that's $name.";

/// Model files the native steps need; plain strings so they can cross into the worker isolate.
class UploadModels {
  const UploadModels({required this.asr, required this.vad, required this.speaker});
  final String asr;
  final String vad;
  final String speaker;
}

/// The native steps, run inside a worker isolate. Created and closed per job.
abstract class UploadNative {
  Float32List denoise(Float32List pcm);
  List<SpeechSpan> speech(Float32List pcm);

  /// Speaker index per span (-1 when unsure), from WeSpeaker embeddings.
  List<int> speakers(Float32List pcm, List<SpeechSpan> spans);
  List<TimedWord> transcribe(Float32List pcm);
  void close();
}

class FfiUploadNative implements UploadNative {
  FfiUploadNative(this._m);
  final UploadModels _m;
  static const _libName = 'libcrispasr.so';
  CrispASR? _asr;

  CrispASR get _whisper => _asr ??= CrispASR(_m.asr, libPath: _libName);

  @override
  Float32List denoise(Float32List pcm) {
    try {
      return enhanceAudioRnnoise(pcm, lib: DynamicLibrary.open(_libName));
    } on UnsupportedError {
      return pcm;
    }
  }

  @override
  List<SpeechSpan> speech(Float32List pcm) => [
    for (final s in _whisper.vadSlices(pcm, modelPath: _m.vad, nThreads: kThreads)) SpeechSpan(s.start, s.end),
  ];

  @override
  List<int> speakers(Float32List pcm, List<SpeechSpan> spans) {
    final segs = [for (final s in spans) DiarizeSegment(t0: s.start, t1: s.end)];
    final ok = diarizeSegments(
      segs: segs,
      left: pcm,
      method: DiarizeMethod.foxNose,
      foxnoseEmbedderPath: _m.speaker,
      nThreads: kThreads,
      lib: DynamicLibrary.open(_libName),
    );
    if (!ok) throw StateError('speaker model failed to load');
    return [for (final s in segs) s.speaker];
  }

  @override
  List<TimedWord> transcribe(Float32List pcm) => wordsFromSegments(
    _whisper.transcribePcm(
      pcm,
      options: const TranscribeOptions(language: 'en', wordTimestamps: true, nThreads: kThreads),
    ),
  );

  @override
  void close() {
    _asr?.dispose();
    _asr = null;
  }
}

UploadNative ffiUploadNative(UploadModels m) => FfiUploadNative(m);

Float32List _slice(Float32List pcm, SpeechSpan s) {
  final a = (s.start * _rate).round().clamp(0, pcm.length);
  final b = (s.end * _rate).round().clamp(a, pcm.length);
  return Float32List.sublistView(pcm, a, b);
}

/// Groups speech spans by speaker. Labels follow first appearance; spans without a speaker are dropped.
List<VoiceCluster> groupVoices(Float32List pcm, List<SpeechSpan> spans, List<int> speakers) {
  final order = <int>[];
  final bySpeaker = <int, List<SpeechSpan>>{};
  for (var i = 0; i < spans.length && i < speakers.length; i++) {
    final s = speakers[i];
    if (s < 0) continue;
    if (!bySpeaker.containsKey(s)) order.add(s);
    (bySpeaker[s] ??= []).add(spans[i]);
  }
  final gap = (_gapSeconds * _rate).round();
  final maxClip = (kRefMaxSeconds * _rate).round();
  return [
    for (final (i, s) in order.indexed)
      () {
        final own = bySpeaker[s]!;
        final clip = <double>[];
        for (final span in own) {
          final room = maxClip - clip.length - (clip.isEmpty ? 0 : gap);
          if (room <= 0) break;
          final part = _slice(pcm, span);
          if (clip.isNotEmpty) clip.addAll(Float32List(gap));
          // Past the room left, cut in a pause so the clip doesn't end inside a word.
          clip.addAll(Float32List.sublistView(part, 0, cutInPause(part, _rate, maxSeconds: room / _rate)));
        }
        final joined = Float32List.fromList(clip);
        return VoiceCluster(
          label: 'Voice ${String.fromCharCode(65 + min(i, 25))}',
          seconds: own.fold<double>(0, (sum, x) => sum + x.seconds),
          sample: Float32List.sublistView(joined, 0, min(joined.length, _sampleSeconds * _rate)),
          clip: joined,
        );
      }(),
  ];
}

/// From any audio or video file to a ready voice: find the voices, transcribe the chosen one, let
/// the owner check the words, then build the reference once consent is confirmed.
class UploadPipeline {
  UploadPipeline(
    this._models,
    this._people,
    this._takes,
    this._builder, {
    required this._decode,
    this._native = ffiUploadNative,
    Duration Function()? keepFor,
  }) : _keepFor = keepFor ?? (() => const Duration(hours: 24));

  /// The keep-for setting: a person built from a file is deleted after it.
  final Duration Function() _keepFor;

  final ModelStore _models;
  final PeopleRepo _people;
  final TakeStore _takes;
  final ReferenceBuilder _builder;

  /// Any audio or video to 16 kHz mono (Android's decoders, see AndroidDecoder).
  final Future<Float32List> Function(File f) _decode;
  final UploadNative Function(UploadModels) _native;

  UploadModels get _paths => UploadModels(
    asr: _models.pathFor(ModelRole.asrBase).path,
    vad: _models.pathFor(ModelRole.vad).path,
    speaker: _models.pathFor(ModelRole.speaker).path,
  );

  Future<T> _run<T>(T Function(UploadNative n) job) {
    final factory = _native;
    final paths = _paths;
    return Isolate.run(() {
      final n = factory(paths);
      try {
        return job(n);
      } finally {
        n.close();
      }
    });
  }

  Future<UploadAnalysis> analyze(File f) async {
    try {
      final decoded = await _decode(f);
      return await _run((n) {
        final pcm = n.denoise(decoded);
        final spans = n.speech(pcm);
        if (spans.isEmpty) return const UploadAnalysis([]);
        return UploadAnalysis(groupVoices(pcm, spans, n.speakers(pcm, spans)));
      });
    } catch (_) {
      throw const UploadError(kUploadReadFailedMessage);
    }
  }

  Future<List<TimedWord>> transcribe(VoiceCluster v) async {
    final clip = v.clip;
    try {
      return await _run((n) => n.transcribe(clip));
    } catch (_) {
      throw const TranscriberError(kTranscribeFailedMessage);
    }
  }

  /// Creates the person only after consent and only when the voice can be built; otherwise
  /// nothing is left behind.
  Future<Person> buildFromUpload(
    String name,
    VoiceCluster v,
    String words, {
    required bool ownVoice,
    required bool spokenConsent,
  }) async {
    if (!ownVoice && !spokenConsent) {
      throw ArgumentError('Consent needs either "own voice" or "spoken consent".');
    }
    final text = words.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (text.isEmpty) throw const PersonInvalid(kCheckWordsMessage);
    if (v.clip.length / _rate < kRefMinSeconds) throw NotEnoughSpeechFrom(name.trim());
    var p = await _people.create(name, PersonSource.upload, keepFor: _keepFor());
    try {
      p = await _people.confirmConsent(p.id, ownVoice: ownVoice, spokenConsent: spokenConsent);
      final take = await _takes.save(p.id, Mood.conversational, v.clip, text: text, fromScript: false, score: 1);
      final ref = await _builder.build([take], Mood.conversational);
      return await _people.setVoice(p.id, Mood.conversational, ref);
    } on NotEnoughSpeech {
      await _people.delete(p.id);
      throw NotEnoughSpeechFrom(p.name);
    } catch (_) {
      await _people.delete(p.id);
      rethrow;
    }
  }
}
