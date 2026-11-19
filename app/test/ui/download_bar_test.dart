import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/models/download_center.dart';
import 'package:fauxnetic/models/model_store.dart';
import 'package:fauxnetic/platform/network.dart';
import 'package:fauxnetic/theme.dart';
import 'package:fauxnetic/ui/download_bar.dart';

import '../models/download_center_test.dart' show CountingKeeper, FakeStore, file;

void main() {
  late Map<String, FakeStore> stores;
  late NetKind net;
  late DownloadCenter center;
  final voice = [file('talker', 1000000000), file('codec', 400000000)];

  setUp(() {
    stores = {};
    net = NetKind.unmetered;
    center = DownloadCenter(
      store: (files) => stores.putIfAbsent(files.first.name, () => FakeStore(files)),
      network: () async => net,
      keeper: CountingKeeper(),
      poll: const Duration(milliseconds: 10),
    );
  });

  Future<void> pump(WidgetTester t) async {
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: Scaffold(body: DownloadBar(center: center)),
      ),
    );
  }

  Future<void> settle(WidgetTester t) async {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await t.pump();
  }

  testWidgets('shows the voice model downloading', (t) async {
    await pump(t);
    await t.runAsync(() => center.enqueue('qwen', 'Voice model', voice));
    await settle(t);
    stores['talker']!.emit(588000000);
    await settle(t);
    expect(find.text('Voice model 42% · 812 MB left'), findsOneWidget);
    center.dispose();
  });

  testWidgets('waiting for Wi-Fi offers mobile data', (t) async {
    net = NetKind.metered;
    await pump(t);
    await t.runAsync(() => center.enqueue('qwen', 'Voice model', voice));
    await settle(t);
    expect(find.text('Waiting for Wi-Fi · 1.4 GB left'), findsOneWidget);
    await t.tap(find.text('Use mobile data'));
    await settle(t);
    expect(center.job('qwen')!.allowMetered, isTrue);
    center.dispose();
  });

  testWidgets('no connection says so', (t) async {
    net = NetKind.none;
    await pump(t);
    await t.runAsync(() => center.enqueue('qwen', 'Voice model', voice));
    await settle(t);
    expect(find.text('Waiting for a connection · 1.4 GB left'), findsOneWidget);
    center.dispose();
  });

  testWidgets('a failure offers Retry', (t) async {
    await pump(t);
    await t.runAsync(() => center.enqueue('qwen', 'Voice model', voice));
    await settle(t);
    stores['talker']!.fail(const ModelStoreError('talker did not match its checksum.'));
    await settle(t);
    expect(find.text('Voice model: download failed'), findsOneWidget);
    await t.tap(find.text('Retry'));
    await settle(t);
    expect(center.job('qwen')!.state, JobState.downloading);
    center.dispose();
  });

  testWidgets('hidden when nothing is downloading', (t) async {
    await pump(t);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.textContaining('left'), findsNothing);
    center.dispose();
  });
}
