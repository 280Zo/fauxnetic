import 'dart:async';

import 'package:flutter/foundation.dart';

import '../cues/preparer.dart';
import '../platform/network.dart';
import 'keep_alive.dart';
import 'model_store.dart';

enum JobState { queued, downloading, waitingWifi, waitingNetwork, failed, done }

/// One download in the queue: the voice set ("Voice model") or an extra model.
class DownloadJob {
  DownloadJob(this.id, this.label, this.files, this.total);
  final String id;
  final String label;
  final List<PinnedModel> files;
  final int total;
  JobState state = JobState.queued;
  int received = 0;
  String? error;

  /// The user pressed "Use mobile data" on it (until it finishes or the app restarts).
  bool allowMetered = false;

  int get left => total - received;
  bool get pending => state != JobState.done && state != JobState.failed;
}

/// The background downloads (2026-11-18): one at a time, Wi-Fi unless the user allowed mobile data
/// on a job, resuming partial files, with the keep-alive notification only while bytes move. A
/// lost connection waits and continues by itself; a checksum, space or server failure waits for
/// Retry.
class DownloadCenter extends ChangeNotifier {
  DownloadCenter({
    required ModelStore Function(List<PinnedModel> files) store,
    required Future<NetKind> Function() network,
    required BackgroundKeeper keeper,
    this.poll = const Duration(seconds: 5),
    this.onDone,
  }) : _store = store,
       _network = network,
       _keeper = keeper;

  final ModelStore Function(List<PinnedModel> files) _store;
  final Future<NetKind> Function() _network;
  final BackgroundKeeper _keeper;

  /// How often the connection is checked while waiting or downloading.
  final Duration poll;
  final void Function(String id)? onDone;

  final _jobs = <DownloadJob>[];
  DownloadJob? _active;
  StreamSubscription<DownloadProgress>? _sub;
  Timer? _wait, _watch;
  var _pumping = false, _disposed = false;

  List<DownloadJob> get jobs => List.unmodifiable(_jobs);
  DownloadJob? job(String id) => _jobs.where((j) => j.id == id).firstOrNull;

  /// What the People bar shows: the job transferring, else the first one not done.
  DownloadJob? get current => _active ?? _jobs.where((j) => j.state != JobState.done).firstOrNull;

  /// Adds a download of [files]; a job with this id that is already there is left as it is.
  Future<void> enqueue(String id, String label, List<PinnedModel> files) async {
    if (job(id) != null) return;
    final total = files.fold<int>(0, (n, f) => n + f.size);
    final j = DownloadJob(id, label, files, total)..received = total - await _store(files).bytesLeft();
    if (job(id) != null || _disposed) return;
    _jobs.add(j);
    notifyListeners();
    await _pump();
  }

  void allowMobileData(String id) {
    job(id)?.allowMetered = true;
    notifyListeners();
    unawaited(_pump());
  }

  void retry(String id) {
    final j = job(id);
    if (j == null || j.state != JobState.failed) return;
    j
      ..state = JobState.queued
      ..error = null;
    notifyListeners();
    unawaited(_pump());
  }

  /// Stops and removes a job (its model is being deleted); its partial file is the caller's to delete.
  Future<void> cancel(String id) async {
    if (_active?.id == id) await _stop();
    _jobs.removeWhere((j) => j.id == id);
    notifyListeners();
    await _pump();
  }

  Future<void> cancelAll() async {
    await _stop();
    _jobs.clear();
    _wait?.cancel();
    _wait = null;
    notifyListeners();
  }

  Future<void> _stop() async {
    _watch?.cancel();
    _watch = null;
    final sub = _sub;
    _sub = null;
    _active = null;
    await sub?.cancel();
  }

  bool _mayRun(DownloadJob j, NetKind net) => net == NetKind.unmetered || (net == NetKind.metered && j.allowMetered);

  Future<void> _pump() async {
    if (_pumping || _active != null || _disposed) return;
    _pumping = true;
    try {
      final pending = _jobs.where((j) => j.pending).toList();
      if (pending.isEmpty) return;
      final net = await _network();
      if (_active != null || _disposed) return;
      final next = pending.where((j) => _mayRun(j, net)).firstOrNull;
      if (next == null) {
        for (final j in pending) {
          j.state = net == NetKind.none ? JobState.waitingNetwork : JobState.waitingWifi;
        }
        notifyListeners();
        _wait ??= Timer(poll, () {
          _wait = null;
          unawaited(_pump());
        });
        return;
      }
      _start(next);
    } finally {
      _pumping = false;
    }
  }

  void _start(DownloadJob j) {
    _active = j
      ..state = JobState.downloading
      ..error = null;
    for (final other in _jobs.where((o) => o != j && o.state == JobState.downloading)) {
      other.state = JobState.queued;
    }
    notifyListeners();
    unawaited(_run(j));
  }

  Future<void> _run(DownloadJob j) async {
    final store = _store(j.files);
    // Bytes of files already complete; the file arriving adds its own count (which includes its
    // resumed part).
    final missing = await store.missing();
    var done = j.total - missing.fold<int>(0, (n, f) => n + f.size);
    String? file;
    var fileSize = 0;
    if (_active != j) return;
    _sub =
        keepAliveWhile(
          store.download(),
          _keeper,
          title: 'Downloading ${j.label}',
          text: 'Fauxnetic keeps downloading with the screen off.',
        ).listen(
          (p) {
            if (file != null && p.model != file) done += fileSize;
            file = p.model;
            fileSize = p.total;
            j.received = done + p.received;
            notifyListeners();
          },
          onError: (Object e) {
            _end(j);
            if (e is ModelStoreError && e.kind == ModelErrorKind.network) {
              j.state = JobState.waitingNetwork;
            } else {
              j
                ..state = JobState.failed
                ..error = e is ModelStoreError ? e.message : 'The download failed.';
            }
            notifyListeners();
            unawaited(_pump());
          },
          onDone: () {
            if (j.state != JobState.downloading) return; // failed or stopped above
            _end(j);
            j
              ..state = JobState.done
              ..received = j.total;
            notifyListeners();
            onDone?.call(j.id);
            unawaited(_pump());
          },
        );
    _watch = Timer.periodic(poll, (_) => unawaited(_check(j)));
  }

  void _end(DownloadJob j) {
    if (_active != j) return;
    _watch?.cancel();
    _watch = null;
    _sub = null;
    _active = null;
  }

  /// While transferring: a switch to mobile data (not allowed for this job) or a lost connection
  /// stops it, keeping the partial file, until the network allows it again.
  Future<void> _check(DownloadJob j) async {
    if (_active != j) return;
    final net = await _network();
    if (_active != j || _mayRun(j, net)) return;
    await _stop();
    j.state = net == NetKind.none ? JobState.waitingNetwork : JobState.waitingWifi;
    notifyListeners();
    await _pump();
  }

  @override
  void dispose() {
    _disposed = true;
    _wait?.cancel();
    unawaited(_stop());
    super.dispose();
  }
}
