import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fauxnetic/people/person.dart';
import 'package:fauxnetic/recording/reference_builder.dart';
import 'package:fauxnetic/recording/scripts.dart';
import 'package:fauxnetic/theme.dart';
import 'package:fauxnetic/ui/people_screen.dart';
import 'package:fauxnetic/ui/voice_ready_screen.dart';

const ref = VoiceRef(clipFile: 'c', refText: 'Hi.', seconds: 9);
const sam = Person(id: 'p', name: 'Sam', source: PersonSource.recorded, voices: {Mood.conversational: ref});
const lightInk = Color(0xFF141822);

void main() {
  test('dark and light themes carry their colors', () {
    final dark = buildTheme(Brightness.dark);
    final d = dark.extension<FauxneticColors>()!;
    expect(d.paper, const Color(0xFF10131A));
    expect(d.card, const Color(0xFF181C25));
    expect(d.ink, const Color(0xFFE8EBF2));
    expect(d.muted, const Color(0xFF8A93A6));
    expect(d.rule, const Color(0xFF2A303C));
    expect(d.real, const Color(0xFF2BC4A3));
    expect(d.clone, const Color(0xFFF0559F));
    expect(d.uncertainFill, const Color(0xFF3A3115));
    expect(d.uncertainBorder, const Color(0xFFE0B000));
    expect(dark.colorScheme.brightness, Brightness.dark);
    expect(dark.scaffoldBackgroundColor, const Color(0xFF10131A));
    expect(dark.colorScheme.onPrimary, const Color(0xFF10131A), reason: 'ink buttons with paper-colored text');

    final l = buildTheme(Brightness.light).extension<FauxneticColors>()!;
    expect(l.paper, const Color(0xFFEEF0F4));
    expect(l.ink, lightInk);
    expect(l.real, const Color(0xFF0E7C66));
    expect(l.clone, const Color(0xFFC21C7A));
    expect(l.uncertainFill, const Color(0xFFFFF1C2));
  });

  test('screens take colors from the theme', () {
    final offenders = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart') && !f.path.endsWith('lib/theme.dart'))
        .where((f) => f.readAsStringSync().contains('Palette.'))
        .map((f) => f.path)
        .toList();
    expect(offenders, isEmpty, reason: 'a fixed light color would be unreadable on dark');
    final literals = Directory('lib/ui')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => RegExp(r'Color\(0x|Colors\.(?!transparent)').hasMatch(f.readAsStringSync()))
        .map((f) => f.path)
        .toList();
    expect(literals, isEmpty, reason: 'screen colors come from FauxneticColors');
  });

  Future<void> pumpDark(WidgetTester t, Widget home) =>
      t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.dark), home: home));

  Color? colorOf(WidgetTester t, String text) {
    final rich = t.widget<RichText>(find.descendant(of: find.text(text), matching: find.byType(RichText)).first);
    return rich.text.style?.color;
  }

  testWidgets('people screen is readable in dark', (t) async {
    await pumpDark(
      t,
      PeopleScreen(
        load: () async => [sam],
        onRecordNew: () async {},
        onFromFile: () async {},
        onOpen: (_) async {},
        onMoods: (_) async {},
        onDelete: (_) async {},
      ),
    );
    await t.pumpAndSettle();
    expect(colorOf(t, 'Sam'), isNot(lightInk));
    expect(colorOf(t, personSubtitle(sam)), FauxneticColors.dark.muted);
  });

  testWidgets('ready screen is readable in dark', (t) async {
    await pumpDark(t, VoiceReadyScreen(person: sam, onAddMore: (_) {}, onReRecord: (_) {}, onStartTyping: () {}));
    expect(colorOf(t, "Sam's voice is ready"), isNot(lightInk));
    expect(
      colorOf(t, 'Conversational voice recorded. Add moods if you want more range; each takes under a minute.'),
      FauxneticColors.dark.muted,
    );
  });
}
