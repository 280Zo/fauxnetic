import 'dart:io';

import '../engine/tts_models.dart';
import 'model_store.dart';

/// The extra models asked for and not yet downloaded, one id per line, so a download that failed
/// (and lost its partial file) is tried again at the next launch.
File _wantedFile(Directory dir) => File('${dir.path}/.wanted');

Future<Set<String>> _wanted(Directory dir) async {
  final f = _wantedFile(dir);
  if (!await f.exists()) return {};
  return (await f.readAsLines()).where((l) => l.trim().isNotEmpty).toSet();
}

Future<void> _saveWanted(Directory dir, Set<String> ids) async {
  await dir.create(recursive: true);
  await _wantedFile(dir).writeAsString(ids.map((i) => '$i\n').join());
}

/// Remembers that extra model [id] was asked for (its download starts).
Future<void> markWanted(Directory dir, String id) async => _saveWanted(dir, {...await _wanted(dir), id});

/// Forgets [id] (its download finished, or the model was deleted).
Future<void> clearWanted(Directory dir, String id) async => _saveWanted(dir, (await _wanted(dir))..remove(id));

/// At launch, once the recording set is here: queues the voice set if it isn't complete, and any
/// extra model whose download was asked for or started (a partial file) but didn't finish.
Future<void> queueMissingDownloads(
  Directory dir,
  Future<void> Function(String id, String label, List<PinnedModel> files) enqueue,
) async {
  if (!await ModelStore(dir, models: kVoiceModels).allPresent()) {
    await enqueue('qwen', 'Voice model', kVoiceModels);
  }
  final wanted = await _wanted(dir);
  for (final m in kTtsModels.where((m) => m.files.isNotEmpty)) {
    final store = ModelStore(dir, models: m.files);
    if (await store.allPresent()) continue;
    if (wanted.contains(m.id)) {
      await enqueue(m.id, m.label, m.files);
      continue;
    }
    for (final f in m.files) {
      if (await File('${store.path(f).path}.part').exists()) {
        await enqueue(m.id, m.label, m.files);
        break;
      }
    }
  }
}
