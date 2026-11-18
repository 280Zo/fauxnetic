import 'dart:math';
import 'dart:typed_data';

const kRate = 16000;

double _amp(double rmsDb) => pow(10, rmsDb / 20).toDouble();

/// A 220 Hz sine whose RMS is [rmsDb] dBFS.
List<double> tone(double seconds, double rmsDb) {
  final a = _amp(rmsDb) * sqrt2;
  return List.generate((seconds * kRate).round(), (i) => a * sin(2 * pi * 220 * i / kRate));
}

/// White noise whose RMS is [rmsDb] dBFS.
List<double> noise(double seconds, double rmsDb, Random r) {
  final a = _amp(rmsDb) * sqrt(3);
  return List.generate((seconds * kRate).round(), (_) => (r.nextDouble() * 2 - 1) * a);
}

/// Half-second "words" at [speechDb] separated by half-second gaps at [floorDb] (6.5 s in all).
Float32List bursts(double speechDb, double floorDb) {
  final r = Random(7);
  final out = <double>[];
  for (var i = 0; i < 6; i++) {
    out
      ..addAll(noise(0.5, floorDb, r))
      ..addAll(tone(0.5, speechDb));
  }
  out.addAll(noise(0.5, floorDb, r));
  return Float32List.fromList(out);
}

/// A clean take: speech at -20 dBFS in a quiet room.
Float32List goodTake() => bursts(-20, -70);
