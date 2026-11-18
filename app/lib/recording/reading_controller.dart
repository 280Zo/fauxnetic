import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../audio/trim.dart';
import '../people/people_repo.dart';
import '../people/person.dart';
import 'align.dart';
import 'recorder.dart';
import 'reference_builder.dart';
import 'scripts.dart';
import 'take_check.dart';
import 'takes.dart';
import 'transcriber.dart';

const kNothingUsableMessage = 'Read the passage or answer the question to make a voice.';
const kBuildFailedMessage = "Couldn't build the voice. Your recordings are kept; try again.";
const kNotEnoughMoodSpeechMessage = "There isn't enough clear speech for this mood yet. Read another line.";

String micDeniedMessage(String name) => 'Fauxnetic needs the microphone to record $name. Allow it in Settings.';

/// On-device measurement only (Task 12): build with --dart-define=FAUXNETIC_TRACE=true.
const kTraceFollowAlong = bool.fromEnvironment('FAUXNETIC_TRACE');

/// Run follow-along again after this much new audio (0.5 s at 16 kHz).
const _followEvery = 8000;
const _rate = 16000;

/// A chunk louder than this counts as speech (the same level as the "speak louder" check).
const _speechDb = -40.0;

/// Words per second assumed until the reader's own pace is known, and the range it may take.
const _defaultPace = 2.6;
const _minPace = 1.5;
const _maxPace = 4.5;
const _maxAhead = 2;

/// Seconds of quiet that end a take: after every word, after most words, after an open answer.
const _lineQuiet = 0.8;
const _missedWordQuiet = 2.0;
const _mostOfLine = 0.6;
const _openQuiet = 3.0;

/// One guided reading session for one mood: record each line, check it, keep the good takes,
/// then build the mood's reference. Nothing is saved for a take that was interrupted.
enum VoiceFill { basic, good, full }

class ReadingController extends ChangeNotifier {
  ReadingController(
    this._person,
    this.mood,
    this._mic,
    this._follow,
    this._full,
    this._takes,
    this._people,
    this._builder, {
    Random? random,
    this.replace = false,
    List<Take> earlier = const [],
  }) : _random = random ?? Random(),
       _earlier = earlier {
    if (mood == Mood.conversational) core = pickCoreSession(_random, earlier: earlier);
  }

  /// The person's takes from earlier sessions of this mood, so Add more and Re-record ask for new text.
  final List<Take> _earlier;

  /// Re-record: the mood is rebuilt from this session's takes only, and the older takes go once it is.
  final bool replace;
  final _sessionTakes = <Take>[];

  Person _person;
  final Mood mood;
  final MicSource _mic;
  final Transcriber _follow;
  final Transcriber _full;
  final TakeStore _takes;
  final PeopleRepo _people;
  final ReferenceBuilder _builder;
  final Random _random;

  /// The conversational session: one passage, then one question; null for mood packs.
  CoreSession? core;
  var _prompt = 0;

  List<ScriptLine> get lines {
    final c = core;
    if (c == null) return scriptFor(mood);
    return [ScriptLine(c.passage), ScriptLine(c.prompts[_prompt], openPrompt: true)];
  }

  bool get canChangePassage => core != null && !recording && !checking && !building;

  var _pausedTake = false;

  /// Paused mid-take: the audio so far is kept and the next [record] continues it.
  bool get hasPausedTake => _pausedTake;

  /// Swaps in another passage (one used least so far) and goes back to it; this session's passage
  /// take is deleted so the reference transcript always matches its audio. Earlier sessions' takes stay.
  Future<void> changePassage() async {
    final c = core;
    if (c == null || !canChangePassage) return;
    final others = kPassages.where((p) => p != c.passage).toList();
    final used = [
      for (final t in [..._earlier, ..._sessionTakes])
        if (t.fromScript) t.prompt ?? t.text,
    ];
    final pick = leastUsed(others, used, _random);
    core = CoreSession(pick[_random.nextInt(pick.length)], c.prompts);
    for (final t in _sessionTakes.where((t) => t.fromScript).toList()) {
      await _takes.delete(t);
      _sessionTakes.remove(t);
    }
    // A take paused on the old passage can't continue on the new one.
    _resetTake();
    paused = false;
    index = 0;
    hint = null;
    error = null;
    _changed();
  }

