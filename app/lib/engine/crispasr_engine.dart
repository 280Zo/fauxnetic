import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crispasr/crispasr.dart';
import 'package:flutter/services.dart';

import '../models/model_store.dart';
import '../people/people_repo.dart';
import '../people/person.dart';
import '../recording/scripts.dart';
import 'spoken_numbers.dart';
import 'tts_models.dart';
import '../storage/temp_sweeper.dart';
import 'voice_engine.dart';

const kThreads = 4;

/// A loose limit on a Qwen line's length, in codec frames (12.5 a second): 1.5 s a spoken word
/// plus 5 s, never below CrispASR's own floor of 240. Qwen speaks ~2–3 words a second, so a line
/// that reaches it never ended (it then runs to the limit and is made again). Counts the words of
/// [spoken], the text with numbers written out, so a card or phone number gets room to be said.
int qwenFrameLimit(String spoken) {
  final words = spoken.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
  return max(240, ((words * 1.5 + 5) * 12.5).ceil());
}

/// Attempts at a Qwen line before it fails: each one that went wrong is made again with a new seed.
const kQwenAttempts = 3;

const kLineFailedMessage = "Couldn't make this line. Try again.";

/// The seed for the one retry after a runaway: a different path through the same line.
int retrySeed(int seed) => (seed * 1103515245 + 12345) % 0x7fffffff + 1;
const kOutOfMemoryMessage = 'The phone ran out of memory while preparing this line. Close other apps and retry.';

/// The CrispASR calls the app uses. Runs inside the worker isolate. There is deliberately no
/// unmarked-synthesis method: every clip goes through CrispASR's watermarking synthesize().
abstract class CrispasrApi {
  /// [backend] is CrispASR's name for the model family: `qwen3-tts` or `omnivoice`.
  void open(String model, String codec, String backend);
  void setVoice(String path, String refText);
  Float32List synthesize(String text, int seed);
  int get sampleRate;
  void close();
}

class FfiCrispasrApi implements CrispasrApi {
  FfiCrispasrApi({this.threads = kThreads});

  /// CPU threads the engine uses.
  final int threads;
  CrispasrSession? _s;

  CrispasrSession get _session => _s ?? (throw StateError('engine not open'));

  @override
  void open(String model, String codec, String backend) {
    // A reopen (after a worker restart or an engine switch) frees any old session first; the phone
    // can't hold two.
    close();
    _s = CrispasrSession.open(model, nThreads: threads, libPath: 'libcrispasr.so', backend: backend);
    // Single-file models have no codec.
    if (codec.isNotEmpty) _session.setCodecPath(codec);
  }

  @override
  void setVoice(String path, String refText) => _session.setVoice(path, refText: refText);

  @override
  Float32List synthesize(String text, int seed) {
    // setTemperature's seed is ignored by qwen3-tts; setTtsSeed is the one it reads.
    _session.setTtsSeed(seed);
    return Float32List.fromList(_session.synthesize(text));
  }

  @override
  int get sampleRate => _session.outputSampleRate;

  @override
  void close() {
    _s?.close();
    _s = null;
  }
}

CrispasrApi ffiApiFactory() => FfiCrispasrApi();

/// Asynchronous view of a [CrispasrApi] running somewhere else (an isolate in the app).
abstract class EngineWorker {
  Future<void> open(String model, String codec, String backend);
  Future<void> setVoice(String path, String refText);

  /// [maxFrames] > 0 caps a Qwen line's length (see [qwenFrameLimit]); 0 leaves CrispASR's default.
  Future<Float32List> synthesize(String text, int seed, {int maxFrames = 0});
  Future<int> sampleRate();
  Future<void> close();

  /// Ends the worker now, even mid-call; calls waiting on it fail with [EngineErrorKind.cancelled].
  Future<void> kill();
}

