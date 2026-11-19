import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:http/http.dart' as http;

import '../engine/tts_models.dart';

/// What each pinned model file is used for.
enum ModelRole { talker, codec, asrBase, asrTiny, vad, speaker, optional }

class PinnedModel {
  const PinnedModel({required this.name, required this.url, required this.size, required this.sha256, this.role});
  final String name;
  final Uri url;
  final int size;
  final String sha256;
  final ModelRole? role;
}

PinnedModel pinnedHf(ModelRole role, String repo, String name, int size, String sha256) => PinnedModel(
  role: role,
  name: name,
  url: Uri.parse('https://huggingface.co/$repo/resolve/main/$name'),
  size: size,
  sha256: sha256,
);

final List<PinnedModel> kModels = [
  // One talker: Q8. On the A54 the Q4 build sounded the same and switching cost a reload (2026-11-15).
  pinnedHf(
    ModelRole.talker,
    'cstr/qwen3-tts-0.6b-base-GGUF',
    'qwen3-tts-12hz-0.6b-base-q8_0.gguf',
    985716544,
    '6162637048fff8ca7f7a16bebc8a62ea8181f4aec4f160894955dee5b87c1961',
  ),
  // The codec at F16, as CrispASR's docs recommend: quantizing it hurts quality before the talker's
  // does; same speed on the A54 (2026-11-17).
  pinnedHf(
    ModelRole.codec,
    'cstr/qwen3-tts-tokenizer-12hz-GGUF',
    'qwen3-tts-tokenizer-12hz.gguf',
    358453280,
    '70dc95dbfdd9aa5d9d406236ff771d061bf17b0cda02a72513953355606e719b',
  ),
  pinnedHf(
    ModelRole.asrBase,
    'ggerganov/whisper.cpp',
    'ggml-base.en-q5_1.bin',
    59721011,
    '4baf70dd0d7c4247ba2b81fafd9c01005ac77c2f9ef064e00dcf195d0e2fdd2f',
  ),
  pinnedHf(
    ModelRole.asrTiny,
    'ggerganov/whisper.cpp',
    'ggml-tiny.en-q5_1.bin',
    32166155,
    'c77c5766f1cef09b6b7d47f21b546cbddd4157886b3b5d6d4f709e91e66c7c2b',
  ),
  pinnedHf(
    ModelRole.vad,
    'ggml-org/whisper-vad',
    'ggml-silero-v6.2.0.bin',
    885098,
    '2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987',
  ),
  pinnedHf(
    ModelRole.speaker,
    'cstr/wespeaker-resnet34-lm-GGUF',
    'wespeaker-resnet34-lm.gguf',
    23904352,
    '2461a2b9a07023a1689fbdb79bd2929dd8793b8bd1ecd9f6ca3b66b4c3668d26',
  ),
];

/// Sizes are shown in decimal gigabytes, the unit Android's storage settings use.
String formatGb(int bytes) => '${(bytes / 1e9).toStringAsFixed(1)} GB';

/// Under 1 GB as MB ("358 MB"), else as [formatGb].
String formatSize(int bytes) => bytes < 1e9 ? '${(bytes / 1e6).round()} MB' : formatGb(bytes);

class DownloadProgress {
  const DownloadProgress(this.model, this.received, this.total);
  final String model;
  final int received;
  final int total;
}

/// What needs recording a voice (Whisper, VAD, the speaker check: about 117 MB), downloaded first
/// on the first launch.
final List<PinnedModel> kRecordingModels = [
  for (final m in kModels)
    if (m.role != ModelRole.talker && m.role != ModelRole.codec) m,
];

/// Qwen's talker and codec (1.34 GB): needed only to make lines, so they download in the background.
final List<PinnedModel> kVoiceModels = [
  for (final m in kModels)
    if (m.role == ModelRole.talker || m.role == ModelRole.codec) m,
];

/// A lost or stalled connection (wait and continue), or a real failure (checksum, space, server).
enum ModelErrorKind { network, failed }

class ModelStoreError implements Exception {
  const ModelStoreError(this.message, {this.kind = ModelErrorKind.failed});
  final String message;
  final ModelErrorKind kind;
  @override
  String toString() => message;
}

const _headroomBytes = 200 * 1024 * 1024;

class ModelStore {
  ModelStore(
    this.dir, {
    http.Client? client,
    Future<int> Function()? freeBytes,
    List<PinnedModel>? models,
    this.stallTimeout = const Duration(seconds: 30),
  }) : _client = client ?? http.Client(),
       _freeBytes = freeBytes ?? (() async => freeBytesAt(dir.path)),
       models = models ?? kModels;

  final Directory dir;
  final List<PinnedModel> models;

