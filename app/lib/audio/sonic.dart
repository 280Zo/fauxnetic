// Port of Sonic (Sonic.java, github.com/waywardgeek/sonic at b93885dcb70aae50c6f76b0fe4e0868f029a077e),
// Copyright 2010, 2011 Bill Cox, licensed under the Apache License 2.0. Ported to Dart for Fauxnetic:
// mono only, speed and pitch only (no volume, rate, chord pitch or byte formats); the 16-bit integer
// arithmetic is kept so it behaves as the original.
import 'dart:typed_data';

/// [pcm] (mono, -1..1) at [speed] (2 = twice as fast) and [pitch] (a factor: 2 = an octave up),
/// each without changing the other. No change returns [pcm] itself.
Float32List sonicProcess(Float32List pcm, int rate, {double speed = 1, double pitch = 1}) {
  if (speed == 1 && pitch == 1) return pcm;
  final s = _Sonic(rate)
    ..speed = speed
    ..pitch = pitch;
  s.write(pcm);
  s.flush();
  return s.read();
}

const _minPitch = 65;
const _maxPitch = 400;
const _amdfFreq = 4000;
const _sincPoints = 12;
const _sincTableSize = 601;

const _sincTable = <int>[
  0, 0, 0, 0, 0, 0, 0, -1, -1, -2, -2, -3, -4, -6, -7, -9, -10, -12, -14, //
  -17, -19, -21, -24, -26, -29, -32, -34, -37, -40, -42, -44, -47, -48, -50,
  -51, -52, -53, -53, -53, -52, -50, -48, -46, -43, -39, -34, -29, -22, -16,
  -8, 0, 9, 19, 29, 41, 53, 65, 79, 92, 107, 121, 137, 152, 168, 184, 200,
  215, 231, 247, 262, 276, 291, 304, 317, 328, 339, 348, 357, 363, 369, 372,
  374, 375, 373, 369, 363, 355, 345, 332, 318, 300, 281, 259, 234, 208, 178,
  147, 113, 77, 39, 0, -41, -85, -130, -177, -225, -274, -324, -375, -426,
  -478, -530, -581, -632, -682, -731, -779, -825, -870, -912, -951, -989,
  -1023, -1053, -1080, -1104, -1123, -1138, -1149, -1154, -1155, -1151,
  -1141, -1125, -1105, -1078, -1046, -1007, -963, -913, -857, -796, -728,
  -655, -576, -492, -403, -309, -210, -107, 0, 111, 225, 342, 462, 584, 708,
  833, 958, 1084, 1209, 1333, 1455, 1575, 1693, 1807, 1916, 2022, 2122, 2216,
  2304, 2384, 2457, 2522, 2579, 2625, 2663, 2689, 2706, 2711, 2705, 2687,
  2657, 2614, 2559, 2491, 2411, 2317, 2211, 2092, 1960, 1815, 1658, 1489,
  1308, 1115, 912, 698, 474, 241, 0, -249, -506, -769, -1037, -1310, -1586,
  -1864, -2144, -2424, -2703, -2980, -3254, -3523, -3787, -4043, -4291,
  -4529, -4757, -4972, -5174, -5360, -5531, -5685, -5819, -5935, -6029,
  -6101, -6150, -6175, -6175, -6149, -6096, -6015, -5905, -5767, -5599,
  -5401, -5172, -4912, -4621, -4298, -3944, -3558, -3141, -2693, -2214,
  -1705, -1166, -597, 0, 625, 1277, 1955, 2658, 3386, 4135, 4906, 5697, 6506,
  7332, 8173, 9027, 9893, 10769, 11654, 12544, 13439, 14335, 15232, 16128,
  17019, 17904, 18782, 19649, 20504, 21345, 22170, 22977, 23763, 24527,
  25268, 25982, 26669, 27327, 27953, 28547, 29107, 29632, 30119, 30569,
  30979, 31349, 31678, 31964, 32208, 32408, 32565, 32677, 32744, 32767,
  32744, 32677, 32565, 32408, 32208, 31964, 31678, 31349, 30979, 30569,
  30119, 29632, 29107, 28547, 27953, 27327, 26669, 25982, 25268, 24527,
  23763, 22977, 22170, 21345, 20504, 19649, 18782, 17904, 17019, 16128,
  15232, 14335, 13439, 12544, 11654, 10769, 9893, 9027, 8173, 7332, 6506,
  5697, 4906, 4135, 3386, 2658, 1955, 1277, 625, 0, -597, -1166, -1705,
  -2214, -2693, -3141, -3558, -3944, -4298, -4621, -4912, -5172, -5401,
  -5599, -5767, -5905, -6015, -6096, -6149, -6175, -6175, -6150, -6101,
  -6029, -5935, -5819, -5685, -5531, -5360, -5174, -4972, -4757, -4529,
  -4291, -4043, -3787, -3523, -3254, -2980, -2703, -2424, -2144, -1864,
  -1586, -1310, -1037, -769, -506, -249, 0, 241, 474, 698, 912, 1115, 1308,
  1489, 1658, 1815, 1960, 2092, 2211, 2317, 2411, 2491, 2559, 2614, 2657,
  2687, 2705, 2711, 2706, 2689, 2663, 2625, 2579, 2522, 2457, 2384, 2304,
  2216, 2122, 2022, 1916, 1807, 1693, 1575, 1455, 1333, 1209, 1084, 958, 833,
  708, 584, 462, 342, 225, 111, 0, -107, -210, -309, -403, -492, -576, -655,
  -728, -796, -857, -913, -963, -1007, -1046, -1078, -1105, -1125, -1141,
  -1151, -1155, -1154, -1149, -1138, -1123, -1104, -1080, -1053, -1023, -989,
  -951, -912, -870, -825, -779, -731, -682, -632, -581, -530, -478, -426,
  -375, -324, -274, -225, -177, -130, -85, -41, 0, 39, 77, 113, 147, 178,
  208, 234, 259, 281, 300, 318, 332, 345, 355, 363, 369, 373, 375, 374, 372,
  369, 363, 357, 348, 339, 328, 317, 304, 291, 276, 262, 247, 231, 215, 200,
  184, 168, 152, 137, 121, 107, 92, 79, 65, 53, 41, 29, 19, 9, 0, -8, -16,
  -22, -29, -34, -39, -43, -46, -48, -50, -52, -53, -53, -53, -52, -51, -50,
  -48, -47, -44, -42, -40, -37, -34, -32, -29, -26, -24, -21, -19, -17, -14,
  -12, -10, -9, -7, -6, -4, -3, -2, -2, -1, -1, 0, 0, 0, 0, 0, 0, 0,
];