/// The engine in its own Android process (EngineService, ":engine"), reached through
/// MethodChannel fauxnetic/engine. [kill] ends that process, which stops a line at once; CrispASR can't
/// stop one partway (2026-11-16). Lines come back as a Float32 samples file, read and deleted here.
class ProcessWorker implements EngineWorker {
  ProcessWorker([this._channel = const MethodChannel('fauxnetic/engine')]);
  final MethodChannel _channel;

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw switch (e.code) {
        'died' => const EngineError(EngineErrorKind.outOfMemory, kOutOfMemoryMessage),
        'cancelled' => const EngineError(EngineErrorKind.cancelled, 'Stopped.'),
        'ranaway' => EngineError(EngineErrorKind.ranAway, e.message ?? 'ranaway'),
        _ => EngineError(EngineErrorKind.synthesisFailed, e.message ?? e.code),
      };
    }
  }

  @override
  Future<void> open(String model, String codec, String backend) =>
      _call<void>('open', {'model': model, 'codec': codec, 'backend': backend, 'threads': kThreads});

  @override
  Future<void> setVoice(String path, String refText) => _call<void>('setVoice', {'path': path, 'refText': refText});

  @override
  Future<Float32List> synthesize(String text, int seed, {int maxFrames = 0}) async {
    final r = await _call<Map<Object?, Object?>>('synthesize', {'text': text, 'seed': seed, 'maxFrames': maxFrames});
    final f = File(r!['path']! as String);
    try {
      final bytes = await f.readAsBytes();
      return Float32List.view(Uint8List.fromList(bytes).buffer, 0, bytes.length ~/ 4);
    } on FileSystemException catch (e) {
      throw EngineError(EngineErrorKind.synthesisFailed, 'The line could not be read: ${e.message}');
    } finally {
      if (await f.exists()) await f.delete();
    }
  }

  @override
  Future<int> sampleRate() async => (await _call<int>('sampleRate'))!;

  @override
  Future<void> close() => _call<void>('close');

  @override
  Future<void> kill() => _call<void>('kill');
}

class _Request {
  _Request(this.id, this.op, this.args);
  final int id;
  final String op;
  final List<Object?> args;
}

class IsolateWorker implements EngineWorker {
  IsolateWorker._(this._isolate, this._send, this._replies, this._exit);

  final Isolate _isolate;
  final SendPort _send;
  final ReceivePort _replies;
  final ReceivePort _exit;
  final _pending = <int, Completer<Object?>>{};
  var _next = 0;
  var _dead = false;

  static Future<IsolateWorker> spawn(CrispasrApi Function() factory) async {
    final replies = ReceivePort();
    final exit = ReceivePort();
    final ready = Completer<SendPort>();
    late IsolateWorker worker;
    replies.listen((msg) {
      if (msg is SendPort) {
        ready.complete(msg);
      } else if (msg is List) {
        worker._reply(msg);
      }
    });
    final isolate = await Isolate.spawn(_main, [replies.sendPort, factory], onExit: exit.sendPort);
    worker = IsolateWorker._(isolate, await ready.future, replies, exit);
    exit.listen((_) => worker._died());
    return worker;
  }

  static void _main(List<Object?> boot) {
    final reply = boot[0]! as SendPort;
    final api = (boot[1]! as CrispasrApi Function())();
    final inbox = ReceivePort();
    reply.send(inbox.sendPort);
    inbox.listen((msg) {
      final r = msg as _Request;
      try {
        Object? result;
        switch (r.op) {
          case 'open':
            api.open(r.args[0]! as String, r.args[1]! as String, r.args[2]! as String);
          case 'setVoice':
            api.setVoice(r.args[0]! as String, r.args[1]! as String);
          case 'synthesize':
            result = api.synthesize(r.args[0]! as String, r.args[1]! as int);
          case 'sampleRate':
            result = api.sampleRate;
          case 'close':
            api.close();
          default:
            throw ArgumentError(r.op);
        }
        reply.send([r.id, true, result]);
      } on OutOfMemoryError {
        reply.send([r.id, false, 'oom']);
      } catch (e) {
        reply.send([r.id, false, e.toString()]);
      }
      if (r.op == 'close') inbox.close();
    });
  }

  void _reply(List<Object?> msg) {
    final c = _pending.remove(msg[0]! as int);
    if (c == null) return;
    if (msg[1] == true) {
      c.complete(msg[2]);
    } else if (msg[2] == 'oom') {
      c.completeError(const EngineError(EngineErrorKind.outOfMemory, kOutOfMemoryMessage));
    } else {
      c.completeError(EngineError(EngineErrorKind.synthesisFailed, msg[2]! as String));
    }
  }