  /// Shows the next question (on the question line, between takes).
  void nextPrompt() {
    final c = core;
    if (c == null || recording || checking || !line.openPrompt) return;
    _prompt = (_prompt + 1) % c.prompts.length;
    // An answer paused on the old question can't continue on the new one.
    _resetTake();
    paused = false;
    hint = null;
    _changed();
  }

  /// Seconds of answers the voice will use: earlier sessions' too when adding more, only this
  /// session's when re-recording, plus the speech so far in the answer being recorded.
  double get answerSeconds {
    final kept = [if (!replace) ..._earlier, ..._sessionTakes].where((t) => !t.fromScript);
    final start = _firstVoiceAt;
    final live = recording && !done && line.openPrompt && start != null ? (_lastVoiceEnd - start) / _rate : 0.0;
    return kept.fold<double>(0, (s, t) => s + t.seconds) + live;
  }

  /// How full the voice is from answers: Basic under 7 s (the passage is used), Good from 7 s
  /// (answers clone closest), Full at 15 s (all a voice holds).
  VoiceFill get fill {
    final s = answerSeconds;
    if (s >= kRefMaxSeconds) return VoiceFill.full;
    if (s >= kAnswerMinSeconds) return VoiceFill.good;
    return VoiceFill.basic;
  }

  /// After an answer that left the voice under Good: another question is shown, with Finish.
  bool moreAnswers = false;

  /// This session's answers, when the voice will be built from answers (7 s or more): their words
  /// come from the phone's speech recognizer, which can slip ("I have to worry" for "I don't have
  /// to worry"), and a transcript that doesn't match its audio sent Qwen into lines that never
  /// ended (2026-11-16). The passage's words are exact, so it needs no check.
  List<Take> get answersToCheck =>
      core != null && answerSeconds >= kAnswerMinSeconds ? [..._sessionTakes.where((t) => !t.fromScript)] : const [];

  var _wordsChecked = false;

  /// Done recording, but the answers' words still need a look before the voice is built.
  bool get needsWordCheck => done && error == null && !_wordsChecked && answersToCheck.isNotEmpty;

  Future<void> setAnswerText(Take t, String text) async {
    final fixed = await _takes.setText(t, text);
    final i = _sessionTakes.indexWhere((x) => x.id == t.id);
    if (i >= 0) _sessionTakes[i] = fixed;
    _changed();
  }

  /// The words are right: the screen goes on to build the voice.
  void confirmWords() {
    _wordsChecked = true;
    _changed();
  }

  /// Finish instead of answering another question; the screen then builds the voice.
  void finishAnswers() {
    if (!moreAnswers || recording || checking) return;
    moreAnswers = false;
    index = total;
    _changed();
  }

  Person get person => _person;
  int index = 0;
  int get total => lines.length;
  bool get done => index >= total;
  ScriptLine get line => lines[min(index, total - 1)];
  ScriptLine? get next => index + 1 < total ? lines[index + 1] : null;
  List<String> get lineWords => line.text.split(RegExp(r'\s+'));

  /// Script words lit up: what Whisper confirmed plus up to [_maxAhead] words predicted at the
  /// reader's pace. Never goes back during a take.
  int spokenWords = 0;

  /// Script words Whisper has actually heard; drives auto-stop.
  int confirmedWords = 0;
  String? hint;
  String? error;
  bool recording = false;
  bool checking = false;
  bool paused = false;
  bool building = false;

  List<double> get levelBars => _meter.recentBars(24);

  var _meter = LevelMeter();
  StreamSubscription<Float32List>? _sub;
  final _chunks = <Float32List>[];
  var _samples = 0;
  var _followedAt = 0;
  var _following = false;

