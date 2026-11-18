import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../audio/wav.dart';
import '../audio/marking.dart';
import '../audio/take_adjust.dart';
import '../audio/word_timing.dart';
import '../cues/take_renderer.dart';
import '../cues/cue.dart';
import '../cues/cue_repo.dart';
import '../cues/preparer.dart';
import '../cues/share.dart';
import '../cues/speed_book.dart';
import '../engine/tts_models.dart';
import '../models/model_store.dart';
import '../people/person.dart';
import '../recording/scripts.dart';
import '../storage/temp_sweeper.dart';
import 'clip_player.dart';

/// State behind the Speak screen.
abstract class SpeakController extends ChangeNotifier {
  SpeakController(this.person);

  final Person person;
  List<CueItem> items = const [];
  String? playingId;

  /// The line in the dock's player: the one selected (or playing); null shows the text box.
  String? shownId;
  List<double> waveform = const [];

  /// Length of the shown line's current take, in seconds; 0 when none is shown.
  double lengthSeconds = 0;

  /// How far the playing line is, in seconds; 0 when nothing plays.
  double playedSeconds = 0;

  /// The shown line's words, and when each starts in its current take (estimated from the text
  /// and the take's loudness); empty when none is shown.
  List<String> words = const [];
  List<double> wordStarts = const [];

  /// Puts [item] in the player without playing it; another line playing stops.
  Future<void> select(CueItem item);

  /// Back to the text box: playback stops and nothing is shown.
  Future<void> newLine();

  /// Applied to lines added from now on; lines already queued keep theirs.
  Mood mood = Mood.conversational;

  CueItem? get playing => items.where((c) => c.id == playingId).firstOrNull;
  CueItem? get shown => items.where((c) => c.id == shownId).firstOrNull;

  /// The mood buttons: only moods this voice recorded, none when that's just Conversational
  /// (no model here can make a mood it didn't hear).
  List<Mood> get moods {
    final m = [
      for (final x in Mood.values)
        if (person.recorded(x)) x,
    ];
    return m.length > 1 ? m : const [];
  }

  /// Stops the line playing; it stays shown.
  Future<void> stop();

  void setMood(Mood m) {
    mood = m;
    notifyListeners();
  }

  Future<void> add(String text);
  Future<void> play(CueItem item);

  /// Plays a line again; played lines keep their clip until cleared or 24 h after generation.
  Future<void> replay(CueItem item) => play(item);

  /// Hands the line's audio to Android's share sheet, as adjusted.
  Future<void> share(CueItem item);

  /// Why the last share sent nothing (its watermark couldn't be confirmed); null otherwise.
  String? shareError;

  /// The shown take's speed, pitch, pauses and volume.
  TakeAdjust adjustOf(CueItem item) =>
      item.clips.isEmpty ? TakeAdjust.defaults : item.clips[item.current.clamp(0, item.clips.length - 1)].adjust;

  /// Saves [a] on the shown take; it plays and shares that way from now on.
  Future<void> adjust(CueItem item, TakeAdjust a) async {}

  Future<void> resetAdjust(CueItem item) => adjust(item, TakeAdjust.defaults);

  /// Generates the line again with a new seed (different audio); ignored for lines without a clip.
  Future<void> tryAgain(CueItem item);

  /// Shows take [index] of the line; Say it and Share then use it.
  Future<void> showTake(CueItem item, int index);
  Future<void> retry(CueItem item);
  Future<void> remove(CueItem item);

  /// 0..1 for a line being made within its time guess; null when there's no honest fraction
  /// (loading its model, or past the guess): the bar then just moves.
  double? progressOf(CueItem item);

  /// One line of status under a line: its place in the queue, what's being done and a time guess,
  /// or ready / played / failed.
  String statusOf(CueItem item);

  /// The voice model that makes new lines (an id from kTtsModels).
  String modelId = 'qwen';

  Future<bool> modelReady(String id) async => true;

  /// Memory Android could give the app now, in bytes; null when unknown (then no warning).
  Future<int?> freeMemory() async => null;

  /// The model the engine has loaded, or null.
  String? get loadedModel => null;

  /// Unloads the current model and loads [id] with this voice, for the loading screen.
  Future<void> loadModel(String id) async {}

  /// Stops a [loadModel] in progress; it then fails as cancelled.
  Future<void> cancelLoad() async {}