  void _died() {
    _dead = true;
    for (final c in _pending.values) {
      c.completeError(const EngineError(EngineErrorKind.outOfMemory, kOutOfMemoryMessage));
    }
    _pending.clear();
    _replies.close();
    _exit.close();
  }

  Future<Object?> _call(String op, List<Object?> args) {
    if (_dead) {
      return Future.error(const EngineError(EngineErrorKind.outOfMemory, kOutOfMemoryMessage));
    }
    final id = _next++;
    final c = Completer<Object?>();
    _pending[id] = c;
    _send.send(_Request(id, op, args));
    return c.future;
  }

  @override
  Future<void> open(String model, String codec, String backend) => _call('open', [model, codec, backend]);
  @override
  Future<void> setVoice(String path, String refText) => _call('setVoice', [path, refText]);

  /// The isolate path (tests and fallback) leaves CrispASR's own cap in place.
  @override
  Future<Float32List> synthesize(String text, int seed, {int maxFrames = 0}) async =>
      (await _call('synthesize', [text, seed]))! as Float32List;
  @override
  Future<int> sampleRate() async => (await _call('sampleRate', const []))! as int;
  @override
  Future<void> close() async {
    if (_dead) return;
    await _call('close', const []);
    _isolate.kill();
  }

  /// An isolate stuck in native code can't be stopped; this ends it as soon as the call returns
  /// and fails waiting calls now. Kept for tests and as a fallback; the app uses [ProcessWorker].
  @override
  Future<void> kill() async {
    if (_dead) return;
    _isolate.kill(priority: Isolate.immediate);
    _dead = true;
    for (final c in _pending.values) {
      c.completeError(const EngineError(EngineErrorKind.cancelled, 'Stopped.'));
    }
    _pending.clear();
    _replies.close();
    _exit.close();
  }
}

/// Runs the voice model in a worker. After an out-of-memory failure the worker is thrown away and
/// the next [load] starts a fresh one, so "close other apps and retry" can actually succeed.
///
/// Every call runs one at a time, so a voice change requested while a line is being spoken
/// applies only after that line.
class CrispasrEngine implements VoiceEngine {
  CrispasrEngine(
    this._spawn,
    this._models,
    this._people,
    this._temp, {
    TtsModel Function()? model,
    Future<bool> Function(TtsModel m)? ready,
  }) : _model = model ?? (() => kTtsModels.first),
       _ready = ready ?? ((_) async => true);

  /// Whether a model's files are on the phone; a line for one that was deleted uses the default.
  final Future<bool> Function(TtsModel m) _ready;

  final Future<EngineWorker> Function() _spawn;
  final ModelStore _models;
  final PeopleRepo _people;
  final TempSweeper _temp;

  /// Which voice model makes lines (picked on the Speak screen); a change applies at the next line.
  final TtsModel Function() _model;

  EngineWorker? _worker;
  int _rate = 0;

  /// Id of the model currently open in the worker, or null.
  String? _open;

  /// The model that made the last line: what a take is labeled with. The picker may have moved on
  /// while a slow model was still working (owner, 2026-11-16).
  @override
  String? get openModel => _open;

  @override
  Future<String> modelFor(String? model) async {
    final want = model == null ? _model() : ttsModel(model);
    return await _ready(want) ? want.id : _model().id;
  }

  /// Person and reference clip currently set as the voice; an unrecorded mood shares its fallback's key.
  String? _voiceKey;
  Future<void> _tail = Future.value();

  @override
  int get sampleRate => _rate;

  Future<T> _serial<T>(Future<T> Function() fn) {
    final result = _tail.then((_) => fn());
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }

  EngineWorker get _live => _worker ?? (throw const EngineError(EngineErrorKind.outOfMemory, kOutOfMemoryMessage));

  Future<T> _guard<T>(Future<T> Function(EngineWorker w) call) async {
    try {
      return await call(_live);
    } on EngineError catch (e) {
      if (e.kind == EngineErrorKind.outOfMemory) {
        _worker = null;
        _rate = 0;
        _open = null;
        _voiceKey = null;
      }
      rethrow;
    }
  }

  @override
  Future<void> load() => _serial(_load);

  /// Starts the worker. The voice model itself may still be downloading (2026-11-18); [prepare]
  /// checks the files of the model it opens.
  Future<void> _load() async {
    _worker ??= await _spawn();
  }

