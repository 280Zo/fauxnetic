import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fauxnetic/engine/tts_models.dart';
import 'package:fauxnetic/models/model_store.dart';
import 'package:fauxnetic/settings/settings_store.dart';
import 'package:fauxnetic/ui/models_section.dart';
import 'package:fauxnetic/storage/storage_report.dart';
import 'package:fauxnetic/theme.dart';
import 'package:fauxnetic/ui/settings_screen.dart';

void main() {
  late List<String> events;

  Future<void> pump(WidgetTester t, {int older = 0, Set<String> downloaded = const {'qwen', 'voxcpm'}}) async {
    events = [];
    final have = {...downloaded};
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: SettingsScreen(
          models: () async => [
            for (final m in kTtsModels)
              ModelInfo(model: m, downloaded: have.contains(m.id), bytes: have.contains(m.id) ? m.downloadBytes : 0),
          ],
          onDefaultModel: (id) async => events.add('default $id'),
          onDeleteModel: (id) async {
            events.add('delete $id');
            have.remove(id);
          },
          downloadModel: (id) {
            events.add('download $id');
            have.add(id);
            return Stream.fromIterable([DownloadProgress('$id.gguf', 5, 10)]);
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
            download: (_) => const Stream.empty(),
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
    await t.tap(find.text('VoxCPM 2'));
    await t.pumpAndSettle();
    expect(events, ['default voxcpm']);
  });

  testWidgets('picking a not-downloaded model as default downloads it first', (t) async {
    await pump(t);
    await scrollTo(t, 'Pocket TTS');
    await t.tap(find.text('Pocket TTS'));
    await t.pumpAndSettle();
    expect(find.textContaining('CC-BY-4.0'), findsOneWidget);
    await t.tap(find.text('Download'));
    await t.pumpAndSettle();
    expect(events, ['download pocket', 'default pocket']);
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