  /// Samples in chunks loud enough to be speech, and where the last one ended.
  var _voiced = 0;
  var _lastVoiceEnd = 0;

  /// Sample where speech first started in this take (the saved take is trimmed to start there).
  int? _firstVoiceAt;
  var _heardVoice = false;

  /// Voiced samples up to the audio behind the latest confirmation, and the reader's pace.
  var _voicedAtConfirm = 0;
  var _pace = _defaultPace;

  /// Bumped whenever a take is abandoned, so late results from it are ignored.
  var _session = 0;
  var _disposed = false;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Float32List _joined() {
    final out = Float32List(_samples);
    var o = 0;
    for (final c in _chunks) {
      out.setRange(o, o + c.length, c);
      o += c.length;
    }
    return out;
  }

  Future<void> record() async {
    if (recording || checking || done) return;
    error = null;
    if (!await _mic.hasPermission()) {
      error = micDeniedMessage(person.name);
      _changed();
      return;
    }
    // A paused take carries on: same audio, same highlight, same session.
    final resuming = hasPausedTake;
    final session = resuming ? _session : ++_session;
    hint = null;
    if (!resuming) {
      _resetTake();
      _meter = LevelMeter();
    }
    _pausedTake = false;
    final Stream<Float32List> stream;
    try {
      stream = await _mic.start();
    } catch (_) {
      error = micDeniedMessage(person.name);
      _changed();
      return;
    }
    paused = false;
    recording = true;
    _sub = stream.listen(
      (chunk) {
        if (session != _session) return;
        _chunks.add(chunk);
        _samples += chunk.length;
        _meter.add(chunk);
        if (chunk.isNotEmpty && _meter.levelDb > _speechDb) {
          _firstVoiceAt ??= _samples - chunk.length;
          _voiced += chunk.length;
          _lastVoiceEnd = _samples;
          _heardVoice = true;
        }
        _predict();
        unawaited(_maybeFollow(session));
        _maybeAutoStop();
        _changed();
      },
      onError: (Object _) async {
        if (session != _session) return;
        await _discard();
        error = micDeniedMessage(person.name);
        paused = true;
        _changed();
      },
    );
    _changed();
  }

  Future<void> _maybeFollow(int session) async {
    if (line.openPrompt || _following || _samples - _followedAt < _followEvery) return;
    _following = true;
    _followedAt = _samples;
    final voicedAtRequest = _voiced;
    final sw = Stopwatch()..start();
    try {
      final heard = await _follow.transcribe(_joined());
      if (session == _session && recording) {
        final heardWords = spokenPrefix(lineWords, heard.map((w) => w.text).toList());
        if (heardWords > confirmedWords) {
          confirmedWords = heardWords;
          _voicedAtConfirm = voicedAtRequest;
          final voicedSeconds = voicedAtRequest / _rate;
          if (voicedSeconds >= 1 && confirmedWords >= 2) {
            _pace = (confirmedWords / voicedSeconds).clamp(_minPace, _maxPace);
          }
        }
        _predict();
        _maybeAutoStop();
        _changed();
      }
      if (kTraceFollowAlong) {
        // Timings only: never words or audio.
        final audio = _followedAt / 16000;
        final lastWordEnd = heard.isEmpty ? 0.0 : heard.last.end;
        final lag = audio - lastWordEnd + sw.elapsedMilliseconds / 1000;
        debugPrint(
          'FAUXNETIC_TRACE follow audio=${audio.toStringAsFixed(2)}s lastWordEnd=${lastWordEnd.toStringAsFixed(2)}s '
          'asr=${sw.elapsedMilliseconds}ms lag=${lag.toStringAsFixed(2)}s highlighted=$spokenWords/${lineWords.length}',
        );
      }
    } catch (_) {
      // Highlighting is a guide only; the full check after the take still runs.
    } finally {
      _following = false;
    }
  }

  void _resetTake() {
    _pausedTake = false;
    spokenWords = 0;
    confirmedWords = 0;
    _chunks.clear();
    _samples = 0;
    _followedAt = 0;
    _voiced = 0;
    _lastVoiceEnd = 0;
    _firstVoiceAt = null;
    _heardVoice = false;
    _voicedAtConfirm = 0;
    _pace = _defaultPace;
  }

