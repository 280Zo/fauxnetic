import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../models/model_store.dart';
import '../settings/settings_store.dart';
import '../storage/storage_report.dart';
import '../theme.dart';
import 'models_section.dart';

/// Theme, how long voices and lines are kept, clearing and deleting, storage, and About.
/// Every deleting action asks first.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.settings,
    required this.onTheme,
    required this.onKeepFor,
    required this.voicesOlderThan,
    required this.onClearLines,
    required this.onDeleteEverything,
    required this.storage,
    required this.onRemoveModels,
    required this.onAbout,
    required this.models,
    required this.onDefaultModel,
    required this.onDeleteModel,
    required this.downloadModel,
  });

  final Future<List<ModelInfo>> Function() models;
  final Future<void> Function(String id) onDefaultModel;
  final Future<void> Function(String id) onDeleteModel;
  final Stream<DownloadProgress> Function(String id) downloadModel;

  final AppSettings settings;
  final Future<void> Function(ThemeChoice c) onTheme;
  final Future<void> Function(Duration d) onKeepFor;

  /// How many voices a switch to this keep-for would delete at once.
  final Future<int> Function(Duration d) voicesOlderThan;
  final Future<void> Function() onClearLines;
  final Future<void> Function() onDeleteEverything;
  final Future<StorageReport> Function() storage;
  final Future<void> Function() onRemoveModels;
  final VoidCallback onAbout;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late AppSettings _s = widget.settings;
  StorageReport? _storage;

  int get _downloadBytes => kModels.fold(0, (n, m) => n + m.size);

  @override
  void initState() {
    super.initState();
    _measure();
  }

  Future<void> _measure() async {
    final r = await widget.storage();
    if (mounted) setState(() => _storage = r);
  }

  Future<bool> _confirm(String title, String body, String no, String yes) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(no)),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(yes)),
          ],
        ),
      ) ??
      false;

  Future<void> _theme(ThemeChoice c) async {
    setState(() => _s = _s.copyWith(theme: c));
    await widget.onTheme(c);
  }

  Future<void> _keep(Duration d) async {
    if (d == _s.keepFor) return;
    if (d < _s.keepFor) {
      final n = await widget.voicesOlderThan(d);
      if (n > 0) {
        final hours = d.inHours == 1 ? '1 hour' : '${d.inHours} hours';
        final ok = await _confirm(
          'Switch to $hours?',
          '$n ${n == 1 ? 'voice is' : 'voices are'} already older than $hours and will be deleted now.',
          'Keep ${_s.keepFor.inHours} hours',
          'Switch',
        );
        if (!ok) return;
      }
    }
    if (!mounted) return;
    setState(() => _s = _s.copyWith(keepFor: d));
    await widget.onKeepFor(d);
    await _measure();
  }

  Future<void> _clear() async {
    if (!await _confirm(
      'Clear all generated lines?',
      'Every line and take for everyone is deleted now.',
      'Keep',
      'Clear',
    )) {
      return;
    }
    await widget.onClearLines();
    await _measure();
  }

  Future<void> _deleteEverything() async {
    final ok = await _confirm(
      'Delete everything?',
      'All people, voices, recordings and lines are erased from this phone. The voice models stay.',
      'Keep',
      'Delete',
    );
    if (!ok) return;
    await widget.onDeleteEverything();
    await _measure();
  }

  Future<void> _removeModels() async {
    final frees = formatBytes(_storage?.models ?? _downloadBytes);
    final ok = await _confirm(
      'Remove the voice models?',
      'Frees $frees. Fauxnetic downloads them again (${formatBytes(_downloadBytes)}) before you can make or use a voice.',
      'Keep',
      'Remove',
    );
    if (ok) await widget.onRemoveModels();
  }

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 8),
    child: Text(text, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
  );

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Expanded(child: Text(label)),
        Text(value, style: TextStyle(color: context.colors.muted)),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final st = _storage;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          children: [
            _heading('Theme'),
            SegmentedButton<ThemeChoice>(
              segments: const [
                ButtonSegment(value: ThemeChoice.dark, label: Text('Dark')),
                ButtonSegment(value: ThemeChoice.light, label: Text('Light')),
                ButtonSegment(value: ThemeChoice.system, label: Text('System')),
              ],
              selected: {_s.theme},
              showSelectedIcon: false,
              onSelectionChanged: (v) => _theme(v.single),
            ),
            _heading('Delete voices and lines after'),
            SegmentedButton<Duration>(
              segments: [
                for (final d in kKeepForChoices)
                  ButtonSegment(value: d, label: Text(d.inHours == 1 ? '1 hour' : '${d.inHours} hours')),
              ],
              selected: {_s.keepFor},
              showSelectedIcon: false,
              onSelectionChanged: (v) => _keep(v.single),
            ),
            const SizedBox(height: 6),
            Text(
              'Counted from when each voice or line was made. A shorter time applies to everything already here.',
              style: TextStyle(color: context.colors.muted, fontSize: 13),
            ),
            _heading('Clean up'),
            OutlinedButton(onPressed: _clear, child: const Text('Clear all generated lines')),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _deleteEverything,
              style: OutlinedButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
              child: const Text('Delete everything'),
            ),
            _heading('Models'),
            ModelsSection(
              initialDefault: _s.model,
              models: widget.models,
              onDefault: widget.onDefaultModel,
              onDelete: (id) async {
                await widget.onDeleteModel(id);
                await _measure();
              },
              download: widget.downloadModel,
            ),
            _heading('Storage'),
            _row('Voice models', st == null ? '…' : formatBytes(st.models)),
            _row('Voices and recordings', st == null ? '…' : formatBytes(st.voices)),
            _row('Generated lines', st == null ? '…' : formatBytes(st.lines)),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: _removeModels, child: const Text('Remove voice models')),
            _heading('About'),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('About and privacy'),
              trailing: const Icon(Icons.chevron_right),
              onTap: widget.onAbout,
            ),
          ],
        ),
      ),
    );
  }
}
