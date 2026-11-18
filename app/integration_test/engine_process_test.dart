// The voice engine runs in its own Android process (":engine") behind MethodChannel fauxnetic/engine,
// so a line can be stopped by killing that process (owner request, 2026-11-16).
// Run: tool/flutter.sh test integration_test/engine_process_test.dart -d <serial> --no-uninstall --dart-define=VOICE=It's Me
// --no-uninstall is required (see engine_speed_test.dart). Keep the screen on. Changes nothing in the app's data.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:fauxnetic/engine/crispasr_engine.dart';
import 'package:fauxnetic/models/model_store.dart';
import 'package:fauxnetic/people/people_repo.dart';
import 'package:fauxnetic/recording/scripts.dart';
import 'package:fauxnetic/recording/takes.dart';
import 'package:fauxnetic/storage/temp_sweeper.dart';
import 'package:fauxnetic/storage/vault.dart';

const voice = String.fromEnvironment('VOICE');
const engine = MethodChannel('fauxnetic/engine');
const short = 'The package should arrive on Thursday, so we can set everything up over the weekend.';
final long = List.filled(6, short).join(' ');

// ignore: avoid_print
void say(String s) => print('ENGINE $s');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late File clip;
  late String refText;
  late TempSweeper temp;
  late ModelStore models;

  setUpAll(() async {
    final support = await getApplicationSupportDirectory();
    temp = TempSweeper(await getTemporaryDirectory());
    final vault = Vault(SecureKeyStore(), checkFile: File('${support.path}/vault.check'));
    final people = PeopleRepo(support, vault, temp, TakeStore(support, vault));
    models = ModelStore(Directory('${support.path}/models'));
    final p = (await people.all()).firstWhere((p) => p.name.toLowerCase() == voice.toLowerCase());
    clip = await people.decryptedRef(p, Mood.conversational);
    refText = p.refFor(Mood.conversational).refText;
  });
  tearDownAll(() => temp.release(clip));

  Future<void> openQwen() => engine.invokeMethod<void>('open', {
    'model': models.pathFor(ModelRole.talker).path,
    'codec': models.pathFor(ModelRole.codec).path,
    'backend': 'qwen3-tts',
    'threads': kThreads,
  });

  Future<Map<Object?, Object?>> make(String text) async =>
      (await engine.invokeMapMethod<Object?, Object?>('synthesize', {'text': text, 'seed': 1}))!;

  testWidgets('process engine makes a line', (t) async {
    await openQwen();
    await engine.invokeMethod<void>('setVoice', {'path': clip.path, 'refText': refText});
    final sw = Stopwatch()..start();
    final r = await make(short);
    final f = File(r['path']! as String);
    final rate = r['rate']! as int;
    final n = await f.length() ~/ 4;
    say(
      'made ${(n / rate).toStringAsFixed(1)} s of audio in ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s, pid ${await engine.invokeMethod<int>('pid')}',
    );
    expect(rate, 24000);
    expect(n, greaterThan(rate), reason: 'more than a second of speech');
    await f.delete();
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('kill stops a line and the next one works', (t) async {
    await openQwen();
    await engine.invokeMethod<void>('setVoice', {'path': clip.path, 'refText': refText});
    final before = await engine.invokeMethod<int>('pid');
    final running = make(long);
    await Future<void>.delayed(const Duration(seconds: 3));
    final sw = Stopwatch()..start();
    await engine.invokeMethod<void>('kill');
    Object? error;
    try {
      await running;
    } on PlatformException catch (e) {
      error = e.code;
    }
    say(
      'kill returned the call in ${sw.elapsedMilliseconds} ms with $error; pid before $before after ${await engine.invokeMethod<int>('pid')}',
    );
    expect(error, 'cancelled');
    expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
    expect(await engine.invokeMethod<int>('pid'), isNot(before));
    await openQwen();
    await engine.invokeMethod<void>('setVoice', {'path': clip.path, 'refText': refText});
    final r = await make('Short one.');
    expect(await File(r['path']! as String).length(), greaterThan(0));
    await File(r['path']! as String).delete();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
