import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fauxnetic/people/person.dart';
import 'package:fauxnetic/recording/reference_builder.dart';
import 'package:fauxnetic/recording/scripts.dart';
import 'package:fauxnetic/theme.dart';
import 'package:fauxnetic/ui/voice_ready_screen.dart';

const ref = VoiceRef(clipFile: 'c', refText: 'Hi.', seconds: 9);
const sam = Person(
  id: 'p',
  name: 'Sam',
  source: PersonSource.recorded,
  voices: {Mood.conversational: ref, Mood.worried: ref},
);

void main() {
  late List<String> events;

  Future<void> pump(WidgetTester t) async {
    events = [];
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: VoiceReadyScreen(
          person: sam,
          onAddMore: (m) => events.add('add ${m.name}'),
          onReRecord: (m) => events.add('rerecord ${m.name}'),
          onStartTyping: () => events.add('typing'),
        ),
      ),
    );
  }

  testWidgets('ready copy and typing', (t) async {
    await pump(t);
    expect(find.text("Sam's voice is ready"), findsOneWidget);
    expect(find.text('Checking how close it sounds…'), findsNothing);
    expect(find.text('Hear a sample'), findsNothing);
    await t.tap(find.text('Start typing lines'));
    expect(events, ['typing']);
  });

  testWidgets('conversational offers add more and re-record', (t) async {
    await pump(t);
    expect(find.text('Conversational'), findsOneWidget);
    await t.tap(find.text('Add more').first);
    await t.tap(find.text('Re-record').first);
    expect(events, ['add conversational', 'rerecord conversational']);
  });

  testWidgets('recorded mood offers add more and re-record', (t) async {
    await pump(t);
    for (final m in ['Excited', 'Annoyed', 'Worried', 'Storytelling']) {
      expect(find.text(m), findsOneWidget, reason: m);
    }
    expect(find.text('Record'), findsNWidgets(3), reason: 'worried is already recorded');
    await t.tap(find.text('Add more').last);
    await t.tap(find.text('Re-record').last);
    await t.tap(find.text('Record').first);
    expect(events, ['add worried', 'rerecord worried', 'add excited']);
  });
}
