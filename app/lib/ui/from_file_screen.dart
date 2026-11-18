import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../theme.dart';
import '../upload/upload_pipeline.dart';

/// Pick any audio or video, then tap the voice that belongs to the person.
class FromFileScreen extends StatefulWidget {
  const FromFileScreen({
    super.key,
    required this.pickFile,
    required this.analyze,
    required this.play,
    required this.onChosen,
  });

  final Future<File?> Function() pickFile;
  final Future<UploadAnalysis> Function(File f) analyze;
  final Future<void> Function(VoiceCluster v) play;
  final void Function(String name, VoiceCluster v) onChosen;

  @override
  State<FromFileScreen> createState() => _FromFileScreenState();
}

class _FromFileScreenState extends State<FromFileScreen> {
  final _name = TextEditingController();
  String? _fileName;
  UploadAnalysis? _analysis;
  VoiceCluster? _chosen;
  var _busy = false;
  String? _error;

  String get _person => _name.text.trim();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _choose() async {
    final f = await widget.pickFile();
    if (f == null || !mounted) return;
    setState(() {
      _fileName = f.path.split('/').last;
      _busy = true;
      _analysis = null;
      _chosen = null;
      _error = null;
    });
    try {
      final a = await widget.analyze(f);
      if (!mounted) return;
      setState(() {
        _analysis = a;
        if (a.voices.length == 1) _chosen = a.voices.single;
      });
    } on UploadError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String get _fileCopy {
    final a = _analysis;
    if (_busy) return 'Finding voices…';
    if (a == null || a.voices.isEmpty) return 'Any audio or video. Only the first 5 minutes are used.';
    return voicesFoundCopy(a.voices.length, _person.isEmpty ? 'them' : _person);
  }

  @override
  Widget build(BuildContext context) {
    final a = _analysis;
    final noSpeech = a != null && a.voices.isEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('From a file')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: 'Their name', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('File', style: TextStyle(fontWeight: FontWeight.w700)),
                        if (_fileName != null) Text(_fileName!),
                      ],
                    ),
                  ),
                  TextButton(onPressed: _busy ? null : _choose, child: const Text('Choose')),
                ],
              ),
              const SizedBox(height: 4),
              Text(_fileCopy, style: TextStyle(color: context.colors.muted)),
              if (_busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
              if (noSpeech)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    NotEnoughSpeechFrom(_person.isEmpty ? 'them' : _person).toString(),
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView(
                  children: [
                    for (final v in a?.voices ?? const <VoiceCluster>[])
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        selected: identical(v, _chosen),
                        selectedColor: context.colors.real,
                        leading: IconButton(
                          tooltip: 'Play ${v.label}',
                          icon: const Icon(Icons.play_circle_outline),
                          onPressed: () => widget.play(v),
                        ),
                        title: Text(v.label, style: const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text('${v.seconds.round()} s of speech'),
                        trailing: identical(v, _chosen) ? Icon(Icons.check_circle, color: context.colors.real) : null,
                        onTap: () => setState(() => _chosen = v),
                      ),
                  ],
                ),
              ),
              FilledButton(
                onPressed: _chosen == null || _person.isEmpty ? null : () => widget.onChosen(_person, _chosen!),
                style: FilledButton.styleFrom(
                  backgroundColor: context.colors.ink,
                  minimumSize: const Size.fromHeight(52),
                ),
                child: const Text('Check the words'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
