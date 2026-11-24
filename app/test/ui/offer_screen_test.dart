import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fauxnetic/theme.dart';
import 'package:fauxnetic/ui/offer_screen.dart';

void main() {
  Future<List<String>> pump(WidgetTester t, Offer offer) async {
    final events = <String>[];
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: OfferScreen(offer: offer, name: 'AJ', onYes: () => events.add('yes'), onNo: () => events.add('no')),
      ),
    );
    return events;
  }

  // Copy from the owner-approved mockup (2026-11-23).
  testWidgets('after the voice: make it sound more like them, or try the voice', (t) async {
    final events = await pump(t, Offer.story);
    expect(find.text("AJ's voice is ready"), findsOneWidget);
    expect(find.text("You can try AJ's voice now."), findsOneWidget);
    expect(find.text('Make it sound more like AJ'), findsOneWidget);
    expect(
      find.text(
        "Read a short story aloud, then answer one question in your own words. About two minutes. Relaxed speech "
        "helps the clone catch AJ's rhythm.",
      ),
      findsOneWidget,
    );
    expect(find.text('You can do this later: on People, tap the mic next to AJ.'), findsOneWidget);
    await t.tap(find.text('Read a story'));
    await t.tap(find.text("Not now, try AJ's voice"));
    expect(events, ['yes', 'no']);
  });

  testWidgets('after the story: give the voice some feeling, or try the voice', (t) async {
    final events = await pump(t, Offer.feelings);
    expect(find.text("Give AJ's voice some emotion"), findsOneWidget);
    expect(find.textContaining('feeling'), findsNothing, reason: 'owner, 2026-11-23: emotions, as on the voice screen');
    expect(
      find.text(
        'Say one short sentence five ways: plainly, as a question, excited, annoyed and worried. About a minute.',
      ),
      findsOneWidget,
    );
    expect(find.text('Then lines can sound excited, annoyed or worried.'), findsOneWidget);
    expect(find.text('You can add emotions later: on People, tap the mic next to AJ.'), findsOneWidget);
    await t.tap(find.text('Add emotions'));
    await t.tap(find.text("Not now, try AJ's voice"));
    expect(events, ['yes', 'no']);
  });
}
