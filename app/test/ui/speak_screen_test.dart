import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/audio/marking.dart';
import 'package:fauxnetic/models/download_center.dart';
import 'package:fauxnetic/audio/take_adjust.dart';
import 'package:fauxnetic/cues/cue.dart';
import 'package:fauxnetic/engine/voice_engine.dart';
import 'package:fauxnetic/people/person.dart';
import 'package:fauxnetic/recording/reference_builder.dart';
import 'package:fauxnetic/recording/scripts.dart';
import 'package:fauxnetic/theme.dart';
import 'package:fauxnetic/ui/speak_controller.dart';
import 'package:fauxnetic/ui/speak_screen.dart';

class FakeSpeakController extends SpeakController {
  FakeSpeakController(super.person);
  final added = <String>[];
  final playedIds = <String>[];
  final sharedIds = <String>[];
  final retried = <String>[];
  final removed = <String>[];

  void setItems(List<CueItem> v) {
    items = v;
    notifyListeners();
  }

  void setShown(String? id) {
    shownId = id;
    notifyListeners();
  }

  @override
  Future<void> remove(CueItem item) async {
    removed.add(item.id);
    items = items.where((c) => c.id != item.id).toList();
    notifyListeners();
  }

  void setPlaying(String? id) {
    shownId = id ?? shownId;
    playingId = id;
    waveform = id == null ? const [] : List.filled(20, 0.5);
    notifyListeners();
  }

  final selectedIds = <String>[];
  var newLines = 0;
  @override
  Future<void> select(CueItem item) async {
    if (!item.hasClip) return;
    selectedIds.add(item.id);
    shownId = item.id;
    lengthSeconds = 8;
    notifyListeners();
  }

  @override
  Future<void> newLine() async {
    newLines++;
    shownId = null;
    playingId = null;
    notifyListeners();
  }

  @override
  Future<void> add(String text) async => added.add('$text|${mood.name}');
  @override
  Future<void> play(CueItem item) async => playedIds.add(item.id);
  var stops = 0;
  @override
  Future<void> stop() async => stops++;
  var failShare = false;
  @override
  Future<void> share(CueItem item) async {
    sharedIds.add(item.id);
    shareError = failShare ? MarkMissing.message : null;
  }

  final loops = <bool>[];
  @override
  Future<void> setLooping(bool on) async => loops.add(on);

  final adjusted = <TakeAdjust>[];
  @override
  Future<void> adjust(CueItem item, TakeAdjust a) async {
    adjusted.add(a);
    items = [
      for (final c in items)
        c.id == item.id
            ? c.copyWith(clips: [for (final (i, k) in c.clips.indexed) i == c.current ? k.withAdjust(a) : k])
            : c,
    ];
    notifyListeners();
  }

  @override
  Future<void> retry(CueItem item) async => retried.add(item.id);
  final retriedIds = <String>[];
  @override
  Future<void> tryAgain(CueItem item) async => retriedIds.add(item.id);
  final takes = <String>[];
  @override
  Future<void> showTake(CueItem item, int index) async => takes.add('${item.id} $index');

  int? free;
  @override
  Future<int?> freeMemory() async => free;

  /// The model the engine has loaded; starts on Qwen so opening the screen needs no load.
  String? loaded = 'qwen';
  @override
  String? get loadedModel => loaded;

  /// When set, a load waits for it (or fails with its error).
  Completer<void>? loading;
  @override
  Future<void> loadModel(String id) async {
    modelEvents.add('load $id');
    await loading?.future;
    loaded = id;
  }

  /// Like a line being made: Cancel can't stop the load (it waits for that line).
  var cancelIgnored = false;

  @override
  Future<void> cancelLoad() async {
    modelEvents.add('cancel');
    if (cancelIgnored) return;
    final l = loading;
    if (l != null && !l.isCompleted) l.completeError(const EngineError(EngineErrorKind.cancelled, 'Stopped.'));
  }

  final ready = <String>{'qwen'};
  final modelEvents = <String>[];
  @override
  Future<bool> modelReady(String id) async => ready.contains(id);
  final jobs = <String, DownloadJob>{};
  @override
  DownloadJob? downloadOf(String id) => jobs[id];
  @override
  Future<void> startDownload(String id) async => modelEvents.add('download $id');

  @override
  Future<void> setModel(String id) async {
    modelEvents.add('model $id');
    await super.setModel(id);
  }

  @override
  double? progressOf(CueItem item) => 0.6;

  @override
  String statusOf(CueItem item) => switch (item.status) {
    CueStatus.preparing => 'Making with Qwen3-TTS · about 20 s left',
    CueStatus.queued => 'Next in line',
    CueStatus.failed => 'failed',
    CueStatus.ready => 'ready',
    CueStatus.played => 'played',
  };
}

const ref = VoiceRef(clipFile: 'c', refText: 'Hi.', seconds: 5);
const sam = Person(
  id: 'p1',
  name: 'Sam',
  source: PersonSource.recorded,
  voices: {Mood.conversational: ref, Mood.excited: ref},
);

CueItem cue(String id, CueStatus s, String text) => CueItem(id: id, personId: 'p1', text: text, status: s);

Future<FakeSpeakController> pump(WidgetTester t) async {
  final c = FakeSpeakController(sam);
  await t.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light),
      home: SpeakScreen(controller: c),
    ),
  );
  return c;
}

