import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../people/expiry.dart';
import '../people/person.dart';
import '../theme.dart';

String personSubtitle(Person p, {DateTime? now}) {
  if (!p.ready) return 'voice not ready';
  final n = p.voices.length;
  final kind = n == 1 ? 'voice ready · conversational' : 'voice ready · $n moods recorded';
  final e = p.expiresAt;
  return e == null || now == null ? kind : '$kind · ${timeLeft(e.difference(now))}';
}

/// Everyone with a voice on this phone, and the two ways to add one.
class PeopleScreen extends StatefulWidget {
  const PeopleScreen({
    super.key,
    required this.load,
    required this.onRecordNew,
    required this.onFromFile,
    required this.onOpen,
    required this.onMoods,
    required this.onDelete,
    this.now,
    this.takeExpired,
    this.onSettings,
  });

  /// Opens Settings; the list reloads when it closes (settings can delete voices).
  final Future<void> Function()? onSettings;

  final Future<List<Person>> Function() load;

  /// The clock for the "deleted in" countdowns (default: now, UTC).
  final DateTime Function()? now;

  /// Names of people whose voices expired since the last call; each is announced once.
  final List<String> Function()? takeExpired;

  /// Each returns once the flow it starts is finished, so the list can refresh.
  final Future<void> Function() onRecordNew;
  final Future<void> Function() onFromFile;
  final Future<void> Function(Person p) onOpen;
  final Future<void> Function(Person p) onMoods;
  final Future<void> Function(Person p) onDelete;

  @override
  State<PeopleScreen> createState() => _PeopleScreenState();
}

class _PeopleScreenState extends State<PeopleScreen> {
  List<Person> _people = const [];

  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _reload();
    // Countdowns move, and voices that expire while the list is open disappear.
    _tick = Timer.periodic(const Duration(minutes: 1), (_) => _reload());
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    final all = await widget.load();
    if (!mounted) return;
    setState(() => _people = all);
    for (final name in widget.takeExpired?.call() ?? const <String>[]) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("$name's voice expired and was deleted.")));
    }
  }

  DateTime _now() => widget.now?.call() ?? DateTime.now().toUtc();

  Future<void> _then(Future<void> Function() flow) async {
    await flow();
    await _reload();
  }

  Future<void> _delete(Person p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${p.name}?'),
        content: const Text('Their voice, recordings and every line in their voice are erased from this phone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) await _then(() => widget.onDelete(p));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('People'),
        actions: [
          if (widget.onSettings != null)
            IconButton(
              tooltip: 'Settings',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => _then(widget.onSettings!),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _people.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          'No voices on this phone yet.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: context.colors.muted),
                        ),
                      ),
                    )
                  : ListView.separated(
                      itemCount: _people.length,
                      separatorBuilder: (_, _) => const Divider(height: 1, indent: 20, endIndent: 20),
                      itemBuilder: (_, i) {
                        final p = _people[i];
                        return ListTile(
                          contentPadding: const EdgeInsets.only(left: 20, right: 8, top: 4, bottom: 4),
                          title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                          subtitle: Text(
                            personSubtitle(p, now: _now()),
                            style: TextStyle(color: context.colors.muted),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (p.ready)
                                IconButton(
                                  tooltip: 'Add moods for ${p.name}',
                                  icon: const Icon(Icons.mic_none),
                                  onPressed: () => _then(() => widget.onMoods(p)),
                                ),
                              IconButton(
                                tooltip: 'Delete ${p.name}',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () => _delete(p),
                              ),
                            ],
                          ),
                          onTap: p.ready ? () => _then(() => widget.onOpen(p)) : null,
                        );
                      },
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton(
                    onPressed: () => _then(widget.onRecordNew),
                    style: FilledButton.styleFrom(
                      backgroundColor: context.colors.ink,
                      minimumSize: const Size.fromHeight(52),
                    ),
                    child: const Text('Record a new voice'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: () => _then(widget.onFromFile),
                    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                    child: const Text('From an audio or video file'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
