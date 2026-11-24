import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'audio/wav.dart';
import 'cues/cue_repo.dart';
import 'cues/preparer.dart';
import 'cues/share.dart';
import 'cues/speed_book.dart';
import 'audio/marking.dart';
import 'models/download_center.dart';
import 'models/line_ready.dart';
import 'models/startup_downloads.dart';
import 'platform/network.dart';
import 'cues/take_renderer.dart';
import 'engine/crispasr_engine.dart';
import 'engine/tts_models.dart';
import 'models/keep_alive.dart';
import 'models/model_store.dart';
import 'people/expiry.dart';
import 'people/people_repo.dart';
import 'people/person.dart';
import 'people/voice_end_repair.dart';
import 'recording/reading_controller.dart';
import 'recording/recorder.dart';
import 'recording/reference_builder.dart';
import 'recording/scripts.dart';
import 'recording/takes.dart';
import 'recording/transcriber.dart';
import 'recording/voice_cleaner.dart';
import 'settings/settings_store.dart';
import 'storage/storage_report.dart';
import 'storage/temp_sweeper.dart';
import 'storage/vault.dart';
import 'ui/clip_player.dart';
import 'ui/models_section.dart';
import 'ui/speak_controller.dart';
import 'upload/android_decoder.dart';
import 'upload/upload_pipeline.dart';

/// A reading session's controller and the transcribers it owns; [close] frees their memory.
class ReadingSession {
  ReadingSession(this.controller, this._transcribers);
  final ReadingController controller;
  final List<Transcriber> _transcribers;

  Future<void> close() async {
    controller.dispose();
    for (final t in _transcribers) {
      await t.dispose();
    }
  }
}

/// Everything the screens need, built once at app start.
class AppServices {
  AppServices._({
    required this.models,
    required this.temp,
    required this.people,
    required this.takes,
    required this.builder,
    required this.cues,
    required this.preparer,
    required this.player,
    required this.shares,
    required this.upload,
    required this.settingsStore,
    required this.settings,
    required this.downloads,
  });

  /// Background downloads (the voice set after the first launch, and extra models).
  final DownloadCenter downloads;

  final ModelStore models;
  final TempSweeper temp;
  final PeopleRepo people;
  final TakeStore takes;
  final ReferenceBuilder builder;
  final CueRepo cues;
  final Preparer preparer;
  final ClipPlayer player;
  final ShareService shares;
  final UploadPipeline upload;
  final SettingsStore settingsStore;

  /// The app rebuilds its theme from this; screens read keep-for from it.
  final ValueNotifier<AppSettings> settings;
  final MicSource _mic = RecordMicSource();

  /// The files of one optional voice model, in the same folder as the core models.
  ModelStore storeFor(TtsModel m) => ModelStore(models.dir, models: m.files);

  /// Qwen once its talker and codec are in (they download in the background after the recording
  /// set); the others once their own files are in.
  Future<bool> modelReady(String id) async {
    final m = ttsModel(id);
    return m.files.isEmpty
        ? await ModelStore(models.dir, models: kVoiceModels).allPresent()
        : await storeFor(m).allPresent();
  }

  /// Whether a line for [model] (null: the default) can be made now; see [lineCanRun].
  Future<bool> lineReady(String? model) => lineCanRun(
    want: ttsModel(model ?? settings.value.model).id,
    fallback: ttsModel(settings.value.model).id,
    ready: modelReady,
    job: downloads.job,
  );

  /// Starts an extra model's background download (2026-11-18).
  Future<void> startModelDownload(String id) {
    final m = ttsModel(id);
    return downloads.enqueue(m.id, m.label, m.files);
  }

  /// The default model: what voices use until one is picked for them on the Speak screen.
  Future<void> setDefaultModel(String id) async {
    settings.value = settings.value.copyWith(model: ttsModel(id).id);
    await settingsStore.save(settings.value);
  }

