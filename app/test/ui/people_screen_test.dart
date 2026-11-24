import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fauxnetic/people/person.dart';
import 'package:fauxnetic/recording/reference_builder.dart';
import 'package:fauxnetic/recording/scripts.dart';
import 'package:fauxnetic/theme.dart';
import 'package:fauxnetic/ui/people_screen.dart';
import 'package:fauxnetic/models/download_center.dart';
import 'package:fauxnetic/platform/network.dart';

import '../models/download_center_test.dart' show CountingKeeper, FakeStore, file;

const ref = VoiceRef(clipFile: 'c', refText: 'Hi.', seconds: 9);

void main() {
  final people = [
    const Person(id: 'a', name: 'Ana', source: PersonSource.recorded, voices: {Mood.conversational: ref}),
    const Person(
      id: 'b',
      name: 'Ben',
      source: PersonSource.upload,
      voices: {Mood.conversational: ref, Mood.excited: ref, Mood.worried: ref},
    ),
  ];

  Future<List<String>> pump(WidgetTester t) async {
    final events = <String>[];
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: PeopleScreen(
          load: () async => people,
          onRecordNew: () async => events.add('record'),
          onFromFile: () async => events.add('file'),
          onOpen: (p) async => events.add('open ${p.name}'),
          onMoods: (p) async => events.add('moods ${p.name}'),
          onDelete: (p) async => events.add('delete ${p.name}'),
        ),
      ),
    );
    await t.pumpAndSettle();
    return events;
  }

  testWidgets('people rows show mood count copy', (t) async {
    await pump(t);
    expect(find.text('People'), findsOneWidget);
    expect(find.text('voice ready · conversational'), findsOneWidget);
    expect(find.text('voice ready · 3 moods recorded'), findsOneWidget);
  });

  testWidgets('record and file buttons route', (t) async {
    final events = await pump(t);
    await t.tap(find.text('Record a new voice'));
    await t.tap(find.text('From an audio or video file'));
    await t.tap(find.text('Ana'));
    await t.tap(find.byTooltip('Add moods for Ben'));
    await t.pumpAndSettle();
    expect(events, ['record', 'file', 'open Ana', 'moods Ben']);
  });

  // Owner, 2026-11-23: an install killed the app mid-session; the person was left "voice not ready"
  // with only Delete. The approved design: how far it got, in amber, and Continue.
  testWidgets('an unfinished voice says how far it got and offers Continue', (t) async {
    final events = <String>[];
    const aj = Person(id: 'j', name: 'AJ', source: PersonSource.recorded);
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: PeopleScreen(
          load: () async => [aj],
          onRecordNew: () async {},
          onFromFile: () async {},
          onOpen: (p) async => events.add('open ${p.name}'),
          onMoods: (p) async {},
          onDelete: (p) async {},
          onContinue: (p) async => events.add('continue ${p.name}'),
          linesRecorded: (p) async => 3,
        ),
      ),
    );
    await t.pumpAndSettle();
    final label = find.text('Not finished: 3 of 7 lines recorded');
    expect(label, findsOneWidget);
    expect(t.widget<Text>(label).style?.color, FauxneticColors.light.making);
    expect(t.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, closeTo(3 / 7, 1e-9));
    expect(find.byTooltip('Delete AJ'), findsOneWidget);
    await t.tap(find.text('AJ'));
    await t.tap(find.text('Continue'));
    await t.pumpAndSettle();
    expect(events, ['continue AJ'], reason: 'the row itself opens nothing; Continue resumes');
  });

  testWidgets('delete asks first', (t) async {
    final events = await pump(t);
    await t.tap(find.byTooltip('Delete Ana'));
    await t.pumpAndSettle();
    expect(find.text('Delete Ana?'), findsOneWidget);
    await t.tap(find.text('Delete'));
    await t.pumpAndSettle();
    expect(events, ['delete Ana']);
  });

  testWidgets('no about button', (t) async {
    await pump(t);
    expect(find.text('About'), findsNothing);
  });

  testWidgets('people show how long their voice has left', (t) async {
    final now = DateTime.utc(2026, 11, 15, 12);
    final sam = Person(
      id: 's',
      name: 'Sam',
      source: PersonSource.recorded,
      voices: const {Mood.conversational: ref},
      createdAt: now,
      expiresAt: now.add(const Duration(hours: 5, minutes: 30)),
    );
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: PeopleScreen(
          load: () async => [sam],
          now: () => now,
          onRecordNew: () async {},
          onFromFile: () async {},
          onOpen: (_) async {},
          onMoods: (_) async {},
          onDelete: (_) async {},
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('voice ready · conversational · deleted in 5 h'), findsOneWidget);
  });

  testWidgets('the download bar shows under the title while the voice model downloads', (t) async {
    final center = DownloadCenter(
      store: (files) => FakeStore(files),
      network: () async => NetKind.metered,
      keeper: CountingKeeper(),
      poll: const Duration(hours: 1),
    );
    await t.runAsync(() => center.enqueue('qwen', 'Voice model', [file('talker', 1400000000)]));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: PeopleScreen(
          load: () async => [],
          onRecordNew: () async {},
          onFromFile: () async {},
          onOpen: (_) async {},
          onMoods: (_) async {},
          onDelete: (_) async {},
          downloads: center,
        ),
      ),
    );
    await t.pump();
    expect(find.text('Waiting for Wi-Fi · 1.4 GB left'), findsOneWidget);
    center.dispose();
  });

  testWidgets('an expired voice is announced', (t) async {
    final expired = ['Sam'];
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: PeopleScreen(
          load: () async => const [],
          takeExpired: () {
            final out = [...expired];
            expired.clear();
            return out;
          },
          onRecordNew: () async {},
          onFromFile: () async {},
          onOpen: (_) async {},
          onMoods: (_) async {},
          onDelete: (_) async {},
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text("Sam's voice expired and was deleted."), findsOneWidget);
  });

  testWidgets('the gear opens settings', (t) async {
    final events = <String>[];
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: PeopleScreen(
          load: () async => const [],
          onSettings: () async => events.add('settings'),
          onRecordNew: () async {},
          onFromFile: () async {},
          onOpen: (_) async {},
          onMoods: (_) async {},
          onDelete: (_) async {},
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Settings'));
    await t.pumpAndSettle();
    expect(events, ['settings']);
  });

  testWidgets('the list refreshes every minute', (t) async {
    var loads = 0;
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: PeopleScreen(
          load: () async {
            loads++;
            return const [];
          },
          onRecordNew: () async {},
          onFromFile: () async {},
          onOpen: (_) async {},
          onMoods: (_) async {},
          onDelete: (_) async {},
        ),
      ),
    );
    await t.pump();
    expect(loads, 1);
    await t.pump(const Duration(minutes: 1));
    expect(loads, 2, reason: 'countdowns move and expired voices disappear');
  });

  test('subtitle for a person without a voice', () {
    expect(personSubtitle(const Person(id: 'x', name: 'X', source: PersonSource.recorded)), 'voice not ready');
  });
}
