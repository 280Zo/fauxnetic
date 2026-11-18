import 'dart:math';
import 'dart:typed_data';

/// Band-limited resampling with a Hann-windowed sinc. When downsampling, the cutoff drops to the
/// new Nyquist and the filter widens, so content above it is removed rather than folded back.
Float32List resample(Float32List x, int from, int to) {
  if (from == to) return Float32List.fromList(x);
  const half = 16;
  final ratio = to / from;
  final cutoff = min(1.0, ratio);
  final width = half / cutoff;
  final step = from / to;
  final out = Float32List((x.length * ratio).floor());
  for (var n = 0; n < out.length; n++) {
    final t = n * step;
    final lo = max(0, (t - width).ceil());
    final hi = min(x.length - 1, (t + width).floor());
    var acc = 0.0;
    for (var k = lo; k <= hi; k++) {
      final d = t - k;
      final a = d * cutoff;
      final sinc = a == 0 ? 1.0 : sin(pi * a) / (pi * a);
      final window = 0.5 + 0.5 * cos(pi * d / width);
      acc += x[k] * sinc * window;
    }
    out[n] = acc * cutoff;
  }
  return out;
}