  /// How long the connection may go without delivering a byte before the download is abandoned.
  final Duration stallTimeout;
  final http.Client _client;
  final Future<int> Function() _freeBytes;

  File path(PinnedModel m) => File('${dir.path}/${m.name}');

  File pathFor(ModelRole role) => path(models.firstWhere((m) => m.role == role));

  /// At launch: deletes model files no longer pinned (such as a talker an earlier version used, or the
  /// dropped OmniVoice test files). Optional voice models share this folder and are kept. Partial
  /// downloads are left to [download], which clears them itself.
  Future<int> removeUnpinned() async {
    if (!await dir.exists()) return 0;
    final pinned = {
      for (final m in [...models, ...kOptionalModelFiles]) m.name,
    };
    var n = 0;
    await for (final e in dir.list()) {
      final name = e.uri.pathSegments.last;
      // Partial downloads resume; dot files (the list of wanted downloads) are the app's own.
      if (e is File && !pinned.contains(name) && !name.endsWith('.part') && !name.startsWith('.')) {
        await e.delete();
        n++;
      }
    }
    return n;
  }

  /// Settings → Remove voice models: deletes every model file, partial downloads included.
  Future<void> removeAll() async {
    if (!await dir.exists()) return;
    await for (final e in dir.list()) {
      if (e is File) await e.delete();
    }
  }

  /// Settings → Models → Delete: removes only this store's files (and their partial downloads);
  /// the other models sharing the folder stay.
  Future<void> removeOwn() async {
    for (final m in models) {
      for (final f in [path(m), File('${path(m).path}.part')]) {
        if (await f.exists()) await f.delete();
      }
    }
  }

  Future<bool> _verified(File f, PinnedModel m) async {
    if (!await f.exists() || await f.length() != m.size) return false;
    final digest = await sha256.bind(f.openRead()).first;
    return digest.toString() == m.sha256;
  }

  /// Cheap check for app start: every model exists at its pinned size. The SHA-256 was verified
  /// when the file was downloaded; files only arrive through [download], via a verified rename.
  Future<bool> allPresent() async => (await missing()).isEmpty;

  /// The models not present at their pinned size (same cheap check as [allPresent]).
  Future<List<PinnedModel>> missing() async => [
    for (final m in models)
      if (!await path(m).exists() || await path(m).length() != m.size) m,
  ];

  /// Bytes still to download: the missing models' sizes less what their partial files hold.
  Future<int> bytesLeft() async {
    var left = 0;
    for (final m in await missing()) {
      final part = File('${path(m).path}.part');
      left += m.size - (await part.exists() ? math.min(await part.length(), m.size) : 0);
    }
    return left;
  }

  Future<bool> allReady() async {
    for (final m in models) {
      if (!await _verified(path(m), m)) return false;
    }
    return true;
  }

  /// Downloads every missing model, continuing partial files. Cancelling the subscription stops
  /// the network read at once and keeps the partial file, so the next download resumes it.
  Stream<DownloadProgress> download() {
    late final StreamController<DownloadProgress> out;
    final cancel = _Cancel();
    out = StreamController<DownloadProgress>(
      onListen: () async {
        try {
          await _downloadAll(out.add, cancel);
        } catch (e) {
          if (!cancel.cancelled) out.addError(e);
        } finally {
          await out.close();
        }
      },
      onCancel: cancel.fire,
    );
    return out.stream;
  }

  Future<void> _downloadAll(void Function(DownloadProgress) emit, _Cancel cancel) async {
    await dir.create(recursive: true);
    final missing = <PinnedModel>[];
    for (final m in models) {
      if (!await _verified(path(m), m)) missing.add(m);
    }
    var already = 0;
    for (final m in missing) {
      final part = File('${path(m).path}.part');
      if (await part.exists()) already += math.min(await part.length(), m.size);
    }
    final need = missing.fold<int>(0, (sum, m) => sum + m.size) - already + _headroomBytes;
    final have = await _freeBytes();
    if (missing.isNotEmpty && have < need) {
      throw ModelStoreError('Not enough free storage: need ${formatGb(need)}, have ${formatGb(have)}.');
    }
    for (final m in missing) {
      if (cancel.cancelled) return;
      final part = File('${path(m).path}.part');
      // A part already complete is checked first; one that is too long or doesn't match starts over.
      if (await part.exists() && await part.length() >= m.size) {
        if (await part.length() == m.size && await _verified(part, m)) {
          await part.rename(path(m).path);
          continue;
        }
        await part.delete();
      }
      await _fetch(m, emit, cancel);
    }
  }