class _Sonic {
  _Sonic(this.sampleRate)
    : minPeriod = sampleRate ~/ _maxPitch,
      maxPeriod = sampleRate ~/ _minPitch,
      maxRequired = 2 * (sampleRate ~/ _minPitch) {
    input = Int16List(maxRequired);
    output = Int16List(maxRequired);
    pitchBuf = Int16List(maxRequired);
    down = Int16List(maxRequired);
  }

  final int sampleRate, minPeriod, maxPeriod, maxRequired;
  double speed = 1, pitch = 1;
  late Int16List input, output, pitchBuf, down;
  int nIn = 0, nOut = 0, nPitch = 0;
  int remainingInputToCopy = 0;
  int oldRatePosition = 0, newRatePosition = 0;
  int prevPeriod = 0, prevMinDiff = 0, minDiff = 0, maxDiff = 0;

  static Int16List _grow(Int16List a, int n) => Int16List(n)..setRange(0, a.length < n ? a.length : n, a);

  void _ensureOut(int n) {
    if (nOut + n > output.length) output = _grow(output, output.length + (output.length >> 1) + n);
  }

  void _ensureIn(int n) {
    if (nIn + n > input.length) input = _grow(input, input.length + (input.length >> 1) + n);
  }

  static void _move(Int16List dst, int dstPos, Int16List src, int srcPos, int n) {
    if (n > 0) dst.setRange(dstPos, dstPos + n, Int16List.sublistView(src, srcPos, srcPos + n));
  }

  void write(Float32List samples) {
    _ensureIn(samples.length);
    for (var i = 0; i < samples.length; i++) {
      input[nIn + i] = (samples[i].clamp(-1.0, 1.0) * 32767).toInt();
    }
    nIn += samples.length;
    _process();
  }

