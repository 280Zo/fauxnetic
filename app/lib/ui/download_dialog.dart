import 'package:material_ui/material_ui.dart';

import '../engine/tts_models.dart';
import '../storage/storage_report.dart';

/// Shows [m]'s size and licence note before its background download; true when the user chose
/// Download.
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