  /// Whether the files [m] opens are here: Qwen's talker and codec from the core download (which
  /// may still be downloading), else what [_ready] says about its own files.
  Future<bool> _filesPresent(TtsModel m) async {
    if (m.files.isNotEmpty) return _ready(m);
    for (final f in _models.models.where((f) => f.role == ModelRole.talker || f.role == ModelRole.codec)) {
      final file = _models.path(f);
      if (!await file.exists() || await file.length() != f.size) return false;
    }
    return true;
  }

  @override
  Future<void> prepare(Person p, Mood m, {String? model}) => _serial(() async {
    await _load();
    final want = ttsModel(await modelFor(model));
    if (_open != want.id && !await _filesPresent(want)) {
      throw EngineError(EngineErrorKind.modelMissing, '${want.label} is still downloading.');
    }
    if (_open != want.id) {
      _open = null;
      _voiceKey = null;
      // Qwen uses the core talker and codec from the model store; the others their own files.
      final core = want.files.isEmpty;
      final talker = core ? _models.pathFor(ModelRole.talker) : _models.path(want.openFile);
      final codecFile = want.codecFile;
      final codec = core
          ? _models.pathFor(ModelRole.codec).path
          : (codecFile == null ? '' : _models.path(codecFile).path);
      await _guard((w) => w.open(talker.path, codec, want.backend));
      _rate = await _guard((w) => w.sampleRate());
      _open = want.id;
    }
    final ref = p.refFor(m);
    // The words count too: a repaired transcript keeps its audio file.
    final key = '${p.id}|${ref.clipFile}|${ref.refText}';
    if (_voiceKey == key) return;
    final clip = await _people.decryptedRef(p, m);
    try {
      await _guard((w) => w.setVoice(clip.path, ref.refText));
      _voiceKey = key;
    } on EngineError catch (e) {
      if (e.kind == EngineErrorKind.outOfMemory || e.kind == EngineErrorKind.cancelled) rethrow;
      throw EngineError(EngineErrorKind.voiceRejected, 'This clip could not be used as a voice: ${e.message}');
    } finally {
      await _temp.release(clip);
    }
  });

  @override
  Future<Float32List> speak(String text, {required int seed}) => _serial(() async {
    if (_open == null || _voiceKey == null) throw StateError('prepare() a voice before speaking');
    lastSeed = seed;
    // Every model hears numbers written out: given raw digits, Pocket and VoxCPM read them oddly and
    // without grouping (owner, 2026-11-23).
    final spoken = spokenNumbers(text);
    if (ttsModel(_open!).backend != 'qwen3-tts') return _guard((w) => w.synthesize(spoken, seed));
    // The engine stops a line that stays silent too long or runs to its limit (Qwen sometimes never
    // ends one); make it again on another path. Anything else, such as a cancel, ends it.
    final limit = qwenFrameLimit(spoken);
    final cancels = _cancels;
    var s = seed;
    for (var attempt = 1; ; attempt++) {
      try {
        lastSeed = s;
        return await _guard((w) => w.synthesize(spoken, s, maxFrames: limit));
      } on EngineError catch (e) {
        if (e.kind != EngineErrorKind.ranAway) rethrow;
        // The line was removed while its stall reply was on the way: it ends here.
        if (_cancels != cancels) throw const EngineError(EngineErrorKind.cancelled, 'Stopped.');
        if (attempt == kQwenAttempts) {
          throw const EngineError(EngineErrorKind.synthesisFailed, kLineFailedMessage);
        }
        s = retrySeed(s);
      }
    }
  });

  /// Not queued behind the call in progress: that call is the one being stopped. The engine forgets
  /// its model and voice, as after running out of memory, so the next line reopens both.
  @override
  int? lastSeed;

  var _cancels = 0;

  @override
  Future<void> cancel() async {
    _cancels++;
    final w = _worker;
    if (w == null) return;
    _worker = null;
    _rate = 0;
    _open = null;
    _voiceKey = null;
    await w.kill();
  }

  /// Frees the worker and everything it holds; the next [load] or [prepare] starts a fresh one.
  @override
  Future<void> dispose() => _serial(() async {
    final w = _worker;
    _worker = null;
    _rate = 0;
    _open = null;
    _voiceKey = null;
    await w?.close();
  });
}
