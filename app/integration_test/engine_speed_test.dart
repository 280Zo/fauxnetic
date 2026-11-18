// On-device speed check (2026-11-16): the same line at several engine thread counts. Uses the models the
// installed app already downloaded and the owner's reference at <files>/device_test/owner_ref.wav.
// Run: tool/flutter.sh test integration_test/engine_speed_test.dart -d <serial> --no-uninstall --dart-define=REF_TEXT=...
// --no-uninstall is required: by default `flutter test` uninstalls the app afterwards, wiping its data (it wiped
// the A54's people and models on 2026-11-16). Keep the screen on (adb shell svc power stayon usb), or Android
// throttles the test app and a line takes minutes instead of seconds.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:fauxnetic/audio/wav.dart';
import 'package:fauxnetic/engine/crispasr_engine.dart';
import 'package:fauxnetic/models/model_store.dart';
import 'package:fauxnetic/people/people_repo.dart';
import 'package:fauxnetic/people/person.dart';
import 'package:fauxnetic/recording/reference_builder.dart';
import 'package:fauxnetic/recording/scripts.dart';
import 'package:fauxnetic/recording/takes.dart';
import 'package:fauxnetic/storage/temp_sweeper.dart';
import 'package:fauxnetic/storage/vault.dart';

const refText = String.fromEnvironment('REF_TEXT');
const line = 'The package should arrive on Thursday, so we can set everything up over the weekend.';

/// A warm-up first (page the model into memory), then each count twice in a mirrored order so
/// the phone warming up doesn't favor one count.
const order = [4, 4, 6, 8, 8, 6, 4];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('engine speed by thread count', (tester) async {
    expect(refText, isNotEmpty, reason: 'pass --dart-define=REF_TEXT=...');
    final support = await getApplicationSupportDirectory();
    final temp = TempSweeper(await getTemporaryDirectory());
    final dir = Directory('${support.path}/device_test_people');
    final vault = Vault(SecureKeyStore());
    final people = PeopleRepo(dir, vault, temp, TakeStore(dir, vault));
    final models = ModelStore(Directory('${support.path}/models'));
    expect(await models.allPresent(), isTrue, reason: 'open the app once so it downloads its models');

    var p = await people.create('Owner', PersonSource.upload);
    final wav = await File('${support.path}/device_test/owner_ref.wav').readAsBytes();
    const rel = 'refs/owner.bin';
    await vault.encryptBytes(wav, File('${dir.path}/$rel'));
    await people.setVoice(
      p.id,
      Mood.conversational,
      VoiceRef(clipFile: rel, refText: refText, seconds: wavSeconds(wav)),
    );
    p = await people.confirmConsent(p.id, ownVoice: true, spokenConsent: false);

    for (final (i, threads) in order.indexed) {
      final worker = await IsolateWorker.spawn(() => FfiCrispasrApi(threads: threads));
      final engine = CrispasrEngine(() async => worker, models, people, temp);
      await engine.prepare(p, Mood.conversational);
      final sw = Stopwatch()..start();
      final audio = await engine.speak(line, seed: 1);
      sw.stop();
      final seconds = audio.length / engine.sampleRate;
      // ignore: avoid_print
      print(
        'DEVICE_SPEED run=$i threads=$threads${i == 0 ? ' warmup' : ''} '
        'gen_s=${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} audio_s=${seconds.toStringAsFixed(2)} '
        'rtf=${(sw.elapsedMilliseconds / 1000 / seconds).toStringAsFixed(2)}',
      );
      await engine.dispose();
    }
    await people.delete(p.id);
    await dir.delete(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 40)));
}
