import 'package:material_ui/material_ui.dart';

import '../theme.dart';

/// The two optional steps after a voice is made (owner-approved flow, 2026-11-23).
enum Offer { story, feelings }

/// Offers the next optional step: read a story (after the main voice), or add feelings (after the
/// story). "Not now" goes straight to trying the voice; both say the step can be done later.
class OfferScreen extends StatelessWidget {
  const OfferScreen({super.key, required this.offer, required this.name, required this.onYes, required this.onNo});

  final Offer offer;
  final String name;
  final VoidCallback onYes;
  final VoidCallback onNo;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final (title, body, cardTitle, cardBody, yes, later) = switch (offer) {
      Offer.story => (
        "$name's voice is ready",
        "You can try $name's voice now.",
        'Make it sound more like $name',
        "Read a short story aloud, then answer one question in your own words. About two minutes. Relaxed speech "
            "helps the clone catch $name's rhythm.",
        'Read a story',
        'You can do this later: on People, tap the mic next to $name.',
      ),
      Offer.feelings => (
        "Give $name's voice some feeling",
        'Say one short sentence five ways: plainly, as a question, excited, annoyed and worried. About a minute.',
        null,
        'Then lines can sound excited, annoyed or worried.',
        'Add feelings',
        'You can add feelings later: on People, tap the mic next to $name.',
      ),
    };
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineMedium!.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              Text(body, style: TextStyle(color: colors.soft, fontSize: 17, height: 1.4)),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(color: colors.card, borderRadius: BorderRadius.circular(18)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (cardTitle != null) ...[
                      Text(cardTitle, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                    ],
                    Text(cardBody, style: TextStyle(color: colors.soft, fontSize: 16, height: 1.4)),
                  ],
                ),
              ),
              const Spacer(),
              FilledButton(
                onPressed: onYes,
                style: FilledButton.styleFrom(backgroundColor: colors.ink, minimumSize: const Size.fromHeight(56)),
                child: Text(yes, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(height: 10),
              OutlinedButton(
                onPressed: onNo,
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                child: Text("Not now, try $name's voice", style: const TextStyle(fontSize: 16)),
              ),
              const SizedBox(height: 12),
              Text(
                later,
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.muted, fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