  Float32List read() {
    final out = Float32List(nOut);
    for (var i = 0; i < nOut; i++) {
      out[i] = output[i] / 32767;
    }
    nOut = 0;
    return out;
  }

  void flush() {
    final remaining = nIn;
    final s = speed / pitch;
    final r = pitch;
    final expected = nOut + ((remaining / s + nPitch) / r + 0.5).toInt();
    _ensureIn(remaining + 2 * maxRequired);
    input.fillRange(remaining, remaining + 2 * maxRequired, 0);
    nIn += 2 * maxRequired;
    _process();
    if (nOut > expected) nOut = expected;
    nIn = 0;
    remainingInputToCopy = 0;
    nPitch = 0;
  }

  void _removeInput(int position) {
    final remaining = nIn - position;
    _move(input, 0, input, position, remaining);
    nIn = remaining;
  }

  void _copyToOutput(Int16List samples, int position, int n) {
    _ensureOut(n);
    _move(output, nOut, samples, position, n);
    nOut += n;
  }

  int _copyInputToOutput(int position) {
    var n = remainingInputToCopy;
    if (n > maxRequired) n = maxRequired;
    _copyToOutput(input, position, n);
    remainingInputToCopy -= n;
    return n;
  }

  void _downSample(Int16List samples, int position, int skip) {
    final n = maxRequired ~/ skip;
    for (var i = 0; i < n; i++) {
      var v = 0;
      for (var j = 0; j < skip; j++) {
        v += samples[position + i * skip + j];
      }
      down[i] = v ~/ skip;
    }
  }

  int _findPeriodInRange(Int16List samples, int position, int minP, int maxP) {
    var bestPeriod = 0, worstPeriod = 255;
    var minD = 1, maxD = 0;
    for (var period = minP; period <= maxP; period++) {
      var diff = 0;
      for (var i = 0; i < period; i++) {
        final s = samples[position + i], p = samples[position + period + i];
        diff += s >= p ? s - p : p - s;
      }
      if (diff * bestPeriod < minD * period) {
        minD = diff;
        bestPeriod = period;
      }
      if (diff * worstPeriod > maxD * period) {
        maxD = diff;
        worstPeriod = period;
      }
    }
    minDiff = minD ~/ bestPeriod;
    maxDiff = maxD ~/ worstPeriod;
    return bestPeriod;
  }

  bool _prevPeriodBetter(int minD, int maxD, bool preferNew) {
    if (minD == 0 || prevPeriod == 0) return false;
    if (preferNew) {
      if (maxD > minD * 3) return false;
      if (minD * 2 <= prevMinDiff * 3) return false;
    } else if (minD <= prevMinDiff) {
      return false;
    }
    return true;
  }

  int _findPeriod(Int16List samples, int position, bool preferNew) {
    int period;
    final skip = sampleRate > _amdfFreq ? sampleRate ~/ _amdfFreq : 1;
    if (skip == 1) {
      period = _findPeriodInRange(samples, position, minPeriod, maxPeriod);
    } else {
      _downSample(samples, position, skip);
      period = _findPeriodInRange(down, 0, minPeriod ~/ skip, maxPeriod ~/ skip) * skip;
      var minP = period - (skip << 2), maxP = period + (skip << 2);
      if (minP < minPeriod) minP = minPeriod;
      if (maxP > maxPeriod) maxP = maxPeriod;
      period = _findPeriodInRange(samples, position, minP, maxP);
    }
    final ret = _prevPeriodBetter(minDiff, maxDiff, preferNew) ? prevPeriod : period;
    prevMinDiff = minDiff;
    prevPeriod = period;
    return ret;
  }

  static void _overlapAdd(int n, Int16List out, int outPos, Int16List down, int downPos, Int16List up, int upPos) {
    for (var t = 0; t < n; t++) {
      out[outPos + t] = (down[downPos + t] * (n - t) + up[upPos + t] * t) ~/ n;
    }
  }

