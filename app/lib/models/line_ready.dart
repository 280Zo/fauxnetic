import '../engine/tts_models.dart';
import 'download_center.dart';

/// Whether a line for model [want] can be made now (2026-11-18). A model on the phone runs. Qwen
/// comes with the core download and is never deleted on its own, so a Qwen line waits for it. A
/// model with a download (in progress or failed) waits for it; a model that was deleted (no
/// download) uses [fallback], the default, as the engine does.
Future<bool> lineCanRun({
  required String want,
  required String fallback,
  required Future<bool> Function(String id) ready,
  required DownloadJob? Function(String id) job,
}) async {
  if (await ready(want)) return true;
  if (want == kTtsModels.first.id) return false;
  if (job(want) != null) return false;
  return fallback != want && await ready(fallback);
}
