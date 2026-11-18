import 'dart:async';
import 'dart:io';

import 'package:just_audio/just_audio.dart';

abstract class ClipPlayer {
  /// Plays [f] from [from]; completes with true when it played to the end, false when stopped.
  Future<bool> play(File f, {Duration from = Duration.zero});
  Future<void> stop();

  /// How far into the clip playback is.
  Stream<Duration> get position;
}

class JustAudioClipPlayer implements ClipPlayer {
  final _player = AudioPlayer();
  Completer<bool>? _active;

  @override
  Future<bool> play(File f, {Duration from = Duration.zero}) async {
    final previous = _active;
    if (previous != null && !previous.isCompleted) previous.complete(false);
    final done = Completer<bool>();
    _active = done;
    await _player.setFilePath(f.path, initialPosition: from);
    final sub = _player.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed && !done.isCompleted) done.complete(true);
    });
    unawaited(_player.play());
    try {
      return await done.future;
    } finally {
      await sub.cancel();
    }
  }

  @override
  Stream<Duration> get position => _player.positionStream;

  @override
  Future<void> stop() async {
    await _player.stop();
    final a = _active;
    if (a != null && !a.isCompleted) a.complete(false);
  }
}
