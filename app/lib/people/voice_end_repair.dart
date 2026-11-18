import 'dart:io';

import '../audio/resample.dart';
import '../audio/wav.dart';
import '../recording/reference_builder.dart';
import '../recording/transcriber.dart';
import '../storage/temp_sweeper.dart';
import 'people_repo.dart';

/// Voices saved before 2026-11-16 could end on a different word than their transcript: a long take
/// was cut at a Whisper word time up to a second off. Qwen then said the missing words before every
/// line (Testy) or skipped a line's first words (Meme). Once per voice, Whisper listens to it; when
/// the last word it hears isn't the transcript's last word, the transcript becomes what it heard.
/// A voice that can't be checked now (no consent yet, a failed transcription) is tried next launch.
/// Returns how many transcripts changed.
Future<int> repairVoiceEnds(PeopleRepo people, Transcriber whisper, TempSweeper temp) async {
  var changed = 0;
  for (final p in await people.all()) {
    if (!p.hasConsent) continue;
    for (final MapEntry(key: mood, value: ref) in p.voices.entries) {
      if (ref.endChecked) continue;
      final File wav;
      try {
        wav = await people.decryptedRef(p, mood);
      } on Exception {
        continue; // unreadable now; the others still get checked
      }
      String heard;
      try {
        final pcm = wavSamples(await wav.readAsBytes());
        heard = (await whisper.transcribe(resample(pcm, kRefRate, 16000))).map((w) => w.text).join(' ').trim();
      } on TranscriberError {
        continue;
      } finally {
        await temp.release(wav);
      }
      final fix = heard.isNotEmpty && _lastWord(heard) != _lastWord(ref.refText);
      try {
        await people.setVoiceText(p.id, mood, clipFile: ref.clipFile, refText: fix ? heard : ref.refText);
      } on PersonInvalid {
        continue; // deleted or expired meanwhile
      }
      if (fix) changed++;
    }
  }
  return changed;
}

String _lastWord(String text) {
  final words = text
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .map((w) => w.replaceAll(RegExp(r"[^\p{L}\p{N}']", unicode: true), ''));
  return words.lastWhere((w) => w.isNotEmpty, orElse: () => '');
}
