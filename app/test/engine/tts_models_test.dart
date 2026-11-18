import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/engine/tts_models.dart';

void main() {
  test('Qwen is the default and needs no extra download', () {
    expect(kTtsModels.first.id, 'qwen');
    expect(ttsModel('qwen').label, 'Qwen3-TTS');
    expect(ttsModel('qwen').files, isEmpty, reason: 'uses the core download');
    expect(ttsModel('nope').id, 'qwen', reason: 'unknown ids fall back to the default');
  });

  test('the smaller VoxCPM is offered alongside the full one', () {
    final small = ttsModel('voxcpm-small');
    expect(small.label, 'VoxCPM 2 (small)');
    expect(small.backend, 'voxcpm2-tts');
    expect(small.openFile.name, 'voxcpm2-q4_k.gguf');
    expect(small.openFile.size, 1689498432);
    expect(small.openFile.sha256, '502efe74f6a59c370b3abf5a3fcfd7c3955ca6c167b411c8aee3977e9e46c079');
  });

  test('models with their own files say how much memory they need', () {
    expect(ttsModel('qwen').memoryBytes, isNull, reason: 'the core model runs fine here');
    expect(ttsModel('voxcpm').memoryBytes, greaterThan(ttsModel('voxcpm-small').memoryBytes!));
    expect(ttsModel('voxcpm').memoryBytes, greaterThan(2827049792));
  });

  test('the optional models are pinned', () {
    expect(kTtsModels.map((m) => m.id), ['qwen', 'voxcpm', 'voxcpm-small', 'pocket']);
    expect(ttsModel('voxcpm').codecFile, isNull, reason: 'single-file models have no codec');
    expect(ttsModel('voxcpm').openFile.sha256, '142f29c4dff1c0ad3f71d9353a03f7cbf08080bee3ab73c577c0219e4094fc4b');
    expect(ttsModel('pocket').openFile.size, 123632992);
    for (final m in kTtsModels.skip(1)) {
      expect(m.files, contains(m.openFile), reason: m.id);
      for (final f in m.files) {
        expect(f.url.scheme, 'https', reason: f.name);
        expect(f.sha256, hasLength(64), reason: f.name);
      }
    }
    expect(kOptionalModelFiles.length, 3);
    expect(ttsModel('vibevoice').id, 'qwen', reason: 'owner: very slow, unlike the voice, research-only; dropped');
    expect(kTtsModels.where((m) => m.id == 'indextts'), isEmpty, reason: 'owner: too slow, left out');
    expect(kTtsModels.where((m) => m.id == 'cosyvoice'), isEmpty, reason: 'owner: dropped');
    expect(kOptionalModelFiles.where((f) => f.name.contains('omnivoice')), isEmpty, reason: 'OmniVoice was dropped');
  });

  test('free memory is read from Android\'s meminfo', () {
    const meminfo = 'MemTotal:        5556228 kB\nMemFree:           93892 kB\nMemAvailable:    1203456 kB\n';
    expect(parseMemAvailable(meminfo), 1203456 * 1024);
    expect(parseMemAvailable('MemTotal: 1 kB\n'), isNull);
    expect(parseMemAvailable('garbage'), isNull);
  });

  test('download size adds up each model', () {
    expect(ttsModel('pocket').downloadBytes, 123632992);
    expect(ttsModel('voxcpm').downloadBytes, 2827049792);
  });
}
