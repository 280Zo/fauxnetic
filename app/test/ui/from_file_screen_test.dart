import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fauxnetic/people/person.dart';
import 'package:fauxnetic/recording/transcriber.dart';
import 'package:fauxnetic/theme.dart';
import 'package:fauxnetic/ui/check_words_screen.dart';
import 'package:fauxnetic/ui/from_file_screen.dart';
import 'package:fauxnetic/upload/upload_pipeline.dart';

VoiceCluster voice(String label, double seconds) =>
    VoiceCluster(label: label, seconds: seconds, sample: Float32List(16000), clip: Float32List(16000 * 5));

void main() {
  Future<List<String>> pumpFromFile(WidgetTester t, List<VoiceCluster> found, {List<String>? chosen}) async {
    final played = <String>[];
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: FromFileScreen(
          pickFile: () async => File('/x/talk.mp4'),
          analyze: (_) async => UploadAnalysis(found),
          play: (v) async => played.add(v.label),
          onChosen: (name, v) => chosen?.add('$name ${v.label}'),
        ),
      ),
    );
    expect(find.text('From a file'), findsOneWidget);
    expect(find.text('File'), findsOneWidget);
    expect(find.text('Any audio or video. Only the first 5 minutes are used.'), findsOneWidget);
    await t.enterText(find.byType(TextField), 'Sam');
    await t.tap(find.text('Choose'));
    await t.pumpAndSettle();
    return played;
  }

  testWidgets('two voices: count copy, play buttons, choose one', (t) async {
    final chosen = <String>[];
    final played = await pumpFromFile(t, [voice('Voice A', 42), voice('Voice B', 7)], chosen: chosen);
    expect(find.text("Any audio or video. Two voices found; tap the one that's Sam."), findsOneWidget);
    expect(find.text('talk.mp4'), findsOneWidget);
    await t.tap(find.byTooltip('Play Voice B'));
    expect(played, ['Voice B']);
    final next = find.widgetWithText(FilledButton, 'Check the words');
    expect(t.widget<FilledButton>(next).onPressed, isNull);
    await t.tap(find.text('Voice B'));
    await t.pump();
    await t.tap(next);
    expect(chosen, ['Sam Voice B']);
  });

  testWidgets('one voice is chosen for you', (t) async {
    await pumpFromFile(t, [voice('Voice A', 20)]);
    expect(find.text('Any audio or video. One voice found.'), findsOneWidget);
    expect(t.widget<FilledButton>(find.widgetWithText(FilledButton, 'Check the words')).onPressed, isNotNull);
  });

  testWidgets('no speech explains itself', (t) async {
    await pumpFromFile(t, const []);
    expect(
      find.text("There isn't enough clear speech from Sam in this file (need at least 3 seconds)."),
      findsOneWidget,
    );
  });

  testWidgets('check words: editable words, uncertain flagged, consent enables build', (t) async {
    final builds = <String>[];
    Person? built;
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: CheckWordsScreen(
          name: 'Sam',
          voice: voice('Voice A', 20),
          transcribe: (_) async => const [TimedWord('Hello', 0, 1, 0.9), TimedWord('thar', 1, 2, 0.3)],
          build: (words, own, spoken) async {
            builds.add('$words|$own|$spoken');
            return const Person(id: 'p', name: 'Sam', source: PersonSource.upload);
          },
          onBuilt: (p) => built = p,
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Check the words'), findsOneWidget);
    expect(find.text('Transcribed on the phone. Tap a word to fix it.'), findsOneWidget);
    expect(find.byKey(const Key('uncertain-1')), findsOneWidget);
    expect(find.byKey(const Key('uncertain-0')), findsNothing);

    await t.tap(find.text('thar'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'there');
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(find.text('there'), findsOneWidget);

    final build = find.widgetWithText(FilledButton, "Build Sam's voice");
    expect(t.widget<FilledButton>(build).onPressed, isNull);
    // Owner, 2026-11-17: one consent box, and no "<name>'s" (a voice named "They" read "They's").
    expect(find.text('This is my own voice'), findsNothing);
    expect(find.byType(CheckboxListTile), findsOneWidget);
    await t.tap(find.text("I have this person's spoken consent to clone their voice"));
    await t.pump();
    await t.tap(build);
    await t.pumpAndSettle();
    expect(builds, ['Hello there|false|true']);
    expect(built!.id, 'p');
  });

  testWidgets('tapping a word plays its stretch and offers Play again', (t) async {
    // Owner, 2026-11-18: hear a yellow word before fixing it.
    final played = <int>[];
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: CheckWordsScreen(
          name: 'Sam',
          voice: voice('Voice A', 20),
          transcribe: (_) async => const [
            TimedWord('Hello', 0.5, 0.9, 0.9),
            TimedWord('thar', 1.0, 1.4, 0.3),
            TimedWord('friend', 1.5, 2.0, 0.9),
          ],
          build: (words, own, spoken) async => throw UnimplementedError(),
          onBuilt: (_) {},
          play: (pcm) async => played.add(pcm.length),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('thar'));
    await t.pumpAndSettle();
    expect(played, hasLength(1));
    expect(played.single, greaterThan(0));
    expect(find.text('Play again'), findsOneWidget);
    await t.tap(find.text('Play again'));
    await t.pump();
    expect(played, hasLength(2));
  });

  testWidgets('without a player, the fix box has no Play again', (t) async {
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: CheckWordsScreen(
          name: 'Sam',
          voice: voice('Voice A', 20),
          transcribe: (_) async => const [TimedWord('Hello', 0.5, 0.9, 0.9)],
          build: (words, own, spoken) async => throw UnimplementedError(),
          onBuilt: (_) {},
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('Hello'));
    await t.pumpAndSettle();
    expect(find.text('Play again'), findsNothing);
  });

  testWidgets('an unexpected build error shows a message', (t) async {
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: CheckWordsScreen(
          name: 'Sam',
          voice: voice('Voice A', 20),
          transcribe: (_) async => const [TimedWord('Hello', 0, 1, 0.9)],
          build: (words, own, spoken) async => throw const FileSystemException('disk full'),
          onBuilt: (_) {},
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text("I have this person's spoken consent to clone their voice"));
    await t.pump();
    await t.tap(find.text("Build Sam's voice"));
    await t.pumpAndSettle();
    expect(find.text("Couldn't build the voice. Try again."), findsOneWidget);
  });
}
