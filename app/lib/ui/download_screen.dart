import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../models/model_store.dart';
import '../theme.dart';

String downloadLabel(List<PinnedModel> models) =>
    'Download (${formatGb(models.fold<int>(0, (sum, m) => sum + m.size))})';

class DownloadScreen extends StatefulWidget {
  const DownloadScreen({super.key, required this.start, required this.onDone, this.missing});
  final Stream<DownloadProgress> Function() start;
  final VoidCallback onDone;

  /// The recording-set models to fetch; null or all of them is a first download (the voice set
  /// follows in the background). Fewer is an update (a new version of one model), shown as such
  /// so the owner doesn't think the app was reset.
  final List<PinnedModel>? missing;

  @override
  State<DownloadScreen> createState() => _DownloadScreenState();
}

class _DownloadScreenState extends State<DownloadScreen> {
  StreamSubscription<DownloadProgress>? _sub;
  DownloadProgress? _progress;
  bool _running = false;
  bool _done = false;
  String? _error;

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _go() {
    setState(() {
      _running = true;
      _error = null;
    });
    _sub = widget.start().listen(
      (p) => setState(() => _progress = p),
      onError: (Object e) => setState(() {
        _running = false;
        _error = e is ModelStoreError && e.kind == ModelErrorKind.network
            ? 'No connection. Connect to the internet to download.'
            : e is ModelStoreError
            ? e.message
            : 'The download failed. Check the connection and try again.';
      }),
      onDone: () {
        if (_error != null) return;
        setState(() {
          _running = false;
          _done = true;
        });
        widget.onDone();
      },
      cancelOnError: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = _progress;
    final need = widget.missing;
    final update = need != null && need.isNotEmpty && need.length < kRecordingModels.length;
    final size = update ? need.fold<int>(0, (s, m) => s + m.size) : 0;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Spacer(),
              Text(update ? 'Voice model update' : 'Voice models', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 12),
              Text(
                update
                    ? 'This version of Fauxnetic uses a better copy of one voice model, downloaded once over '
                          'Wi-Fi from Hugging Face and checked against a pinned checksum. Your voices and lines '
                          'are kept.'
                    : 'Fauxnetic needs about 1.5 GB of model files from Hugging Face, each checked against a '
                          'fixed fingerprint. Recording needs only 120 MB, so you can start in about a minute '
                          'while the rest downloads.',
              ),
              const SizedBox(height: 24),
              if (_running && p != null) ...[
                Text('${p.model}: ${(p.received * 100 / p.total).floor()}%'),
                const SizedBox(height: 8),
                LinearProgressIndicator(value: p.received / p.total, color: context.colors.ink),
              ],
              if (_done) Text('Models verified', style: TextStyle(color: context.colors.real)),
              if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              const Spacer(),
              if (!_running && !_done)
                FilledButton(
                  onPressed: _go,
                  child: Text(
                    _error != null && _error!.startsWith('No connection')
                        ? 'Retry'
                        : update
                        ? 'Download update (${formatSize(size)})'
                        : downloadLabel(kModels),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
