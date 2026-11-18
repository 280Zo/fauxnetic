import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crispasr/crispasr.dart';

import '../engine/crispasr_engine.dart' show kThreads;
import '../models/model_store.dart';

const kTranscribeFailedMessage = "Couldn't transcribe this recording. Try again.";

class TimedWord {
  const TimedWord(this.text, this.start, this.end, this.confidence);
  final String text;
  final double start;
  final double end;
  final double confidence;
}

class TranscriberError implements Exception {
  const TranscriberError(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract class Transcriber {
  Future<void> load();

  /// 16 kHz mono samples in, words with timings (seconds) out.
  Future<List<TimedWord>> transcribe(Float32List pcm16k);
  Future<void> dispose();
}

/// The Whisper calls the app uses. Runs inside the worker isolate.
abstract class AsrApi {
  void open(String model);
  List<Segment> transcribe(Float32List pcm);
  void close();
}

class FfiAsrApi implements AsrApi {
  CrispASR? _asr;

  @override
  void open(String model) => _asr = CrispASR(model, libPath: 'libcrispasr.so');

  @override
  List<Segment> transcribe(Float32List pcm) => (_asr ?? (throw StateError('transcriber not open'))).transcribePcm(
    pcm,
    options: const TranscribeOptions(language: 'en', wordTimestamps: true, nThreads: kThreads),
  );

  @override
  void close() {
    _asr?.dispose();
    _asr = null;
  }
}

AsrApi ffiAsrFactory() => FfiAsrApi();

/// Whisper reports sub-word tokens; a token starting with a space begins a new word. A word's
/// confidence is its least certain token. Segments without token timing are spread evenly.
List<TimedWord> wordsFromSegments(List<Segment> segments) {
  final out = <TimedWord>[];
  for (final s in segments) {
    final merged = <({String text, double start, double end, double p})>[];
    for (final t in s.words) {
      if (merged.isEmpty || t.text.startsWith(' ')) {
        merged.add((text: t.text.trim(), start: t.start, end: t.end, p: t.p));
      } else {
        final last = merged.removeLast();
        merged.add((text: last.text + t.text, start: last.start, end: t.end, p: last.p < t.p ? last.p : t.p));
      }
    }
    merged.removeWhere((w) => w.text.isEmpty);
    if (merged.isNotEmpty && merged.every((w) => w.start >= 0 && w.end >= 0)) {
      out.addAll(merged.map((w) => TimedWord(w.text, w.start, w.end, w.p)));
      continue;
    }
    final texts = s.text.trim().split(RegExp(r'\s+'))..removeWhere((w) => w.isEmpty);
    if (texts.isEmpty) continue;
    final start = s.start < 0 ? 0.0 : s.start;
    final end = s.end < start ? start : s.end;
    final step = (end - start) / texts.length;
    final confidence = (1 - s.noSpeechProb).clamp(0.0, 1.0);
    for (var i = 0; i < texts.length; i++) {
      out.add(TimedWord(texts[i], start + i * step, start + (i + 1) * step, confidence));
    }
  }
  return out;
}

/// Runs Whisper (the model for [role]) in its own isolate so recording and the UI stay smooth.
class WhisperTranscriber implements Transcriber {
  WhisperTranscriber(this._models, this._role, {this._factory = ffiAsrFactory});

  final ModelStore _models;
  final ModelRole _role;
  final AsrApi Function() _factory;
  Future<_AsrWorker>? _worker;

  @override
  Future<void> load() async {
    await _live();
  }

  /// A failed start is forgotten, so the next call tries again.
  Future<_AsrWorker> _live() =>
      _worker ??= _AsrWorker.spawn(_factory, _models.pathFor(_role).path).catchError((Object e) {
        _worker = null;
        throw e;
      });

  @override
  Future<List<TimedWord>> transcribe(Float32List pcm16k) async {
    final w = await _live();
    try {
      return await w.transcribe(pcm16k);
    } on TranscriberError {
      // A worker that died (for example out of memory) is replaced on the next call.
      if (w.dead) _worker = null;
      rethrow;
    }
  }

  @override
  Future<void> dispose() async {
    final w = _worker;
    _worker = null;
    if (w == null) return;
    try {
      await (await w).close();
    } catch (_) {
      // Never started, or already gone: nothing to close.
    }
  }
}

class _AsrWorker {
  _AsrWorker._(this._isolate, this._send, this._replies, this._exit);

  final Isolate _isolate;
  final SendPort _send;
  final ReceivePort _replies;
  final ReceivePort _exit;
  final _pending = <int, Completer<Object?>>{};
  var _next = 0;
  var dead = false;

  static Future<_AsrWorker> spawn(AsrApi Function() factory, String model) async {
    final replies = ReceivePort();
    final exit = ReceivePort();
    final ready = Completer<SendPort>();
    late _AsrWorker worker;
    replies.listen((msg) {
      if (msg is SendPort) {
        ready.complete(msg);
      } else if (msg is List) {
        worker._reply(msg);
      }
    });
    final isolate = await Isolate.spawn(_main, [replies.sendPort, factory], onExit: exit.sendPort);
    worker = _AsrWorker._(isolate, await ready.future, replies, exit);
    exit.listen((_) => worker._died());
    try {
      await worker._call('open', model);
    } catch (_) {
      isolate.kill();
      rethrow;
    }
    return worker;
  }

  static void _main(List<Object?> boot) {
    final reply = boot[0]! as SendPort;
    final api = (boot[1]! as AsrApi Function())();
    final inbox = ReceivePort();
    reply.send(inbox.sendPort);
    inbox.listen((msg) {
      final m = msg as List<Object?>;
      final id = m[0]! as int, op = m[1]! as String;
      try {
        Object? result;
        switch (op) {
          case 'open':
            api.open(m[2]! as String);
          case 'transcribe':
            result = wordsFromSegments(api.transcribe(m[2]! as Float32List));
          case 'close':
            api.close();
        }
        reply.send([id, true, result]);
      } catch (_) {
        reply.send([id, false, null]);
      }
      if (op == 'close') inbox.close();
    });
  }

  void _reply(List<Object?> msg) {
    final c = _pending.remove(msg[0]! as int);
    if (c == null) return;
    if (msg[1] == true) {
      c.complete(msg[2]);
    } else {
      c.completeError(const TranscriberError(kTranscribeFailedMessage));
    }
  }

  void _died() {
    dead = true;
    for (final c in _pending.values) {
      c.completeError(const TranscriberError(kTranscribeFailedMessage));
    }
    _pending.clear();
    _replies.close();
    _exit.close();
  }

  Future<Object?> _call(String op, [Object? arg]) {
    if (dead) return Future.error(const TranscriberError(kTranscribeFailedMessage));
    final id = _next++;
    final c = Completer<Object?>();
    _pending[id] = c;
    _send.send([id, op, arg]);
    return c.future;
  }

  Future<List<TimedWord>> transcribe(Float32List pcm) async =>
      ((await _call('transcribe', pcm))! as List).cast<TimedWord>();

  Future<void> close() async {
    if (dead) return;
    try {
      await _call('close');
    } finally {
      _isolate.kill();
    }
  }
}
