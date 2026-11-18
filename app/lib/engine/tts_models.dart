import '../models/model_store.dart';

/// A voice model the app can make lines with. Qwen3-TTS comes with the core download; the others are
/// optional test downloads (owner testing, 2026-11-16) to be pruned to the ones that work. Pins: plan
/// docs/superpowers/plans/2026-11-16-model-picker.md.
class TtsModel {
  const TtsModel({
    required this.id,
    required this.label,
    required this.backend,
    required this.files,
    this.open,
    this.codec,
    this.note,
  });

  /// Stored in settings.
  final String id;

  /// Shown in the picker and on each take.
  final String label;

  /// CrispASR's backend name for the session.
  final String backend;

  /// Extra files to download; empty for Qwen, which uses the core talker and codec.
  final List<PinnedModel> files;
  final PinnedModel? open;
  final PinnedModel? codec;

  /// Licence and expectations, shown before downloading.
  final String? note;

  PinnedModel get openFile => open ?? kModels.firstWhere((m) => m.role == ModelRole.talker);

  /// The codec/companion passed with set_codec_path, or null when the model has none.
  PinnedModel? get codecFile => files.isEmpty ? kModels.firstWhere((m) => m.role == ModelRole.codec) : codec;

  int get downloadBytes => files.fold(0, (n, f) => n + f.size);

  /// Roughly the free memory it needs to run without Android swapping it out: its weights plus a
  /// quarter for working memory. Null for Qwen, which runs fine on the A54. VoxCPM's 2.8 GB copy
  /// took over 5 minutes a line on an A54 with 93 MB free (2026-11-16).
  int? get memoryBytes => files.isEmpty ? null : (downloadBytes * 1.25).round();
}

/// Bytes of memory Android could give an app now ("MemAvailable" in /proc/meminfo), or null.
int? parseMemAvailable(String meminfo) {
  final m = RegExp(r'^MemAvailable:\s+(\d+)\s*kB', multiLine: true).firstMatch(meminfo);
  return m == null ? null : int.parse(m.group(1)!) * 1024;
}

PinnedModel _f(String repo, String name, int size, String sha256) =>
    pinnedHf(ModelRole.optional, repo, name, size, sha256);

final _voxcpm = _f(
  'cstr/voxcpm2-GGUF',
  'voxcpm2-q8_0.gguf',
  2827049792,
  '142f29c4dff1c0ad3f71d9353a03f7cbf08080bee3ab73c577c0219e4094fc4b',
);
final _voxcpmSmall = _f(
  'cstr/voxcpm2-GGUF',
  'voxcpm2-q4_k.gguf',
  1689498432,
  '502efe74f6a59c370b3abf5a3fcfd7c3955ca6c167b411c8aee3977e9e46c079',
);
final _pocket = _f(
  'cstr/pocket-tts-GGUF',
  'pocket-tts-english-q8_0.gguf',
  123632992,
  'fc80ece425f647b93174860ef279b877e5ad3454bbba3ec4fc76f535942c12c4',
);

final List<TtsModel> kTtsModels = [
  const TtsModel(id: 'qwen', label: 'Qwen3-TTS', backend: 'qwen3-tts', files: []),
  TtsModel(
    id: 'voxcpm',
    label: 'VoxCPM 2',
    backend: 'voxcpm2-tts',
    open: _voxcpm,
    files: [_voxcpm],
    note: 'Apache-2.0; its card forbids impersonation and asks for AI labels. A 2B model: expect it to be slow.',
  ),
  TtsModel(
    id: 'voxcpm-small',
    label: 'VoxCPM 2 (small)',
    backend: 'voxcpm2-tts',
    open: _voxcpmSmall,
    files: [_voxcpmSmall],
    note:
        'A lighter copy of VoxCPM 2 for phones with less memory; slightly lower quality. Apache-2.0; '
        'its card forbids impersonation and asks for AI labels.',
  ),
  TtsModel(
    id: 'pocket',
    label: 'Pocket TTS',
    backend: 'pocket-tts',
    open: _pocket,
    files: [_pocket],
    note: 'CC-BY-4.0; cloning only with consent. English only, small and fast.',
  ),
];

TtsModel ttsModel(String id) => kTtsModels.firstWhere((m) => m.id == id, orElse: () => kTtsModels.first);

/// Every optional file; launch cleanup keeps them.
final List<PinnedModel> kOptionalModelFiles = [for (final m in kTtsModels) ...m.files];