  /// Completes once [modelId] is this voice's real starting model.
  Future<void> get modelSettled => Future.value();
  Stream<DownloadProgress> downloadModel(String id) => const Stream.empty();

  Future<void> setModel(String id) async {
    modelId = id;
    notifyListeners();
  }
}

/// "2nd", "3rd", "11th", "22nd".
String ordinal(int n) {
  final teen = n % 100 >= 11 && n % 100 <= 13;
  final suffix = teen ? 'th' : const {1: 'st', 2: 'nd', 3: 'rd'}[n % 10] ?? 'th';
  return '$n$suffix';
}

/// The model the Speak screen starts on for [p]: the one picked for this voice, unless it was
/// deleted since, else [fallback] (the default from Settings).
Future<String> modelForVoice(Person p, String fallback, Future<bool> Function(String id) ready) async {
  final own = p.model;
  if (own != null && ttsModel(own).id == own && await ready(own)) return own;
  return fallback;
}

/// Where the Speak screen's voice model picker reads and changes the saved choice.
class ModelChoice {
  const ModelChoice({
    required this.current,
    required this.ready,
    required this.download,
    required this.select,
    this.resolve,
  });

  /// Shown at once; [resolve], when given, then settles the model this voice really starts on.
  final String Function() current;
  final Future<String> Function()? resolve;
  final Future<bool> Function(String id) ready;
  final Stream<DownloadProgress> Function(String id) download;
  final Future<void> Function(String id) select;
}

/// From the 2a run-through on the A54 (warm engine): a 61-word line took about 2 minutes and
/// short lines well under one, so roughly 2 seconds per word plus a few seconds of setup.
double estimatedPrepareSeconds(String text) {
  final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
  return 2.0 * words + 5.0;
}

