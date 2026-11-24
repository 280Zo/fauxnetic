import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fauxnetic/engine/tts_models.dart';
import 'package:fauxnetic/settings/settings_store.dart';
import 'package:fauxnetic/ui/models_section.dart';
import 'package:fauxnetic/storage/storage_report.dart';
import 'package:fauxnetic/theme.dart';
import 'package:fauxnetic/ui/settings_screen.dart';
import 'package:fauxnetic/models/download_center.dart';
import 'package:fauxnetic/platform/network.dart';

import '../models/download_center_test.dart' show CountingKeeper, FakeStore;

void main() {
  late List<String> events;
  late Map<String, FakeStore> stores;
  late DownloadCenter center;
  late NetKind net;
  setUp(() => net = NetKind.unmetered);

  Future<void> pump(WidgetTester t, {int older = 0, Set<String> downloaded = const {'qwen', 'voxcpm'}}) async {
    events = [];
    stores = {};
    final have = {...downloaded};
    center = DownloadCenter(
      store: (files) => stores.putIfAbsent(files.first.name, () => FakeStore(files)),
      network: () async => net,
      keeper: CountingKeeper(),
      poll: const Duration(milliseconds: 10),
      onDone: have.add,
    );
    addTearDown(center.dispose);
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: SettingsScreen(
          models: () async => [
            for (final m in kTtsModels)
              ModelInfo(model: m, downloaded: have.contains(m.id), bytes: have.contains(m.id) ? m.downloadBytes : 0),
          ],
          onDefaultModel: (id) async => events.add('default $id'),
          onWantDefault: (id) async => events.add('want $id'),
          onDeleteModel: (id) async {
            events.add('delete $id');
            have.remove(id);
          },
          downloads: center,
          startDownload: (id) async {
            events.add('download $id');
            final m = ttsModel(id);
            await center.enqueue(m.id, m.label, m.files);
          },
          settings: AppSettings.defaults,
          onTheme: (c) async => events.add('theme ${c.name}'),
          onKeepFor: (d) async => events.add('keep ${d.inHours}h'),
          voicesOlderThan: (d) async => older,
          onClearLines: () async => events.add('clear'),
          onDeleteEverything: () async => events.add('delete all'),
          storage: () async => const StorageReport(models: 1400000000, voices: 2300000, lines: 120000),
          onRemoveModels: () async => events.add('remove models'),
          onAbout: () => events.add('about'),
          onReport: () async {
            events.add('report');
            return true;
          },
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  Future<void> scrollTo(WidgetTester t, String text) async {
    await t.scrollUntilVisible(find.text(text), 200, scrollable: find.byType(Scrollable).first);
    await t.pumpAndSettle();
  }

  testWidgets('sections and storage', (t) async {
    await pump(t);
    expect(find.text('Settings'), findsOneWidget);
    for (final s in ['Theme', 'Dark', 'Light', 'System', 'Delete voices and lines after', '1 hour', '24 hours']) {
      expect(find.text(s), findsOneWidget, reason: s);
    }
    await scrollTo(t, 'About and privacy');
    expect(find.text('1.4 GB'), findsOneWidget);
    expect(find.text('2 MB'), findsOneWidget);
    expect(find.text('120 KB'), findsOneWidget);
  });

  testWidgets('reporting a generated line lives in Settings, under About', (t) async {
    // Google Play's AI-generated content policy needs an in-app way to report offensive content.
    await pump(t);
    await scrollTo(t, 'Report a generated line');
    await t.tap(find.text('Report a generated line'));
    await t.pump();
    expect(events, ['report']);
  });

  testWidgets('models list size, state and default', (t) async {
    await pump(t);
    await scrollTo(t, 'Models');
    await scrollTo(t, 'Pocket TTS');
    for (final s in ['Qwen3-TTS', 'VoxCPM 2', 'Pocket TTS']) {
      expect(find.text(s), findsOneWidget, reason: s);
    }
    expect(find.text('Default · Comes with the voice models'), findsOneWidget, reason: 'Qwen is the default');
    expect(find.text('2.8 GB on this phone'), findsOneWidget);
    expect(find.textContaining('Not downloaded'), findsNWidgets(2), reason: 'VoxCPM 2 (small) and Pocket');
  });

  testWidgets('deleting a model asks first', (t) async {
    await pump(t);
    await scrollTo(t, 'Pocket TTS');
    await t.ensureVisible(find.widgetWithText(TextButton, 'Delete'));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(TextButton, 'Delete'));
    await t.pumpAndSettle();
    expect(find.text('Delete VoxCPM 2?'), findsOneWidget);
    await t.tap(find.text('Keep'));
    await t.pumpAndSettle();
    expect(events, isEmpty);
    await t.tap(find.widgetWithText(TextButton, 'Delete'));
    await t.pumpAndSettle();
    await t.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Delete')));
    await t.pumpAndSettle();
    expect(events, ['delete voxcpm']);
    expect(find.textContaining('Not downloaded'), findsNWidgets(3));
  });

  testWidgets('a delete waiting for the line being made says so and locks the row', (t) async {
    final gate = Completer<void>();
    final calls = <String>[];
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: Scaffold(
          body: ModelsSection(
            initialDefault: 'qwen',
            models: () async => [
              for (final m in kTtsModels) ModelInfo(model: m, downloaded: m.id != 'pocket', bytes: m.downloadBytes),
            ],
            onDefault: (id) async => calls.add('default $id'),
            onDelete: (id) async {
              calls.add('delete $id');
              await gate.future;
            },
            startDownload: (_) async {},
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(TextButton, 'Delete').first); // VoxCPM 2
    await t.pumpAndSettle();
    await t.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Delete')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400)); // the confirm dialog finishes closing
    expect(find.text('Deleting…'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Delete'), findsNothing, reason: "can't be tapped twice");
    await t.tap(find.text('VoxCPM 2'));
    await t.pump();
    expect(calls, ['delete voxcpm'], reason: "can't become the default while it's being deleted");
    gate.complete();
    await t.pumpAndSettle();
    expect(find.text('Deleting…'), findsNothing);
  });

  testWidgets('Qwen has no delete', (t) async {
    await pump(t, downloaded: {'qwen'});
    await scrollTo(t, 'Pocket TTS');
    expect(find.widgetWithText(TextButton, 'Delete'), findsNothing);
  });

  testWidgets('picking a downloaded model as default sets it', (t) async {
    await pump(t);
    await scrollTo(t, 'Pocket TTS');
    await t.ensureVisible(find.text('VoxCPM 2'));
    await t.pumpAndSettle();
    await t.tap(find.text('VoxCPM 2'));
    await t.pumpAndSettle();
    expect(events, ['default voxcpm']);
  });

  Future<void> settle(WidgetTester t) async {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await t.pump();
  }

  testWidgets('a not-downloaded model downloads in the background, then becomes the default', (t) async {
    await pump(t);
    await scrollTo(t, 'Pocket TTS');
    await t.tap(find.text('Pocket TTS'));
    await t.pumpAndSettle();
    expect(find.textContaining('CC-BY-4.0'), findsOneWidget);
    await t.tap(find.text('Download'));
    await t.pump();
    await settle(t);
    // Review minor (2026-11-19): the wish lived only in this screen and was lost when it closed;
    // it's handed on, so the app makes it the default whenever the download finishes.
    expect(events, ['want pocket', 'download pocket'], reason: 'not the default until it is here');
    stores['pocket-tts-english-q8_0.gguf']!.emit(41000000);
    await settle(t);
    expect(find.textContaining('33%'), findsOneWidget);
    await t.runAsync(() => stores['pocket-tts-english-q8_0.gguf']!.finish());
    await settle(t);
    await settle(t);
    expect(events, ['want pocket', 'download pocket', 'default pocket']);
  });

  testWidgets('picking another default drops the wish for the one still downloading', (t) async {
    // Review minor (2026-11-19): the downloading one still took over when it finished.
    await pump(t);
    await scrollTo(t, 'Pocket TTS');
    await t.tap(find.text('Pocket TTS'));
    await t.pumpAndSettle();
    await t.tap(find.text('Download'));
    await t.pump();
    await settle(t);
    await t.ensureVisible(find.text('VoxCPM 2'));
    await t.pumpAndSettle();
    await t.tap(find.text('VoxCPM 2'));
    await t.pumpAndSettle();
    await t.runAsync(() => stores['pocket-tts-english-q8_0.gguf']!.finish());
    await settle(t);
    await settle(t);
    expect(events, ['want pocket', 'download pocket', 'default voxcpm']);
  });

  testWidgets('a download started elsewhere updates its row when it finishes', (t) async {
    // Review I4: the row went back to "Not downloaded" and tapping it did nothing.
    await pump(t);
    await scrollTo(t, 'Pocket TTS');
    final pocket = ttsModel('pocket');
    await t.runAsync(() => center.enqueue(pocket.id, pocket.label, pocket.files)); // from the Speak picker
    await settle(t);
    await t.runAsync(() => stores[pocket.files.single.name]!.finish());
    await settle(t);
    await settle(t);
    expect(find.textContaining('Not downloaded (124 MB)'), findsNothing);
    expect(find.textContaining('on this phone'), findsNWidgets(2), reason: 'VoxCPM 2 and now Pocket');
    await t.tap(find.text('Pocket TTS'));
    await t.pumpAndSettle();
    expect(events, ['default pocket']);
  });

  testWidgets('a row waiting for Wi-Fi says so and offers mobile data', (t) async {
    net = NetKind.metered;
    await pump(t);
    await scrollTo(t, 'Pocket TTS');
    await t.tap(find.text('Pocket TTS'));
    await t.pumpAndSettle();
    await t.tap(find.text('Download'));
    await t.pump();
    await settle(t);
    expect(find.textContaining('Waiting for Wi-Fi'), findsOneWidget);
    await t.tap(find.text('Use mobile data'));
    await settle(t);
    expect(center.job('pocket')!.allowMetered, isTrue);
  });

  testWidgets('theme choice applies and is saved', (t) async {
    await pump(t);
    await t.tap(find.text('Light'));
    await t.pumpAndSettle();
    expect(events, ['theme light']);
  });

  testWidgets('clearing lines asks first', (t) async {
    await pump(t);
    await scrollTo(t, 'Clear all generated lines');
    await t.tap(find.text('Clear all generated lines'));
    await t.pumpAndSettle();
    expect(find.text('Every line and take for everyone is deleted now.'), findsOneWidget);
    await t.tap(find.text('Keep'));
    await t.pumpAndSettle();
    expect(events, isEmpty);
    await t.tap(find.text('Clear all generated lines'));
    await t.pumpAndSettle();
    await t.tap(find.text('Clear'));
    await t.pumpAndSettle();
    expect(events, ['clear']);
  });

  testWidgets('switching to 1 hour warns when voices will go', (t) async {
    await pump(t, older: 2);
    await t.tap(find.text('1 hour'));
    await t.pumpAndSettle();
    expect(find.text('Switch to 1 hour?'), findsOneWidget);
    expect(find.text('2 voices are already older than 1 hour and will be deleted now.'), findsOneWidget);
    await t.tap(find.text('Keep 24 hours'));
    await t.pumpAndSettle();
    expect(events, isEmpty);
    await t.tap(find.text('1 hour'));
    await t.pumpAndSettle();
    await t.tap(find.text('Switch'));
    await t.pumpAndSettle();
    expect(events, ['keep 1h']);
  });

  testWidgets('switching to 1 hour with no old voices needs no warning', (t) async {
    await pump(t);
    await t.tap(find.text('1 hour'));
    await t.pumpAndSettle();
    expect(find.text('Switch to 1 hour?'), findsNothing);
    expect(events, ['keep 1h']);
  });

  testWidgets('delete everything asks first', (t) async {
    await pump(t);
    await scrollTo(t, 'Delete everything');
    await t.tap(find.text('Delete everything'));
    await t.pumpAndSettle();
    expect(
      find.text('All people, voices, recordings and lines are erased from this phone. The voice models stay.'),
      findsOneWidget,
    );
    await t.tap(find.text('Keep'));
    await t.pumpAndSettle();
    expect(events, isEmpty);
    await t.tap(find.text('Delete everything'));
    await t.pumpAndSettle();
    await t.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Delete')));
    await t.pumpAndSettle();
    expect(events, ['delete all']);
  });

  testWidgets('remove models asks first', (t) async {
    await pump(t);
    await scrollTo(t, 'Remove voice models');
    await t.tap(find.text('Remove voice models'));
    await t.pumpAndSettle();
    expect(
      find.text('Frees 1.4 GB. Fauxnetic downloads them again (1.5 GB) before you can make or use a voice.'),
      findsOneWidget,
    );
    await t.tap(find.text('Keep'));
    await t.pumpAndSettle();
    expect(events, isEmpty);
    await t.tap(find.text('Remove voice models'));
    await t.pumpAndSettle();
    await t.tap(find.text('Remove'));
    await t.pumpAndSettle();
    expect(events, ['remove models']);
  });

  testWidgets('no OmniVoice switch any more', (t) async {
    await pump(t);
    expect(find.textContaining('OmniVoice'), findsNothing);
  });

  testWidgets('about opens', (t) async {
    await pump(t);
    await scrollTo(t, 'About and privacy');
    await t.tap(find.text('About and privacy'));
    expect(events, ['about']);
  });
}
