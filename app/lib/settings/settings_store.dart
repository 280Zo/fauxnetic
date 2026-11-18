import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../engine/tts_models.dart';

enum ThemeChoice { dark, light, system }

ThemeMode themeModeOf(ThemeChoice c) => switch (c) {
  ThemeChoice.dark => ThemeMode.dark,
  ThemeChoice.light => ThemeMode.light,
  ThemeChoice.system => ThemeMode.system,
};

/// How long voices and lines are kept. 24 hours is the default and the maximum.
const kKeepForChoices = [Duration(hours: 1), Duration(hours: 24)];

class AppSettings {
  const AppSettings({required this.theme, required this.keepFor, this.model = 'qwen'});

  final ThemeChoice theme;
  final Duration keepFor;

  /// The voice model that makes lines (an id from kTtsModels; Qwen3-TTS by default).
  final String model;

  static const defaults = AppSettings(theme: ThemeChoice.dark, keepFor: Duration(hours: 24));

  AppSettings copyWith({ThemeChoice? theme, Duration? keepFor, String? model}) =>
      AppSettings(theme: theme ?? this.theme, keepFor: keepFor ?? this.keepFor, model: model ?? this.model);
}

/// The few settings, in a small plain JSON file (nothing in it is sensitive). A missing or
/// unreadable file, or a value that isn't allowed, means the default for that value.
class SettingsStore {
  SettingsStore(this.file);
  final File file;

  Future<AppSettings> load() async {
    Map<String, Object?> j;
    try {
      j = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    } catch (_) {
      return AppSettings.defaults;
    }
    final theme = ThemeChoice.values.where((t) => t.name == j['theme']).firstOrNull;
    final minutes = j['keepForMinutes'];
    final keep = kKeepForChoices.where((d) => d.inMinutes == minutes).firstOrNull;
    final model = ttsModel(j['model'] is String ? j['model']! as String : AppSettings.defaults.model).id;
    return AppSettings(
      theme: theme ?? AppSettings.defaults.theme,
      keepFor: keep ?? AppSettings.defaults.keepFor,
      model: model,
    );
  }

  Future<void> save(AppSettings s) async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      jsonEncode({'theme': s.theme.name, 'keepForMinutes': s.keepFor.inMinutes, 'model': s.model}),
      flush: true,
    );
    await tmp.rename(file.path);
  }
}
