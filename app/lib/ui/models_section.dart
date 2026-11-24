import 'package:material_ui/material_ui.dart';

import '../engine/tts_models.dart';
import '../models/download_center.dart';
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

/// Settings → Models: pick the default model and delete optional ones. A model that isn't on the
/// phone downloads in the background (2026-11-18) and becomes the default once it is here. Qwen
/// comes with the core download, so only "Remove voice models" removes it.
class ModelsSection extends StatefulWidget {
  const ModelsSection({
    super.key,
    required this.initialDefault,
    required this.models,
    required this.onDefault,
    required this.onDelete,
    required this.startDownload,
    this.downloads,
    this.onWantDefault,
  });

  final String initialDefault;
  final Future<List<ModelInfo>> Function() models;
  final Future<void> Function(String id) onDefault;

  /// A model picked while not downloaded: the app makes it the default when its download is
  /// done, even after Settings closes (review minor, 2026-11-19).
  final Future<void> Function(String id)? onWantDefault;
  final Future<void> Function(String id) onDelete;
  final Future<void> Function(String id) startDownload;
  final DownloadCenter? downloads;

  @override
  State<ModelsSection> createState() => _ModelsSectionState();
}

class _ModelsSectionState extends State<ModelsSection> {
  late String _default = widget.initialDefault;
  List<ModelInfo> _rows = const [];

  /// While a model is being deleted its row says so and can't be tapped.
  String? _deleting;

  /// Picked while not downloaded: becomes the default when its download is done.
  String? _wanted;

  @override
  void initState() {
    super.initState();
    widget.downloads?.addListener(_downloadsChanged);
    _load();
  }

  @override
  void dispose() {
    widget.downloads?.removeListener(_downloadsChanged);
    super.dispose();
  }

  /// Downloads seen finished, so each one reloads the rows once (wherever it was started).
  final _seenDone = <String>{};

  Future<void> _downloadsChanged() async {
    if (!mounted) return;
    setState(() {});
    final done = [
      for (final j in widget.downloads?.jobs ?? const <DownloadJob>[])
        if (j.state == JobState.done && _seenDone.add(j.id)) j.id,
    ];
    if (done.isNotEmpty) await _load();
    final w = _wanted;
    if (w == null || widget.downloads?.job(w)?.state != JobState.done) return;
    _wanted = null;
    await widget.onDefault(w);
    if (!mounted) return;
    setState(() => _default = w);
    await _load();
  }

  Future<void> _load() async {
    final r = await widget.models();
    if (mounted) setState(() => _rows = r);
  }

  Future<void> _pick(ModelInfo i) async {
    if (i.model.id == _default || i.model.id == _deleting) return;
    if (!i.downloaded) {
      if (widget.downloads?.job(i.model.id)?.pending ?? false) return;
      if (!await confirmDownload(context, i.model)) return;
      _wanted = i.model.id;
      await widget.onWantDefault?.call(i.model.id);
      await widget.startDownload(i.model.id);
      return;
    }
    // Another pick replaces the wish for one still downloading.
    _wanted = null;
    await widget.onDefault(i.model.id);
    if (!mounted) return;
    setState(() => _default = i.model.id);
    await _load();
  }

  /// The row's line while its model downloads; null otherwise.
  String? _downloadText(String id) {
    final j = widget.downloads?.job(id);
    if (j == null || j.state == JobState.done) return null;
    return switch (j.state) {
      JobState.waitingWifi => 'Waiting for Wi-Fi · ${formatSize(j.left)} left',
      JobState.waitingNetwork => 'Waiting for a connection · ${formatSize(j.left)} left',
      JobState.failed => 'Failed: ${j.error ?? 'download failed'}',
      _ => 'Downloading ${j.received * 100 ~/ (j.total == 0 ? 1 : j.total)}% · ${formatSize(j.left)} left',
    };
  }

  Widget? _downloadAction(String id) {
    final d = widget.downloads;
    final j = d?.job(id);
    if (d == null || j == null) return null;
    if (j.state == JobState.waitingWifi) {
      return TextButton(onPressed: () => d.allowMobileData(id), child: const Text('Use mobile data'));
    }
    if (j.state == JobState.failed) return TextButton(onPressed: () => d.retry(id), child: const Text('Retry'));
    return null;
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
                  : _downloadText(i.model.id) ??
                        [
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
                : _downloadAction(i.model.id) ??
                      (i.downloaded && i.model.files.isNotEmpty && _deleting == null
                          ? TextButton(onPressed: () => _delete(i), child: const Text('Delete'))
                          : null),
          ),
      ],
    );
  }
}
