import 'dart:async';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../audio/trim.dart';
import '../audio/wav.dart';
import '../engine/crispasr_engine.dart';
import '../engine/voice_engine.dart';
import '../people/people_repo.dart';
import '../people/person.dart';
import '../recording/scripts.dart';
import '../storage/temp_sweeper.dart';
import 'cue.dart';
import 'cue_repo.dart';
import 'speed_book.dart';

/// Keeps the app process alive with the screen off (lines preparing, models downloading).
abstract class BackgroundKeeper {
  /// [title] and [text] are shown in the notification while it runs.
  Future<void> start({String title, String text});
  Future<void> stop();
}

class ForegroundKeeper implements BackgroundKeeper {
  static void init() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'preparing_lines',
        channelName: 'Preparing lines',
        channelDescription: 'Shown while cloned lines are being prepared.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
      // The Wi-Fi lock keeps a model download going with the screen off.
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  @override
  Future<void> start({String title = 'Preparing lines', String text = 'Fauxnetic is preparing your cue list.'}) async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.updateService(notificationTitle: title, notificationText: text);
      return;
    }
    if (await FlutterForegroundTask.checkNotificationPermission() != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    await FlutterForegroundTask.startService(
      serviceTypes: [ForegroundServiceTypes.dataSync],
      notificationTitle: title,
      notificationText: text,
    );
  }

  @override
  Future<void> stop() => FlutterForegroundTask.stopService();
}

class StartupReport {
  const StartupReport(this.tempFilesRemoved, this.expiredClipsRemoved);
  final int tempFilesRemoved;
  final int expiredClipsRemoved;
}

const kGenericFailureMessage = 'Preparing this line failed. Tap to retry.';

/// Run at every app start, before anything else touches the cue list.
Future<StartupReport> startupCleanup(CueRepo cues, TempSweeper temp, DateTime now) async {
  final swept = await temp.sweep();
  // Half-written encrypted files from a crash mid-write (the real file is only replaced by rename).
  if (await cues.dir.exists()) {
    await for (final e in cues.dir.list(recursive: true)) {
      if (e is File && e.path.endsWith('.tmp')) await e.delete();
    }
  }
  await cues.recoverAfterRestart();
  await cues.sweepUnindexedClips();
  final expired = await cues.enforceRetention(now);
  return StartupReport(swept, expired);
}

/// A line being made first opens its voice model (slow for a big one, and not counted in its time
/// guess), then makes speech.
enum PrepPhase { loading, making }

class Preparer {
  Preparer(
    this._engine,
    this._cues,
    this._people,
    this._keeper, {
    DateTime Function()? clock,
    Duration Function()? keepFor,
    String? Function()? engineLabel,
    this.speeds,
  }) : _clock = clock ?? (() => DateTime.now().toUtc()),
       _keepFor = keepFor ?? (() => kRetention),
       _engineLabel = engineLabel ?? (() => null);

  /// Learned seconds per word for each model; null in tests that don't time lines.
  final SpeedBook? speeds;

  final _phase = <String, PrepPhase>{};
  final _makingSince = <String, DateTime>{};

  /// What the line [cueId] is doing now: opening its model, or making speech; null when not
  /// being made.
  PrepPhase? phaseOf(String cueId) => _phase[cueId];

  /// When speech making started for [cueId] (after its model was opened).
  DateTime? startedAt(String cueId) => _makingSince[cueId];

  final _modelOf = <String, String>{};

  /// The model really making [cueId] (the default when its own was deleted); null when not
  /// being made.
  String? modelOf(String cueId) => _modelOf[cueId];

  /// Name of the voice model in use, stored on each take.
  final String? Function() _engineLabel;

  final VoiceEngine _engine;
  final CueRepo _cues;
  final PeopleRepo _people;
  final BackgroundKeeper _keeper;
  final DateTime Function() _clock;

  /// The keep-for setting; a new line is deleted after it, or with its person if that's sooner.
  final Duration Function() _keepFor;
  final _updates = StreamController<CueItem>.broadcast();
  bool _loaded = false;
  Future<void>? _running;

  Stream<CueItem> get updates => _updates.stream;

  /// Starts work if idle; returns the in-flight run otherwise.
  Future<void> runUntilEmpty() => _running ??= _run().whenComplete(() => _running = null);

  var _unloading = false;

  /// The line being made, or null between lines.
  String? _makingId;

  /// Completes when the line being made is done.
  Completer<void>? _lineDone;

  /// Cancel on the loading screen: ends the engine (and the load) unless a line is being made,
  /// which is never cut off by this.
  Future<void> stopLoading() async {
    if (_makingId == null) await _engine.cancel();
  }

  /// The model the engine has loaded, or null.
  String? get loadedModel => _engine.openModel;

  /// Loads [model] (and [p]'s voice) now, so the Speak screen can show a loading screen instead of
  /// the first line paying for it (owner, 2026-11-16). The old model is unloaded first by ending
  /// the engine process, which frees all its memory. A line being made is never cut off: this waits
  /// for it. Throws the engine's error, e.g. out of memory or cancelled.
  Future<void> loadModel(Person p, Mood mood, String model) async {
    final want = await _engine.modelFor(model);
    while (_makingId != null) {
      await _lineDone?.future;
    }
    if (_engine.openModel == want) return;
    await _wake();
    try {
      if (_engine.openModel != null) await _engine.cancel();
      await _engine.prepare(p, mood, model: model);
    } finally {
      await _sleep();
    }
  }