  int _skipPitchPeriod(Int16List samples, int position, double speed, int period) {
    int n;
    if (speed >= 2.0) {
      n = period ~/ (speed - 1.0);
    } else {
      n = period;
      remainingInputToCopy = (period * (2.0 - speed) / (speed - 1.0)).toInt();
    }
    _ensureOut(n);
    _overlapAdd(n, output, nOut, samples, position, samples, position + period);
    nOut += n;
    return n;
  }

  int _insertPitchPeriod(Int16List samples, int position, double speed, int period) {
    int n;
    if (speed < 0.5) {
      n = (period * speed / (1.0 - speed)).toInt();
    } else {
      n = period;
      remainingInputToCopy = (period * (2.0 * speed - 1.0) / (1.0 - speed)).toInt();
    }
    _ensureOut(period + n);
    _move(output, nOut, samples, position, period);
    _overlapAdd(n, output, nOut + period, samples, position + period, samples, position);
    nOut += period + n;
    return n;
  }

  void _changeSpeed(double speed) {
    final n = nIn;
    var position = 0;
    if (nIn < maxRequired) return;
    do {
      if (remainingInputToCopy > 0) {
        position += _copyInputToOutput(position);
      } else {
        final period = _findPeriod(input, position, true);
        if (speed > 1.0) {
          final made = _skipPitchPeriod(input, position, speed, period);
          position += period + made;
        } else {
          position += _insertPitchPeriod(input, position, speed, period);
        }
      }
    } while (position + maxRequired <= n);
    _removeInput(position);
  }

  void _moveNewToPitchBuffer(int originalOut) {
    final n = nOut - originalOut;
    if (nPitch + n > pitchBuf.length) pitchBuf = _grow(pitchBuf, pitchBuf.length + (pitchBuf.length >> 1) + n);
    _move(pitchBuf, nPitch, output, originalOut, n);
    nOut = originalOut;
    nPitch += n;
  }

  void _removePitchSamples(int n) {
    if (n == 0) return;
    _move(pitchBuf, 0, pitchBuf, n, nPitch - n);
    nPitch -= n;
  }

  int _sincCoefficient(int i, int ratio, int width) {
    const lobePoints = (_sincTableSize - 1) ~/ _sincPoints;
    final left = i * lobePoints + (ratio * lobePoints) ~/ width;
    final position = i * lobePoints * width + ratio * lobePoints - left * width;
    return ((_sincTable[left] * (width - position) + _sincTable[left + 1] * position) << 1) ~/ width;
  }

  int _interpolate(Int16List inp, int inPos, int oldRate, int newRate) {
    var total = 0;
    final position = newRatePosition * oldRate;
    final leftPosition = oldRatePosition * newRate;
    final rightPosition = (oldRatePosition + 1) * newRate;
    final ratio = rightPosition - position - 1;
    final width = rightPosition - leftPosition;
    for (var i = 0; i < _sincPoints; i++) {
      total += inp[inPos + i] * _sincCoefficient(i, ratio, width);
    }
    // 64-bit here, so clamp where the original detected 32-bit overflow.
    return (total >> 16).clamp(-32768, 32767);
  }

  void _adjustRate(double rate, int originalOut) {
    var newRate = sampleRate ~/ rate;
    var oldRate = sampleRate;
    while (newRate > (1 << 14) || oldRate > (1 << 14)) {
      newRate >>= 1;
      oldRate >>= 1;
    }
    if (nOut == originalOut) return;
    _moveNewToPitchBuffer(originalOut);
    var position = 0;
    for (; position < nPitch - _sincPoints; position++) {
      while ((oldRatePosition + 1) * newRate > newRatePosition * oldRate) {
        _ensureOut(1);
        output[nOut] = _interpolate(pitchBuf, position, oldRate, newRate);
        newRatePosition++;
        nOut++;
      }
      oldRatePosition++;
      if (oldRatePosition == oldRate) {
        oldRatePosition = 0;
        newRatePosition = 0;
      }
    }
    _removePitchSamples(position);
  }

  void _process() {
    final originalOut = nOut;
    final s = speed / pitch;
    final r = pitch;
    if (s > 1.00001 || s < 0.99999) {
      _changeSpeed(s);
    } else {
      _copyToOutput(input, 0, nIn);
      nIn = 0;
    }
    if (r != 1.0) _adjustRate(r, originalOut);
  }
}
