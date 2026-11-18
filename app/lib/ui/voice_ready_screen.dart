import 'package:material_ui/material_ui.dart';

import '../people/person.dart';
import '../recording/scripts.dart';
import '../theme.dart';

/// After a session: refine the conversational voice, add moods, or go straight to typing lines.
class VoiceReadyScreen extends StatelessWidget {
  const VoiceReadyScreen({
    super.key,
    required this.person,
    required this.onAddMore,
    required this.onReRecord,
    required this.onStartTyping,
  });

  final Person person;

  /// Records (more) takes for a mood; also used for a mood not recorded yet.
  final void Function(Mood m) onAddMore;
  final void Function(Mood m) onReRecord;
  final VoidCallback onStartTyping;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                "${person.name}'s voice is ready",
                style: Theme.of(context).textTheme.headlineMedium!.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              Text(
                'Conversational voice recorded. Add moods if you want more range; each takes under a minute.',
                style: TextStyle(color: context.colors.muted),
              ),
              const SizedBox(height: 8),
              for (final m in Mood.values)
                Container(
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: context.colors.rule)),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Expanded(child: Text(m.label, style: const TextStyle(fontSize: 17))),
                      if (person.recorded(m)) ...[
                        TextButton(onPressed: () => onAddMore(m), child: const Text('Add more')),
                        TextButton(onPressed: () => onReRecord(m), child: const Text('Re-record')),
                      ] else
                        TextButton(onPressed: () => onAddMore(m), child: const Text('Record')),
                    ],
                  ),
                ),
              const Spacer(),
              FilledButton(
                onPressed: onStartTyping,
                style: FilledButton.styleFrom(
                  backgroundColor: context.colors.ink,
                  minimumSize: const Size.fromHeight(52),
                ),
                child: const Text('Start typing lines'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
