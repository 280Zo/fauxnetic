import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../models/download_center.dart';
import '../people/expiry.dart';
import '../people/person.dart';
import '../recording/scripts.dart';
import '../theme.dart';
import 'download_bar.dart';

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
    this.downloads,
    this.onContinue,
    this.linesRecorded,
  });

  /// Resumes a recorded voice whose session was cut short (killed by an install, a crash, a
  /// flat battery); null: such a voice only offers Delete. Returns once that session is done.
  final Future<void> Function(Person p)? onContinue;

  /// How many of the core session's lines an unfinished voice has recorded.
  final Future<int> Function(Person p)? linesRecorded;

  /// Background downloads, shown as a slim bar under the title while one is pending.
  final DownloadCenter? downloads;

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

  /// Lines recorded so far, for each unfinished voice that can be continued.
  var _recorded = <String, int>{};

  bool _unfinished(Person p) => !p.ready && p.source == PersonSource.recorded && widget.onContinue != null;

  Future<void> _reload() async {
    final all = await widget.load();
    final count = widget.linesRecorded;
    final recorded = <String, int>{for (final p in all.where(_unfinished)) p.id: count == null ? 0 : await count(p)};
    if (!mounted) return;
    setState(() {
      _people = all;
      _recorded = recorded;
    });
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
            if (widget.downloads != null) DownloadBar(center: widget.downloads!),
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
                        final unfinished = _unfinished(p);
                        final done = (_recorded[p.id] ?? 0).clamp(0, kCoreLines);
                        return ListTile(
                          contentPadding: const EdgeInsets.only(left: 20, right: 8, top: 4, bottom: 4),
                          title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                          // An unfinished voice says how far it got, in the "in progress" amber.
                          subtitle: unfinished
                              ? Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      done >= kCoreLines
                                          ? 'Not finished: the voice still has to be made'
                                          : 'Not finished: read the passage to make the voice',
                                      style: TextStyle(color: context.colors.making, fontWeight: FontWeight.w700),
                                    ),
                                  ],
                                )
                              : Text(
                                  personSubtitle(p, now: _now()),
                                  style: TextStyle(color: context.colors.muted),
                                ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (unfinished)
                                FilledButton(
                                  onPressed: () => _then(() => widget.onContinue!(p)),
                                  style: FilledButton.styleFrom(
                                    backgroundColor: context.colors.making,
                                    foregroundColor: context.colors.paper,
                                    minimumSize: const Size(0, 40),
                                  ),
                                  child: const Text('Continue', style: TextStyle(fontWeight: FontWeight.w700)),
                                ),
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
