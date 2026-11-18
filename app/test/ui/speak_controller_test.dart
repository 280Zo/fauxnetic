import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/audio/marking.dart';
import 'package:fauxnetic/audio/take_adjust.dart';
import 'package:fauxnetic/audio/wav.dart';
import 'package:fauxnetic/cues/take_renderer.dart';

import '../support/keys.dart';
import '../support/people.dart';

import 'package:fauxnetic/cues/cue.dart';
import 'package:fauxnetic/cues/cue_repo.dart';
import 'package:fauxnetic/cues/preparer.dart';
import 'package:fauxnetic/cues/share.dart';
import 'package:fauxnetic/cues/speed_book.dart';
import 'package:fauxnetic/recording/scripts.dart';
import 'package:fauxnetic/people/people_repo.dart';
import 'package:fauxnetic/people/person.dart';
import 'package:fauxnetic/recording/takes.dart';
import 'package:fauxnetic/storage/temp_sweeper.dart';
import 'package:fauxnetic/storage/vault.dart';
import 'package:fauxnetic/ui/clip_player.dart';
import 'package:fauxnetic/ui/speak_controller.dart';

import '../support/fake_engine.dart';

class NoKeeper implements BackgroundKeeper {
  @override
  Future<void> start({String title = '', String text = ''}) async {}
  @override
  Future<void> stop() async {}
}

class FakeClipPlayer implements ClipPlayer {
  final events = <String>[];
  final played = <String>[];
  final playedBytes = <int>[];
  final froms = <Duration>[];
  Completer<bool>? _current;

  @override
  Future<bool> play(File f, {Duration from = Duration.zero}) {
    events.add('play');
    played.add(f.path);
    playedBytes.add(f.lengthSync());
    froms.add(from);
    _current = Completer<bool>();
    return _current!.future;
  }

  void finish() => _current?.complete(true);

  @override
  Future<void> stop() async {
    events.add('stop');
    if (_current != null && !_current!.isCompleted) _current!.complete(false);
  }

  final positions = StreamController<Duration>.broadcast();

  @override
  Stream<Duration> get position => positions.stream;
}

class ThrowingPlayer implements ClipPlayer {
  @override
  Future<bool> play(File f, {Duration from = Duration.zero}) async => throw StateError('audio device busy');
  @override
  Future<void> stop() async {}
  @override
  Stream<Duration> get position => const Stream.empty();
}

class PassMarker implements Marker {
  PassMarker({this.score = 0.97});
  final double score;
  @override
  Float32List embed(Float32List pcm) => pcm;
  @override
  double detect(Float32List pcm) => score;
}

/// Always hands back a 2 s WAV, whatever the take.
class TwoSecondRenderer extends TakeRenderer {
  TwoSecondRenderer(CueRepo cues) : super(cues, PassMarker.new);
  @override
  Future<Uint8List> wav(CueItem item) async => encodeWav(Float32List(48000), 24000);
}

/// Fails the way a broken background render or library load would.
class BrokenRenderer extends TakeRenderer {
  BrokenRenderer(CueRepo cues) : super(cues, PassMarker.new);
  @override
  Future<Uint8List> wav(CueItem item) async => throw StateError('isolate failed');
}

R syncRun<R>(R Function() f) => f();

