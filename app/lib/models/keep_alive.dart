import 'dart:async';

import '../cues/preparer.dart';

/// Lets lines and downloads share one keep-alive notification: it starts with the first user and
/// stops when the last one is done.
class SharedKeeper implements BackgroundKeeper {
  SharedKeeper(this._inner);
  final BackgroundKeeper _inner;
  var _users = 0;

  @override
  Future<void> start({String title = 'Preparing lines', String text = 'Fauxnetic is preparing your cue list.'}) async {
    _users++;
    await _inner.start(title: title, text: text);
  }

  @override
  Future<void> stop() async {
    if (_users == 0) return;
    _users--;
    if (_users == 0) await _inner.stop();
  }
}

/// Passes [source] through, keeping the app awake (with the screen off) from when it is listened
/// to until it ends, fails or is cancelled. Without this Android freezes the app and the download stalls.
Stream<T> keepAliveWhile<T>(Stream<T> source, BackgroundKeeper keeper, {required String title, String text = ''}) {
  late final StreamController<T> out;
  StreamSubscription<T>? sub;
  var stopped = false;
  Future<void> stop() async {
    if (stopped) return;
    stopped = true;
    await keeper.stop();
  }

  out = StreamController<T>(
    onListen: () async {
      await keeper.start(title: title, text: text);
      sub = source.listen(
        out.add,
        onError: out.addError,
        onDone: () async {
          await stop();
          await out.close();
        },
      );
    },
    onCancel: () async {
      await sub?.cancel();
      await stop();
    },
  );
  return out.stream;
}
