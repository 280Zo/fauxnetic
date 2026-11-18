// On-device: real libcrispasr through the app's engine. Before running, push the two models into
// <files>/models/ and the reference WAV to <files>/device_test/owner_ref.wav with adb. The reference transcript is passed with
// --dart-define=REF_TEXT=... Always pass --no-uninstall: `flutter test` otherwise uninstalls the app afterwards,
// wiping its data.
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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('engine clones the owner voice on the phone', (tester) async {
    expect(refText, isNotEmpty, reason: 'pass --dart-define=REF_TEXT=...');
    final support = await getApplicationSupportDirectory();
    final cache = await getTemporaryDirectory();
    final temp = TempSweeper(cache);
    final dir = Directory('${support.path}/device_test_people');
    final vault = Vault(SecureKeyStore());
    final people = PeopleRepo(dir, vault, temp, TakeStore(dir, vault));
    final models = ModelStore(Directory('${support.path}/models'));
    final worker = await IsolateWorker.spawn(ffiApiFactory);
    final engine = CrispasrEngine(() async => worker, models, people, temp);

    await engine.load();
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
    await engine.prepare(p, Mood.conversational);

    final sw = Stopwatch()..start();
    final audio = await engine.speak(line, seed: 1);
    sw.stop();
    final seconds = audio.length / engine.sampleRate;
    final rtf = sw.elapsedMilliseconds / 1000 / seconds;
    // ignore: avoid_print
    print(
      'DEVICE_RESULT audio_s=${seconds.toStringAsFixed(2)} rtf=${rtf.toStringAsFixed(2)} '
      'rate=${engine.sampleRate} temp_left=${temp.dir.existsSync() ? temp.dir.listSync().length : 0}',
    );
    expect(seconds, greaterThanOrEqualTo(3.0));
    expect(rtf, lessThanOrEqualTo(40.0));
    expect(temp.dir.existsSync() ? temp.dir.listSync() : [], isEmpty);

    await engine.dispose();
    await people.delete(p.id);
  }, timeout: const Timeout(Duration(minutes: 15)));
}
