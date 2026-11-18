import 'dart:math';
import 'dart:typed_data';

/// Cuts quiet from both ends, keeping [keepSeconds] around the speech. Quiet means 20 ms frames below
/// [thresholdDb] dBFS. Audio with no frame above the threshold comes back empty. [keepSeconds] is
/// 0.3 s because 0.1 s clipped soft word starts ("h", "f") on the A54 (2026-11-15).
Float32List trimSilence(Float32List pcm, int rate, {double thresholdDb = -50, double keepSeconds = 0.3}) {
  final frame = max(1, rate ~/ 50);
  final limit = pow(10, thresholdDb / 20);
  bool loud(int start) {
    final end = min(start + frame, pcm.length);
    var sum = 0.0;
    for (var i = start; i < end; i++) {
      sum += pcm[i] * pcm[i];
    }
    return end > start && sqrt(sum / (end - start)) > limit;
  }

  var first = -1;
  for (var i = 0; i < pcm.length; i += frame) {
    if (loud(i)) {
      first = i;
      break;
    }
  }
  if (first < 0) return Float32List(0);
  var last = first;
  for (var i = ((pcm.length - 1) ~/ frame) * frame; i >= first; i -= frame) {
    if (loud(i)) {
      last = min(i + frame, pcm.length);
      break;
    }
  }
  final keep = (keepSeconds * rate).round();
  return Float32List.fromList(pcm.sublist(max(0, first - keep), min(pcm.length, last + keep)));
}

/// Where to end audio that may be at most [maxSeconds] long: in the quietest 0.1 s of the last
/// [searchSeconds] before the limit (the latest such stretch, within 3 dB), so the cut falls in a
/// pause between words rather than inside one. Returns a sample count; audio that fits is not cut.
/// Uses the audio, not Whisper's word times, which were up to a second off on the A54 (2026-11-16).
int cutInPause(Float32List pcm, int rate, {required double maxSeconds, double searchSeconds = 3}) {
  final limit = (maxSeconds * rate).floor();
  if (pcm.length <= limit) return pcm.length;
  final frame = max(1, rate ~/ 50);
  const window = 5; // 0.1 s
  final first = max(0, (limit - searchSeconds * rate).ceil()) ~/ frame;
  final end = limit ~/ frame;
  if (end - first < window) return limit;
  final energy = List<double>.generate(end - first, (k) {
    var sum = 0.0;
    for (var i = (first + k) * frame; i < (first + k + 1) * frame; i++) {
      sum += pcm[i] * pcm[i];
    }
    return sum / frame;
  });
  final db = List<double>.generate(energy.length - window + 1, (w) {
    var sum = 0.0;
    for (var k = w; k < w + window; k++) {
      sum += energy[k];
    }
    return 10 * log(sum / window + 1e-12) / ln10;
  });
  final quietest = db.reduce(min);
  final w = db.lastIndexWhere((d) => d <= quietest + 3);
  return (first + w) * frame + window * frame ~/ 2;
}

/// Trims a generated line. The model sometimes opens or closes a line with a click or breath and
/// seconds of near-silence, above [trimSilence]'s fixed threshold (owner's "haha" take,
/// 2026-11-15: 4 s before the laugh). So the speech is found relative to the line itself: the first
/// and last stretch of at least 0.1 s within 12 dB of its loudest frame, widened over any sound
/// joined to it by less than 0.25 s of quiet (a soft first word stays), keeping [keepSeconds] each
/// side. Sounds cut off by longer quiet are dropped. Checked on 100 clones; the owner confirmed
/// by ear that no first word was lost. Falls back to [trimSilence] with no clear stretch of speech.
Float32List trimGenerated(Float32List pcm, int rate, {double keepSeconds = 0.3}) {
  final frame = max(1, rate ~/ 50);
  final n = pcm.length ~/ frame;
  if (n == 0) return trimSilence(pcm, rate, keepSeconds: keepSeconds);
  final db = List<double>.generate(n, (f) {
    var sum = 0.0;
    for (var i = f * frame; i < (f + 1) * frame; i++) {
      sum += pcm[i] * pcm[i];
    }
    return 20 * log(sqrt(sum / frame) + 1e-9) / ln10;
  });
  final loud = db.reduce(max) - 12;
  const run = 5; // 0.1 s
  const joinGap = 13; // 0.26 s
  const floor = -50.0;

  int? firstRun(Iterable<int> order) {
    for (final i in order) {
      if (i + run > n) continue;
      if (List.generate(run, (k) => db[i + k] >= loud).every((x) => x)) return i;
    }
    return null;
  }

  final s = firstRun(List.generate(n, (i) => i));
  final eRun = firstRun(List.generate(n, (i) => n - 1 - i));
  if (s == null || eRun == null || db.reduce(max) <= floor) {
    return trimSilence(pcm, rate, keepSeconds: keepSeconds);
  }
  int widen(int from, int step) {
    var edge = from, quiet = 0;
    for (var i = from + step; i >= 0 && i < n; i += step) {
      if (db[i] > floor) {
        edge = i;
        quiet = 0;
      } else if (++quiet >= joinGap) {
        break;
      }
    }
    return edge;
  }

  final start = widen(s, -1) * frame;
  final end = (widen(eRun + run - 1, 1) + 1) * frame;
  final keep = (keepSeconds * rate).round();
  return Float32List.fromList(pcm.sublist(max(0, start - keep), min(pcm.length, end + keep)));
}
