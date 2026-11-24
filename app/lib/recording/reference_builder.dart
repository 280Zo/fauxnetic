import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../audio/resample.dart';
import '../audio/trim.dart';
import '../audio/wav.dart';
import '../storage/vault.dart';
import 'scripts.dart';
import 'takes.dart';

const kRefRate = 24000;
const kRefMinSeconds = 3.0;
const kRefMaxSeconds = 15.0;
const _gapSeconds = kRefGapSeconds;

/// Quiet between the takes joined into a voice.
const kRefGapSeconds = 0.3;

/// The reference the engine clones from for one mood: an encrypted 24 kHz WAV and its exact transcript.
class VoiceRef {
  const VoiceRef({required this.clipFile, required this.refText, required this.seconds, this.endChecked = true});

  /// Encrypted clip, relative to the app support directory.
  final String clipFile;
  final String refText;
  final double seconds;

  /// False for voices saved before 2026-11-16, whose transcript may end on a different word than
  /// the audio; repairVoiceEnds checks each once.
  final bool endChecked;

  Map<String, Object?> toJson() => {
    'clipFile': clipFile,
    'refText': refText,
    'seconds': seconds,
    'endChecked': endChecked,
  };

  factory VoiceRef.fromJson(Map<String, Object?> j) => VoiceRef(
    clipFile: j['clipFile']! as String,
    refText: j['refText']! as String,
    seconds: (j['seconds']! as num).toDouble(),
    endChecked: j['endChecked'] as bool? ?? false,
  );
}

class NotEnoughSpeech implements Exception {
  const NotEnoughSpeech(this.seconds);

  /// Usable speech found, in seconds.
  final double seconds;
  @override
  String toString() => 'Not enough speech for a voice (${seconds.toStringAsFixed(1)} s, need $kRefMinSeconds s).';
}

Float32List resample16to24(Float32List x) => resample(x, 16000, kRefRate);

/// Own-words answers clone closest (2026-11-15 measurement), so they make the core reference once
/// they hold at least 7 s of speech; otherwise the passage does.
const kAnswerMinSeconds = 7.0;

List<Take> coreReferenceTakes(List<Take> conversational) {
  final answers = conversational.where((t) => !t.fromScript).toList();
  // The plain and question sentences are read too, but too short to stand in for the passage.
  final passage = conversational.where((t) => t.fromScript && t.phrase == null).toList();
  final answerSeconds = answers.fold<double>(0, (s, t) => s + t.seconds);
  if (answerSeconds >= kAnswerMinSeconds || passage.isEmpty) return answers;
  return passage;
}

class ReferenceBuilder {
  ReferenceBuilder(this.dir, this._vault, this._takes);

  final Directory dir;
  final Vault _vault;
  final TakeStore _takes;
  final _random = Random.secure();

  /// Deletes a reference that was built but couldn't be attached (its person is gone).
  Future<void> discard(VoiceRef ref) async {
    final f = File('${dir.path}/${ref.clipFile}');
    if (await f.exists()) await f.delete();
  }

  /// Picks the best-scoring takes for [mood] up to 15 s (with 0.3 s gaps), joins them in recording
  /// order and stores the result encrypted. Throws [NotEnoughSpeech] under 3 s.
  Future<VoiceRef> build(List<Take> takes, Mood mood) async {
    final forMood = takes.where((t) => t.mood == mood).toList();
    // Best score first; equal scores keep recording order (List.sort is not stable).
    final candidates = [...forMood]
      ..sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        return byScore != 0 ? byScore : forMood.indexOf(a).compareTo(forMood.indexOf(b));
      });
    final chosen = <Take>{};
    var total = 0.0;
    for (final t in candidates) {
      final withGap = total + (chosen.isEmpty ? 0 : _gapSeconds) + t.seconds;
      if (withGap > kRefMaxSeconds) continue;
      chosen.add(t);
      total = withGap;
    }
    final speech = chosen.fold<double>(0, (s, t) => s + t.seconds);
    if (speech < kRefMinSeconds) throw NotEnoughSpeech(speech);

    final ordered = takes.where(chosen.contains).toList();
    return _store([for (final t in ordered) (await _takes.samples(t), t.text)]);
  }

  /// Joins [pieces] (16 kHz audio and its exact words) in the order given, with 0.3 s gaps, and
  /// stores the result encrypted. For a mood voice made of the passage and that mood's sentences.
  /// Throws [NotEnoughSpeech] under 3 s.
  Future<VoiceRef> buildJoined(List<(Float32List, String)> pieces) async {
    final speech = pieces.fold<double>(0, (s, p) => s + p.$1.length / 16000);
    if (speech < kRefMinSeconds) throw NotEnoughSpeech(speech);
    return _store(pieces);
  }

  Future<VoiceRef> _store(List<(Float32List, String)> pieces) async {
    final gap = Float32List((_gapSeconds * kRefRate).round());
    final parts = <Float32List>[];
    for (final (raw, _) in pieces) {
      if (parts.isNotEmpty) parts.add(gap);
      final trimmed = trimSilence(raw, 16000);
      parts.add(resample16to24(trimmed.isEmpty ? raw : trimmed));
    }
    final joined = Float32List(parts.fold<int>(0, (s, p) => s + p.length));
    var o = 0;
    for (final p in parts) {
      joined.setRange(o, o + p.length, p);
      o += p.length;
    }
    final id = List.generate(8, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    final rel = 'refs/$id.bin';
    await _vault.encryptBytes(encodeWav(joined, kRefRate), File('${dir.path}/$rel'));
    return VoiceRef(clipFile: rel, refText: pieces.map((p) => p.$2).join(' '), seconds: joined.length / kRefRate);
  }
}
