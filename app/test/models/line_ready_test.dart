import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/models/download_center.dart';
import 'package:fauxnetic/models/line_ready.dart';

void main() {
  DownloadJob job(String id, JobState s) => DownloadJob(id, id, const [], 100)..state = s;

  Future<bool> can(String want, {String fallback = 'qwen', Set<String> here = const {}, DownloadJob? j}) =>
      lineCanRun(want: want, fallback: fallback, ready: (id) async => here.contains(id), job: (_) => j);

  test('a model on the phone runs', () async {
    expect(await can('pocket', here: {'pocket'}), isTrue);
  });

  test('a Qwen line waits while Qwen is missing, even when another model is the default', () async {
    // Review I2: it fell back, then the engine failed it with "still downloading".
    expect(await can('qwen', fallback: 'pocket', here: {'pocket'}), isFalse);
    expect(await can('qwen', fallback: 'pocket', here: {'pocket'}, j: job('qwen', JobState.failed)), isFalse);
  });

  test('a line waits for its model while it downloads, or after its download failed', () async {
    expect(await can('pocket', here: {'qwen'}, j: job('pocket', JobState.downloading)), isFalse);
    expect(await can('pocket', here: {'qwen'}, j: job('pocket', JobState.failed)), isFalse);
  });

  test('a line for a deleted model (no download) uses the default', () async {
    expect(await can('pocket', here: {'qwen'}), isTrue);
    expect(await can('pocket'), isFalse, reason: 'unless the default is missing too');
  });
}
