import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fauxnetic/settings/settings_store.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('settings');
    file = File('${dir.path}/settings.json');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('defaults when there is no file', () async {
    final s = await SettingsStore(file).load();
    expect(s.theme, ThemeChoice.dark);
    expect(s.keepFor, const Duration(hours: 24));
  });

  test('round trip', () async {
    await SettingsStore(file).save(const AppSettings(theme: ThemeChoice.light, keepFor: Duration(hours: 1)));
    final s = await SettingsStore(file).load();
    expect(s.theme, ThemeChoice.light);
    expect(s.keepFor, const Duration(hours: 1));
    expect(dir.listSync().map((e) => e.path.split('/').last), ['settings.json'], reason: 'no temp file left');
  });

  test('an unreadable file means the defaults', () async {
    file.writeAsStringSync('not json');
    expect((await SettingsStore(file).load()).theme, ThemeChoice.dark);
    file.writeAsStringSync('{"theme":"purple","keepForMinutes":5}');
    final s = await SettingsStore(file).load();
    expect(s.theme, ThemeChoice.dark);
    expect(s.keepFor, const Duration(hours: 24), reason: 'keep-for must be one of the choices');
    file.writeAsStringSync('{"theme":"system","keepForMinutes":60}');
    final ok = await SettingsStore(file).load();
    expect([ok.theme, ok.keepFor], [ThemeChoice.system, const Duration(hours: 1)]);
  });

  test('the voice model is saved and defaults to Qwen', () async {
    expect((await SettingsStore(file).load()).model, 'qwen');
    await SettingsStore(file).save(AppSettings.defaults.copyWith(model: 'pocket'));
    expect((await SettingsStore(file).load()).model, 'pocket');
    file.writeAsStringSync('{"theme":"dark","keepForMinutes":1440,"engine":"omnivoice"}');
    expect((await SettingsStore(file).load()).model, 'qwen', reason: 'the dropped OmniVoice switch reads as Qwen');
    file.writeAsStringSync('{"theme":"dark","keepForMinutes":1440,"model":"nope"}');
    expect((await SettingsStore(file).load()).model, 'qwen');
  });

  test('theme modes', () {
    expect(themeModeOf(ThemeChoice.dark), ThemeMode.dark);
    expect(themeModeOf(ThemeChoice.light), ThemeMode.light);
    expect(themeModeOf(ThemeChoice.system), ThemeMode.system);
    expect(kKeepForChoices, [const Duration(hours: 1), const Duration(hours: 24)]);
  });
}