  /// The line already being stopped, so a second delete doesn't stop the engine twice.
  String? _stopping;

  /// After anything deletes lines (Remove, a person, Clear lines, Delete everything, expiry): if
  /// the line being made is gone, stop the engine now instead of letting it run for minutes
  /// (owner, 2026-11-16). Does nothing between lines or while that line still exists.
  Future<void> cancelIfGone() async {
    final id = _makingId;
    if (id == null || id == _stopping) return;
    if ((await _cues.all()).any((c) => c.id == id)) return;
    if (_makingId != id || _stopping == id) return;
    _stopping = id;
    await _engine.cancel();
  }

  /// Before models are removed: stops the line being made (it goes back to the queue), starts no
  /// other, then frees the engine. The next [runUntilEmpty] loads it again.
  Future<void> unload() async {
    _unloading = true;
    try {
      if (_makingId != null) {
        _stopping = _makingId;
        await _engine.cancel();
      }
      await _running;
      await _engine.dispose();
      _loaded = false;
    } finally {
      _unloading = false;
    }
  }

  Future<void> _run() async {
    var started = false;
    try {
      while (!_unloading) {
        final next = (await _cues.all()).where((c) => c.status == CueStatus.queued).firstOrNull;
        if (next == null) break;
        if (!started) {
          started = true;
          await _wake();
        }
        await _prepare(next);
      }
    } finally {
      if (started) await _sleep();
    }
  }

  /// Lines being made and models loading each keep the app awake (a foreground notification), so
  /// Android doesn't freeze the engine when the owner leaves the screen. Counted, so one finishing
  /// doesn't let the other be frozen.
  var _awake = 0;

  Future<void> _wake() async {
    if (_awake++ == 0) await _keeper.start();
  }

  Future<void> _sleep() async {
    if (--_awake == 0) await _keeper.stop();
  }

  /// update() on a removed line is a no-op, so a line deleted mid-preparation stays deleted.
  Future<void> _set(CueItem c) async {
    await _cues.update(c);
    _updates.add(c);
  }

  Future<void> _prepare(CueItem c) async {
    final working = c.copyWith(status: CueStatus.preparing, attempts: c.attempts + 1);
    await _set(working);
    _makingId = c.id;
    final done = _lineDone = Completer<void>();
    try {
      final person = (await _people.all()).where((p) => p.id == c.personId).firstOrNull;
      if (person == null) {
        await _set(working.copyWith(status: CueStatus.failed, error: 'This person was deleted.'));
        return;
      }
      if (!_loaded) {
        await _engine.load();
        _loaded = true;
      }
      _modelOf[c.id] = await _engine.modelFor(c.model);
      _phase[c.id] = PrepPhase.loading;
      _updates.add(working);
      await _engine.prepare(person, c.mood, model: c.model);
      final since = _clock();
      _phase[c.id] = PrepPhase.making;
      _makingSince[c.id] = since;
      _updates.add(working);
      final raw = await _engine.speak(c.text, seed: c.seed);
      final took = _clock().difference(since).inMilliseconds / 1000;
      final used = _engine.openModel;
      if (used != null) await speeds?.record(used, wordCount(c.text), took);
      // The model sometimes opens or ends a line with a second of quiet; a line that is all quiet is kept as is.
      final trimmed = trimGenerated(raw, _engine.sampleRate);
      final audio = trimmed.isEmpty ? raw : trimmed;
      final now = _clock();
      final own = now.add(_keepFor());
      final voiceGoes = person.expiresAt;
      final expiresAt = voiceGoes != null && voiceGoes.isBefore(own) ? voiceGoes : own;
      final ready = await _cues.storeClip(
        working.copyWith(seed: _engine.lastSeed ?? working.seed),
        encodeWav(audio, _engine.sampleRate),
        now,
        expiresAt: expiresAt,
        engine: _engineLabel(),
      );
      _updates.add(ready ?? working);
    } on EngineError catch (e) {
      if (e.kind == EngineErrorKind.cancelled) {
        // Stopped on purpose: a removed line stays gone (update is a no-op); one stopped by
        // unload goes back to the queue, not counted as a failed try.
        await _set(c.copyWith(status: CueStatus.queued));
        return;
      }
      final oom = e.kind == EngineErrorKind.outOfMemory;
      // The engine respawns its worker on the next load(), so retries can succeed.
      if (oom) _loaded = false;
      await _set(working.copyWith(status: CueStatus.failed, error: oom ? kOutOfMemoryMessage : e.message));
    } on ConsentRequired catch (e) {
      await _set(working.copyWith(status: CueStatus.failed, error: e.toString()));
    } catch (_) {
      await _set(working.copyWith(status: CueStatus.failed, error: kGenericFailureMessage));
    } finally {
      _phase.remove(c.id);
      _makingSince.remove(c.id);
      _modelOf.remove(c.id);
      _makingId = null;
      if (_stopping == c.id) _stopping = null;
      done.complete();
    }
  }

  Future<void> dispose() => _updates.close();
}
