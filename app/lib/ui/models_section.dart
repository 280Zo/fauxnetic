import 'package:material_ui/material_ui.dart';

import '../engine/tts_models.dart';
import '../models/model_store.dart';
import '../storage/storage_report.dart';
import '../theme.dart';
import 'download_dialog.dart';

/// One voice model as Settings shows it.
class ModelInfo {
  const ModelInfo({required this.model, required this.downloaded, required this.bytes});
  final TtsModel model;
  final bool downloaded;

  /// Space it takes on this phone (0 when not downloaded).
  final int bytes;
}

/// Settings → Models: pick the default model (downloading it first if needed) and delete optional
/// ones. Qwen comes with the core download, so only "Remove voice models" removes it.
class ModelsSection extends StatefulWidget {
  const ModelsSection({
    super.key,
    required this.initialDefault,
    required this.models,
    required this.onDefault,
    required this.onDelete,
    required this.download,
  });

  final String initialDefault;
  final Future<List<ModelInfo>> Function() models;
  final Future<void> Function(String id) onDefault;
  final Future<void> Function(String id) onDelete;
  final Stream<DownloadProgress> Function(String id) download;

  @override
  State<ModelsSection> createState() => _ModelsSectionState();
}

class _ModelsSectionState extends State<ModelsSection> {
  late String _default = widget.initialDefault;
  List<ModelInfo> _rows = const [];

  /// While a model is being deleted its row says so and can't be tapped.
  String? _deleting;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await widget.models();
    if (mounted) setState(() => _rows = r);
  }

  Future<void> _pick(ModelInfo i) async {
    if (i.model.id == _default || i.model.id == _deleting) return;
    if (!i.downloaded && !await confirmAndDownload(context, i.model, () => widget.download(i.model.id))) return;
    await widget.onDefault(i.model.id);
    if (!mounted) return;
    setState(() => _default = i.model.id);
    await _load();
  }

  Future<void> _delete(ModelInfo i) async {
    final ok =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('Delete ${i.model.label}?'),
            content: Text(
              'Frees ${formatBytes(i.bytes)}.'
              '${i.model.id == _default ? ' New lines use Qwen3-TTS instead.' : ''} You can download it again here.',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
              TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
            ],
          ),
        ) ??
        false;
    if (!ok || !mounted) return;
    setState(() => _deleting = i.model.id);
    try {
      await widget.onDelete(i.model.id);
    } finally {
      if (mounted) setState(() => _deleting = null);
    }
    if (!mounted) return;
    if (i.model.id == _default) setState(() => _default = kTtsModels.first.id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(color: context.colors.muted, fontSize: 13);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final i in _rows)
          ListTile(
            contentPadding: EdgeInsets.zero,
            onTap: () => _pick(i),
            leading: Icon(
              i.model.id == _default ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              color: i.model.id == _default ? context.colors.clone : context.colors.muted,
            ),
            title: Text(i.model.label),
            subtitle: Text(
              i.model.id == _deleting
                  ? 'Deleting…'
                  : [
                      if (i.model.id == _default) 'Default',
                      i.model.files.isEmpty
                          ? 'Comes with the voice models'
                          : i.downloaded
                          ? '${formatBytes(i.bytes)} on this phone'
                          : 'Not downloaded (${formatBytes(i.model.downloadBytes)})',
                    ].join(' · '),
              style: muted,
            ),
            trailing: i.model.id == _deleting
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : i.downloaded && i.model.files.isNotEmpty && _deleting == null
                ? TextButton(onPressed: () => _delete(i), child: const Text('Delete'))
                : null,
          ),
      ],
    );
  }
}
