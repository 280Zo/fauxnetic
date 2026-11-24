import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/recording/voice_cleaner.dart';

void main() {
  Float32List ramp(int from, int n) => Float32List.fromList([for (var i = 0; i < n; i++) (from + i).toDouble()]);

  test('each chunk is cleaned with the second before it, and only its own part comes back', () async {
    final windows = <int>[];
    final d = LiveDenoiser((pcm) async {
      windows.add(pcm.length);
      return Float32List.fromList([for (final v in pcm) -v]);
    });
    final a = await d.add(ramp(0, 10000));
    final b = await d.add(ramp(10000, 10000));
    final c = await d.add(ramp(20000, 10000));
    expect(a, ramp(0, 10000).map((v) => -v).toList());
    expect(b, ramp(10000, 10000).map((v) => -v).toList());
    expect(c, ramp(20000, 10000).map((v) => -v).toList());
    expect(windows, [10000, 20000, 16000 + 10000], reason: 'at most a second of context');
  });

  test('results come back in order even when cleaning takes longer for some', () async {
    final gates = <Completer<void>>[];
    final d = LiveDenoiser((pcm) async {
      final g = Completer<void>();
      gates.add(g);
      await g.future;
      return pcm;
    });
    final order = <double>[];
    final f1 = d.add(ramp(1, 1)).then((x) => order.add(x.first));
    final f2 = d.add(ramp(2, 1)).then((x) => order.add(x.first));
    await Future<void>.delayed(Duration.zero);
    gates.first.complete();
    await Future<void>.delayed(Duration.zero);
    gates.last.complete();
    await Future.wait([f1, f2]);
    expect(order, [1, 2]);
  });

  test('a failure gives the chunk back as it was', () async {
    final d = LiveDenoiser((pcm) async => throw StateError('native'));
    expect(await d.add(ramp(5, 3)), ramp(5, 3));
  });

  test('when cleaning falls behind, chunks come back as they were instead of piling up', () async {
    final gate = Completer<void>();
    final d = LiveDenoiser((pcm) async {
      await gate.future;
      return Float32List(pcm.length);
    });
    final pending = [for (var i = 0; i < 3; i++) d.add(ramp(1, 4))];
    final skipped = await d.add(ramp(9, 2));
    expect(skipped, ramp(9, 2));
    gate.complete();
    await Future.wait(pending);
  });
}
