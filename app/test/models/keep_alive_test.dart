import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/cues/preparer.dart';
import 'package:fauxnetic/models/keep_alive.dart';

class _Keeper implements BackgroundKeeper {
  final events = <String>[];
  @override
  Future<void> start({String title = '', String text = ''}) async => events.add('start $title');
  @override
  Future<void> stop() async => events.add('stop');
}

/// A keeper whose start finishes only when [gate] does.
class _SlowKeeper implements BackgroundKeeper {
  _SlowKeeper(this.inner, this.gate);
  final _Keeper inner;
  final Future<void> gate;
  @override
  Future<void> start({String title = '', String text = ''}) async {
    await gate;
    await inner.start(title: title, text: text);
  }

  @override
  Future<void> stop() => inner.stop();
}

void main() {
  test('the app is kept awake from the first event until the download ends', () async {
    final k = _Keeper();
    final shared = SharedKeeper(k);
    final out = await keepAliveWhile(Stream.fromIterable([1, 2]), shared, title: 'Downloading voice models').toList();
    expect(out, [1, 2]);
    expect(k.events, ['start Downloading voice models', 'stop']);
  });

  test('a failed download still lets the app sleep again', () async {
    final k = _Keeper();
    final s = keepAliveWhile(Stream<int>.error(StateError('stalled')), SharedKeeper(k), title: 'd');
    await expectLater(s.toList(), throwsStateError);
    expect(k.events, ['start d', 'stop']);
  });

  test('a cancel while the notification is still starting never starts the download', () async {
    // Review: onCancel before onListen's await left sub null, so the source was listened anyway.
    final gate = Completer<void>();
    final k = _Keeper();
    var listened = false;
    final source = StreamController<int>(onListen: () => listened = true);
    final slow = _SlowKeeper(k, gate.future);
    final sub = keepAliveWhile(source.stream, slow, title: 'd').listen((_) {});
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(listened, isFalse);
    expect(k.events.last, 'stop', reason: 'the notification goes away again');
    unawaited(source.close()); // never listened to, so it never finishes closing
  });

  test('leaving the download screen lets the app sleep again', () async {
    final k = _Keeper();
    final source = StreamController<int>();
    final sub = keepAliveWhile(source.stream, SharedKeeper(k), title: 'd').listen((_) {});
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(k.events, ['start d', 'stop']);
    await source.close();
  });

  test('the notification stays while anything still needs it', () async {
    final k = _Keeper();
    final shared = SharedKeeper(k);
    await shared.start(title: 'Preparing lines');
    await shared.start(title: 'Downloading voice models');
    await shared.stop();
    expect(k.events.where((e) => e == 'stop'), isEmpty, reason: 'one user is left');
    await shared.stop();
    expect(k.events.last, 'stop');
    await shared.stop();
    expect(k.events.where((e) => e == 'stop').length, 1, reason: 'extra stops are ignored');
  });
}
