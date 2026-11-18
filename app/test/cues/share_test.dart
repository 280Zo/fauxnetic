import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/audio/wav.dart';
import 'package:fauxnetic/cues/cue.dart';
import 'package:fauxnetic/cues/cue_repo.dart';
import 'package:fauxnetic/cues/share.dart';
import 'package:fauxnetic/storage/vault.dart';

import '../support/keys.dart';
import '../support/people.dart';

/// The phone's local time as YYYYMMDDHHMMSS.
String stamp(DateTime t) {
  final l = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${l.year}${two(l.month)}${two(l.day)}${two(l.hour)}${two(l.minute)}${two(l.second)}';
}

void main() {
  late Directory dir;
  late Directory shareDir;
  late CueRepo cues;
  late CueItem line;
  late DateTime now;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('share');
    shareDir = Directory('${dir.path}/cache/share');
    cues = CueRepo(dir, Vault(FixedKeyStore()));
    final added = await cues.add('p1', 'Hi.');
    now = DateTime.utc(2026, 11, 15, 12);
    line = (await cues.storeClip(added, testRefWav(), now))!;
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('share writes a WAV in cache and deletes it afterwards', () async {
    final handed = <String>[];
    var existedWhileSharing = false;
    var bytesWhileSharing = <int>[];
    final s = ShareService(
      cues,
      shareDir,
      clock: () => now,
      sink: (f) async {
        handed.add(f.path);
        existedWhileSharing = f.existsSync();
        bytesWhileSharing = f.readAsBytesSync();
      },
    );
    expect(await s.share(line, 'Sam Quill'), isTrue);
    expect(handed.single, '${shareDir.path}/Sam-Quill-AI-Fauxnetic-v1-${stamp(now)}.wav');
    expect(existedWhileSharing, isTrue);
    expect(wavSeconds(bytesWhileSharing), closeTo(5, 1e-6));
    expect(File(handed.single).existsSync(), isFalse);
  });

  test('each version is named by its model, number and when it was made', () async {
    // Owner, 2026-11-18: takes of one line all came out with the same name.
    final later = now.add(const Duration(minutes: 3, seconds: 7));
    final again = await cues.regenerate(line.id, 2, model: 'pocket').then((_) async => (await cues.all()).single);
    final two = (await cues.storeClip(again, testRefWav(), later, engine: 'VoxCPM 2 (small)'))!;
    final handed = <String>[];
    final s = ShareService(cues, shareDir, clock: () => later, sink: (f) async => handed.add(f.path.split('/').last));
    await s.share(two, 'AJ');
    await s.share(two.copyWith(current: 0), 'AJ');
    expect(handed, ['AJ-AI-VoxCPM-2-small-v2-${stamp(later)}.wav', 'AJ-AI-Fauxnetic-v1-${stamp(now)}.wav']);
  });

  test('the file is deleted even when the share sheet fails', () async {
    final s = ShareService(cues, shareDir, clock: () => now, sink: (f) async => throw StateError('no app'));
    await expectLater(s.share(line, 'Sam'), throwsStateError);
    expect(shareDir.listSync(), isEmpty);
  });

  test('names are made safe for a file name', () async {
    final handed = <String>[];
    final s = ShareService(cues, shareDir, clock: () => now, sink: (f) async => handed.add(f.path));
    await s.share(line, '../../Zoë & Co.');
    await s.share(line, '***');
    await s.share(line, 'Bartholomew' * 40);
    final names = handed.map((p) => p.split('/').last).toList();
    expect(names[0], 'Zoë-Co-AI-Fauxnetic-v1-${stamp(now)}.wav');
    expect(names[1], 'line-AI-Fauxnetic-v1-${stamp(now)}.wav');
    expect(names[2].length, lessThanOrEqualTo(100), reason: 'a very long name still makes a valid file name');
    expect(handed.every((p) => File(p).parent.path == shareDir.path), isTrue);
  });

  test('an expired or unprepared line is not shared', () async {
    var calls = 0;
    final late = ShareService(
      cues,
      shareDir,
      clock: () => now.add(const Duration(hours: 25)),
      sink: (f) async => calls++,
    );
    expect(await late.share(line, 'Sam'), isFalse);
    final queued = await cues.add('p1', 'Not yet.');
    expect(
      await ShareService(cues, shareDir, clock: () => now, sink: (f) async => calls++).share(queued, 'Sam'),
      isFalse,
    );
    expect(calls, 0);
  });

  test("the share plugin's own copies are swept: all at launch, and once 10 minutes old", () async {
    final plugin = Directory('${dir.path}/cache/share_plus');
    File plain(String name, Duration age) => File('${plugin.path}/$name')
      ..createSync(recursive: true)
      ..writeAsStringSync('RIFF')
      ..setLastModifiedSync(now.subtract(age));
    final old = plain('old.wav', const Duration(minutes: 11));
    final fresh = plain('fresh.wav', const Duration(minutes: 2));
    final s = ShareService(cues, shareDir, pluginDir: plugin, clock: () => now, sink: (f) async {});
    expect(await s.sweepStale(), 1);
    expect(old.existsSync(), isFalse);
    expect(fresh.existsSync(), isTrue, reason: 'a receiver such as SMS may still be reading it');
    expect(await s.sweepShares(), 1);
    expect(plugin.listSync(), isEmpty);
  });

  test('launch sweeps share files', () async {
    File('${shareDir.path}/old.wav')
      ..createSync(recursive: true)
      ..writeAsStringSync('x');
    final s = ShareService(cues, shareDir, sink: (f) async {});
    expect(await s.sweepShares(), 1);
    expect(shareDir.listSync(), isEmpty);
    expect(await ShareService(cues, Directory('${dir.path}/none'), sink: (f) async {}).sweepShares(), 0);
  });
}
