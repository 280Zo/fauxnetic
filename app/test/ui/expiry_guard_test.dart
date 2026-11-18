import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fauxnetic/people/person.dart';
import 'package:fauxnetic/theme.dart';
import 'package:fauxnetic/ui/expiry_guard.dart';

void main() {
  final expires = DateTime.utc(2026, 11, 15, 13);
  final sam = Person(id: 's', name: 'Sam', source: PersonSource.recorded, createdAt: expires, expiresAt: expires);

  Future<List<String>> pump(WidgetTester t, DateTime Function() now, {Brightness b = Brightness.light}) async {
    final events = <String>[];
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(b),
        home: Scaffold(
          body: ExpiryGuard(
            person: sam,
            now: now,
            onExpired: () async => events.add('expired'),
            child: const Text('screen'),
          ),
        ),
      ),
    );
    return events;
  }

  testWidgets('no banner with more than 5 minutes left', (t) async {
    await pump(t, () => expires.subtract(const Duration(minutes: 6)));
    expect(find.textContaining('will be deleted'), findsNothing);
    expect(find.text('screen'), findsOneWidget);
  });

  testWidgets('banner at 5 minutes', (t) async {
    await pump(t, () => expires.subtract(const Duration(minutes: 5)));
    expect(find.text("Sam's voice will be deleted in 5 min"), findsOneWidget);
  });

  testWidgets('the banner appears as time passes and counts down', (t) async {
    var now = expires.subtract(const Duration(minutes: 5, seconds: 10));
    await pump(t, () => now);
    expect(find.textContaining('will be deleted'), findsNothing);
    now = now.add(const Duration(seconds: 15));
    await t.pump(const Duration(seconds: 15));
    expect(find.text("Sam's voice will be deleted in 5 min"), findsOneWidget);
    now = expires.subtract(const Duration(minutes: 2, seconds: 30));
    await t.pump(const Duration(seconds: 15));
    expect(find.text("Sam's voice will be deleted in 3 min"), findsOneWidget);
  });

  testWidgets('expiry calls onExpired once', (t) async {
    var now = expires.subtract(const Duration(seconds: 5));
    final events = await pump(t, () => now);
    now = expires.add(const Duration(seconds: 10));
    await t.pump(const Duration(seconds: 15));
    await t.pump(const Duration(seconds: 30));
    expect(events, ['expired']);
  });

  testWidgets('already expired when opened calls onExpired', (t) async {
    final events = await pump(t, () => expires.add(const Duration(minutes: 1)));
    await t.pump();
    expect(events, ['expired']);
  });

  testWidgets('the banner uses the theme', (t) async {
    await pump(t, () => expires.subtract(const Duration(minutes: 1)), b: Brightness.dark);
    final rich = t.widget<RichText>(
      find.descendant(of: find.text("Sam's voice will be deleted in 1 min"), matching: find.byType(RichText)),
    );
    expect(rich.text.style?.color, FauxneticColors.dark.ink);
  });
}