  /// Whisper refreshes about once a second on the A54, so between passes the highlight moves on at
  /// the reader's pace while they are audibly speaking, never more than [_maxAhead] words past
  /// what Whisper confirmed.
  void _predict() {
    if (line.openPrompt) return;
    final ahead = (_pace * (_voiced - _voicedAtConfirm) / _rate).floor().clamp(0, _maxAhead);
    spokenWords = max(spokenWords, min(confirmedWords + ahead, lineWords.length));
    spokenWords = max(spokenWords, confirmedWords);
  }

  /// Ends the take on its own once the reader is done: a read line after a short pause once every
  /// word was heard (or a longer one once most were), an open answer after a longer pause.
  void _maybeAutoStop() {
    if (!recording || !_heardVoice) return;
    final quiet = (_samples - _lastVoiceEnd) / _rate;
    final bool done;
    if (line.openPrompt) {
      done = quiet >= _openQuiet;
    } else {
      final total = lineWords.length;
      done =
          (confirmedWords >= total && quiet >= _lineQuiet) ||
          (confirmedWords >= (total * _mostOfLine).ceil() && quiet >= _missedWordQuiet);
    }
    if (done) unawaited(stopAndCheck());
  }

  /// Stops the microphone and throws away the take in progress.
  Future<void> _discard() async {
    _session++;
    final sub = _sub;
    _sub = null;
    await sub?.cancel();
    final wasRecording = recording;
    recording = false;
    checking = false;
    if (wasRecording) await _mic.stop();
    _resetTake();
  }

  Future<void> stopAndCheck() async {
    if (!recording) return;
    // Cleared before any await, so an auto-stop and a tap on Stop can't both run the check.
    recording = false;
    checking = true;
    final session = _session;
    final sub = _sub;
    _sub = null;
    _changed();
    await sub?.cancel();
    await _mic.stop();
    final pcm = _joined();
    _chunks.clear();
    _samples = 0;

    List<TimedWord>? heard;
    try {
      heard = await _full.transcribe(pcm);
    } on TranscriberError {
      heard = null;
    }
    if (session != _session) return;

    final heardText = heard?.map((w) => w.text).join(' ');
    final open = line.openPrompt;
    TakeProblem? problem = checkTake(pcm, script: open ? null : line.text, heard: open ? null : heardText);
    String? message;
    if (problem == null && open) {
      if (heard == null) {
        message = kTranscribeFailedMessage;
      } else if (heardText!.trim().isEmpty) {
        problem = TakeProblem.tooQuiet;
      }
    }
    if (problem != null || message != null) {
      hint = message ?? takeHint(problem);
      spokenWords = 0;
      checking = false;
      _changed();
      return;
    }

    final score = open
        ? heard!.fold<double>(0, (s, w) => s + w.confidence) / heard.length
        : (heardText == null ? 0.5 : (1 - wordErrorRate(line.text, heardText)).clamp(0.0, 1.0));
    // A take past what a voice holds is cut in a pause before the limit, and what is kept is
    // transcribed again: words picked by Whisper's times on the whole take ran up to a second past
    // or short of the audio (Testy, Meme, 2026-11-16), and Qwen then added or skipped words at the
    // start of every line. Then the quiet edges go, so a take's seconds are speech: the 7 s answer
    // rule must not count the wait before speaking or the 3 s of quiet that ends an answer.
    final end = cutInPause(pcm, kTakeRate, maxSeconds: kRefMaxSeconds);
    final cut = end < pcm.length;
    final kept = cut ? Float32List.sublistView(pcm, 0, end) : pcm;
    final trimmed = trimSilence(kept, kTakeRate);
    final audio = trimmed.isEmpty ? kept : trimmed;
    var text = open ? heardText! : line.text;
    if (cut) {
      String? again;
      try {
        again = (await _full.transcribe(audio)).map((w) => w.text).join(' ').trim();
      } on TranscriberError {
        again = null;
      }
      if (session != _session) return;
      if (again == null || again.isEmpty) {
        hint = again == null ? kTranscribeFailedMessage : takeHint(TakeProblem.tooQuiet);
        spokenWords = 0;
        checking = false;
        _changed();
        return;
      }
      text = again;
    }
    final saved = await _takes.save(
      person.id,
      mood,
      audio,
      text: text,
      fromScript: !open,
      score: score.toDouble(),
      prompt: line.text,
    );
    _sessionTakes.add(saved);
    if (session != _session) return;
    hint = takeHint(null);
    checking = false;
    final c = core;
    if (open && c != null && answerSeconds < kAnswerMinSeconds) {
      // Not enough answers for them to beat the passage yet: ask another question (owner, 2026-11-16).
      _prompt = (_prompt + 1) % c.prompts.length;
      moreAnswers = true;
      spokenWords = 0;
    } else {
      moreAnswers = false;
      _advance();
    }
    _changed();
  }

