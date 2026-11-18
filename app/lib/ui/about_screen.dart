import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// Why Fauxnetic exists, what stays on the phone, and the licences. Copy approved by the owner (2026-11-15).
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  static const _paragraphs = [
    'Fauxnetic shows how little it takes to copy a voice. A minute of reading aloud, or a short clip from a video, is '
        'enough for a convincing clone. Voice-cloning scams work less well when more people know that.',
    'Everything happens on this phone. Your recordings, voices and lines never leave it. Fauxnetic has no account, no ads '
        'and no tracking, and its only download is the voice models, each checked against a fixed fingerprint.',
    null, // the bold line
    'Every line Fauxnetic makes carries an inaudible watermark that detection tools can find. It isn\'t tamper-proof, and '
        'a shared file doesn\'t announce that it\'s AI. If you share a line, tell people it\'s synthetic.',
    'Only clone voices with permission.',
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          children: [
            Text(
              'About Fauxnetic',
              style: Theme.of(context).textTheme.headlineMedium!.copyWith(fontWeight: FontWeight.w700),
            ),
            for (final p in _paragraphs)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: p == null
                    ? const Text(
                        'Voices and lines delete themselves after 24 hours (or 1 hour, in Settings).',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      )
                    : Text(p),
              ),
            const SizedBox(height: 24),
            OutlinedButton(
              onPressed: () => showLicensePage(context: context, applicationName: 'Fauxnetic'),
              child: const Text('View licences'),
            ),
          ],
        ),
      ),
    );
  }
}

/// One licence-page entry per bundled or downloaded component that isn't a Dart package (those are
/// registered by Flutter). Texts come from each component's own source; see assets/licenses/.
Future<void> registerLicences() async {
  Future<String> asset(String name) => rootBundle.loadString(name);
  final apache = await asset('assets/licenses/apache-2.0.txt');
  final entries = [
    LicenseEntryWithLineBreaks(
      ['CrispASR'],
      [
        'CrispASR (github.com/CrispStrobe/CrispASR), the on-device speech engine.',
        await asset('assets/licenses/crispasr-license.txt'),
        await asset('assets/licenses/crispasr-third-party-notices.txt'),
      ].join('\n\n'),
    ),
    LicenseEntryWithLineBreaks(
      ['Qwen3-TTS'],
      [
        'Qwen3-TTS 12Hz 0.6B Base and Qwen3-TTS Tokenizer 12Hz by the Qwen team (Alibaba Cloud), '
            'Qwen/Qwen3-TTS-12Hz-0.6B-Base and Qwen/Qwen3-TTS-Tokenizer-12Hz; GGUF conversions '
            'cstr/qwen3-tts-0.6b-base-GGUF and cstr/qwen3-tts-tokenizer-12hz-GGUF. Licensed under the Apache License 2.0.',
        apache,
      ].join('\n\n'),
    ),
    LicenseEntryWithLineBreaks(
      ['Whisper'],
      [
        'Whisper base.en and tiny.en models by OpenAI, in ggml format from ggerganov/whisper.cpp.',
        await asset('assets/licenses/whisper-license.txt'),
      ].join('\n\n'),
    ),
    LicenseEntryWithLineBreaks(
      ['Silero VAD'],
      [
        'Silero VAD v6.2.0 by the Silero Team, in ggml format from ggml-org/whisper-vad.',
        await asset('assets/licenses/silero-vad-license.txt'),
      ].join('\n\n'),
    ),
    const LicenseEntryWithLineBreaks(
      ['WeSpeaker ResNet34-LM'],
      'WeSpeaker ResNet34-LM speaker-embedding model by the WeNet community (github.com/wenet-e2e/wespeaker), '
      'from Wespeaker/wespeaker-voxceleb-resnet34-LM. Converted to GGUF (cstr/wespeaker-resnet34-lm-GGUF); '
      'no other changes. Licensed under the Creative Commons Attribution 4.0 International licence: '
      'https://creativecommons.org/licenses/by/4.0/',
    ),
    LicenseEntryWithLineBreaks(['Atkinson Hyperlegible Next'], await asset('assets/fonts/OFL.txt')),
  ];
  LicenseRegistry.addLicense(() => Stream.fromIterable(entries));
}
