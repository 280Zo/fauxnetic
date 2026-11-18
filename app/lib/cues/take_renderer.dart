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

  String? _key;
  Uint8List? _wav;

  /// The rendered, re-marked WAV of [item]'s shown take. Throws [MarkMissing] when the watermark
  /// can't be confirmed afterwards.
  Future<Uint8List> wav(CueItem item) async {
    final take = item.clips[item.current.clamp(0, item.clips.length - 1)];
    final key = '${take.file}|${take.adjust.toJson()}';
    if (key == _key && _wav != null) return _wav!;
    final bytes = Uint8List.fromList(await _cues.clipBytes(item));
    final marker = _marker;
    final adjust = take.adjust;
    final words = item.text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final watch = Stopwatch()..start();
    final out = await _run(() => _render(bytes, adjust, words, marker));
    // On the phone's log (no text of the line): how long a take takes to render.
    debugPrint('Fauxnetic render: ${watch.elapsedMilliseconds} ms for ${wavSeconds(bytes).toStringAsFixed(1)} s');
    if (out == null) throw const MarkMissing();
    _key = key;
    _wav = out;
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
