import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../engine/tts_models.dart';
import '../models/model_store.dart';
import '../storage/storage_report.dart';

/// Shows [m]'s size and licence note; true when the user chose Download.
Future<bool> confirmDownload(BuildContext context, TtsModel m) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Download ${m.label}?'),
        content: Text('Downloads ${formatBytes(m.downloadBytes)}. ${m.note ?? ''}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not now')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Download')),
        ],
      ),
    ) ==
    true;

/// Shows [m]'s size and licence note, then downloads it with progress. True once it's on the phone.
Future<bool> confirmAndDownload(BuildContext context, TtsModel m, Stream<DownloadProgress> Function() start) async {
  final ok = await confirmDownload(context, m);
  if (!ok || !context.mounted) return false;
  final done = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => DownloadDialog(title: 'Downloading ${m.label}', stream: start()),
  );
  return done == true;
}

/// Shows download progress; pops true when done, false on cancel or an error (shown first).
class DownloadDialog extends StatefulWidget {
  const DownloadDialog({super.key, required this.title, required this.stream});
  final String title;
  final Stream<DownloadProgress> stream;

  @override
  State<DownloadDialog> createState() => _DownloadDialogState();
}

class _DownloadDialogState extends State<DownloadDialog> {
  DownloadProgress? _p;
  String? _error;
  StreamSubscription<DownloadProgress>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.stream.listen(
      (p) => setState(() => _p = p),
      onError: (Object e) => setState(() => _error = e.toString()),
      onDone: () {
        if (_error == null && mounted) Navigator.pop(context, true);
      },
    );
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    return AlertDialog(
      title: Text(widget.title),
      content: _error != null
          ? Text(_error!)
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LinearProgressIndicator(value: p == null ? null : p.received / p.total),
                const SizedBox(height: 8),
                Text(p == null ? 'Starting…' : '${p.model}: ${formatBytes(p.received)} of ${formatBytes(p.total)}'),
              ],
            ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(_error != null ? 'Close' : 'Cancel')),
      ],
    );
  }
}
