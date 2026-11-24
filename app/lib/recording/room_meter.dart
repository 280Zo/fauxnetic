import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

enum RoomLevel {
  unknown(''),
  quiet('Room: quiet'),
  someNoise('Room: some noise'),
  noisy('Room: noisy');

  const RoomLevel(this.label);
  final String label;
}

const _frame = 320; // 20 ms at 16 kHz
const _window = 150; // the last 3 s
const _minFrames = 25; // half a second before saying anything

/// Over this the room is noisy: a voice close to the phone (about -20 dBFS) stands out by less than
/// the take check's 20 dB, so the cleaner is worth turning on.
const kNoisyRoomDb = -40.0;

/// Over this there is some noise (the owner's home takes measure -50 to -62).
const kSomeNoiseDb = -50.0;

/// How noisy the room is, from the last 3 s of microphone audio (16 kHz). Like the take check, the
/// room is the quiet end of the 20 ms frame levels, so speech in between doesn't count.
class RoomMeter {
  final _levels = Queue<double>();
  final _pending = <double>[];

  void add(Float32List pcm) {
    _pending.addAll(pcm);
    var used = 0;
    while (_pending.length - used >= _frame) {
      var s = 0.0;
      for (var i = used; i < used + _frame; i++) {
        s += _pending[i] * _pending[i];
      }
      _levels.addLast(10 * log(s / _frame + 1e-12) / ln10);
      if (_levels.length > _window) _levels.removeFirst();
      used += _frame;
    }
    _pending.removeRange(0, used);
  }

  /// The room's level in dBFS (the 10th percentile of recent frames), or null before half a second.
  double? get roomDb {
    if (_levels.length < _minFrames) return null;
    final sorted = _levels.toList()..sort();
    return sorted[((sorted.length - 1) * 0.10).round()];
  }

  RoomLevel get level {
    final db = roomDb;
    if (db == null) return RoomLevel.unknown;
    if (db > kNoisyRoomDb) return RoomLevel.noisy;
    if (db > kSomeNoiseDb) return RoomLevel.someNoise;
    return RoomLevel.quiet;
  }
}