  void _advance() {
    index++;
    spokenWords = 0;
  }

  Future<void> redo() async {
    await _discard();
    hint = null;
    _changed();
  }

  Future<void> skip() async {
    if (done) return;
    await _discard();
    hint = null;
    _advance();
    _changed();
  }

  /// Stops the microphone but keeps the take; [record] resumes it.
  Future<void> pause() async {
    if (!recording) return;
    final sub = _sub;
    _sub = null;
    recording = false;
    _pausedTake = true;
    await sub?.cancel();
    await _mic.stop();
    paused = true;
    hint = null;
    _changed();
  }

  /// A call, the app going to the background, or the screen turning off: the take is dropped,
  /// paused or not.
  Future<void> onInterrupted() async {
    if (!recording && !checking && !_pausedTake) return;
    await _discard();
    paused = true;
    hint = null;
    _changed();
  }

  /// Back to the first line, keeping takes already saved.
  void restart() {
    index = 0;
    error = null;
    hint = null;
    _changed();
  }

  /// Builds this mood's reference from every take of the mood and attaches it. Returns null, with
  /// [error] set, when there is not enough to build from.
  Future<Person?> finish() async {
    error = null;
    final sessionIds = {for (final t in _sessionTakes) t.id};
    final all = (await _takes.forPerson(person.id)).where((t) => t.mood == mood).toList();
    final forMood = replace ? all.where((t) => sessionIds.contains(t.id)).toList() : all;
    final core = mood == Mood.conversational;
    if (forMood.isEmpty) {
      error = core ? kNothingUsableMessage : kNotEnoughMoodSpeechMessage;
      _changed();
      return null;
    }
    building = true;
    _changed();
    try {
      VoiceRef ref;
      try {
        ref = await _builder.build(core ? coreReferenceTakes(forMood) : forMood, mood);
      } on NotEnoughSpeech {
        if (!core) rethrow;
        // The chosen recording was too short on its own; any mix of what was kept may still do.
        ref = await _builder.build(forMood, mood);
      }
      try {
        _person = await _people.setVoice(person.id, mood, ref);
      } catch (_) {
        // The person expired (or was deleted) while this was being built: nothing of it may stay.
        await _builder.discard(ref);
        rethrow;
      }
      if (replace) {
        for (final t in all.where((t) => !sessionIds.contains(t.id))) {
          await _takes.delete(t);
        }
      }
      return _person;
    } on NotEnoughSpeech {
      error = core ? kNothingUsableMessage : kNotEnoughMoodSpeechMessage;
      return null;
    } catch (_) {
      // Anything else (storage, encryption) must still end in a message, never a spinner.
      error = kBuildFailedMessage;
      return null;
    } finally {
      building = false;
      _changed();
    }
  }

  /// Leaving the screen. A core session that never produced a voice leaves no person behind.
  Future<void> abandon() async {
    await _discard();
    if (mood == Mood.conversational && !_person.ready) await _people.delete(person.id);
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_discard());
    super.dispose();
  }
}
