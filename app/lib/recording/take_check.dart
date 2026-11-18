import 'dart:math';
import 'dart:typed_data';

enum TakeProblem { tooQuiet, clipping, noisy, missedWords }

const _frame = 320; // 20 ms at 16 kHz
const _silentDb = -120.0;
const _quietDb = -40.0;
const _noisyDb = -45.0;
const _clipLevel = 0.99;
const _clipShare = 0.005;
const _maxWer = 0.35;

double _db(double rms) => rms <= 0 ? _silentDb : max(_silentDb, 20 * log(rms) / ln10);

double _rms(Float32List s, int start, int end) {
  var sum = 0.0;
  for (var i = start; i < end; i++) {
    sum += s[i] * s[i];
  }
  return end > start ? sqrt(sum / (end - start)) : 0;
}

double _percentile(List<double> sorted, double p) => sorted[((sorted.length - 1) * p).round()];

/// Checks one recorded take (16 kHz mono). Speech level is the loud end of the 20 ms frame levels
/// and the noise floor the quiet end, so pauses between words measure the room.
TakeProblem? checkTake(Float32List pcm16k, {String? script, String? heard}) {
  if (pcm16k.isEmpty) return TakeProblem.tooQuiet;
  var clipped = 0;
  for (final s in pcm16k) {
    if (s.abs() >= _clipLevel) clipped++;
  }
  if (clipped / pcm16k.length > _clipShare) return TakeProblem.clipping;

  final levels = <double>[
    for (var i = 0; i < pcm16k.length; i += _frame) _db(_rms(pcm16k, i, min(i + _frame, pcm16k.length))),
  ]..sort();
  if (_percentile(levels, 0.95) < _quietDb) return TakeProblem.tooQuiet;
  if (_percentile(levels, 0.10) > _noisyDb) return TakeProblem.noisy;
  if (script != null && heard != null && wordErrorRate(script, heard) > _maxWer) return TakeProblem.missedWords;
  return null;
}

String takeHint(TakeProblem? p) => switch (p) {
  null => 'Good level. Room is quiet.',
  TakeProblem.tooQuiet => 'Speak a little louder.',
  TakeProblem.clipping => 'Move the phone a bit further away.',
  TakeProblem.noisy => "It's noisy here. Try a quieter spot.",
  TakeProblem.missedWords => 'We missed some words. Try that line again.',
};

List<String> _words(String t) =>
    t.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').replaceAll(RegExp('[^a-z ]'), '').split(' ')
      ..removeWhere((w) => w.isEmpty);

/// Word error rate with the harness normalisation (lowercase, letters and spaces only).
double wordErrorRate(String reference, String hypothesis) {
  final ref = _words(reference), hyp = _words(hypothesis);
  final d = List<int>.generate(hyp.length + 1, (j) => j);
  for (var i = 1; i <= ref.length; i++) {
    var prev = d[0];
    d[0] = i;
    for (var j = 1; j <= hyp.length; j++) {
      final cur = d[j];
      d[j] = min(min(d[j] + 1, d[j - 1] + 1), prev + (ref[i - 1] == hyp[j - 1] ? 0 : 1));
      prev = cur;
    }
  }
  return d[hyp.length] / max(ref.length, 1);
}

/// Live input level for the recording screen's meter.
class LevelMeter {
  static const _floorDb = -60.0;
  static const _keep = 128;
  final _history = <double>[];

  void add(Float32List chunk) {
    if (chunk.isEmpty) return;
    _history.add(_db(_rms(chunk, 0, chunk.length)).clamp(-90.0, 0.0));
    if (_history.length > _keep) _history.removeAt(0);
  }

  double get levelDb => _history.isEmpty ? -90 : _history.last;

  /// The last [n] levels scaled to 0..1 (-60 dBFS and below is 0), oldest first, padded with 0.
  List<double> recentBars(int n) {
    final recent = _history.length > n ? _history.sublist(_history.length - n) : _history;
    return [
      for (var i = recent.length; i < n; i++) 0.0,
      for (final db in recent) ((db - _floorDb) / -_floorDb).clamp(0.0, 1.0),
    ];
  }
}