void main() {
  late Directory dir;
  late TempSweeper temp;
  late CueRepo cues;
  late PeopleRepo people;
  late Person sam;
  late Preparer preparer;
  late FakeClipPlayer player;
  late FakeEngine engine;
  late ShareService shares;
  late List<String> shared;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('speak');
    final vault = Vault(FixedKeyStore());
    temp = TempSweeper(dir);
    cues = CueRepo(dir, vault);
    people = PeopleRepo(dir, vault, temp, TakeStore(dir, vault));
    sam = await readyPerson(people, vault);
    engine = FakeEngine();
    preparer = Preparer(engine, cues, people, NoKeeper());
    player = FakeClipPlayer();
    shared = [];
    shares = ShareService(cues, Directory('${dir.path}/share'), sink: (f) async => shared.add(f.path.split('/').last));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<CueSpeakController> controller() async {
    final c = CueSpeakController(sam, cues, preparer, player, temp, shares);
    await c.refresh();
    return c;
  }

  test('Generate queues with the chosen mood', () async {
    final c = await controller();
    expect(c.mood, Mood.conversational);
    c.setMood(Mood.excited);
    await c.add('We won!');
    await c.idle;
    expect(c.items.single.mood, Mood.excited);
    expect(engine.prepared, ['${sam.id} excited']);
  });

  test('a line being made shows loading, then a time guess, then taking longer', () async {
    final speeds = SpeedBook(File('${dir.path}/speeds.json'));
    await speeds.load();
    await speeds.record('voxcpm', 10, 60); // 6 s a word on this phone
    var now = DateTime.utc(2026, 11, 16, 12);
    preparer = Preparer(engine, cues, people, NoKeeper(), speeds: speeds, clock: () => now);
    final c = CueSpeakController(sam, cues, preparer, player, temp, shares, clock: () => now, speeds: speeds);
    await c.setModel('voxcpm');
    final seen = <String>[];
    Future<String> status() async {
      await c.refresh();
      return c.statusOf(c.items.single);
    }

    engine.onPrepare = () async => seen.add(await status());
    engine.onSpeak = () async {
      seen.add(await status());
      now = now.add(const Duration(seconds: 20));
      seen.add(await status());
      now = now.add(const Duration(seconds: 45));
      seen.add(await status());
    };
    await c.add('One two three four five six seven eight nine ten.');
    await c.idle;
    expect(seen, [
      'Loading VoxCPM 2…',
      'Making with VoxCPM 2 · about 1 min left',
      'Making with VoxCPM 2 · about 40 s left',
      'Taking longer than usual · 1:05',
    ]);
    expect(c.statusOf(c.items.single), 'ready');
  });

  test('a line moved to the default because its model was deleted names the model really used', () async {
    final speeds = SpeedBook(File('${dir.path}/speeds.json'));
    await speeds.load();
    await speeds.record('voxcpm', 10, 600); // VoxCPM's slow rate must not be used
    var now = DateTime.utc(2026, 11, 16, 12);
    engine.missing.add('voxcpm');
    preparer = Preparer(engine, cues, people, NoKeeper(), speeds: speeds, clock: () => now);
    final c = CueSpeakController(sam, cues, preparer, player, temp, shares, clock: () => now, speeds: speeds);
    await c.setModel('voxcpm');
    final seen = <String>[];
    Future<void> look() async {
      await c.refresh();
      seen.add(c.statusOf(c.items.single));
    }

    engine.onPrepare = look;
    engine.onSpeak = look;
    await c.add('Four words right here.');
    await c.idle;
    expect(seen, ['Loading Qwen3-TTS…', 'Making with Qwen3-TTS · about 15 s left']);
  });

  test('a model never timed here uses the old rule', () async {
    var now = DateTime.utc(2026, 11, 16, 12);
    preparer = Preparer(engine, cues, people, NoKeeper(), clock: () => now);
    final c = CueSpeakController(sam, cues, preparer, player, temp, shares, clock: () => now);
    String? seen;
    engine.onSpeak = () async {
      await c.refresh();
      seen = c.statusOf(c.items.single);
    };
    await c.add('Four words right here.');
    await c.idle;
    expect(seen, 'Making with Qwen3-TTS · about 15 s left', reason: '2 s a word + 5 s = 13 s, rounded up to 5 s');
  });

  test('waiting lines count every line ahead, other voices included', () async {
    final ann = await readyPerson(people, Vault(FixedKeyStore()), name: 'Ann');
    await cues.add(ann.id, 'Hi from Ann.');
    await cues.add(sam.id, 'First.');
    await cues.add(sam.id, 'Second.');
    final c = await controller();
    expect(c.items.map(c.statusOf), ['2nd in line', '3rd in line']);
    final alone = await cues.all();
    await cues.remove(alone.first.id);
    await c.refresh();
    expect(c.items.map(c.statusOf), ['Next in line', '2nd in line']);
  });

  test('removing the line being made stops it', () async {
    final c = await controller();
    engine.onSpeak = () async {
      await c.refresh();
      await c.remove(c.items.single);
      await engine.held.future;
    };
    await c.add('Stop me now.');
    await c.idle;
    expect(engine.cancels, 1);
    expect(c.items, isEmpty);
  });

  test('stop ends playback and keeps the line shown', () async {
    final c = await controller();
    await c.add('Stop me.');
    await c.idle;
    final playing = c.play(c.items.single);
    await pumpUntil(() => player.played.length == 1);
    await c.stop();
    await playing;
    expect(player.events, contains('stop'));
    expect(c.playingId, isNull);
    expect(c.shownId, c.items.single.id);
    expect(c.items.single.status, CueStatus.ready, reason: 'stopped early is not played');
  });

  group('take adjustments (2026-11-18)', () {
    Future<CueSpeakController> adjusting({TakeRenderer? renderer}) async {
      final c = CueSpeakController(
        sam,
        cues,
        preparer,
        player,
        temp,
        shares,
        renderer: renderer ?? TakeRenderer(cues, PassMarker.new, run: syncRun),
      );
      await c.refresh();
      return c;
    }

    // 4 s of sound, so speed changes show in the length.
    setUp(() => engine.audio = (_) => Float32List.fromList(List.generate(96000, (i) => (i % 50) / 100.0)));

    Future<CueItem> oneLine(CueSpeakController c) async {
      await c.add('Hello there.');
      await c.idle;
      return c.items.single;
    }

    test('play and the waveform use the rendered take', () async {
      final c = await adjusting(renderer: TwoSecondRenderer(cues));
      final item = await oneLine(c);
      await c.select(item);
      expect(c.lengthSeconds, closeTo(2, 1e-6));
      expect(c.wordStarts.last, lessThan(2));
      unawaited(c.play(item));
      await pumpUntil(() => player.played.length == 1);
      expect(player.playedBytes.single, 44 + 48000 * 2);
    });

    test('adjust saves and re-renders', () async {
      final c = await adjusting();
      final item = await oneLine(c);
      await c.select(item);
      final before = c.lengthSeconds;
      await c.adjust(item, const TakeAdjust(speed: 1.25));
      expect(c.lengthSeconds, closeTo(before / 1.25, 0.05));
      final again = await adjusting();
      expect(again.adjustOf(again.items.single), const TakeAdjust(speed: 1.25));
    });

    test('resetAdjust returns to defaults', () async {
      final c = await adjusting();
      final item = await oneLine(c);
      await c.adjust(item, const TakeAdjust(pitch: 2));
      await c.resetAdjust(c.items.single);
      expect(c.adjustOf(c.items.single), TakeAdjust.defaults);
    });

    test('adjusting while playing restarts at the same place', () async {
      final c = await adjusting();
      final item = await oneLine(c);
      unawaited(c.play(item));
      await pumpUntil(() => player.played.length == 1);
      player.positions.add(const Duration(seconds: 2));
      await pumpUntil(() => c.playedSeconds == 2);
      await c.adjust(c.items.single, const TakeAdjust(speed: 1.25));
      await pumpUntil(() => player.played.length == 2);
      expect(player.events, ['play', 'stop', 'play']);
      expect(player.froms.last.inMilliseconds / 1000, closeTo(2 / 1.25, 0.1));
      expect(c.playingId, item.id);
    });

    test('two quick changes while playing resume once, with the second setting', () async {
      final c = await adjusting();
      final item = await oneLine(c);
      unawaited(c.play(item));
      await pumpUntil(() => player.played.length == 1);
      final first = c.adjust(c.items.single, const TakeAdjust(speed: 1.25));
      final second = c.adjust(c.items.single, const TakeAdjust(speed: 1.5));
      await Future.wait([first, second]);
      await pumpUntil(() => player.played.length >= 2);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(player.played, hasLength(2), reason: 'one resume');
      expect((player.playedBytes.last - 44) / 2 / 24000, closeTo(4 / 1.5, 0.1), reason: 'the second setting');
      expect(c.lengthSeconds, closeTo(4 / 1.5, 0.1));
    });

    test('a take re-rendering does not restart after another line is played', () async {
      final c = await adjusting();
      await c.add('One.');
      await c.add('Two.');
      await c.idle;
      final one = c.items.firstWhere((x) => x.text == 'One.');
      final two = c.items.firstWhere((x) => x.text == 'Two.');
      unawaited(c.play(one));
      await pumpUntil(() => player.played.length == 1);
      final adjusting1 = c.adjust(one, const TakeAdjust(speed: 1.25));
      unawaited(c.play(two));
      await adjusting1;
      await pumpUntil(() => player.played.length >= 2);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(player.played, hasLength(2), reason: 'only Two plays');
      expect(c.playingId, two.id);
    });

    test('a render error still plays the take as it was stored', () async {
      final c = await adjusting(renderer: BrokenRenderer(cues));
      final item = await oneLine(c);
      await c.select(item);
      expect(c.lengthSeconds, greaterThan(0), reason: 'the waveform falls back too');
      unawaited(c.play(item));
      await pumpUntil(() => player.played.length == 1);
      expect(player.played, hasLength(1));
    });

    test('a failed mark shares nothing and says why', () async {
      final c = await adjusting(renderer: TakeRenderer(cues, () => PassMarker(score: 0.2), run: syncRun));
      final item = await oneLine(c);
      await c.share(item);
      expect(shared, isEmpty);
      expect(c.shareError, MarkMissing.message);
    });
  });

  group('selection (Speak dock, 2026-11-18)', () {
    Future<CueSpeakController> withLines(List<String> texts) async {
      final c = await controller();
      for (final t in texts) {
        await c.add(t);
      }
      await c.idle;
      return c;
    }

    test('select shows a line without playing it', () async {
      final c = await withLines(['Hello there.']);
      await c.select(c.items.single);
      expect(c.shownId, c.items.single.id);
      expect(c.playingId, isNull);
      expect(player.played, isEmpty);
      expect(c.waveform, isNotEmpty);
      expect(c.lengthSeconds, greaterThan(0));
    });

    test('the shown take has a start time for each word, in order, within the clip', () async {
      final c = await withLines(['Hello there, Sam.']);
      await c.select(c.items.single);
      expect(c.words, ['Hello', 'there,', 'Sam.']);
      expect(c.wordStarts, hasLength(3));
      for (var k = 1; k < 3; k++) {
        expect(c.wordStarts[k], greaterThan(c.wordStarts[k - 1]));
      }
      expect(c.wordStarts.last, lessThan(c.lengthSeconds));
    });

    test('newLine clears the selection and stops playback', () async {
      final c = await withLines(['Hello there.']);
      final playing = c.play(c.items.single);
      await pumpUntil(() => player.played.length == 1);
      await c.newLine();
      await playing;
      expect(c.shownId, isNull);
      expect(c.wordStarts, isEmpty);
      expect(c.playingId, isNull);
      expect(player.events, contains('stop'));
    });

    test('selecting another line stops playback', () async {
      final c = await withLines(['First.', 'Second.']);
      final first = c.items.firstWhere((x) => x.text == 'First.');
      final second = c.items.firstWhere((x) => x.text == 'Second.');
      final playing = c.play(first);
      await pumpUntil(() => player.played.length == 1);
      await c.select(second);
      await playing;
      expect(c.shownId, second.id);
      expect(c.playingId, isNull);
      expect(player.played, hasLength(1));
    });

    test('removing the selected line returns to compose', () async {
      final c = await withLines(['Hello there.']);
      await c.select(c.items.single);
      await c.remove(c.items.single);
      expect(c.shownId, isNull);
    });

    test('playedSeconds follows the player position', () async {
      final c = await withLines(['Hello there.']);
      final playing = c.play(c.items.single);
      await pumpUntil(() => player.played.length == 1);
      player.positions.add(const Duration(milliseconds: 1500));
      await pumpUntil(() => c.playedSeconds > 0);
      expect(c.playedSeconds, 1.5);
      player.finish();
      await playing;
      expect(c.playedSeconds, 0);
    });
  });

  test('moods lists recorded moods only, and none for conversational alone', () async {
    final c = await controller();
    expect(c.moods, isEmpty);
    final both = await addTestVoice(people, Vault(FixedKeyStore()), sam, Mood.excited);
    final d = CueSpeakController(both, cues, preparer, player, temp, shares);
    expect(d.moods, [Mood.conversational, Mood.excited]);
  });

  test('the picker starts on the voice\'s own model, else the default', () async {
    Future<bool> ready(String id) async => id != 'voxcpm';
    expect(await modelForVoice(sam, 'qwen', ready), 'qwen');
    final picked = await people.setModel(sam.id, 'pocket');
    expect(await modelForVoice(picked, 'qwen', ready), 'pocket');
    final gone = await people.setModel(sam.id, 'voxcpm');
    expect(await modelForVoice(gone, 'qwen', ready), 'qwen', reason: 'its model was deleted');
  });

  test('lines and takes keep the model picked when they were asked for', () async {
    final c = await controller();
    await c.setModel('voxcpm');
    await c.add('First.');
    await c.setModel('qwen'); // switched while the first line may still be waiting
    await c.idle;
    expect(c.items.single.model, 'voxcpm');
    await c.setModel('pocket');
    await c.tryAgain(c.items.single);
    await c.idle;
    expect(engine.models, ['voxcpm', 'pocket']);
  });

  test('selecting a take changes what plays and shares', () async {
    final c = await controller();
    await c.add('Again.');
    await c.idle;
    final first = c.items.single;
    await c.tryAgain(first);
    await c.idle;
    expect(c.items.single.current, 1);
    await c.showTake(c.items.single, 0);
    expect(c.items.single.clipFile, first.clipFile);
    final done = c.play(c.items.single);
    await pumpUntil(() => player.played.length == 1);
    player.finish();
    await done;
    expect(c.items.single.clipFile, first.clipFile, reason: 'playing keeps the chosen take');
    await c.share(c.items.single);
    expect(shared, hasLength(1));
  });

  test('try again adds a take and stops playback', () async {
    final c = await controller();
    await c.add('Again.');
    await c.idle;
    final old = c.items.single;
    final playing = c.play(old);
    await pumpUntil(() => player.played.length == 1);
    await c.tryAgain(c.items.single);
    await playing;
    expect(player.events, contains('stop'));
    await c.idle;
    final redone = c.items.single;
    expect(redone.status, CueStatus.ready);
    expect(redone.seed, isNot(old.seed));
    expect(engine.seeds, [old.seed, redone.seed]);
    expect(redone.clips, hasLength(2));
    expect(File('${dir.path}/${old.clipFile}').existsSync(), isTrue, reason: 'the earlier take is kept');
  });

  test('try again ignores a preparing line', () async {
    final c = await controller();
    await cues.add(sam.id, 'Busy.');
    final busy = (await cues.all()).single;
    await cues.update(busy.copyWith(status: CueStatus.preparing));
    await c.refresh();
    await c.tryAgain(c.items.single);
    expect((await cues.all()).single.seed, busy.seed);
  });

  test('replay plays a played line', () async {
    final c = await controller();
    await c.add('Again.');
    await c.idle;
    final first = c.play(c.items.single);
    await pumpUntil(() => player.played.length == 1);
    player.finish();
    await first;
    expect(c.items.single.status, CueStatus.played);
    final again = c.replay(c.items.single);
    await pumpUntil(() => player.played.length == 2);
    player.finish();
    await again;
    expect(player.played.length, 2);
  });

  test('share calls the share service', () async {
    final c = await controller();
    await c.add('Send it.');
    await c.idle;
    await c.share(c.items.single);
    expect(shared.single, startsWith('Sam-'));
  });

  test('add queues a line and prepares it', () async {
    final c = await controller();
    await c.add('  Hi there.  ');
    await c.idle;
    expect(c.items.single.text, 'Hi there.');
    expect(c.items.single.status, CueStatus.ready);
  });

  test('empty lines are ignored', () async {
    final c = await controller();
    await c.add('   ');
    expect(c.items, isEmpty);
  });

  test('a played line can be played again', () async {
    final c = await controller();
    await c.add('Hi there.');
    await c.idle;
    for (var i = 0; i < 2; i++) {
      final done = c.play(c.items.single);
      await pumpUntil(() => player.played.length == i + 1);
      player.finish();
      await done;
    }
    expect(player.played.length, 2);
    expect(c.items.single.status, CueStatus.played);
    expect(temp.dir.listSync(), isEmpty);
  });

  test('finished playback marks the line played and removes the temp file', () async {
    final c = await controller();
    await c.add('Hi there.');
    await c.idle;
    final done = c.play(c.items.single);
    await pumpUntil(() => player.events.isNotEmpty);
    expect(c.playingId, c.items.single.id);
    expect(c.waveform, isNotEmpty);
    player.finish();
    await done;
    expect(c.items.single.status, CueStatus.played);
    expect(File(player.played.single).existsSync(), isFalse);
    expect(c.playingId, isNull);
  });

  test('second play stops first', () async {
    final c = await controller();
    await c.add('One.');
    await c.add('Two.');
    await c.idle;
    final first = c.play(c.items[0]);
    await pumpUntil(() => player.events.length == 1);
    final second = c.play(c.items[1]);
    await pumpUntil(() => player.events.length == 3);
    expect(player.events, ['play', 'stop', 'play']);
    await first;
    expect(c.items[0].status, CueStatus.ready, reason: 'interrupted line is kept');
    player.finish();
    await second;
    expect(c.items[1].status, CueStatus.played);
  });

  test('last line stays in the quote card after playback', () async {
    final c = await controller();
    await c.add('Hi there.');
    await c.idle;
    final done = c.play(c.items.single);
    await pumpUntil(() => player.events.isNotEmpty);
    player.finish();
    await done;
    expect(c.playingId, isNull);
    expect(c.shown?.text, 'Hi there.');
  });

  test('progress estimate follows the A54 measurements', () {
    final c = CueSpeakController(sam, cues, preparer, player, temp, shares);
    final words25 = List.filled(25, 'word').join(' ');
    expect(estimatedPrepareSeconds(words25), closeTo(55, 1e-9));
    expect(estimatedPrepareSeconds(List.filled(61, 'w').join(' ')), closeTo(127, 1e-9));
    c.dispose();
  });

  test('removing a waiting line deletes it', () async {
    final c = await controller();
    await cues.add(sam.id, 'Waiting.');
    await c.refresh();
    await c.remove(c.items.single);
    expect(c.items, isEmpty);
  });

  test('two taps without waiting play only the newest and keep the first unplayed', () async {
    final c = await controller();
    await c.add('One.');
    await c.add('Two.');
    await c.idle;
    final a = c.items[0], b = c.items[1];
    final first = c.play(a);
    final second = c.play(b);
    await pumpUntil(() => player.events.contains('play'));
    player.finish();
    await Future.wait([first, second]);
    expect(player.events.where((e) => e == 'play').length, 1);
    expect(c.items.firstWhere((x) => x.id == a.id).status, CueStatus.ready);
    expect(c.items.firstWhere((x) => x.id == b.id).status, CueStatus.played);
    expect(temp.dir.listSync(), isEmpty);
  });

  test('an expired line is not played and is removed', () async {
    var now = DateTime.now().toUtc();
    final c = CueSpeakController(sam, cues, preparer, player, temp, shares, clock: () => now);
    await c.refresh();
    await c.add('Old.');
    await c.idle;
    now = now.add(const Duration(hours: 25));
    await c.play(c.items.single);
    expect(player.events, isEmpty);
    expect(c.items, isEmpty);
    c.dispose();
  });

  test('a playback error clears the playing state', () async {
    final c = CueSpeakController(sam, cues, preparer, ThrowingPlayer(), temp, shares);
    await c.refresh();
    await c.add('One.');
    await c.idle;
    await c.play(c.items.single);
    expect(c.playingId, isNull);
    expect(c.items.single.status, CueStatus.ready);
    expect(temp.dir.listSync(), isEmpty);
    c.dispose();
  });

  test('leaving the screen stops playback', () async {
    final c = await controller();
    c.dispose();
    expect(player.events, ['stop']);
  });

  test('remove drops the line from the list immediately', () async {
    final c = await controller();
    await cues.add(sam.id, 'Waiting.');
    await c.refresh();
    final pending = c.remove(c.items.single);
    expect(c.items, isEmpty);
    await pending;
  });

  test('only this person\'s lines are shown', () async {
    await cues.add('someone-else', 'Not mine.');
    final c = await controller();
    expect(c.items, isEmpty);
  });
}

Future<void> pumpUntil(bool Function() cond) async {
  for (var i = 0; i < 200 && !cond(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(cond(), isTrue);
}