void main() {
  // The dock (owner, 2026-11-18): one magenta-edged area at the bottom that is the text box, or the
  // player for the selected line.
  Finder inDock(Finder f) => find.descendant(of: find.byKey(const Key('dock')), matching: f);

  testWidgets('with nothing yet, it says what to do in plain words', (t) async {
    // Owner, 2026-11-23: "lines" read as nonsense.
    await pump(t);
    expect(find.text('Type something for Sam to say.'), findsOneWidget);
    expect(find.textContaining('lines'), findsNothing);
  });

  testWidgets('the dock is the text box when nothing is selected', (t) async {
    final c = await pump(t);
    c.setItems([cue('a', CueStatus.ready, 'One.')]);
    await t.pump();
    expect(inDock(find.text('Type what Sam should say')), findsOneWidget);
    expect(inDock(find.text('Generate')), findsOneWidget);
    expect(find.text('Again'), findsNothing);
  });

  testWidgets('tapping a ready line puts it in the player, with synthetic, model and mood', (t) async {
    final c = await pump(t);
    c.setItems([
      const CueItem(
        id: 'a',
        personId: 'p1',
        text: 'Can you read me the code?',
        status: CueStatus.ready,
        mood: Mood.excited,
        clips: [CueClip('cues/a-0.bin', 1, engine: 'VoxCPM 2')],
      ),
    ]);
    await t.pump();
    await t.tap(find.text('Can you read me the code?'));
    await t.pump();
    expect(c.selectedIds, ['a']);
    expect(c.playedIds, isEmpty, reason: 'selecting does not play');
    expect(inDock(find.text('“Can you read me the code?”')), findsOneWidget);
    expect(inDock(find.text('Sam synthetic, VoxCPM 2')), findsOneWidget);
    expect(inDock(find.text('Excited')), findsOneWidget);
    expect(inDock(find.text('Again')), findsOneWidget);
    expect(inDock(find.text('New line')), findsOneWidget);
    expect(find.byType(TextField), findsNothing, reason: 'the player replaces the text box');
  });

  testWidgets('play and stop are in the player', (t) async {
    final c = await pump(t);
    c.setItems([cue('a', CueStatus.ready, 'One.')]);
    c.setShown('a');
    await t.pump();
    await t.tap(inDock(find.byTooltip('Play')));
    expect(c.playedIds, ['a']);
    c.setPlaying('a');
    await t.pump();
    await t.tap(inDock(find.byTooltip('Stop')));
    expect(c.stops, 1);
  });

  testWidgets('New goes back to typing', (t) async {
    final c = await pump(t);
    c.setItems([cue('a', CueStatus.ready, 'One.')]);
    c.setShown('a');
    await t.pump();
    await t.tap(find.text('New line'));
    await t.pump();
    expect(c.newLines, 1);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('a short line can be tapped anywhere across its row, not just on its words', (t) async {
    final c = await pump(t);
    c.setItems([cue('a', CueStatus.ready, 'Hi.')]);
    await t.pump();
    final words = t.getRect(find.text('Hi.'));
    final play = t.getRect(find.byKey(const Key('play-a')));
    // Between the words and the line's own play button (which plays instead).
    await t.tapAt(Offset((words.right + play.left) / 2, words.center.dy));
    await t.pump();
    expect(c.selectedIds, ['a']);
  });

  testWidgets('tapping the selected line again goes back to typing', (t) async {
    final c = await pump(t);
    c.setItems([cue('a', CueStatus.ready, 'One.')]);
    c.setShown('a');
    await t.pump();
    await t.tap(find.text('One.'));
    await t.pump();
    expect(c.newLines, 1);
  });

  testWidgets('the dock keeps one height', (t) async {
    final c = await pump(t);
    c.setItems([cue('a', CueStatus.ready, 'One.')]);
    await t.pump();
    final typing = t.getSize(find.byKey(const Key('dock'))).height;
    c.setShown('a');
    await t.pump();
    expect(t.getSize(find.byKey(const Key('dock'))).height, typing);
    c.setPlaying('a');
    await t.pump();
    expect(t.getSize(find.byKey(const Key('dock'))).height, typing);
  });

  testWidgets('only lines with audio can be selected', (t) async {
    final c = await pump(t);
    c.setItems([cue('c', CueStatus.preparing, 'Three.'), cue('d', CueStatus.failed, 'Four.')]);
    await t.pump();
    await t.tap(find.text('Three.'));
    await t.tap(find.text('Four.'));
    await t.pump();
    expect(c.selectedIds, isEmpty);
    expect(c.retried, ['d'], reason: 'a failed line retries');
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('newest line is at the bottom, next to the dock', (t) async {
    final c = await pump(t);
    c.setItems([cue('a', CueStatus.played, 'Older.'), cue('b', CueStatus.ready, 'Newest.')]);
    await t.pump();
    expect(t.getCenter(find.text('Newest.')).dy, greaterThan(t.getCenter(find.text('Older.')).dy));
  });

  testWidgets('the selected line is highlighted in the list', (t) async {
    final c = await pump(t);
    c.setItems([cue('a', CueStatus.ready, 'One.'), cue('b', CueStatus.ready, 'Two.')]);
    c.setShown('a');
    await t.pump();
    expect(find.byKey(const Key('selected-a')), findsOneWidget);
    expect(find.byKey(const Key('selected-b')), findsNothing);
  });

  testWidgets('the title shows the name in the clone color', (t) async {
    await pump(t);
    final name = t.widget<Text>(find.descendant(of: find.byType(AppBar), matching: find.text('Sam')));
    expect(name.style?.color, Palette.clone);
  });

  testWidgets('the dock has the card look with the magenta edge', (t) async {
    await pump(t);
    final box = t.widget<Container>(find.byKey(const Key('dock')));
    final d = box.decoration! as BoxDecoration;
    expect(d.color, Palette.card);
    expect(d.border, isA<Border>().having((b) => b.top.color, 'top', Palette.clone));
  });

  testWidgets('the player shows the takes switcher when there are several', (t) async {
    final c = await pump(t);
    c.setItems([
      const CueItem(
        id: 'a',
        personId: 'p1',
        text: 'Two takes.',
        status: CueStatus.ready,
        clips: [CueClip('cues/a-0.bin', 1), CueClip('cues/a-1.bin', 2)],
        current: 1,
      ),
      const CueItem(
        id: 'b',
        personId: 'p1',
        text: 'One take.',
        status: CueStatus.ready,
        clips: [CueClip('cues/b-0.bin', 1)],
      ),
    ]);
    c.setShown('b');
    await t.pump();
    expect(find.text('1/1'), findsNothing, reason: 'one take: no switcher');
    c.setShown('a');
    await t.pump();
    expect(inDock(find.text('2/2')), findsOneWidget);
    await t.tap(find.byTooltip('Previous take'));
    await t.tap(find.byTooltip('Next take'));
    expect(c.takes, ['a 0'], reason: 'next is past the last take, so disabled');
  });

  testWidgets('the player has no Report button (it is in Settings)', (t) async {
    final c = await pump(t);
    c.setItems([cue('a', CueStatus.ready, 'One.')]);
    c.setShown('a');
    await t.pump();
    expect(find.byTooltip('Report this line'), findsNothing);
  });

  testWidgets('holding a line copies its text', (t) async {
    final copied = <String>[];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final c = await pump(t);
    c.setItems([cue('a', CueStatus.ready, 'Can you read me the code?')]);
    await t.pump();
    await t.longPress(find.text('Can you read me the code?'));
    await t.pump();
    expect(copied, ['Can you read me the code?']);
    expect(find.text('Copied'), findsOneWidget);
    expect(c.selectedIds, isEmpty, reason: 'holding copies; it does not select');
  });

  testWidgets('Re-generate and Share act on the shown line', (t) async {
    final c = await pump(t);
    c.setItems([cue('a', CueStatus.played, 'One.'), cue('b', CueStatus.ready, 'Two.')]);
    c.setShown('a');
    await t.pump();
    await t.tap(find.text('Again'));
    await t.tap(inDock(find.text('Share')));
    expect(c.retriedIds, ['a']);
    expect(c.sharedIds, ['a']);
  });

  group('player layout (owner-approved redesign, 2026-11-23)', () {
    CueItem twoTakes() => const CueItem(
      id: 'a',
      personId: 'p1',
      text: 'Two takes.',
      status: CueStatus.ready,
      clips: [CueClip('cues/a-0.bin', 1), CueClip('cues/a-1.bin', 2)],
      current: 1,
    );

    Future<FakeSpeakController> narrow(WidgetTester t) async {
      // Test text is drawn as wide squares (about 1.5× the app's font), so 440 here is tighter than a
      // real 360 dp phone; the top row has to shrink to fit.
      t.view.physicalSize = const Size(440, 760);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final c = await pump(t);
      c.setItems([twoTakes()]);
      c.setShown('a');
      await t.pump();
      return c;
    }

    testWidgets('top row: who made it, then the takes, then the model picker at the right', (t) async {
      await narrow(t);
      final who = t.getRect(inDock(find.textContaining('synthetic')));
      final takes = t.getRect(inDock(find.byTooltip('Previous take')));
      final model = t.getRect(inDock(find.byTooltip('Choose the voice model')));
      final dock = t.getRect(find.byKey(const Key('dock')));
      expect(who.left - dock.left, lessThan(40));
      expect(who.right, lessThanOrEqualTo(takes.left));
      expect(takes.right, lessThanOrEqualTo(model.left));
      expect(model.right, lessThanOrEqualTo(dock.right));
      expect((who.center.dy - model.center.dy).abs(), lessThan(4), reason: 'one row');
      expect(inDock(find.text('Model')), findsNothing, reason: 'no label in the player');
    });

    testWidgets('picking a model in the player sets the voice model for the next take', (t) async {
      final c = await narrow(t);
      c.ready.add('voxcpm');
      await t.tap(inDock(find.text('Qwen3-TTS')));
      await t.pumpAndSettle();
      await t.tap(find.text('VoxCPM 2').last);
      await t.pumpAndSettle();
      expect(c.modelEvents, ['load voxcpm', 'model voxcpm']);
      expect(c.retriedIds, isEmpty, reason: 'picking does not re-generate by itself');
    });

    testWidgets('the transport: Play at the left, the waveform, the time at the right; actions below', (t) async {
      await narrow(t);
      final play = t.getRect(inDock(find.byTooltip('Play')));
      final wave = t.getRect(inDock(find.byKey(const Key('waveform'))));
      final time = t.getRect(inDock(find.textContaining(' / ')));
      expect(play.right, lessThanOrEqualTo(wave.left));
      expect(wave.right, lessThanOrEqualTo(time.left));
      expect((play.center.dy - wave.center.dy).abs(), lessThan(2));
      final acts = [
        for (final l in ['Share', 'Adjust', 'Again', 'New line']) t.getRect(inDock(find.text(l))),
      ];
      for (var i = 1; i < acts.length; i++) {
        expect(acts[i - 1].right, lessThan(acts[i].left), reason: 'in order, left to right');
        expect((acts[i].center.dy - acts[0].center.dy).abs(), lessThan(2), reason: 'one row');
      }
      expect(acts.first.top, greaterThan(play.bottom), reason: 'under the transport');
    });

    testWidgets('tapping outside the lines and the player goes back to typing', (t) async {
      final c = await narrow(t);
      final list = t.getRect(find.byType(ListView));
      await t.tapAt(Offset(list.center.dx, list.top + 10)); // empty space above the only line
      await t.pump();
      expect(c.newLines, 1);
      expect(inDock(find.text('Generate')), findsOneWidget);
    });

    testWidgets('lines are separate cards with a gap between them', (t) async {
      final c = await pump(t);
      c.setItems([cue('a', CueStatus.ready, 'One.'), cue('b', CueStatus.ready, 'Two.')]);
      await t.pump();
      final rows = find.byType(Dismissible);
      final first = t.getRect(rows.at(0));
      final second = t.getRect(rows.at(1));
      expect((first.top - second.bottom).abs(), greaterThanOrEqualTo(8));
    });
  });

  group('take adjustments', () {
    CueItem withTake([TakeAdjust a = TakeAdjust.defaults]) => CueItem(
      id: 'a',
      personId: 'p1',
      text: 'Adjust me.',
      status: CueStatus.ready,
      clips: [CueClip('cues/a-0.bin', 1, adjust: a)],
    );
    final glyph = find.byKey(const Key('adjusted'));

    Future<FakeSpeakController> shown(WidgetTester t, [TakeAdjust a = TakeAdjust.defaults]) async {
      final c = await pump(t);
      c.setItems([withTake(a)]);
      c.setShown('a');
      await t.pump();
      return c;
    }

    testWidgets("the Adjust button opens the panel with the take's settings", (t) async {
      await shown(t);
      await t.tap(inDock(find.text('Adjust')));
      await t.pumpAndSettle();
      for (final s in ['Speed', 'Pitch', 'Pauses', 'Volume', 'Even out loudness', 'Reset']) {
        expect(find.text(s), findsOneWidget, reason: s);
      }
      expect(find.text('1.0×'), findsNWidgets(2), reason: 'speed and pauses');
      expect(find.text('0 st'), findsOneWidget);
      expect(find.text('0 dB'), findsOneWidget);
    });

    testWidgets('moving Speed saves it on release', (t) async {
      final c = await shown(t);
      await t.tap(inDock(find.text('Adjust')));
      await t.pumpAndSettle();
      await t.drag(find.byKey(const Key('adjust-speed')), const Offset(60, 0));
      await t.pumpAndSettle();
      expect(c.adjusted, hasLength(1));
      expect(c.adjusted.single.speed, greaterThan(1));
    });

    testWidgets('Reset restores defaults', (t) async {
      final c = await shown(t, const TakeAdjust(speed: 1.25, pitch: 2));
      await t.tap(inDock(find.text('Adjust')));
      await t.pumpAndSettle();
      expect(find.text('1.25×'), findsOneWidget);
      await t.tap(find.text('Reset'));
      await t.pumpAndSettle();
      expect(c.adjusted.last, TakeAdjust.defaults);
      expect(find.text('0 st'), findsOneWidget);
    });

    testWidgets('each slider has its own reset, which leaves the others', (t) async {
      final c = await shown(t, const TakeAdjust(speed: 1.25, pitch: 2));
      await t.tap(inDock(find.text('Adjust')));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('Reset Speed'));
      await t.pumpAndSettle();
      expect(c.adjusted.last, const TakeAdjust(pitch: 2));
      expect(
        t.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.restart_alt).first).onPressed,
        isNull,
        reason: 'Speed is back at its default, so its reset is off',
      );
    });

    testWidgets('the take loops while the panel is open', (t) async {
      final c = await shown(t);
      await t.tap(inDock(find.text('Adjust')));
      await t.pumpAndSettle();
      expect(c.loops, [true]);
      await t.tapAt(const Offset(10, 10)); // outside the sheet
      await t.pumpAndSettle();
      expect(c.loops, [true, false]);
    });

    testWidgets('an adjusted take shows the glyph, a default one does not', (t) async {
      final c = await shown(t);
      expect(inDock(glyph), findsNothing);
      c.setItems([withTake(const TakeAdjust(pauses: 1.5))]);
      await t.pump();
      expect(inDock(glyph), findsOneWidget);
    });

    testWidgets('a refused share shows why', (t) async {
      final c = await shown(t);
      c.failShare = true;
      await t.tap(inDock(find.text('Share')));
      await t.pump();
      expect(find.text(MarkMissing.message), findsOneWidget);
    });
  });

  group('spoken word highlight', () {
    List<TextSpan> spans(WidgetTester t) =>
        (t.widget<Text>(find.byKey(const Key('spoken-words'))).textSpan! as TextSpan).children!.cast<TextSpan>();
    Color? colorOf(WidgetTester t, String word) => spans(t).firstWhere((s) => s.text!.contains(word)).style?.color;

    testWidgets('the word being spoken is magenta; none is before playing', (t) async {
      final c = await pump(t);
      c.setItems([cue('a', CueStatus.ready, 'One two three')]);
      c.words = ['One', 'two', 'three'];
      c.wordStarts = [0, 1, 2];
      c.setShown('a');
      await t.pump();
      expect(spans(t).map((s) => s.style?.color), everyElement(isNot(Palette.clone)));
      c.setPlaying('a');
      c.playedSeconds = 1.5;
      c.setPlaying('a');
      await t.pump();
      expect(colorOf(t, 'two'), Palette.clone);
      expect(colorOf(t, 'One'), isNot(Palette.clone));
      expect(colorOf(t, 'three'), isNot(Palette.clone));
    });

    testWidgets('a long line scrolls down to keep the spoken word in view', (t) async {
      final c = await pump(t);
      final text = List.generate(30, (i) => 'word$i').join(' ');
      c.setItems([cue('a', CueStatus.ready, text)]);
      c.words = text.split(' ');
      c.wordStarts = [for (var i = 0; i < 30; i++) i.toDouble()];
      c.setShown('a');
      await t.pump();
      ScrollController scroll() => t.widget<SingleChildScrollView>(find.byKey(const Key('spoken-line'))).controller!;
      expect(scroll().offset, 0);
      c.playedSeconds = 25.5;
      c.setPlaying('a');
      await t.pumpAndSettle();
      expect(scroll().offset, greaterThan(0));
      final word = t.getRect(find.byKey(const Key('spoken-line')));
      expect(word.width, greaterThan(0));
    });
  });

  testWidgets('a take shows which engine made it', (t) async {
    final c = await pump(t);
    c.setItems([
      const CueItem(
        id: 'a',
        personId: 'p1',
        text: 'Compare me.',
        status: CueStatus.ready,
        clips: [
          CueClip('cues/a-0.bin', 1, engine: 'VoxCPM 2'),
          CueClip('cues/a-1.bin', 2, engine: 'Pocket TTS'),
        ],
        current: 1,
      ),
    ]);
    c.setShown('a');
    await t.pump();
    expect(inDock(find.text('Sam synthetic, Pocket TTS')), findsOneWidget);
    expect(find.textContaining('VoxCPM 2'), findsNothing, reason: 'only the take shown');
  });

  testWidgets('the voice model picker sits by the text box and starts on Qwen', (t) async {
    await pump(t);
    expect(find.text('Model'), findsOneWidget);
    expect(find.text('Qwen3-TTS'), findsOneWidget);
  });

  testWidgets('picking a model that is not downloaded asks, then downloads it in the background', (t) async {
    // 2026-11-18: no blocking download dialog; the model downloads while the app is used.
    final c = await pump(t);
    await t.tap(find.text('Qwen3-TTS'));
    await t.pumpAndSettle();
    await t.tap(find.text('Pocket TTS').last);
    await t.pumpAndSettle();
    expect(find.textContaining('124 MB'), findsOneWidget);
    expect(find.textContaining('CC-BY-4.0'), findsOneWidget);
    await t.tap(find.text('Not now'));
    await t.pumpAndSettle();
    expect(c.modelEvents, isEmpty);
    await t.tap(find.text('Qwen3-TTS'));
    await t.pumpAndSettle();
    await t.tap(find.text('Pocket TTS').last);
    await t.pumpAndSettle();
    await t.tap(find.text('Download'));
    await t.pump();
    expect(c.modelEvents, ['download pocket'], reason: 'started; not switched until it is here');
    expect(c.modelId, 'qwen');
    expect(find.text('Downloading Pocket TTS in the background'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing, reason: 'no blocking download dialog');
  });

  testWidgets('a downloading model shows its progress and cannot be picked', (t) async {
    final c = await pump(t);
    c.jobs['pocket'] = DownloadJob('pocket', 'Pocket TTS', const [], 100)
      ..state = JobState.downloading
      ..received = 34;
    await t.tap(find.text('Qwen3-TTS'));
    await t.pumpAndSettle();
    expect(find.text('Pocket TTS · 34%'), findsOneWidget);
    await t.tap(find.text('Pocket TTS · 34%'));
    await t.pumpAndSettle();
    expect(c.modelEvents, isEmpty);
    expect(c.modelId, 'qwen');
  });

  testWidgets('a model too big for the free memory warns first', (t) async {
    final c = await pump(t);
    c.ready.add('voxcpm');
    c.free = 1200 * 1024 * 1024;
    await t.tap(find.text('Qwen3-TTS'));
    await t.pumpAndSettle();
    await t.tap(find.text('VoxCPM 2').last);
    await t.pumpAndSettle();
    expect(find.text('VoxCPM 2 may be very slow here'), findsOneWidget);
    expect(find.textContaining('1.3 GB free'), findsOneWidget);
    expect(find.textContaining('VoxCPM 2 (small)'), findsOneWidget, reason: 'points to the lighter one');
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(c.modelEvents, isEmpty);
    await t.tap(find.text('Qwen3-TTS'));
    await t.pumpAndSettle();
    await t.tap(find.text('VoxCPM 2').last);
    await t.pumpAndSettle();
    await t.tap(find.text('Use anyway'));
    await t.pumpAndSettle();
    expect(c.modelEvents, ['load voxcpm', 'model voxcpm']);
  });

  testWidgets('enough free memory: no warning', (t) async {
    final c = await pump(t);
    c.ready.add('voxcpm');
    c.free = 6 * 1024 * 1024 * 1024;
    await t.tap(find.text('Qwen3-TTS'));
    await t.pumpAndSettle();
    await t.tap(find.text('VoxCPM 2').last);
    await t.pumpAndSettle();
    expect(c.modelEvents, ['load voxcpm', 'model voxcpm']);
  });

  testWidgets('picking a downloaded model loads it behind a loading screen, then switches', (t) async {
    final c = await pump(t);
    c.ready.add('voxcpm');
    c.loading = Completer<void>();
    await t.tap(find.text('Qwen3-TTS'));
    await t.pumpAndSettle();
    await t.tap(find.text('VoxCPM 2').last);
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Loading VoxCPM 2…'), findsOneWidget);
    expect(find.text('0:00'), findsOneWidget);
    await t.pump(const Duration(seconds: 2));
    expect(find.text('0:02'), findsOneWidget, reason: 'the clock ticks');
    expect(c.modelEvents, ['load voxcpm'], reason: 'not switched until it is loaded');
    c.loading!.complete();
    await t.pumpAndSettle();
    expect(find.text('Loading VoxCPM 2…'), findsNothing);
    expect(c.modelEvents, ['load voxcpm', 'model voxcpm']);
  });

  testWidgets('cancel on the loading screen keeps the old model', (t) async {
    final c = await pump(t);
    c.ready.add('voxcpm');
    c.loading = Completer<void>();
    await t.tap(find.text('Qwen3-TTS'));
    await t.pumpAndSettle();
    await t.tap(find.text('VoxCPM 2').last);
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(c.modelEvents, ['load voxcpm', 'cancel']);
    expect(c.modelId, 'qwen');
    expect(find.text('Loading VoxCPM 2…'), findsNothing);
  });

  testWidgets('cancel closes the loading screen at once, even when the load can\'t stop', (t) async {
    // Owner, 2026-11-17: Cancel did nothing while VoxCPM was loading behind a line.
    final c = await pump(t);
    c.ready.add('voxcpm');
    c.loading = Completer<void>();
    c.cancelIgnored = true;
    await t.tap(find.text('Qwen3-TTS'));
    await t.pumpAndSettle();
    await t.tap(find.text('VoxCPM 2').last);
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(find.text('Loading VoxCPM 2…'), findsNothing);
    expect(c.modelId, 'qwen');
    c.loading!.complete();
    await t.pumpAndSettle();
    expect(c.modelId, 'qwen', reason: 'a load that finishes after Cancel does not switch the model');
  });

  testWidgets('running out of memory while loading offers Qwen', (t) async {
    final c = await pump(t);
    c.ready.add('voxcpm');
    c.loading = Completer<void>()
      ..future.ignore()
      ..completeError(const EngineError(EngineErrorKind.outOfMemory, 'Not enough memory.'));
    await t.tap(find.text('Qwen3-TTS'));
    await t.pumpAndSettle();
    await t.tap(find.text('VoxCPM 2').last);
    await t.pumpAndSettle();
    expect(find.textContaining('not enough free memory'), findsOneWidget);
    await t.tap(find.text('Use Qwen3-TTS'));
    await t.pumpAndSettle();
    expect(c.modelEvents.last, 'model qwen');
    expect(c.modelId, 'qwen');
  });

  testWidgets('opening a voice loads its model quietly, with no loading screen', (t) async {
    // Owner, 2026-11-17: the loading screen on opening a voice "makes no sense, nothing has been
    // played". The model still loads in the background so the first line isn't slower.
    final c = FakeSpeakController(sam)
      ..loaded = null
      ..loading = Completer<void>();
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: SpeakScreen(controller: c),
      ),
    );
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Loading Qwen3-TTS…'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(c.modelEvents, ['load qwen']);
    c.loading!.complete();
    await t.pumpAndSettle();
  });

  testWidgets('no reveal mode exists', (t) async {
    final c = await pump(t);
    c.setItems([cue('a', CueStatus.played, 'Line.')]);
    c.setShown('a');
    await t.pump();
    expect(find.text('Reveal mode'), findsNothing);
    expect(find.text('Reveal'), findsNothing);
  });

  testWidgets('preparing and failed keep their status', (t) async {
    final c = await pump(t);
    c.setItems([
      cue('c', CueStatus.preparing, 'Three.'),
      cue('d', CueStatus.failed, 'Four.'),
      cue('e', CueStatus.queued, 'Five.'),
    ]);
    await t.pump();
    for (final s in ['Making with Qwen3-TTS · about 20 s left', 'failed', 'Next in line']) {
      expect(find.text(s), findsOneWidget, reason: s);
    }
  });

  testWidgets('rows have no buttons of their own; ready rows show their takes', (t) async {
    final c = await pump(t);
    c.setItems([cue('a', CueStatus.played, 'One.'), cue('b', CueStatus.ready, 'Two.')]);
    await t.pump();
    expect(find.text('Say it'), findsNothing);
    expect(find.text('Try again'), findsNothing);
    expect(find.text('played'), findsNothing);
    expect(find.text('ready'), findsNothing);
  });

  testWidgets('generate closes the keyboard', (t) async {
    final c = await pump(t);
    await t.tap(find.byType(TextField));
    await t.enterText(find.byType(TextField), 'One.');
    expect(t.testTextInput.isVisible, isTrue);
    await t.tap(find.text('Generate'));
    await t.pump();
    expect(t.testTextInput.isVisible, isFalse);
    await t.enterText(find.byType(TextField), 'Two.');
    await t.testTextInput.receiveAction(TextInputAction.send);
    await t.pump();
    expect(t.testTextInput.isVisible, isFalse);
    expect(c.added, ['One.|conversational', 'Two.|conversational']);
  });

  testWidgets('input button says Generate', (t) async {
    await pump(t);
    expect(find.text('Generate'), findsOneWidget);
  });

  testWidgets('mood buttons have their own row under the text box, only for recorded moods', (t) async {
    final c = await pump(t);
    expect(find.widgetWithText(ChoiceChip, 'Conversational'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'Excited'), findsOneWidget);
    for (final m in [Mood.annoyed, Mood.worried, Mood.storytelling]) {
      expect(find.widgetWithText(ChoiceChip, m.label), findsNothing, reason: '${m.label} is not recorded');
    }
    expect(t.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Conversational')).selected, isTrue);
    final chipY = t.getCenter(find.widgetWithText(ChoiceChip, 'Excited')).dy;
    expect(chipY, greaterThan(t.getRect(find.byType(TextField)).bottom), reason: 'under the text box');
    expect(chipY, lessThan(t.getRect(find.text('Model')).top), reason: 'above the model picker');
    await t.tap(find.text('Excited'));
    await t.pump();
    expect(c.mood, Mood.excited);
    expect(find.textContaining('not recorded'), findsNothing);
  });

  // Owner, 2026-11-23: since the core session records Excited, Annoyed and Worried too, picking a
  // mood moved things around until the screen was unusable.
  const allMoods = Person(
    id: 'p3',
    name: 'Sam',
    source: PersonSource.recorded,
    voices: {Mood.conversational: ref, Mood.excited: ref, Mood.annoyed: ref, Mood.worried: ref},
  );

  Future<FakeSpeakController> pumpMoods(WidgetTester t, Size size) async {
    // The app's font: the test font's square letters are far wider, so widths would mean nothing.
    final loader = FontLoader(kFontFamily)
      ..addFont(rootBundle.load('assets/fonts/AtkinsonHyperlegibleNext-Regular.ttf'))
      ..addFont(rootBundle.load('assets/fonts/AtkinsonHyperlegibleNext-Bold.ttf'));
    await t.runAsync(loader.load);
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final c = FakeSpeakController(allMoods);
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: SpeakScreen(controller: c),
      ),
    );
    return c;
  }

  for (final (name, size) in [('A54', const Size(411, 891)), ('Pixel 9 Pro XL', const Size(448, 997))]) {
    testWidgets('on a $name, picking a mood moves nothing', (t) async {
      final c = await pumpMoods(t, size);
      Map<String, Rect> where() => {
        for (final m in c.moods) m.label: t.getRect(find.widgetWithText(ChoiceChip, m.label)),
        'text': t.getRect(find.byType(TextField)),
        'generate': t.getRect(find.text('Generate')),
        'dock': t.getRect(find.byKey(const Key('dock'))),
      };
      final before = where();
      final rows = {for (final m in c.moods) before[m.label]!.center.dy.round()};
      expect(rows, hasLength(1), reason: 'the moods stay on one row');
      for (final m in c.moods) {
        await t.tap(find.widgetWithText(ChoiceChip, m.label));
        await t.pumpAndSettle();
        expect(c.mood, m);
        expect(where(), before, reason: 'after picking ${m.label}');
      }
    });
  }

  // Owner, 2026-11-23: the line was cut to one row; the approved design wraps it, with a slim waveform.
  testWidgets('the player shows a two-row line in full, with a slim waveform', (t) async {
    final c = await pumpMoods(t, const Size(448, 997));
    const text = 'Hey, can you pick up the kids from school today? I have a meeting that runs late.';
    c.setItems([
      const CueItem(
        id: 'a',
        personId: 'p3',
        text: text,
        status: CueStatus.ready,
        clips: [CueClip('cues/a-0.bin', 1, engine: 'Qwen3-TTS')],
      ),
    ]);
    c.setShown('a');
    await t.pump();
    final line = t.state<ScrollableState>(
      find.descendant(of: find.byKey(const Key('spoken-line')), matching: find.byType(Scrollable)),
    );
    expect(line.position.maxScrollExtent, 0, reason: 'nothing hidden');
    expect(line.position.axis, Axis.vertical, reason: 'the line wraps instead of running off the side');
    expect(t.getSize(find.byKey(const Key('waveform'))).height, lessThanOrEqualTo(32));
  });

  // The owner-approved redesign (2026-11-23): lines read as clearly as the rest of the screen, color
  // carries meaning (status, mood), and the player has a big Play and four labeled actions.
  group('redesign', () {
    const colors = FauxneticColors.light;
    const clip = [CueClip('cues/a-0.bin', 1, engine: 'Qwen3-TTS')];
    CueItem line(CueStatus s, {Mood mood = Mood.conversational, String? error}) => CueItem(
      id: 'a',
      personId: 'p1',
      text: 'Feed the dog.',
      status: s,
      mood: mood,
      error: error,
      clips: s == CueStatus.ready || s == CueStatus.played ? clip : const [],
    );
    Color? colorOfText(WidgetTester t, String s) => t.widget<Text>(find.text(s).first).style?.color;

    testWidgets('a played line keeps full-strength text and says Played', (t) async {
      final c = await pump(t);
      c.setItems([line(CueStatus.played)]);
      await t.pump();
      expect(colorOfText(t, 'Feed the dog.'), colors.ink, reason: 'grey looked disabled');
      expect(find.text('Played'), findsOneWidget);
    });

    testWidgets('a ready line has its own play button', (t) async {
      final c = await pump(t);
      c.setItems([line(CueStatus.ready)]);
      await t.pump();
      expect(find.text('Ready'), findsOneWidget);
      await t.tap(find.byKey(const Key('play-a')));
      await t.pump();
      expect(c.playedIds, ['a']);
      expect(t.getSize(find.byKey(const Key('play-a'))).width, greaterThanOrEqualTo(44));
    });

    testWidgets('a line being made says so in amber, with an amber bar', (t) async {
      final c = await pump(t);
      c.setItems([line(CueStatus.preparing)]);
      await t.pump();
      expect(colorOfText(t, 'Making with Qwen3-TTS · about 20 s left'), colors.making);
      expect(t.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).color, colors.making);
      expect(find.byKey(const Key('play-a')), findsNothing, reason: 'nothing to play yet');
    });

    testWidgets('a failed line says so in the failed color', (t) async {
      final c = await pump(t);
      c.setItems([line(CueStatus.failed, error: 'Out of memory.')]);
      await t.pump();
      expect(colorOfText(t, 'Out of memory. Tap to retry.'), colors.failed);
    });

    testWidgets("a line's mood shows as a tag in that mood's color", (t) async {
      final c = await pump(t);
      c.setItems([line(CueStatus.ready, mood: Mood.excited)]);
      await t.pump();
      final tag = find.descendant(of: find.byType(ListView), matching: find.text('Excited'));
      expect(t.widget<Text>(tag).style?.color, colors.excited);
    });

    testWidgets('the player has a big Play and four labeled actions', (t) async {
      final c = await pump(t);
      c.setItems([line(CueStatus.ready, mood: Mood.excited)]);
      c.setShown('a');
      await t.pump();
      expect(t.getSize(inDock(find.byTooltip('Play'))).width, greaterThanOrEqualTo(56));
      for (final label in ['Share', 'Adjust', 'Again', 'New line']) {
        expect(inDock(find.text(label)), findsOneWidget, reason: label);
        expect(
          t.getSize(inDock(find.ancestor(of: find.text(label), matching: find.byKey(Key('act-$label'))))).height,
          greaterThanOrEqualTo(56),
          reason: label,
        );
      }
      await t.tap(inDock(find.text('Again')));
      expect(c.retriedIds, ['a']);
      await t.tap(inDock(find.text('New line')));
      expect(c.newLines, 1);
    });

    testWidgets("a picked mood chip takes that mood's color", (t) async {
      final c = await pump(t);
      c.setMood(Mood.excited);
      await t.pump();
      final chip = t.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Excited'));
      expect(chip.selectedColor, colors.excited);
    });
  });

  testWidgets('no mood buttons when only conversational is recorded', (t) async {
    final c = FakeSpeakController(
      const Person(id: 'p2', name: 'Ann', source: PersonSource.recorded, voices: {Mood.conversational: ref}),
    );
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: SpeakScreen(controller: c),
      ),
    );
    expect(find.byType(ChoiceChip), findsNothing);
  });

  testWidgets('no Fast or Accurate control', (t) async {
    await pump(t);
    expect(find.text('Fast'), findsNothing);
    expect(find.text('Accurate'), findsNothing);
  });

  testWidgets('Generate queues with the chosen mood', (t) async {
    final c = await pump(t);
    expect(find.text('Type what Sam should say'), findsOneWidget);
    await t.tap(find.text('Excited'));
    await t.enterText(find.byType(TextField), 'Send me the deck.');
    await t.tap(find.text('Generate'));
    await t.pump();
    expect(c.added, ['Send me the deck.|excited']);
  });

  testWidgets('tapping lines selects ready and played ones and retries failed ones', (t) async {
    // A phone-sized screen: the default 800x600 leaves the list under the taller dock too short.
    t.view.physicalSize = const Size(448, 997);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final c = await pump(t);
    c.setItems([
      cue('a', CueStatus.played, 'One.'),
      cue('b', CueStatus.ready, 'Two.'),
      cue('d', CueStatus.failed, 'Four.'),
    ]);
    await t.pump();
    await t.tap(find.text('Two.'));
    await t.pump();
    await t.tap(find.text('One.'));
    await t.pump();
    await t.tap(find.text('Four.'));
    expect(c.selectedIds, ['b', 'a']);
    expect(c.retried, ['d']);
  });

  testWidgets('after Generate the dock stays on typing', (t) async {
    final c = await pump(t);
    await t.enterText(find.byType(TextField), 'Queue me.');
    await t.tap(find.text('Generate'));
    await t.pump();
    expect(c.added, ['Queue me.|conversational']);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('swiping a line removes it', (t) async {
    final c = await pump(t);
    c.setItems([cue('e', CueStatus.queued, 'Five.')]);
    await t.pump();
    await t.drag(find.text('Five.'), const Offset(-600, 0));
    await t.pumpAndSettle();
    expect(c.removed, ['e']);
  });
}
