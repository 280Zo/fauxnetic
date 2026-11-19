import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/models/model_store.dart';
import 'package:fauxnetic/theme.dart';
import 'package:fauxnetic/ui/download_screen.dart';

void main() {
  Future<void> pump(WidgetTester t, Stream<DownloadProgress> Function() start, {List<PinnedModel>? missing}) =>
      t.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: DownloadScreen(start: start, onDone: () {}, missing: missing),
        ),
      );

  testWidgets('shows progress and verified state', (t) async {
    final ctrl = StreamController<DownloadProgress>();
    var done = false;
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: DownloadScreen(start: () => ctrl.stream, onDone: () => done = true),
      ),
    );
    await t.tap(find.text('Download (1.5 GB)'));
    await t.pump();
    ctrl.add(const DownloadProgress('ggml-base.en-q5_1.bin', 500, 1000));
    await t.pump();
    expect(find.text('ggml-base.en-q5_1.bin: 50%'), findsOneWidget);
    await ctrl.close();
    await t.pump();
    expect(find.text('Models verified'), findsOneWidget);
    expect(done, isTrue);
  });

  testWidgets('first launch says recording comes first', (t) async {
    // Owner, 2026-11-18: start recording within a minute while the voice model downloads.
    await pump(t, () => const Stream.empty());
    expect(
      find.text(
        'Fauxnetic needs about 1.5 GB of model files from Hugging Face, each checked against a fixed '
        'fingerprint. Recording needs only 120 MB, so you can start in about a minute while the rest '
        'downloads.',
      ),
      findsOneWidget,
    );
    expect(find.text('Download (1.5 GB)'), findsOneWidget);
  });

  testWidgets('no connection says so and offers Retry', (t) async {
    await pump(t, () => Stream.error(const ModelStoreError('interrupted', kind: ModelErrorKind.network)));
    await t.tap(find.text('Download (1.5 GB)'));
    await t.pump();
    await t.pump();
    expect(find.text('No connection. Connect to the internet to download.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  test('download button shows total size', () {
    expect(downloadLabel(kModels), 'Download (1.5 GB)');
    expect(
      downloadLabel([
        PinnedModel(name: 'a', url: Uri.parse('https://x/a'), size: 1250000000, sha256: ''),
        PinnedModel(name: 'b', url: Uri.parse('https://x/b'), size: 100000000, sha256: ''),
      ]),
      'Download (1.4 GB)',
    );
  });

  testWidgets('an update names only the missing model and keeps voices', (t) async {
    // Review 2026-11-17: an updated model showed the full first-run download screen.
    final whisper = kModels.firstWhere((m) => m.role == ModelRole.asrBase);
    await pump(t, () => const Stream.empty(), missing: [whisper]);
    expect(find.text('Voice model update'), findsOneWidget);
    expect(find.textContaining('Your voices and lines are kept'), findsOneWidget);
    expect(find.text('Download update (60 MB)'), findsOneWidget);
  });

  testWidgets('shows storage error message', (t) async {
    await pump(t, () => Stream.error(const ModelStoreError('Not enough free storage: need 1.6 GB, have 1.1 GB.')));
    await t.tap(find.text('Download (1.5 GB)'));
    await t.pump();
    await t.pump();
    expect(find.text('Not enough free storage: need 1.6 GB, have 1.1 GB.'), findsOneWidget);
    expect(find.text('Download (1.5 GB)'), findsOneWidget);
  });
}
