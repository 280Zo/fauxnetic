import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fauxnetic/people/people_repo.dart';
import 'package:fauxnetic/people/person.dart';
import 'package:fauxnetic/recording/reading_controller.dart';
import 'package:fauxnetic/recording/reference_builder.dart';
import 'package:fauxnetic/recording/scripts.dart';
import 'package:fauxnetic/recording/takes.dart';
import 'package:fauxnetic/storage/temp_sweeper.dart';
import 'package:fauxnetic/storage/vault.dart';
import 'package:fauxnetic/theme.dart';
import 'package:fauxnetic/ui/new_voice_screen.dart';
import 'package:fauxnetic/ui/reading_screen.dart';

import '../support/keys.dart';
import '../support/recording_fakes.dart';
import '../support/signals.dart';

void main() {
  late Directory dir;
  late PeopleRepo people;
  late TakeStore takes;
  late ReferenceBuilder builder;
  late FakeMic mic;
  late FakeTranscriber follow;
  late FakeTranscriber full;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('reading-ui');
    final vault = Vault(FixedKeyStore());
    takes = TakeStore(dir, vault);
    people = PeopleRepo(dir, vault, TempSweeper(dir), takes);
    builder = ReferenceBuilder(dir, vault, takes);
    mic = FakeMic();
    follow = FakeTranscriber();
    full = FakeTranscriber();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<ReadingController> pump(
    WidgetTester t, {
    Mood mood = Mood.conversational,
    Future<void> Function()? settings,
    bool cleaner = false,
  }) async {
    final sam = await t.runAsync(() => people.create('Sam', PersonSource.recorded));
    final c = ReadingController(
      sam!,
      mood,
      mic,
      follow,
      full,
      takes,
      people,
      builder,
      cleaner: cleaner ? (pcm) async => pcm : null,
    );
    full.next = () => words(c.line.text);
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: ReadingScreen(controller: c, onFinished: (_) {}, openSettings: settings ?? () async {}),
      ),
    );
    return c;
  }

  ScrollPosition scriptScroll(WidgetTester t) => t
      .state<ScrollableState>(
        find.ancestor(of: find.byKey(const Key('script-line')), matching: find.byType(Scrollable)),
      )
      .position;

  void screen(WidgetTester t, double w, double h) {
    t.view.physicalSize = Size(w, h);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
  }

  testWidgets('every passage fits on an A54-sized screen', (t) async {
    screen(t, 411, 891); // Galaxy A54: 1080 x 2340 at 2.625
    final c = await pump(t);
    final seen = <String>{};
    for (var i = 0; i < 30 && seen.length < kPassages.length; i++) {
      seen.add(c.line.text);
      await t.pump();
      expect(scriptScroll(t).maxScrollExtent, 0, reason: 'no scrolling needed: ${c.line.text.substring(0, 20)}');
      await t.runAsync(c.changePassage);
    }
    expect(seen, kPassages.toSet());
  });

  testWidgets('with the noise cleaner switch, every passage still fits on an A54-sized screen', (t) async {
    screen(t, 411, 891);
    final c = await pump(t, cleaner: true);
    expect(find.text('Clean up background noise'), findsOneWidget);
    for (var i = 0; i < 30; i++) {
      await t.pump();
      expect(scriptScroll(t).maxScrollExtent, 0, reason: 'no scrolling needed: ${c.line.text.substring(0, 20)}');
      await t.runAsync(c.changePassage);
    }
  });

  testWidgets('the noise cleaner switch starts off and turns on', (t) async {
    final c = await pump(t, cleaner: true);
    expect(t.widget<Switch>(find.byType(Switch)).value, isFalse);
    await t.tap(find.byType(Switch));
    await t.pump();
    expect(c.cleanNoise, isTrue);
    expect(t.widget<Switch>(find.byType(Switch)).value, isTrue);
  });

  testWidgets('no cleaner, no switch', (t) async {
    await pump(t);
    expect(find.text('Clean up background noise'), findsNothing);
  });

  testWidgets('a noisy take offers the cleaner with a Turn on button', (t) async {
    final c = await pump(t, cleaner: true);
    await t.runAsync(() async {
      await c.record();
      await mic.say(bursts(-25, -40));
      await c.stopAndCheck();
    });
    await t.pump();
    expect(find.text(kNoisyOfferHint), findsOneWidget);
    await t.tap(find.text('Turn on'));
    await t.pump();
    expect(c.cleanNoise, isTrue);
    expect(find.text('Turn on'), findsNothing);
  });

  testWidgets('on a screen too small to fit, the text follows the spoken word', (t) async {
    screen(t, 360, 600);
    final c = await pump(t);
    await t.pump();
    expect(scriptScroll(t).maxScrollExtent, greaterThan(0), reason: 'this screen is too small to fit the passage');
    expect(scriptScroll(t).pixels, 0);
    follow.next = () => words(c.lineWords.take(c.lineWords.length - 3).join(' '));
    await t.runAsync(() async {
      await c.record();
      await mic.say(goodTake().sublist(0, 8000));
    });
    await t.pumpAndSettle();
    expect(scriptScroll(t).pixels, greaterThan(0), reason: 'scrolled down to keep the spoken word in view');
    await t.runAsync(c.redo);
  });

  testWidgets('core line shows the exact copy', (t) async {
    final c = await pump(t);
    expect(find.text('Line 1 of 2'), findsOneWidget);
    expect(find.text("say it like you'd say it to a friend"), findsOneWidget);
    expect(find.text('Next: ${c.lines[1].text}'), findsOneWidget);
    for (final label in ['Redo', 'Record', 'Skip']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
  });

  testWidgets('spoken words are teal and the rest ink', (t) async {
    final c = await pump(t);
    follow.next = () => words(c.lineWords.take(2).join(' '));
    await t.runAsync(() async {
      await c.record();
      await mic.say(goodTake().sublist(0, 8000));
    });
    await t.pump();
    final rich = t.widget<RichText>(find.byKey(const Key('script-line'))).text as TextSpan;
    final spans = rich.children!.cast<TextSpan>();
    expect(spans.first.text, '${c.lineWords.take(2).join(' ')} ');
    expect(spans.first.style!.color, Palette.real);
    expect(spans.last.style!.color, Palette.ink);
    expect(find.text('Stop'), findsOneWidget);
    await t.runAsync(c.redo);
  });

  testWidgets('a denied microphone offers settings', (t) async {
    var opened = 0;
    mic.allowed = false;
    await pump(t, settings: () async => opened++);
    await t.runAsync(() async {
      await t.tap(find.text('Record'));
      await settle();
    });
    await t.pump();
    expect(find.text('Fauxnetic needs the microphone to record Sam. Allow it in Settings.'), findsOneWidget);
    await t.tap(find.text('Open settings'));
    expect(opened, 1);
  });

  testWidgets('no separate pause button when idle', (t) async {
    await pump(t);
    expect(find.text('Pause'), findsNothing);
    expect(find.text('Stop'), findsNothing);
  });

  testWidgets('recording shows pause and stop in place of record', (t) async {
    final c = await pump(t);
    await t.runAsync(c.record);
    await t.pump();
    expect(find.text('Record'), findsNothing);
    expect(find.text('Pause'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    await t.runAsync(() async {
      await t.tap(find.text('Pause'));
      await settle();
    });
    await t.pump();
    expect(c.paused, isTrue);
    expect(c.recording, isFalse);
    expect(find.text('Resume'), findsOneWidget);
    await t.runAsync(c.redo);
  });

  testWidgets('paused take shows resume', (t) async {
    final c = await pump(t);
    await t.runAsync(() async {
      await c.record();
      await mic.say(goodTake().sublist(0, 8000));
      await c.pause();
    });
    await t.pump();
    expect(find.text('Resume'), findsOneWidget);
    expect(find.text('Record'), findsNothing);
    await t.runAsync(c.redo);
  });

  testWidgets('swap button sits under record', (t) async {
    final c = await pump(t);
    final swap = find.widgetWithText(OutlinedButton, 'Try a different passage');
    expect(swap, findsOneWidget);
    expect(t.getSize(swap).width, greaterThan(300), reason: 'full width, not a small text link');
    expect(t.getTopLeft(swap).dy, greaterThan(t.getTopLeft(find.text('Record')).dy));
    await t.runAsync(c.record);
    await t.pump();
    expect(t.widget<OutlinedButton>(swap).onPressed, isNull, reason: 'disabled while recording');
    await t.runAsync(c.redo);
  });

  testWidgets('passage shows try a different passage', (t) async {
    final c = await pump(t);
    final first = c.line.text;
    await t.runAsync(() async {
      await t.tap(find.text('Try a different passage'));
      await settle();
    });
    await t.pump();
    expect(c.line.text, isNot(first));
    expect(find.text('Another question'), findsNothing);
  });

  testWidgets('question shows another question', (t) async {
    final c = await pump(t);
    await t.runAsync(c.skip);
    await t.pump();
    final first = c.line.text;
    await t.tap(find.text('Another question'));
    await t.pump();
    expect(c.line.text, isNot(first));
    expect(find.text('Try a different passage'), findsNothing);
  });

  testWidgets('the meter shows under questions, not under the passage', (t) async {
    final c = await pump(t);
    expect(find.byKey(const Key('voiceMeter')), findsNothing, reason: 'reading the passage');
    await t.runAsync(c.skip);
    await t.pump();
    expect(find.byKey(const Key('voiceMeter')), findsOneWidget);
    expect(find.text('Basic'), findsOneWidget);
    expect(find.text('Keep going'), findsOneWidget);
    expect(find.text('Finish'), findsNothing, reason: 'only after a short answer');
  });

  testWidgets('a short answer offers one more question and Finish', (t) async {
    final c = await pump(t);
    await t.runAsync(c.skip);
    full.next = () => words('Flying, obviously, every single day.');
    await t.runAsync(() async {
      await c.record();
      await mic.say(goodTake());
      await c.stopAndCheck();
    });
    await t.pump();
    expect(find.text('Answer one more for a better voice'), findsOneWidget);
    expect(find.text('Finish'), findsOneWidget);
    await t.tap(find.text('Finish'));
    expect(c.done, isTrue);
  });

  testWidgets('after answers the words are shown to check; a tap fixes one; then the voice is built', (t) async {
    Person? built;
    final sam = await t.runAsync(() => people.create('Sam', PersonSource.recorded));
    final c = ReadingController(sam!, Mood.conversational, mic, follow, full, takes, people, builder);
    full.next = () => words(c.line.text);
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: ReadingScreen(controller: c, onFinished: (p) => built = p, openSettings: () async {}),
      ),
    );
    await t.runAsync(c.skip);
    full.next = () => words('I have to worry about falling and flying everywhere today.');
    await t.runAsync(() async {
      await c.record();
      await mic.say(Float32List.fromList([...goodTake(), ...goodTake()]));
      await c.stopAndCheck();
    });
    await t.pump();
    expect(c.needsWordCheck, isTrue);
    expect(find.text('Check what you said'), findsOneWidget);
    await t.tap(find.text('have'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), "don't have");
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    // Saving writes the encrypted take file: let real time pass so it finishes, then redraw.
    for (var i = 0; i < 30 && !c.answersToCheck.first.text.contains("don't"); i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await t.pump();
    }
    await t.pump();
    expect(find.text("don't"), findsOneWidget);
    await t.tap(find.text('Build the voice'));
    for (var i = 0; i < 50 && built == null; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await t.pump();
    }
    expect(built, isNotNull);
    expect(built!.refFor(Mood.conversational).refText, contains("I don't have to worry"));
  });

  testWidgets('meter copy for good and full', (t) async {
    expect(meterCopy(VoiceFill.basic), ('Basic', 'Keep going'));
    expect(meterCopy(VoiceFill.good), ('Good', 'Good — you can stop any time'));
    expect(meterCopy(VoiceFill.full), ('Full', "Full — that's all a voice can use"));
  });

  testWidgets('a mood session names the mood', (t) async {
    await pump(t, mood: Mood.excited);
    expect(find.text('Line 1 of 3'), findsOneWidget);
    expect(find.text('Excited · say it like you mean it'), findsOneWidget);
  });

  testWidgets('new voice screen copy and start', (t) async {
    String? started;
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: NewVoiceScreen(onStart: (name) async => started = name),
      ),
    );
    expect(find.text('New voice'), findsOneWidget);
    expect(find.text('Their name'), findsOneWidget);
    final start = find.widgetWithText(FilledButton, 'Start reading');
    expect(t.widget<FilledButton>(start).onPressed, isNull);
    await t.enterText(find.byType(TextField), 'Ana');
    await t.pump();
    expect(
      find.text(
        'Hand the phone to Ana. They read one short passage and answer one question, about 30 seconds. '
        'Speaking is their consent.',
      ),
      findsOneWidget,
    );
    await t.tap(start);
    expect(started, 'Ana');
  });
}