class CueSpeakController extends SpeakController {
  CueSpeakController(
    super.person,
    this._cues,
    this._preparer,
    this._player,
    this._temp,
    this._shares, {
    DateTime Function()? clock,
    this.models,
    this.speeds,
    this.memoryReader,
    this.renderer,
  }) : _clock = clock ?? (() => DateTime.now().toUtc()) {
    final m = models;
    if (m != null) {
      modelId = m.current();
      final r = m.resolve;
      if (r != null) {
        _settled = r().then((id) {
          if (_disposed || id == modelId) return;
          modelId = id;
          notifyListeners();
        });
      }
    }
    _sub = _preparer.updates.listen((_) => unawaited(refresh()));
    _position = _player.position.listen((d) {
      if (playingId == null || _disposed) return;
      playedSeconds = d.inMilliseconds / 1000;
      notifyListeners();
    });
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (items.any((c) => c.status == CueStatus.preparing)) notifyListeners();
    });
  }

  Future<void> _settled = Future.value();

  @override
  Future<void> get modelSettled => _settled;

  @override
  String? get loadedModel => _preparer.loadedModel;

  @override
  Future<void> loadModel(String id) => _preparer.loadModel(person, mood, id);

  @override
  Future<void> cancelLoad() => _preparer.stopLoading();

  final CueRepo _cues;
  final Preparer _preparer;
  final ClipPlayer _player;
  final TempSweeper _temp;
  final ShareService _shares;
  final DateTime Function() _clock;

  /// Learned speed per model for the time guess; null falls back to [estimatedPrepareSeconds].
  final SpeedBook? speeds;

  /// Reads the memory free now; null in tests that don't need it.
  final Future<int?> Function()? memoryReader;

  /// Renders the shown take with its adjustments; null plays the stored clip as it is.
  final TakeRenderer? renderer;

  /// What plays and is measured: the rendered take, or the stored clip if its mark couldn't be
  /// confirmed (Share refuses that case instead, see [share]).
  Future<List<int>> _audio(CueItem item) async {
    final r = renderer;
    if (r == null) return _cues.clipBytes(item);
    try {
      return await r.wav(item);
    } catch (e) {
      // Playback never goes silent because processing failed: the take plays as it was made.
      if (e is! MarkMissing) debugPrint('Fauxnetic render failed: ${e.runtimeType}');
      return _cues.clipBytes(item);
    }
  }

  /// The newest adjust wins; a line stopped by an adjust resumes once, after the last one.
  var _adjustSeq = 0;
  ({String id, double at, double length})? _resume;

  @override
  Future<void> adjust(CueItem item, TakeAdjust a) async {
    final seq = ++_adjustSeq;
    if (playingId == item.id) {
      _resume = (id: item.id, at: playedSeconds, length: lengthSeconds);
      await _stopIfPlaying(item);
    }
    final token = _token;
    await _cues.setAdjust(item.id, item.current, a);
    await refresh();
    if (seq != _adjustSeq) return;
    final latest = items.where((c) => c.id == item.id).firstOrNull;
    if (latest == null) return;
    if (shownId == item.id) await _loadShape(latest);
    if (seq != _adjustSeq) return;
    notifyListeners();
    final r = _resume;
    if (r == null || r.id != item.id) return;
    _resume = null;
    // Not if another line was played or shown in the meantime.
    if (_token != token || shownId != item.id) return;
    final from = r.length > 0 ? r.at * lengthSeconds / r.length : 0.0;
    unawaited(_play(latest, from: Duration(milliseconds: (from * 1000).round())));
  }

  @override
  Future<int?> freeMemory() => memoryReader?.call() ?? Future.value();

  /// Every waiting line in queue order, all voices: the queue is shared.
  List<String> _queue = const [];
  var _busy = false;
  late final StreamSubscription<CueItem> _sub;
  late final StreamSubscription<Duration> _position;
  late final Timer _ticker;
  Future<void>? _run;
  var _token = 0;
  var _disposed = false;

  Future<void> get idle => _run ?? Future.value();

  /// The voice model choice, saved app-wide; null in tests that don't need it.
  final ModelChoice? models;

  @override
  Future<bool> modelReady(String id) => models?.ready(id) ?? Future.value(true);

  @override
  Stream<DownloadProgress> downloadModel(String id) => models?.download(id) ?? const Stream.empty();

  @override
  Future<void> setModel(String id) async {
    await models?.select(id);
    await super.setModel(id);
  }

  Future<void> refresh() async {
    final all = await _cues.all();
    if (_disposed) return;
    items = all.where((c) => c.personId == person.id).toList();
    _queue = [
      for (final c in all)
        if (c.status == CueStatus.queued) c.id,
    ];
    notifyListeners();
  }

  void _kick() {
    _run = _preparer.runUntilEmpty().whenComplete(refresh);
  }

  @override
  Future<void> add(String text) async {
    if (text.trim().isEmpty) return;
    await _cues.add(person.id, text, mood: mood, model: modelId);
    await refresh();
    _kick();
  }

  @override
  Future<void> tryAgain(CueItem item) async {
    if (!item.hasClip) return;
    await _stopIfPlaying(item);
    await _cues.regenerate(item.id, _cues.newSeed(), model: modelId);
    await refresh();
    _kick();
  }

  @override
  Future<void> showTake(CueItem item, int index) async {
    await _stopIfPlaying(item);
    await _cues.select(item.id, index);
    await refresh();
  }

  @override
  Future<void> stop() async {
    final p = playing;
    if (p == null) return;
    await _stopIfPlaying(p);
    notifyListeners();
  }

  Future<void> _stopIfPlaying(CueItem item) async {
    if (playingId != item.id) return;
    _token++;
    playingId = null;
    playedSeconds = 0;
    _busy = false;
    await _player.stop();
  }

  @override
  Future<void> share(CueItem item) async {
    shareError = null;
    try {
      final sent = await _shares.share(item, person.name, bytes: renderer?.wav);
      if (!sent) await _cues.enforceRetention(_clock());
    } on MarkMissing {
      shareError = MarkMissing.message;
    }
    await refresh();
  }

  @override
  Future<void> retry(CueItem item) async {
    await _cues.retry(item.id);
    await refresh();
    _kick();
  }

  @override
  Future<void> remove(CueItem item) async {
    // Drop it from the list right away so a swiped row never reappears while the delete runs.
    items = items.where((c) => c.id != item.id).toList();
    if (shownId == item.id) shownId = null;
    notifyListeners();
    await _cues.remove(item.id);
    // If it was being made, stop the engine now rather than finish a line nobody wants.
    await _preparer.cancelIfGone();
    await refresh();
  }

  @override
  Future<void> select(CueItem item) async {
    if (!item.hasClip) return;
    final p = playing;
    if (p != null && p.id != item.id) await _stopIfPlaying(p);
    shownId = item.id;
    await _loadShape(item);
    notifyListeners();
  }

  @override
  Future<void> newLine() async {
    final p = playing;
    if (p != null) await _stopIfPlaying(p);
    shownId = null;
    _clearShape();
    notifyListeners();
  }

  /// Waveform, length and word starts of [item]'s take from its WAV [bytes].
  void _shape(CueItem item, List<int> bytes) {
    waveform = wavPeaks(bytes, 32);
    lengthSeconds = wavSeconds(bytes);
    words = item.text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    // 20 ms frames: fine enough to find the pauses between words.
    wordStarts = estimateWordStarts(words, wavPeaks(bytes, max(1, (lengthSeconds * 50).round())), lengthSeconds);
  }

  void _clearShape() {
    waveform = const [];
    lengthSeconds = 0;
    words = const [];
    wordStarts = const [];
  }

  /// The shown take's waveform and length, read from its clip without playing it.
  Future<void> _loadShape(CueItem item) async {
    try {
      _shape(item, await _audio(item));
    } catch (_) {
      _clearShape();
    }
  }

  /// The newest tap always wins: the token is taken and the old clip stopped before any await,
  /// so two quick taps can never both play, and an interrupted line is never marked played.
  @override
  Future<void> play(CueItem item) => _play(item);

  Future<void> _play(CueItem item, {Duration from = Duration.zero}) async {
    if (!item.hasClip) return;
    final mine = ++_token;
    if (_busy) unawaited(_player.stop());
    _busy = true;
    if (isExpired(item, _clock())) {
      await _cues.enforceRetention(_clock());
      if (mine == _token) _busy = false;
      await refresh();
      return;
    }
    File? clip;
    var finished = false;
    try {
      final bytes = await _audio(item);
      if (mine != _token) return;
      clip = await _temp.create('.wav');
      await clip.writeAsBytes(bytes, flush: true);
      if (mine != _token) return;
      _shape(item, bytes);
      playingId = item.id;
      shownId = item.id;
      playedSeconds = from.inMilliseconds / 1000;
      notifyListeners();
      finished = await _player.play(clip, from: from);
    } catch (_) {
      finished = false;
    } finally {
      if (clip != null) await _temp.release(clip);
      if (mine == _token) {
        playingId = null;
        playedSeconds = 0;
        _busy = false;
      }
    }
    if (finished && mine == _token) await _cues.markPlayed(item.id);
    if (!_disposed) await refresh();
  }

  /// The model making (or that will make) [item]: what the preparer opened, else the line's own.
  TtsModel _modelOf(CueItem item) => ttsModel(_preparer.modelOf(item.id) ?? item.model ?? modelId);

  double _guessSeconds(CueItem item) {
    final rate = speeds?.secondsPerWord(_modelOf(item).id);
    return rate == null ? estimatedPrepareSeconds(item.text) : rate * wordCount(item.text);
  }

  double? _elapsed(CueItem item) {
    final since = _preparer.startedAt(item.id);
    if (_preparer.phaseOf(item.id) != PrepPhase.making || since == null) return null;
    return _clock().difference(since).inMilliseconds / 1000;
  }

  @override
  double? progressOf(CueItem item) {
    final e = _elapsed(item);
    if (e == null) return null;
    final guess = _guessSeconds(item);
    return e < guess ? e / guess : null;
  }

  @override
  String statusOf(CueItem item) {
    final label = _modelOf(item).label;
    switch (item.status) {
      case CueStatus.queued:
        final n = _queue.indexOf(item.id) + 1;
        return n <= 1 ? 'Next in line' : '${ordinal(n)} in line';
      case CueStatus.preparing:
        final e = _elapsed(item);
        if (e == null) return 'Loading $label…';
        final left = _guessSeconds(item) - e;
        if (left <= 0) {
          final s = e.floor();
          return 'Taking longer than usual · ${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
        }
        final when = left < 60
            ? 'about ${max(5, (left / 5).ceil() * 5)} s left'
            : 'about ${(left / 60).ceil()} min left';
        return 'Making with $label · $when';
      case CueStatus.ready:
        return 'ready';
      case CueStatus.played:
        return 'played';
      case CueStatus.failed:
        return 'failed';
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _token++;
    unawaited(_player.stop());
    _ticker.cancel();
    unawaited(_sub.cancel());
    unawaited(_position.cancel());
    super.dispose();
  }
}
