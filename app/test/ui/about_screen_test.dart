import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fauxnetic/theme.dart';
import 'package:fauxnetic/ui/about_screen.dart';

void main() {
  testWidgets('about shows the copy', (t) async {
    await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.dark), home: const AboutScreen()));
    expect(find.text('About Fauxnetic'), findsOneWidget);
    expect(
      find.text(
        'Fauxnetic shows how little it takes to copy a voice. A minute of reading aloud, or a short clip from a video, '
        'is enough for a convincing clone. Voice-cloning scams work less well when more people know that.',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        'Everything happens on this phone. Your recordings, voices and lines never leave it. Fauxnetic has no account, '
        'no ads and no tracking, and its only download is the voice models, each checked against a fixed fingerprint.',
      ),
      findsOneWidget,
    );
    final bold = find.text('Voices and lines delete themselves after 24 hours (or 1 hour, in Settings).');
    expect(bold, findsOneWidget);
    expect(t.widget<Text>(bold).style?.fontWeight, FontWeight.w700);
    expect(
      find.text(
        'Every line Fauxnetic makes carries an inaudible watermark that detection tools can find. It isn\'t '
        'tamper-proof, and a shared file doesn\'t announce that it\'s AI. If you share a line, tell people it\'s '
        'synthetic.',
      ),
      findsOneWidget,
    );
    expect(find.text('Only clone voices with permission.'), findsOneWidget);
    expect(find.text('View licences'), findsOneWidget);
  });

  testWidgets('licences are registered', (t) async {
    await t.runAsync(registerLicences);
    final packages = <String>{};
    await t.runAsync(() async {
      await for (final l in LicenseRegistry.licenses) {
        packages.addAll(l.packages);
      }
    });
    expect(
      packages,
      containsAll([
        'CrispASR',
        'Qwen3-TTS',
        'Whisper',
        'Silero VAD',
        'WeSpeaker ResNet34-LM',
        'Atkinson Hyperlegible Next',
        'Sonic',
      ]),
    );
  });
}
