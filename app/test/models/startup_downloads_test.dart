import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/engine/tts_models.dart';
import 'package:fauxnetic/models/model_store.dart';
import 'package:fauxnetic/models/startup_downloads.dart';

void main() {
  late Directory dir;
  late List<String> queued;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('startup');
    queued = [];
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<void> enqueue(String id, String label, List<PinnedModel> files) async => queued.add('$id $label');

  /// A file of [m]'s pinned size without writing gigabytes (sparse).
  void present(PinnedModel m) {
    final f = File('${dir.path}/${m.name}').openSync(mode: FileMode.write);
    f.truncateSync(m.size);
    f.closeSync();
  }

  test('startup with only the recording set queues the voice set', () async {
    kRecordingModels.forEach(present);
    await queueMissingDownloads(dir, enqueue);
    expect(queued, ['qwen Voice model']);
  });

  test('an extra with a partial download is queued again', () async {
    [...kRecordingModels, ...kVoiceModels].forEach(present);
    final pocket = ttsModel('pocket');
    File('${dir.path}/${pocket.files.single.name}.part').writeAsBytesSync([1, 2, 3]);
    await queueMissingDownloads(dir, enqueue);
    expect(queued, ['pocket Pocket TTS']);
  });

  test('nothing missing queues nothing', () async {
    [...kRecordingModels, ...kVoiceModels].forEach(present);
    await queueMissingDownloads(dir, enqueue);
    expect(queued, isEmpty);
  });
}
