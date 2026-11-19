import 'package:material_ui/material_ui.dart';

import '../models/download_center.dart';
import '../models/model_store.dart';
import '../theme.dart';

/// The People screen's slim line for the download in progress ("Voice model 42% · 812 MB left"),
/// with "Use mobile data" while it waits for Wi-Fi and "Retry" after a failure. Hidden when
/// nothing is downloading.
class DownloadBar extends StatelessWidget {
  const DownloadBar({super.key, required this.center});
  final DownloadCenter center;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: center,
    builder: (context, _) {
      final j = center.current;
      if (j == null) return const SizedBox.shrink();
      final left = formatSize(j.left);
      final (String text, String? action, VoidCallback? onAction) = switch (j.state) {
        JobState.waitingWifi => (
          'Waiting for Wi-Fi · $left left',
          'Use mobile data',
          () => center.allowMobileData(j.id),
        ),
        JobState.waitingNetwork => ('Waiting for a connection · $left left', null, null),
        JobState.failed => ('${j.label}: download failed', 'Retry', () => center.retry(j.id)),
        _ => ('${j.label} ${(j.received * 100 ~/ (j.total == 0 ? 1 : j.total))}% · $left left', null, null),
      };
      final muted = TextStyle(color: context.colors.muted, fontSize: 13);
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text(text, style: muted)),
                if (action != null)
                  TextButton(
                    onPressed: onAction,
                    style: TextButton.styleFrom(
                      foregroundColor: context.colors.clone,
                      visualDensity: VisualDensity.compact,
                    ),
                    child: Text(action),
                  ),
              ],
            ),
            if (j.state != JobState.failed)
              LinearProgressIndicator(
                value: j.total == 0 ? null : j.received / j.total,
                minHeight: 2,
                color: context.colors.muted,
                backgroundColor: context.colors.rule,
              ),
          ],
        ),
      );
    },
  );
}