  /// Settings → Models: every model, whether it's on the phone, and the space it takes.
  Future<List<ModelInfo>> modelInfo() async => [
    for (final m in kTtsModels)
      if (await modelReady(m.id))
        ModelInfo(model: m, downloaded: true, bytes: m.downloadBytes)
      else
        ModelInfo(model: m, downloaded: false, bytes: 0),
  ];

  /// Deletes an optional model's files (Qwen is part of the core download). The engine lets go of
  /// it first: a line being made stops and goes back to the queue. A deleted default falls back to
  /// Qwen.
  Future<void> deleteModel(String id) async {
    final m = ttsModel(id);
    if (m.files.isEmpty) return;
    await downloads.cancel(m.id);
    await clearWanted(models.dir, m.id);
    await preparer.unload();
    await storeFor(m).removeOwn();
    if (settings.value.model == m.id) await setDefaultModel(kTtsModels.first.id);
    // Lines still waiting carry on, with the default for any that wanted the deleted model.
    unawaited(preparer.runUntilEmpty());
  }

  Future<void> setTheme(ThemeChoice c) async {
    settings.value = settings.value.copyWith(theme: c);
    await settingsStore.save(settings.value);
  }

  /// Saves the keep-for setting. A shorter one moves every delete time earlier and deletes what is
  /// now due; a longer one only affects voices and lines made from now on.
  Future<void> setKeepFor(Duration d) async {
    final shorter = d < settings.value.keepFor;
    // Delete times move first, so nothing reads the new setting against old delete times.
    if (shorter) {
      await people.shorten(d);
      await cues.shorten(d);
    }
    settings.value = settings.value.copyWith(keepFor: d);
    await settingsStore.save(settings.value);
    if (!shorter) return;
    final now = DateTime.now().toUtc();
    await enforceExpiry(now);
    await cues.enforceRetention(now);
    await preparer.cancelIfGone();
  }

  Future<int> countVoicesOlderThan(Duration d) async => voicesOlderThan(await people.all(), d, DateTime.now().toUtc());

  /// Every line and take for everyone, now.
  Future<void> clearLines() async {
    await cues.clear();
    await preparer.cancelIfGone();
    await shares.sweepShares();
  }

  /// All people, voices, recordings and lines. The models and settings stay.
  Future<void> deleteEverything() async {
    for (final p in await people.all()) {
      await deletePerson(p.id);
    }
    await clearLines();
    await sweepLeftovers();
    await temp.sweep();
  }

  Future<StorageReport> storage() => measureStorage(models: models.dir, support: people.dir);

  /// One keep-alive notification shared by line preparation and downloads.
  static final keeper = SharedKeeper(ForegroundKeeper());

  /// The first launch's download: only what recording needs (the voice set follows in the
  /// background, see [startBackground]). Keeps running with the screen off.
  Stream<DownloadProgress> downloadRecordingSet() => keepAliveWhile(
    ModelStore(models.dir, models: kRecordingModels).download(),
    keeper,
    title: 'Downloading voice models',
    text: 'Fauxnetic keeps downloading with the screen off.',
  );

  /// The recording-set files not yet on the phone (the first-launch screen shows while any are).
  Future<List<PinnedModel>> missingRecordingSet() => ModelStore(models.dir, models: kRecordingModels).missing();

  /// Once the recording set is here: the voice set, and any extra model whose download was cut
  /// off, continue in the background.
  Future<void> startBackground() => queueMissingDownloads(models.dir, downloads.enqueue);

  /// Stops downloads and the line being made (it goes back to the queue), frees the engine, then
  /// deletes the model files and their partial downloads.
  Future<void> removeModels() async {
    await downloads.cancelAll();
    await preparer.unload();
    await models.removeAll();
  }

