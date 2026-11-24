import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fauxnetic/people/person.dart';
import 'package:fauxnetic/recording/reference_builder.dart';
import 'package:fauxnetic/recording/scripts.dart';
import 'package:fauxnetic/theme.dart';
import 'package:fauxnetic/ui/voice_ready_screen.dart';

const ref = VoiceRef(clipFile: 'c', refText: 'Hi.', seconds: 9);
const sam = Person(id: 'p', name: 'Sam', source: PersonSource.recorded, voices: {Mood.conversational: ref});
const felt = Person(
  id: 'p',
  name: 'Sam',
  source: PersonSource.recorded,
  voices: {Mood.conversational: ref, Mood.excited: ref, Mood.annoyed: ref, Mood.worried: ref},
);

void main() {
  late List<String> events;

  Future<void> pump(WidgetTester t, {Person person = sam, bool story = false}) async {
    events = [];
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: VoiceReadyScreen(
          person: person,
          storyDone: story,
          onMainAgain: () => events.add('main'),
          onStory: () => events.add('story'),
          onFeelings: () => events.add('feelings'),
          onStartTyping: () => events.add('typing'),
        ),
      ),
    );
  }

  // The owner-approved flow (2026-11-23): the main voice, then a story, then feelings, each
  // available later from People.
  testWidgets('three parts, with what is done and what is not', (t) async {
    await pump(t);
    expect(find.text("Sam's voice"), findsOneWidget);
    expect(find.text('Main voice'), findsOneWidget);
    expect(find.text('Ready · Record again'), findsOneWidget);
    expect(find.text('Not yet · makes it sound more like Sam'), findsOneWidget);
    expect(find.text('Not yet · excited, annoyed, worried'), findsOneWidget);
  });

  testWidgets('done parts say so and can be recorded again', (t) async {
    await pump(t, person: felt, story: true);
    expect(find.text('Done · Read another story'), findsOneWidget);
    expect(find.text('Done · Record again'), findsOneWidget);
  });

  testWidgets("each row starts its part; Try Sam's voice goes to typing", (t) async {
    await pump(t);
    await t.tap(find.text('Main voice'));
    await t.tap(find.text('Story'));
    await t.tap(find.text('Feelings'));
    await t.tap(find.text("Try Sam's voice"));
    expect(events, ['main', 'story', 'feelings', 'typing']);
  });
}
