import 'dart:io';

import '../engine/tts_models.dart';
import 'model_store.dart';

/// At launch, once the recording set is here: queues the voice set if it isn't complete, and any
/// extra model whose download was started (it has a partial file) but didn't finish.
Future<void> queueMissingDownloads(
  Directory dir,
  Future<void> Function(String id, String label, List<PinnedModel> files) enqueue,
) async {
  if (!await ModelStore(dir, models: kVoiceModels).allPresent()) {
    await enqueue('qwen', 'Voice model', kVoiceModels);
  }
  for (final m in kTtsModels.where((m) => m.files.isNotEmpty)) {
    final store = ModelStore(dir, models: m.files);
    if (await store.allPresent()) continue;
    for (final f in m.files) {
      if (await File('${store.path(f).path}.part').exists()) {
        await enqueue(m.id, m.label, m.files);
        break;
      }
    }
  }
}