  Future<void> _fetch(PinnedModel m, void Function(DownloadProgress) emit, _Cancel cancel, {bool fresh = false}) async {
    final target = path(m);
    final part = File('${target.path}.part');
    if (await target.exists()) await target.delete();
    if (fresh && await part.exists()) await part.delete();
    var resumed = false;
    IOSink? sink;
    // A partial file survives interruptions (to resume from); only a real failure discards it.
    var keepPart = true;
    var done = false;
    try {
      final have = await part.exists() ? await part.length() : 0;
      final request = http.Request('GET', m.url);
      if (have > 0) request.headers['range'] = 'bytes=$have-';
      final response = await _client.send(request).timeout(stallTimeout);
      // Cancelled while waiting for the server: write nothing.
      if (cancel.cancelled) {
        unawaited(response.stream.listen((_) {}).cancel());
        throw const _Cancelled();
      }
      resumed = have > 0 && response.statusCode == 206;
      if (response.statusCode != 200 && !resumed) {
        final status = response.statusCode;
        unawaited(response.stream.listen((_) {}).cancel());
        // Busy or a server error: wait and try again, keeping what arrived. 416 means the part
        // doesn't fit the file any more: it starts over.
        if (status == 416) keepPart = false;
        if (status == 429 || status >= 500) {
          throw ModelStoreError(
            'The download server is busy (HTTP $status). It will try again.',
            kind: ModelErrorKind.network,
          );
        }
        throw ModelStoreError('Download of ${m.name} failed (HTTP $status).');
      }
      // A 200 to a resume is the whole file: the part starts over.
      final out = sink = part.openWrite(mode: resumed ? FileMode.append : FileMode.write);
      var received = resumed ? have : 0;
      final finished = Completer<void>();
      final sub = response.stream
          .timeout(stallTimeout)
          .listen(
            (chunk) {
              received += chunk.length;
              if (received > m.size) {
                if (!finished.isCompleted) {
                  finished.completeError(ModelStoreError('${m.name} is larger than expected.'));
                }
                return;
              }
              out.add(chunk);
              emit(DownloadProgress(m.name, received, m.size));
            },
            onError: (Object e) {
              if (!finished.isCompleted) finished.completeError(e);
            },
            onDone: () {
              if (!finished.isCompleted) finished.complete();
            },
            cancelOnError: true,
          );
      cancel.onFire = () async {
        await sub.cancel();
        if (!finished.isCompleted) finished.completeError(const _Cancelled());
      };
      try {
        await finished.future;
      } finally {
        cancel.onFire = null;
        await sub.cancel();
      }
      await sink.close();
      sink = null;
      if (!await _verified(part, m)) {
        keepPart = false;
        // A resumed part may hold old or damaged bytes: the whole file once more from zero.
        if (resumed && !fresh) {
          await part.delete();
          await _fetch(m, emit, cancel, fresh: true);
          done = true;
          return;
        }
        throw ModelStoreError('${m.name} did not match its checksum. Try the download again.');
      }
      await part.rename(target.path);
      done = true;
    } on ModelStoreError catch (e) {
      if (e.kind == ModelErrorKind.failed) keepPart = false;
      rethrow;
    } on _Cancelled {
      rethrow;
    } catch (e) {
      throw ModelStoreError(
        'Download of ${m.name} was interrupted. Check the connection and try again.',
        kind: ModelErrorKind.network,
      );
    } finally {
      if (!done) await _discard(sink, part, keep: keepPart);
    }
  }

  Future<void> _discard(IOSink? sink, File part, {bool keep = false}) async {
    try {
      await sink?.close();
    } catch (_) {}
    if (!keep && await part.exists()) await part.delete();
  }
}

class _Cancel {
  bool cancelled = false;
  Future<void> Function()? onFire;

  Future<void> fire() async {
    cancelled = true;
    await onFire?.call();
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}

final class _Statvfs extends Struct {
  @Uint64()
  external int bsize;
  @Uint64()
  external int frsize;
  @Uint64()
  external int blocks;
  @Uint64()
  external int bfree;
  @Uint64()
  external int bavail;
  @Array(27)
  external Array<Uint64> rest;
}

typedef _StatvfsC = Int32 Function(Pointer<Utf8>, Pointer<_Statvfs>);
typedef _StatvfsDart = int Function(Pointer<Utf8>, Pointer<_Statvfs>);

/// Bytes available to this app on the filesystem holding [path] (statvfs f_bavail * f_frsize, LP64).
int freeBytesAt(String path) {
  final statvfs = DynamicLibrary.process().lookupFunction<_StatvfsC, _StatvfsDart>('statvfs');
  final p = path.toNativeUtf8();
  final buf = calloc<_Statvfs>();
  try {
    if (statvfs(p, buf) != 0) throw const ModelStoreError('Could not read free storage.');
    return buf.ref.bavail * buf.ref.frsize;
  } finally {
    calloc.free(p);
    calloc.free(buf);
  }
}