  static Future<AppServices> create() async {
    final support = await getApplicationSupportDirectory();
    final cache = await getTemporaryDirectory();
    final vault = Vault(SecureKeyStore(), checkFile: File('${support.path}/vault.check'));
    final temp = TempSweeper(cache);
    final takes = TakeStore(support, vault);
    final people = PeopleRepo(support, vault, temp, takes);
    final builder = ReferenceBuilder(support, vault, takes);
    final cues = CueRepo(support, vault);
    final models = ModelStore(Directory('${support.path}/models'));
    final settingsStore = SettingsStore(File('${support.path}/settings.json'));
    final settings = ValueNotifier(await settingsStore.load());
    Duration keepFor() => settings.value.keepFor;
    final engine = CrispasrEngine(
      // In its own process, so a removed line can be stopped at once (see ProcessWorker).
      () async => ProcessWorker(),
      models,
      people,
      temp,
      model: () => ttsModel(settings.value.model),
      ready: (m) async => m.files.isEmpty || await ModelStore(models.dir, models: m.files).allPresent(),
    );
    ForegroundKeeper.init();
    final speeds = SpeedBook(File('${support.path}/speeds.json'));
    await speeds.load();
    late final AppServices s;
    final preparer = Preparer(
      engine,
      cues,
      people,
      keeper,
      keepFor: keepFor,
      engineLabel: () => ttsModel(engine.openModel ?? settings.value.model).label,
      speeds: speeds,
      // Lines whose model is still downloading wait (2026-11-18).
      ready: (m) => s.lineReady(m),
    );
    final shares = ShareService(
      cues,
      Directory('${cache.path}/share'),
      pluginDir: Directory('${cache.path}/share_plus'),
    );
    s = AppServices._(
      models: models,
      temp: temp,
      people: people,
      takes: takes,
      builder: builder,
      cues: cues,
      preparer: preparer,
      player: JustAudioClipPlayer(),
      shares: shares,
      upload: UploadPipeline(models, people, takes, builder, decode: AndroidDecoder(temp).decode16k, keepFor: keepFor),
      settingsStore: settingsStore,
      settings: settings,
      downloads: DownloadCenter(
        store: (files) => ModelStore(models.dir, models: files),
        network: currentNetwork,
        keeper: keeper,
        // A model arriving lets the lines waiting for it be made.
        onDone: (id) {
          unawaited(clearWanted(models.dir, id));
          unawaited(preparer.runUntilEmpty());
        },
        // An extra model asked for is tried again at the next launch until it is here.
        onEnqueue: (id) {
          if (id != kTtsModels.first.id) unawaited(markWanted(models.dir, id));
        },
      ),
    );
    final now = DateTime.now().toUtc();
    // People from before voices expired start their clock now; then anything already due goes,
    // including voices that expired while the app was closed.
    await people.stampMissing(now, keepFor());
    await s.enforceExpiry(now);
    await startupCleanup(cues, temp, now);
    await shares.sweepShares();
    try {
      await s.sweepLeftovers();
    } catch (_) {
      // If people can't be read, keep every take; nothing is lost by sweeping on a later launch.
    }
    await models.removeUnpinned();
    await FilePicker.clearTemporaryFiles();
    // The end check needs only Whisper; lines whose model is still downloading wait.
    if ((await s.missingRecordingSet()).isEmpty) unawaited(s._repairThenPrepare());
    s._startRetention();
    return s;
  }

  /// Checks voices saved before the end fix once (see repairVoiceEnds), then makes waiting lines.
  Future<void> _repairThenPrepare() async {
    final whisper = WhisperTranscriber(models, ModelRole.asrBase);
    try {
      await repairVoiceEnds(people, whisper, temp);
    } catch (_) {
      // Whatever couldn't be checked now is tried again at the next launch.
    } finally {
      await whisper.dispose();
    }
    await preparer.runUntilEmpty();
  }

  Timer? _retentionTimer;
  AppLifecycleListener? _lifecycle;

  /// Android can keep the app alive for days, so expiry and the line wipe also run every minute
  /// and whenever the app comes back to the foreground, not only at launch.
  void _startRetention() {
    Future<void> enforce() async {
      try {
        final now = DateTime.now().toUtc();
        await enforceExpiry(now);
        await cues.enforceRetention(now);
        await preparer.cancelIfGone();
        await shares.sweepStale();
      } catch (_) {}
    }

    _retentionTimer = Timer.periodic(const Duration(minutes: 1), (_) => enforce());
    _lifecycle = AppLifecycleListener(onResume: enforce);
  }

