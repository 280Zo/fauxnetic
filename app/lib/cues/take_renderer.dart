import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../audio/marking.dart';
import '../audio/render.dart';
import '../audio/take_adjust.dart';
import '../audio/wav.dart';
import 'cue.dart';
import 'cue_repo.dart';

/// The shown take of a line as it is heard and shared: rendered with its settings, watermarked
/// again (pitch changes erase the mark) and checked. The last result is kept in memory.
class TakeRenderer {
  TakeRenderer(this._cues, this._marker, {FutureOr<R> Function<R>(R Function())? run}) : _run = run ?? Isolate.run;

  final CueRepo _cues;

  /// Made inside the background isolate: FFI handles don't cross isolates.
  final Marker Function() _marker;
  final FutureOr<R> Function<R>(R Function()) _run;

  // The last result (audio, or a failed mark check as null) and the line it belongs to.
  String? _key, _line;
  Uint8List? _wav;
  final _inflight = <String, Future<Uint8List?>>{};

  /// The rendered, re-marked WAV of [item]'s shown take. Throws [MarkMissing] when the watermark
  /// can't be confirmed afterwards, and [StateError] for a line with no take.
  Future<Uint8List> wav(CueItem item) async {
    if (item.clips.isEmpty) throw StateError('line ${item.id} has no take');
    final take = item.clips[item.current.clamp(0, item.clips.length - 1)];
    final key = '${take.file}|${take.adjust.toJson()}';
    final Uint8List? out;
    if (key == _key) {
      out = _wav;
    } else {
      // A second request for the same take while it renders waits for that render.
      // (A block body: returning the removed future would make whenComplete wait for itself.)
      out = await (_inflight[key] ??= _renderNow(item, take.adjust).whenComplete(() {
        _inflight.remove(key);
      }));
      _key = key;
      _line = item.id;
      _wav = out;
    }
    if (out == null) throw const MarkMissing();
    return out;
  }

  /// Drops what is kept for line [id] (it was removed).
  void forget(String id) {
    if (_line != id) return;
    _key = _line = _wav = null;
  }

  Future<Uint8List?> _renderNow(CueItem item, TakeAdjust adjust) async {
    final bytes = Uint8List.fromList(await _cues.clipBytes(item));
    final marker = _marker;
    final words = item.text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final watch = Stopwatch()..start();
    final out = await _run(() => _render(bytes, adjust, words, marker));
    if (kDebugMode) {
      debugPrint('Fauxnetic render: ${watch.elapsedMilliseconds} ms for ${wavSeconds(bytes).toStringAsFixed(1)} s');
    }
    return out;
  }
}

Uint8List? _render(Uint8List bytes, TakeAdjust adjust, List<String> words, Marker Function() makeMarker) {
  final rate = wavSampleRate(bytes);
  final marker = makeMarker();
  final marked = marker.embed(renderTake(wavSamples(bytes), rate, adjust, words: words));
  if (marker.detect(marked) <= kMarkDetected) return null;
  return encodeWav(marked, rate);
}
