import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/models/model_store.dart';
import 'package:fauxnetic/theme.dart';
import 'package:fauxnetic/ui/download_screen.dart';

void main() {
  testWidgets('shows progress and verified state', (t) async {
    final ctrl = StreamController<DownloadProgress>();
    var done = false;
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: DownloadScreen(start: () => ctrl.stream, onDone: () => done = true),
      ),
    );
    await t.tap(find.text('Download voice models (1.5 GB)'));
    await t.pump();
    ctrl.add(const DownloadProgress('qwen3-tts-12hz-0.6b-base-q8_0.gguf', 500, 1000));
    await t.pump();
    expect(find.text('qwen3-tts-12hz-0.6b-base-q8_0.gguf: 50%'), findsOneWidget);
    await ctrl.close();
    await t.pump();
    expect(find.text('Models verified'), findsOneWidget);
    expect(done, isTrue);
  });

  test('download button shows total size', () {
    expect(downloadLabel(kModels), 'Download voice models (1.5 GB)');
    expect(
      downloadLabel([
        PinnedModel(name: 'a', url: Uri.parse('https://x/a'), size: 1250000000, sha256: ''),
        PinnedModel(name: 'b', url: Uri.parse('https://x/b'), size: 100000000, sha256: ''),
      ]),
      'Download voice models (1.4 GB)',
    );
  });

  testWidgets('an update names only the missing model and keeps voices', (t) async {
    // Review 2026-11-17: upgrading to the F16 codec showed the full first-run download screen.
    final codec = kModels.firstWhere((m) => m.role == ModelRole.codec);
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: DownloadScreen(start: () => const Stream.empty(), onDone: () {}, missing: [codec]),
      ),
    );
    expect(find.text('Voice model update'), findsOneWidget);
    expect(find.textContaining('Your voices and lines are kept'), findsOneWidget);
    expect(find.text('Download update (358 MB)'), findsOneWidget);
  });

  testWidgets('shows storage error message', (t) async {
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: DownloadScreen(
          start: () => Stream.error(const ModelStoreError('Not enough free storage: need 1.6 GB, have 1.1 GB.')),
          onDone: () {},
        ),
      ),
    );
    await t.tap(find.text('Download voice models (1.5 GB)'));
    await t.pump();
    await t.pump();
    expect(find.text('Not enough free storage: need 1.6 GB, have 1.1 GB.'), findsOneWidget);
    expect(find.text('Download voice models (1.5 GB)'), findsOneWidget);
  });
}