  /// Names of people whose voices expired and haven't been announced yet; the People screen takes them.
  final expiredNames = <String>[];

  /// Deletes every expired voice (with its recordings and lines) and remembers the names to announce.
  Future<List<String>> enforceExpiry(DateTime now) async {
    final names = await expireVoices(people, deletePerson, now, settings.value.keepFor);
    expiredNames.addAll(names);
    if (names.isNotEmpty) await sweepLeftovers();
    return names;
  }

  /// Recordings, references and lines that belong to no one on the phone: left by a session that
  /// was still saving when its person expired or was deleted, or by a crash.
  Future<void> sweepLeftovers() async {
    final ids = {for (final p in await people.all()) p.id};
    await takes.sweepOrphans(ids);
    await people.sweepOrphanRefs();
    await cues.removeOrphans(ids);
  }

  List<String> takeExpired() {
    final out = [...expiredNames];
    expiredNames.clear();
    return out;
  }

  void dispose() {
    _retentionTimer?.cancel();
    _lifecycle?.dispose();
  }

  /// Deletes the person, their voices and recordings, and every line in their voice.
  Future<void> deletePerson(String id) async {
    await cues.removeForPerson(id);
    // Also reached by expiry and Delete everything: a line of theirs being made stops now.
    await preparer.cancelIfGone();
    await people.delete(id);
    await shares.sweepShares();
  }

  SpeakController speakController(Person p) {
    final c = CueSpeakController(
      p,
      cues,
      preparer,
      player,
      temp,
      shares,
      speeds: preparer.speeds,
      renderer: TakeRenderer(cues, CrispMarker.new),
      downloads: downloads,
      memoryReader: () async {
        try {
          return parseMemAvailable(await File('/proc/meminfo').readAsString());
        } catch (_) {
          return null; // unknown: no warning
        }
      },
      models: ModelChoice(
        current: () => settings.value.model,
        resolve: () => modelForVoice(p, settings.value.model, modelReady),
        ready: modelReady,
        select: (id) => people.setModel(p.id, id),
      ),
    );
    unawaited(c.refresh());
    return c;
  }

  /// tiny.en follows along while reading; base.en checks each finished take.
  /// Earlier takes of [mood] are passed in so Add more and Re-record ask for text not used yet.
  Future<ReadingSession> readingSession(Person p, Mood mood, {bool replace = false}) async {
    final earlier = (await takes.forPerson(p.id)).where((t) => t.mood == mood).toList();
    final follow = WhisperTranscriber(models, ModelRole.asrTiny);
    final full = WhisperTranscriber(models, ModelRole.asrBase);
    final c = ReadingController(
      p,
      mood,
      _mic,
      follow,
      full,
      takes,
      people,
      builder,
      replace: replace,
      earlier: earlier,
      cleaner: rnnoiseCleaner,
      denoise: rnnoiseDenoise,
    );
    return ReadingSession(c, [follow, full]);
  }

  Future<File?> pickUploadFile() async {
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: kUploadExtensions);
    final path = f?.path;
    return path == null ? null : File(path);
  }

  /// The picker leaves a plain copy of the file in the cache; it is removed once decoded.
  Future<UploadAnalysis> analyzeUpload(File f) async {
    try {
      return await upload.analyze(f);
    } finally {
      await FilePicker.clearTemporaryFiles();
    }
  }

  /// Plays a few seconds of a voice found in a file, from a temp WAV removed right after.
  Future<void> playSample(VoiceCluster v) => playPcm16k(v.sample);

  /// Plays 16 kHz audio (a sample, or a word's stretch on Check the words) from a temp WAV removed
  /// right after; a new call stops the one playing.
  Future<void> playPcm16k(Float32List pcm) async {
    final f = await temp.create('.wav');
    try {
      await f.writeAsBytes(encodeWav(pcm, 16000), flush: true);
      await player.play(f);
    } finally {
      await temp.release(f);
    }
  }
}
