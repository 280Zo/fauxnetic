import 'package:material_ui/material_ui.dart';

import '../people/person.dart';
import '../recording/scripts.dart';
import '../theme.dart';

/// A voice's three parts, opened from People (owner-approved flow, 2026-11-23): the main voice,
/// a story that makes it sound more like the person, and feelings. Each can be done or redone here.
class VoiceReadyScreen extends StatelessWidget {
  const VoiceReadyScreen({
    super.key,
    required this.person,
    required this.storyDone,
    required this.onMainAgain,
    required this.onStory,
    required this.onFeelings,
    required this.onStartTyping,
  });

  final Person person;

  /// A story was read for this voice.
  final bool storyDone;
  final VoidCallback onMainAgain;
  final VoidCallback onStory;
  final VoidCallback onFeelings;
  final VoidCallback onStartTyping;

  bool get _felt => [Mood.excited, Mood.annoyed, Mood.worried].any(person.recorded);

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final name = person.name;
    Widget part(String title, bool done, String rest, VoidCallback onTap) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: colors.card,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: done ? (title == 'Main voice' ? 'Ready' : 'Done') : 'Not yet',
                              // Teal is only for the real voice, so done reads in full ink.
                              style: TextStyle(color: done ? colors.ink : colors.making, fontWeight: FontWeight.w700),
                            ),
                            TextSpan(text: ' · $rest'),
                          ],
                        ),
                        style: TextStyle(color: colors.soft, fontSize: 15),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: colors.soft),
              ],
            ),
          ),
        ),
      ),
    );
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                "$name's voice",
                style: Theme.of(context).textTheme.headlineMedium!.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 16),
              part('Main voice', person.ready, 'Record again', onMainAgain),
              part('Story', storyDone, storyDone ? 'Read another story' : 'makes it sound more like $name', onStory),
              part('Emotions', _felt, _felt ? 'Record again' : 'excited, annoyed, worried', onFeelings),
              const Spacer(),
              FilledButton(
                onPressed: onStartTyping,
                style: FilledButton.styleFrom(backgroundColor: colors.ink, minimumSize: const Size.fromHeight(56)),
                child: Text("Try $name's voice", style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
