import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/audio/take_adjust.dart';
import 'package:fauxnetic/cues/cue.dart';
import 'package:fauxnetic/cues/cue_repo.dart';
import 'package:fauxnetic/storage/vault.dart';

import '../support/keys.dart';
import '../support/people.dart';

void main() {
  late Directory dir;
  late CueRepo cues;
  late CueItem line;
  final now = DateTime.utc(2026, 11, 18, 12);

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('cue_repo');
    cues = CueRepo(dir, Vault(FixedKeyStore()));
    final added = await cues.add('p1', 'Hi.');
    final one = (await cues.storeClip(added, testRefWav(), now))!;
    await cues.regenerate(one.id, 2);
    line = (await cues.storeClip((await cues.all()).single, testRefWav(), now))!;
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('setAdjust keeps settings across reloads, on that take only', () async {
    const a = TakeAdjust(speed: 1.25, pitch: 2);
    final got = await cues.setAdjust(line.id, 1, a);
    expect(got!.clips[1].adjust, a);
    final again = (await CueRepo(dir, Vault(FixedKeyStore())).all()).single;
    expect(again.clips[1].adjust, a);
    expect(again.clips[0].adjust, TakeAdjust.defaults);
  });

  test('setAdjust on a missing line or take returns null', () async {
    expect(await cues.setAdjust('nope', 0, const TakeAdjust(speed: 1.1)), isNull);
    expect(await cues.setAdjust(line.id, 5, const TakeAdjust(speed: 1.1)), isNull);
  });

  test('old takes load with defaults', () {
    final c = CueClip.fromJson({'file': 'cues/x-0.bin', 'seed': 1});
    expect(c.adjust, TakeAdjust.defaults);
    expect(c.toJson().containsKey('adjust'), isFalse, reason: 'defaults are not stored');
  });
}
