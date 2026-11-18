import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/cues/cue.dart';
import 'package:fauxnetic/engine/voice_engine.dart';
import 'package:fauxnetic/models/model_store.dart';
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
  @override
  Future<void> share(CueItem item) async => sharedIds.add(item.id);
  final reportedIds = <String>[];
  @override
  Future<bool> report(CueItem item) async {
    reportedIds.add(item.id);
    return true;
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
  @override
  Stream<DownloadProgress> downloadModel(String id) {
    modelEvents.add('download $id');
    ready.add(id);
    return Stream.fromIterable([DownloadProgress('$id.gguf', 5, 10)]);
  }

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

  testWidgets('the dock is the text box when nothing is selected', (t) async {
    final c = await pump(t);
    c.setItems([cue('a', CueStatus.ready, 'One.')]);
    await t.pump();
    expect(inDock(find.text('Type what Sam should say')), findsOneWidget);
    expect(inDock(find.text('Generate')), findsOneWidget);
    expect(find.text('↻ Re-generate'), findsNothing);
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
    expect(inDock(find.text('Sam · synthetic · VoxCPM 2 · Excited')), findsOneWidget);
    expect(inDock(find.text('↻ Re-generate')), findsOneWidget);
    expect(inDock(find.text('✎ New')), findsOneWidget);
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
    await t.tap(find.text('✎ New'));
    await t.pump();
    expect(c.newLines, 1);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('a short line can be tapped anywhere across its row, not just on its words', (t) async {
    final c = await pump(t);
    c.setItems([cue('a', CueStatus.ready, 'Hi.')]);
    await t.pump();
    final words = t.getRect(find.text('Hi.'));
    final list = t.getRect(find.byType(ListView));
    await t.tapAt(Offset(list.right - 30, words.center.dy));
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

  testWidgets('the player has a Report button for the shown line', (t) async {
    // Google Play's AI-generated content policy: an in-app way to report offensive content.
    final c = await pump(t);
    c.setItems([cue('a', CueStatus.ready, 'One.')]);
    c.setShown('a');
    await t.pump();
    await t.tap(inDock(find.byTooltip('Report this line')));
    expect(c.reportedIds, ['a']);
  });

  testWidgets('Re-generate and Share act on the shown line', (t) async {
    final c = await pump(t);
    c.setItems([cue('a', CueStatus.played, 'One.'), cue('b', CueStatus.ready, 'Two.')]);
    c.setShown('a');
    await t.pump();
    await t.tap(find.text('↻ Re-generate'));
    await t.tap(inDock(find.byTooltip('Share')));
    expect(c.retriedIds, ['a']);
    expect(c.sharedIds, ['a']);
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
    expect(inDock(find.text('Sam · synthetic · Pocket TTS')), findsOneWidget);
    expect(find.textContaining('VoxCPM 2'), findsNothing, reason: 'only the take shown');
  });

  testWidgets('the voice model picker sits by the text box and starts on Qwen', (t) async {
    await pump(t);
    expect(find.text('Model'), findsOneWidget);
    expect(find.text('Qwen3-TTS'), findsOneWidget);
  });

  testWidgets('picking a model that is not downloaded asks, downloads, then switches', (t) async {
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
    expect(c.modelId, 'qwen');
    await t.tap(find.text('Qwen3-TTS'));
    await t.pumpAndSettle();
    await t.tap(find.text('Pocket TTS').last);
    await t.pumpAndSettle();
    await t.tap(find.text('Download'));
    await t.pumpAndSettle();
    expect(c.modelEvents, ['download pocket', 'load pocket', 'model pocket']);
    expect(find.text('Pocket TTS'), findsOneWidget, reason: 'the picker shows the new model');
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

  testWidgets('mood buttons sit by the model picker, only for recorded moods', (t) async {
    final c = await pump(t);
    expect(find.widgetWithText(ChoiceChip, 'Conversational'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'Excited'), findsOneWidget);
    for (final m in [Mood.annoyed, Mood.worried, Mood.storytelling]) {
      expect(find.widgetWithText(ChoiceChip, m.label), findsNothing, reason: '${m.label} is not recorded');
    }
    expect(t.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Conversational')).selected, isTrue);
    final chipY = t.getCenter(find.widgetWithText(ChoiceChip, 'Excited')).dy;
    expect((chipY - t.getCenter(find.text('Model')).dy).abs(), lessThan(24), reason: 'same row as the picker');
    expect(chipY, greaterThan(t.getCenter(find.byType(TextField)).dy - 80), reason: 'just above the text box');
    await t.tap(find.text('Excited'));
    await t.pump();
    expect(c.mood, Mood.excited);
    expect(find.textContaining('not recorded'), findsNothing);
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
