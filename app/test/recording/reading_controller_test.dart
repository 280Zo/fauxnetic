import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/people/people_repo.dart';
import 'package:fauxnetic/people/person.dart';
import 'package:fauxnetic/recording/reading_controller.dart';
import 'package:fauxnetic/recording/reference_builder.dart';
import 'package:fauxnetic/recording/room_meter.dart';
import 'package:fauxnetic/recording/scripts.dart';
import 'package:fauxnetic/recording/takes.dart';
import 'package:fauxnetic/recording/transcriber.dart';
import 'package:fauxnetic/storage/temp_sweeper.dart';
import 'package:fauxnetic/storage/vault.dart';

import '../support/keys.dart';
import '../support/recording_fakes.dart';
import '../support/signals.dart';

class _BrokenBuilder extends ReferenceBuilder {
  _BrokenBuilder(Directory dir, TakeStore takes) : super(dir, Vault(FixedKeyStore()), takes);
  @override
  Future<VoiceRef> build(List<Take> takes, Mood mood) async => throw const FileSystemException('disk full');
}

void main() {
  late Directory dir;
  late TakeStore takes;
  late PeopleRepo people;
  late ReferenceBuilder builder;
  late FakeMic mic;
  late FakeTranscriber follow;
  late FakeTranscriber full;
  late Person sam;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('reading');
    final vault = Vault(FixedKeyStore());
    takes = TakeStore(dir, vault);
    people = PeopleRepo(dir, vault, TempSweeper(dir), takes);
    builder = ReferenceBuilder(dir, vault, takes);
    mic = FakeMic();
    follow = FakeTranscriber();
    full = FakeTranscriber();
    sam = await people.create('Sam', PersonSource.recorded);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  ReadingController controller([Mood mood = Mood.conversational]) {
    final c = ReadingController(sam, mood, mic, follow, full, takes, people, builder, random: Random(1));
    // A perfect transcript of whatever line is being read.
    full.next = () => words(c.line.text);
    return c;
  }

  Future<void> readGood(ReadingController c) async {
    await c.record();
    await mic.say(goodTake());
    await c.stopAndCheck();
  }

  /// Skips a story session's story to its question.
  Future<void> toQuestion(ReadingController c) async {
    expect(c.lines.any((l) => l.openPrompt), isTrue, reason: 'only a story session asks a question');
    while (!c.line.openPrompt) {
      await c.skip();
    }
  }

  /// A story session (owner, 2026-11-23: the question in the person's own words comes after the
  /// story, not in the first session), at its question.
  Future<ReadingController> asking({Random? random, List<Take>? earlier, bool replace = false}) async {
    final c = ReadingController(
      sam,
      Mood.conversational,
      mic,
      follow,
      full,
      takes,
      people,
      builder,
      random: random ?? Random(1),
      kind: SessionKind.story,
      earlier: earlier ?? await takes.forPerson(sam.id),
      replace: replace,
    );
    full.next = () => words(c.line.text);
    await toQuestion(c);
    return c;
  }

  /// Reads the passage well in a first session, then opens a story session at its question.
  Future<ReadingController> passageThenAsking() async {
    await readGood(controller());
    return asking();
  }

  test('follow-along marks spoken words', () async {
    final c = controller();
    follow.next = () => words(c.lineWords.take(3).join(' '));
    await c.record();
    expect(c.recording, isTrue);
    await mic.say(Float32List.fromList(tone(0.5, -20)));
    expect(c.confirmedWords, 3);
    expect(c.spokenWords, 3);
    expect(c.levelBars.last, greaterThan(0.5));
    follow.next = () => words(c.lineWords.take(2).join(' '));
    await mic.say(Float32List.fromList(tone(1, -20)));
    expect(c.confirmedWords, 3, reason: 'a shorter partial transcript never moves the highlight back');
  });

  test('the highlight runs ahead at speaking pace by at most two words', () async {
    final c = controller();
    follow.next = () => words(c.lineWords.take(3).join(' '));
    await c.record();
    await mic.say(Float32List.fromList(tone(0.5, -20)));
    expect(c.spokenWords, 3);
    await mic.say(Float32List.fromList(tone(0.4, -20)), chunk: 1600);
    expect(c.spokenWords, 4, reason: '2.6 words/s for 0.4 s of speech is one word');
    await mic.say(Float32List.fromList(tone(2, -20)), chunk: 1600);
    expect(c.spokenWords, 5, reason: 'never more than two words past what Whisper confirmed');
    expect(c.confirmedWords, 3);
  });

  test('silence does not move the highlight', () async {
    final c = controller();
    follow.next = () => words(c.lineWords.take(3).join(' '));
    await c.record();
    await mic.say(Float32List.fromList(tone(0.5, -20)));
    await mic.pause(1.5);
    expect(c.spokenWords, 3);
    expect(c.recording, isTrue);
  });

  test('a read line stops by itself after the last word and a short pause', () async {
    final c = controller();
    follow.next = () => words(c.line.text);
    await c.record();
    await mic.say(Float32List.fromList(tone(1, -20)));
    expect(c.confirmedWords, c.lineWords.length);
    await mic.pause(0.5);
    expect(c.recording, isTrue, reason: 'not quiet long enough yet');
    await mic.pause(0.5);
    expect(c.recording, isFalse);
    await until(() => !c.checking);
    expect(c.index, 1);
    expect(await takes.forPerson(sam.id), hasLength(1));
  });

  test('a missed word still stops after two seconds of quiet', () async {
    final c = controller();
    // Most of the line heard (80%), the rest missed by the recogniser.
    follow.next = () => words(c.lineWords.take((c.lineWords.length * 0.8).floor()).join(' '));
    await c.record();
    await mic.say(Float32List.fromList(tone(1, -20)));
    await mic.pause(1.2);
    expect(c.recording, isTrue);
    await mic.pause(1);
    expect(c.recording, isFalse);
    await until(() => !c.checking);
    expect(c.index, 1);
  });

  test('a pause early in a read line does not stop it', () async {
    final c = controller();
    follow.next = () => words(c.lineWords.take(3).join(' '));
    await c.record();
    await mic.say(Float32List.fromList(tone(1, -20)));
    await mic.pause(3);
    expect(c.recording, isTrue);
  });

  test('an open question stops after three seconds of quiet, not before speech', () async {
    final c = await asking();
    full.next = () => words('Honestly the traffic this morning was ridiculous');
    await c.record();
    await mic.pause(4);
    expect(c.recording, isTrue, reason: 'nothing said yet');
    await mic.say(goodTake());
    await mic.pause(2.3);
    expect(c.recording, isTrue, reason: 'the take ends with 0.5 s of quiet, so 2.8 s in all');
    await mic.pause(1);
    expect(c.recording, isFalse);
    await until(() => !c.checking);
    expect((await takes.forPerson(sam.id)).single.fromScript, isFalse);
  });

  test('bad take shows hint and stays on line', () async {
    final c = controller();
    await c.record();
    await mic.say(Float32List.fromList(tone(3, -50)));
    await c.stopAndCheck();
    expect(c.hint, 'Speak a little louder.');
    expect(c.index, 0);
    expect(c.recording, isFalse);
    expect(await takes.forPerson(sam.id), isEmpty);
  });

  test('missed words keep the reader on the line', () async {
    final c = controller();
    full.next = () => words("I'm heading");
    await readGood(c);
    expect(c.hint, 'We missed some words. Try that line again.');
    expect(c.index, 0);
  });

  test('good take advances', () async {
    final c = controller();
    await readGood(c);
    expect(c.index, 1);
    expect(c.hint, 'Good level. Room is quiet.');
    expect(c.spokenWords, 0);
    final saved = (await takes.forPerson(sam.id)).single;
    expect(saved.text, c.lines.first.text);
    expect(saved.fromScript, isTrue);
    expect(saved.mood, Mood.conversational);
  });

  // Owner, 2026-11-23: the main voice first (passage and a question), then a story to make it sound
  // more like the person, then feelings (one sentence said five ways); each one optional.
  group('the three parts', () {
    ReadingController session(SessionKind kind, {List<Take> earlier = const []}) {
      final c = ReadingController(
        sam,
        Mood.conversational,
        mic,
        follow,
        full,
        takes,
        people,
        builder,
        random: Random(1),
        kind: kind,
        earlier: earlier,
      );
      full.next = () => words(c.line.text);
      return c;
    }

    Future<Person> mainVoice() async {
      final c = controller();
      await readGood(c); // the passage
      while (!c.done) {
        await c.skip();
      }
      return sam = (await c.finish())!;
    }

    test('a core session is the passage alone', () {
      final c = controller();
      expect(c.kind, SessionKind.core);
      expect(c.lines, hasLength(1));
      expect(kPassages, contains(c.lines.first.text));
    });

    test('a story session reads a five-line story, kept for the main voice, then asks a question', () async {
      await mainVoice();
      final c = session(SessionKind.story);
      expect(c.lines, hasLength(6));
      expect(c.lines.take(5).every((l) => l.story), isTrue);
      expect(c.lines.last.openPrompt, isTrue);
      while (!c.line.openPrompt) {
        await readGood(c);
      }
      await c.skip();
      expect(c.done, isTrue);
      final saved = (await takes.forPerson(sam.id)).where((t) => t.story).toList();
      expect(saved, hasLength(5));
      expect(saved.every((t) => t.mood == Mood.conversational && t.fromScript && !t.isPassage), isTrue);
      final p = await c.finish();
      expect(
        p!.voices[Mood.conversational]!.refText,
        startsWith(c.lines.first.text),
        reason: 'the story makes the voice',
      );
    });

    test('each sentence is kept with its mood and marked as a sentence', () async {
      await mainVoice();
      final c = session(SessionKind.feelings);
      expect([for (final l in c.lines) l.phrase], PhraseTone.values);
      for (var i = 0; i < 5; i++) {
        await readGood(c);
      }
      final saved = (await takes.forPerson(sam.id)).where((t) => t.phrase != null);
      expect(
        {for (final t in saved) t.phrase: t.mood},
        {
          'plain': Mood.conversational,
          'question': Mood.conversational,
          'excited': Mood.excited,
          'annoyed': Mood.annoyed,
          'worried': Mood.worried,
        },
      );
      expect(c.done, isTrue);
    });

    test('finishing feelings makes excited, annoyed and worried voices: the passage, then the sentence', () async {
      final before = (await mainVoice()).voices[Mood.conversational]!;
      final passage = before.refText;
      final c = session(SessionKind.feelings);
      for (var i = 0; i < 5; i++) {
        await readGood(c);
      }
      final p = await c.finish();
      expect(p, isNotNull, reason: c.error);
      final excited = c.lines.firstWhere((l) => l.phrase == PhraseTone.excited).text;
      for (final m in [Mood.excited, Mood.annoyed, Mood.worried]) {
        expect(p!.recorded(m), isTrue, reason: m.name);
        expect(p.voices[m]!.refText, startsWith(passage.substring(0, 20)));
        expect(p.voices[m]!.seconds, lessThanOrEqualTo(15));
      }
      expect(p!.voices[Mood.excited]!.refText, endsWith(excited));
      expect(p.voices[Mood.conversational]!.clipFile, before.clipFile, reason: 'feelings leave the main voice alone');
    });

    test('feelings with nothing recorded say so', () async {
      await mainVoice();
      final c = session(SessionKind.feelings);
      while (!c.done) {
        await c.skip();
      }
      expect(await c.finish(), isNull);
      expect(c.error, kNotEnoughMoodSpeechMessage);
    });

    test('continuing an unfinished session starts at the first line not recorded, same text', () async {
      final first = controller();
      await readGood(first); // passage
      final earlier = await takes.forPerson(sam.id);
      final c = ReadingController(
        sam,
        Mood.conversational,
        mic,
        follow,
        full,
        takes,
        people,
        builder,
        random: Random(9),
        earlier: earlier,
        resume: true,
      );
      full.next = () => words(c.line.text);
      expect(c.lines.first.text, first.lines.first.text);
      expect(c.done, isTrue, reason: 'the passage was read: the voice is made straight away');
      final p = await c.finish();
      expect(p!.ready, isTrue);
      expect(p.voices[Mood.conversational]!.refText, first.lines.first.text, reason: 'the earlier passage take');
    });

    test('an excited session reads three excited sentences, each with its scene', () {
      final c = controller(Mood.excited);
      expect(c.lines, hasLength(3));
      expect(c.lines.every((l) => l.phrase == PhraseTone.excited && (l.scene ?? '').isNotEmpty), isTrue);
    });
  });

  group('in a noisy room', () {
    // Owner, 2026-11-23: with background noise the follow-along highlight was way off. Anything over
    // -40 dBFS counted as speaking, so a hum moved the highlight and the take never heard its pause.
    test('steady noise alone does not move the highlight', () async {
      final c = controller();
      await c.listen();
      await mic.say(Float32List.fromList(noise(1, -35, Random(1))));
      follow.next = () => const [];
      await c.record();
      await mic.say(Float32List.fromList(noise(3, -35, Random(2))));
      expect(c.spokenWords, 0);
      await c.redo();
    });

    test('speech over the noise still moves it', () async {
      final c = controller();
      await c.listen();
      await mic.say(Float32List.fromList(noise(1, -35, Random(1))));
      follow.next = () => const [];
      await c.record();
      await mic.say(bursts(-15, -35));
      expect(c.spokenWords, greaterThan(0));
      await c.redo();
    });

    ReadingController withDenoise() {
      final c = ReadingController(
        sam,
        Mood.conversational,
        mic,
        follow,
        full,
        takes,
        people,
        builder,
        random: Random(1),
        cleaner: (pcm) async => pcm,
        denoise: (pcm) async => Float32List(pcm.length), // removes everything
      );
      full.next = () => words(c.line.text);
      return c;
    }

    test('with the cleaner on, the level bars show the cleaned sound', () async {
      final off = withDenoise();
      await off.record();
      await mic.say(Float32List.fromList(noise(1, -30, Random(3))), chunk: 1600);
      expect(off.levelBars.last, greaterThan(0.3), reason: 'off: the raw room');
      await off.redo();

      final on = withDenoise()..cleanNoise = true;
      await on.record();
      await mic.say(Float32List.fromList(noise(1, -30, Random(3))), chunk: 1600);
      await settle();
      expect(on.levelBars.every((b) => b == 0), isTrue, reason: 'on: what the cleaner leaves');
      await on.redo();
    });

    test('with the cleaner on, the follow-along hears the cleaned sound', () async {
      final c = withDenoise()..cleanNoise = true;
      final heard = <double>[];
      follow.nextFor = (pcm) {
        heard.add(pcm.fold(0.0, (m, v) => max(m, v.abs())));
        return const [];
      };
      await c.record();
      await mic.say(goodTake());
      await settle();
      expect(heard, isNotEmpty);
      expect(heard.every((h) => h == 0), isTrue);
      await c.redo();
    });
  });

  group('room meter', () {
    test('listening shows the room before recording and keeps nothing', () async {
      final c = controller();
      await c.listen();
      expect(mic.live, isTrue);
      await mic.say(Float32List.fromList(noise(1, -35, Random(1))));
      expect(c.roomLevel, RoomLevel.noisy);
      expect(c.recording, isFalse);
      expect(await takes.forPerson(sam.id), isEmpty);
    });

    test('Record takes the microphone over, and listening comes back after the take', () async {
      final c = controller(Mood.excited); // more than one line, so the session goes on after the take
      await c.listen();
      await readGood(c);
      expect(c.index, 1);
      expect(mic.starts, 3, reason: 'listen, record, listen again');
      expect(mic.live, isTrue);
      expect(await takes.forPerson(sam.id), hasLength(1));
    });

    test('the room shows while recording too', () async {
      final c = controller();
      await c.record();
      await mic.say(bursts(-20, -36));
      expect(c.roomLevel, RoomLevel.noisy);
      await c.redo();
    });

    test('without the microphone permission, listening does nothing and shows no error', () async {
      mic.allowed = false;
      final c = controller();
      await c.listen();
      expect(mic.starts, 0);
      expect(c.error, isNull);
    });

    test('an interruption stops listening; listening again resumes', () async {
      final c = controller();
      await c.listen();
      await c.onInterrupted();
      expect(mic.live, isFalse);
      await c.listen();
      expect(mic.live, isTrue);
    });

    test('a noisy room suggests the cleaner while it is off', () async {
      cleanedSetup() => ReadingController(
        sam,
        Mood.conversational,
        mic,
        follow,
        full,
        takes,
        people,
        builder,
        random: Random(1),
        cleaner: (pcm) async => pcm,
      );
      final c = cleanedSetup();
      await c.listen();
      await mic.say(Float32List.fromList(noise(1, -35, Random(1))));
      expect(c.suggestCleaner, isTrue);
      c.cleanNoise = true;
      expect(c.suggestCleaner, isFalse);
      expect(controller().suggestCleaner, isFalse, reason: 'no cleaner, nothing to suggest');
    });
  });

  group('voice cleaner', () {
    // A noisy room: the voice stands out by only 15 dB.
    Float32List noisyTake() => bursts(-25, -40);
    late List<int> cleaned;

    ReadingController cleaning(Future<Float32List> Function(Float32List) clean) {
      cleaned = [];
      final c = ReadingController(
        sam,
        Mood.conversational,
        mic,
        follow,
        full,
        takes,
        people,
        builder,
        random: Random(1),
        cleaner: (pcm) {
          cleaned.add(pcm.length);
          return clean(pcm);
        },
      );
      full.next = () => words(c.line.text);
      return c;
    }

    Future<void> read(ReadingController c, Float32List pcm) async {
      await c.record();
      await mic.say(pcm);
      await c.stopAndCheck();
    }

    test('is off at the start of a session and leaves takes as recorded', () async {
      final c = cleaning((pcm) async => goodTake());
      expect(c.canClean, isTrue);
      expect(c.cleanNoise, isFalse);
      await read(c, noisyTake());
      expect(cleaned, isEmpty);
      expect(c.index, 0, reason: 'the noisy take is rejected as before');
    });

    test('with it off, a noisy take says so plainly and offers it', () async {
      final c = cleaning((pcm) async => goodTake());
      await read(c, noisyTake());
      expect(c.noisyOffer, isTrue);
      expect(c.hint, kNoisyOfferHint);
      c.cleanNoise = true;
      expect(c.noisyOffer, isFalse, reason: 'turning it on answers the offer');
    });

    test('with it on, the checks and the saved take use the cleaned audio', () async {
      final c = cleaning((pcm) async => goodTake());
      c.cleanNoise = true;
      await read(c, noisyTake());
      expect(cleaned, hasLength(1));
      expect(c.index, 1, reason: 'the cleaned take passes the noise check');
      final saved = await takes.samples((await takes.forPerson(sam.id)).single);
      // The cleaned take's pauses are near silent (-70); the raw take's were at -40.
      final frames = [
        for (var i = 0; i + 320 <= saved.length; i += 320)
          sqrt(saved.sublist(i, i + 320).fold(0.0, (s, v) => s + v * v) / 320),
      ]..sort();
      expect(20 * log(frames[frames.length ~/ 10] + 1e-12) / ln10, lessThan(-55));
    });

    test('with it on, a take still noisy after cleaning gets the plain hint, no offer', () async {
      final c = cleaning((pcm) async => pcm);
      c.cleanNoise = true;
      await read(c, noisyTake());
      expect(c.index, 0);
      expect(c.noisyOffer, isFalse);
      expect(c.hint, "It's noisy here. Try a quieter spot.");
    });

    test('without a cleaner the switch is not offered', () async {
      final c = controller();
      expect(c.canClean, isFalse);
      await c.record();
      await mic.say(noisyTake());
      await c.stopAndCheck();
      expect(c.noisyOffer, isFalse);
      expect(c.hint, "It's noisy here. Try a quieter spot.");
    });
  });

  test('skip advances without a take', () async {
    final c = controller();
    await c.record();
    await mic.say(goodTake());
    await c.skip();
    expect(c.index, 1);
    expect(c.recording, isFalse);
    expect(await takes.forPerson(sam.id), isEmpty);
  });

  test('redo restarts the line', () async {
    final c = controller();
    await c.record();
    await mic.say(goodTake());
    await c.redo();
    expect(c.index, 0);
    expect(c.recording, isFalse);
    expect(mic.live, isFalse);
    expect(await takes.forPerson(sam.id), isEmpty);
  });

  test('permission denied shows settings prompt', () async {
    mic.allowed = false;
    final c = controller();
    await c.record();
    expect(c.error, 'Fauxnetic needs the microphone to record Sam. Allow it in Settings.');
    expect(c.recording, isFalse);
    expect(mic.starts, 0);
    expect(await takes.forPerson(sam.id), isEmpty);
  });

  test('a microphone failure mid-take discards it and shows the prompt', () async {
    final c = controller();
    await c.record();
    await mic.say(Float32List.fromList(tone(1, -20)));
    mic.fail();
    await settle();
    expect(c.recording, isFalse);
    expect(c.error, contains('needs the microphone'));
    await c.stopAndCheck();
    expect(await takes.forPerson(sam.id), isEmpty);
  });

  test('pause keeps the take and resume continues it', () async {
    final c = controller();
    follow.next = () => words(c.lineWords.take(3).join(' '));
    await c.record();
    await mic.say(Float32List.fromList(tone(1, -20)));
    expect(c.spokenWords, greaterThanOrEqualTo(3));
    await c.pause();
    expect(c.paused, isTrue);
    expect(c.recording, isFalse);
    expect(c.hasPausedTake, isTrue);
    expect(c.spokenWords, greaterThanOrEqualTo(3), reason: 'the highlight stays where the reader stopped');
    await c.record();
    expect(c.recording, isTrue);
    expect(c.paused, isFalse);
    expect(c.spokenWords, greaterThanOrEqualTo(3), reason: 'resuming does not start the line again');
    await mic.say(goodTake());
    await c.stopAndCheck();
    final saved = (await takes.forPerson(sam.id)).single;
    // Both parts (1 s + 6.5 s), less the quiet trimmed from the end beyond 0.3 s.
    expect(saved.seconds, closeTo(1 + 6.5 - 0.2, 0.05), reason: 'one take holding both parts');
  });

  test('changing the passage while paused starts a fresh take', () async {
    final c = controller();
    follow.next = () => words(c.lineWords.take(3).join(' '));
    await c.record();
    await mic.say(goodTake());
    await c.pause();
    expect(c.hasPausedTake, isTrue);
    await c.changePassage();
    expect(c.hasPausedTake, isFalse, reason: 'the old audio belongs to the old passage');
    expect(c.paused, isFalse);
    expect(c.spokenWords, 0);
    full.next = () => words(c.line.text);
    await readGood(c);
    final saved = (await takes.forPerson(sam.id)).single;
    expect(saved.prompt, c.lines[0].text);
    expect(saved.seconds, lessThan(6.6), reason: 'only the new reading');
  });

  test('another question while paused starts a fresh answer', () async {
    final c = await asking();
    await c.record();
    await mic.say(goodTake().sublist(0, 16000));
    await c.pause();
    c.nextPrompt();
    expect(c.hasPausedTake, isFalse);
    expect(c.paused, isFalse);
  });

  test('interruption still discards a paused take', () async {
    final c = controller();
    await c.record();
    await mic.say(goodTake());
    await c.pause();
    await c.redo();
    expect(c.hasPausedTake, isFalse);
    await c.record();
    await mic.say(goodTake());
    await c.pause();
    await c.onInterrupted();
    expect(c.hasPausedTake, isFalse);
    expect(await takes.forPerson(sam.id), isEmpty);
  });

  test('interruption discards the take and pauses', () async {
    final c = controller();
    await c.record();
    await mic.say(goodTake());
    await c.onInterrupted();
    expect(c.paused, isTrue);
    expect(c.recording, isFalse);
    expect(c.index, 0);
    expect(mic.live, isFalse);
    await c.stopAndCheck();
    expect(await takes.forPerson(sam.id), isEmpty);
    await readGood(c);
    expect(c.paused, isFalse);
    expect(c.index, 1);
  });

  test('an interruption during the check drops the take', () async {
    final c = controller();
    await c.record();
    await mic.say(goodTake());
    final check = c.stopAndCheck();
    await c.onInterrupted();
    await check;
    expect(c.index, 0);
    expect(await takes.forPerson(sam.id), isEmpty);
  });

  Float32List longAnswer() => Float32List.fromList([...goodTake(), ...goodTake()]);

  test('core session is the passage alone; the story session ends with a question', () async {
    final c = controller();
    expect(c.total, 1);
    expect(kPassages, contains(c.lines[0].text));
    expect(c.lines[0].openPrompt, isFalse);
    final s = await asking();
    expect(s.total, 6);
    expect(s.lines.take(5).every((l) => l.story), isTrue);
    expect(kPrompts, contains(s.lines.last.text));
    expect(s.lines.last.openPrompt, isTrue);
  });

  test('another question swaps only the prompt', () async {
    final c = await asking();
    final story = c.lines[0].text, prompt = c.line.text;
    c.nextPrompt();
    expect(c.line.text, isNot(prompt));
    expect(kPrompts, contains(c.line.text));
    expect(c.lines[0].text, story);
    expect(c.index, 5);
  });

  test('changing the passage drops its take', () async {
    final c = controller();
    final first = c.line.text;
    await readGood(c);
    expect(await takes.forPerson(sam.id), hasLength(1));
    await c.changePassage();
    expect(c.index, 0);
    expect(c.line.text, isNot(first));
    expect(await takes.forPerson(sam.id), isEmpty);
  });

  Float32List seconds(double s) {
    final one = goodTake();
    return Float32List.fromList([for (var i = 0; i < (s * 16000).round(); i++) one[i % one.length]]);
  }

  test('a passage read past 15 s is cut and stores the words heard in what is kept', () async {
    final c = controller();
    final passage = c.line.text;
    final kept = passage.split(' ').take(30).join(' ');
    // Testy (2026-11-16): words picked by Whisper's times ran past the audio, and Qwen said them
    // before every line. The kept audio is transcribed again instead.
    full.nextFor = (pcm) => words(pcm.length > 15 * 16000 ? passage : kept);
    await c.record();
    await mic.say(seconds(26));
    await c.stopAndCheck();
    await c.skip();
    final p = await c.finish();
    expect(p, isNotNull, reason: c.error);
    final ref = p!.refFor(Mood.conversational);
    expect(ref.seconds, lessThanOrEqualTo(15));
    expect(ref.refText, kept);
    expect(full.heardSeconds.last, lessThanOrEqualTo(15), reason: 'the second pass hears only the kept audio');
  });

  test('a cut take whose kept audio cannot be transcribed asks for another try', () async {
    final c = controller();
    full.nextFor = (pcm) {
      if (pcm.length <= 15 * 16000) throw const TranscriberError('worker died');
      return words(c.line.text);
    };
    await c.record();
    await mic.say(seconds(26));
    await c.stopAndCheck();
    expect(c.hint, kTranscribeFailedMessage);
    expect(c.index, 0);
    expect(await takes.forPerson(sam.id), isEmpty);
  });

  test('a cut passage still counts as used on add more', () async {
    final first = controller();
    final passage = first.line.text;
    full.next = () => words(passage);
    await first.record();
    await mic.say(seconds(26));
    await first.stopAndCheck();
    await first.skip();
    sam = (await first.finish())!;
    final earlier = await takes.forPerson(sam.id);
    expect(earlier.single.prompt, passage);
    for (var s = 0; s < 10; s++) {
      final c = ReadingController(
        sam,
        Mood.conversational,
        mic,
        follow,
        full,
        takes,
        people,
        builder,
        random: Random(s),
        earlier: earlier,
      );
      expect(c.lines[0].text, isNot(passage));
    }
  });

  test('silence around an answer does not count toward its 7 s', () async {
    final c = await passageThenAsking();
    final passage = (await takes.forPerson(sam.id)).single.text;
    full.next = () => words('Flying, obviously, every single day.');
    await c.record();
    await mic.say(Float32List.fromList([...Float32List(16000), ...seconds(4), ...Float32List(3 * 16000)]));
    await c.stopAndCheck(); // usually already auto-stopped by the 3 s of quiet
    await until(() => !c.checking);
    final [_, answer] = await takes.forPerson(sam.id);
    expect(answer.fromScript, isFalse);
    expect(answer.seconds, lessThan(5), reason: 'stored trimmed: 4 s of speech plus a little room');
    final p = await c.finish();
    expect(p!.refFor(Mood.conversational).refText, passage, reason: 'only 4 s of speech, so the passage is used');
  });

  test('a long answer is cut and stores the words heard in what is kept', () async {
    final c = await asking();
    final said = List.generate(50, (i) => 'word$i').join(' ');
    final kept = said.split(' ').take(33).join(' ');
    // Meme (2026-11-16): the audio ran a word past its transcript, and Qwen skipped the start of lines.
    full.nextFor = (pcm) => words(pcm.length > 15 * 16000 ? said : kept);
    await c.record();
    await mic.say(seconds(21));
    await c.stopAndCheck();
    final p = await c.finish();
    expect(p, isNotNull, reason: c.error);
    final ref = p!.refFor(Mood.conversational);
    expect(ref.seconds, lessThanOrEqualTo(15));
    expect(ref.refText, kept);
  });

  group('answer meter', () {
    Future<void> answer(ReadingController c, double s, String said) async {
      full.next = () => words(said);
      await c.record();
      await mic.say(seconds(s));
      await c.stopAndCheck();
      await until(() => !c.checking);
    }

    test('a short answer asks one more question instead of finishing', () async {
      final c = await passageThenAsking();
      final first = c.line.text;
      expect(c.fill, VoiceFill.basic);
      await answer(c, 4, 'Flying, obviously, every single day.');
      expect(c.done, isFalse);
      expect(c.moreAnswers, isTrue);
      expect(c.line.openPrompt, isTrue);
      expect(c.line.text, isNot(first), reason: 'the next question');
      expect(c.answerSeconds, inInclusiveRange(3.5, 5), reason: 'the quiet before and after is trimmed off');
      expect(c.fill, VoiceFill.basic);
    });

    test('answers adding up to 7 s finish by themselves', () async {
      final c = await passageThenAsking();
      await answer(c, 4, 'Flying, obviously, every single day.');
      await answer(c, 4, 'Pizza with pineapple, and I will not apologize.');
      expect(c.done, isTrue);
      expect(c.fill, VoiceFill.good);
    });

    test('Finish at Basic builds from the passage', () async {
      final c = await passageThenAsking();
      final passage = (await takes.forPerson(sam.id)).single.text;
      await answer(c, 4, 'Flying, obviously, every single day.');
      c.finishAnswers();
      expect(c.done, isTrue);
      final p = await c.finish();
      expect(p!.refFor(Mood.conversational).refText, passage);
    });

    test('earlier answers count when adding more, not when re-recording', () async {
      final first = await asking();
      await answer(first, 8, 'A long first answer that easily fills eight seconds of talking.');
      sam = (await first.finish())!;
      final earlier = await takes.forPerson(sam.id);
      ReadingController again({required bool replace}) {
        final c = ReadingController(
          sam,
          Mood.conversational,
          mic,
          follow,
          full,
          takes,
          people,
          builder,
          random: Random(2),
          earlier: earlier,
          replace: replace,
          kind: SessionKind.story,
        );
        full.next = () => words(c.line.text);
        return c;
      }

      final more = again(replace: false);
      expect(more.fill, VoiceFill.good, reason: 'the earlier 8 s answer still counts');
      final redo = again(replace: true);
      expect(redo.fill, VoiceFill.basic);
      await toQuestion(redo);
      await answer(redo, 2, 'Short one.');
      expect(redo.done, isFalse, reason: 'only this session counts when re-recording');
    });

    test('answers the voice will use wait for a word check, and fixes reach the voice', () async {
      // Owner, 2026-11-16: "I have to worry" for "I don't have to worry" sent Qwen into lines
      // that never ended.
      final c = await passageThenAsking();
      await answer(c, 4, 'I have to worry about falling.');
      await answer(c, 4, 'Pizza with pineapple, obviously.');
      expect(c.done, isTrue);
      expect(c.needsWordCheck, isTrue);
      expect(c.answersToCheck.map((t) => t.text), [
        'I have to worry about falling.',
        'Pizza with pineapple, obviously.',
      ]);
      await c.setAnswerText(c.answersToCheck.first, "I don't have to worry about falling.");
      c.confirmWords();
      expect(c.needsWordCheck, isFalse);
      final p = await c.finish();
      expect(p!.refFor(Mood.conversational).refText, contains("I don't have to worry about falling."));
    });

    test('a voice from the passage needs no word check', () async {
      final c = await passageThenAsking();
      await answer(c, 4, 'Flying, obviously, every single day.');
      c.finishAnswers();
      expect(c.done, isTrue);
      expect(c.needsWordCheck, isFalse, reason: 'under 7 s of answers: the passage, with its exact words, is used');
    });

    test('fill is full once 15 s are spoken', () async {
      // A saved answer is cut in a pause before 15 s, so Full shows while still talking: the cue to stop.
      final c = await asking();
      await c.record();
      await mic.say(seconds(16));
      expect(c.fill, VoiceFill.full);
    });

    test('the meter counts the answer while it is being recorded', () async {
      final c = await asking();
      await c.record();
      await mic.say(seconds(3));
      expect(c.answerSeconds, closeTo(2.5, 0.3), reason: 'from the first word to the last so far');
    });
  });

  test('a voice built for a person who expired meanwhile leaves no file', () async {
    final c = controller();
    await readGood(c);
    await people.delete(sam.id); // expired while the take was being checked
    full.next = () => words('Flying, obviously, every single day of the week.');
    await c.record();
    await mic.say(Float32List.fromList([...goodTake(), ...goodTake()]));
    await c.stopAndCheck();
    expect(await c.finish(), isNull);
    final refs = Directory('${dir.path}/refs');
    expect(refs.existsSync() ? refs.listSync() : const [], isEmpty);
  });

  test('an unexpected error while building shows a message instead of hanging', () async {
    final c = ReadingController(sam, Mood.conversational, mic, follow, full, takes, people, _BrokenBuilder(dir, takes));
    full.next = () => words(c.line.text);
    await readGood(c);
    await c.skip();
    expect(await c.finish(), isNull);
    expect(c.error, kBuildFailedMessage);
    expect(c.building, isFalse);
  });

  test('answer takes remember their question', () async {
    final first = controller();
    final shown = first.line.text;
    await readGood(first);
    final c = await asking();
    final prompt = c.line.text;
    full.next = () => words('Flying, obviously.');
    await readGood(c);
    final [passage, answer] = await takes.forPerson(sam.id);
    expect(passage.prompt, shown, reason: 'a passage take remembers its passage too');
    expect(answer.prompt, prompt);
    expect(Take.fromJson(answer.toJson()).prompt, prompt);
    expect(Take.fromJson(answer.toJson()..remove('prompt')).prompt, isNull, reason: 'older takes read');
  });

  test('add more avoids the passage and question already used', () async {
    final first = controller();
    await readGood(first);
    sam = (await first.finish())!;
    final story = await asking();
    final usedPrompt = story.line.text;
    full.next = () => words('Flying, obviously.');
    await readGood(story);
    final earlier = await takes.forPerson(sam.id);
    for (var s = 0; s < 10; s++) {
      final c = ReadingController(
        sam,
        Mood.conversational,
        mic,
        follow,
        full,
        takes,
        people,
        builder,
        random: Random(s),
        earlier: earlier,
      );
      expect(c.lines[0].text, isNot(earlier.first.text));
      final again = await asking(random: Random(s), earlier: earlier);
      expect(again.line.text, isNot(usedPrompt));
    }
  });

  test('changing the passage on add more keeps earlier passage takes', () async {
    final first = controller();
    await readGood(first);
    sam = (await first.finish())!;
    final earlier = await takes.forPerson(sam.id);
    final c = ReadingController(sam, Mood.conversational, mic, follow, full, takes, people, builder, earlier: earlier);
    full.next = () => words(c.line.text);
    await readGood(c);
    expect(await takes.forPerson(sam.id), hasLength(2));
    await c.changePassage();
    expect(c.line.text, isNot(earlier.first.text), reason: 'the swap also avoids used passages');
    final left = await takes.forPerson(sam.id);
    expect(left.map((t) => t.id), [earlier.single.id], reason: "only this session's passage take goes");
  });

  test('answer of 7 s or more builds the reference', () async {
    final c = await passageThenAsking();
    full.next = () => words('Honestly the traffic this morning was ridiculous');
    await c.record();
    await mic.say(longAnswer());
    await c.stopAndCheck();
    final p = await c.finish();
    expect(p!.refFor(Mood.conversational).refText, 'Honestly the traffic this morning was ridiculous');
  });

  test('short answer falls back to the passage', () async {
    final c = await passageThenAsking();
    final passage = (await takes.forPerson(sam.id)).single.text;
    full.next = () => words('Pizza.');
    await readGood(c);
    final p = await c.finish();
    expect(p!.refFor(Mood.conversational).refText, passage);
  });

  test('skip on the passage still allows a voice from the answer', () async {
    final c = await asking();
    full.next = () => words('Honestly the traffic this morning was ridiculous');
    await c.record();
    await mic.say(longAnswer());
    await c.stopAndCheck();
    expect((await c.finish())!.ready, isTrue);
  });

  test('nothing usable keeps voice not ready', () async {
    final c = await asking();
    await c.skip();
    expect(c.done, isTrue);
    expect(await c.finish(), isNull);
    expect(c.error, 'Read the passage or answer the question to make a voice.');
    expect((await people.all()).single.ready, isFalse);
  });

  test('open prompt take uses the transcript as text', () async {
    final c = await asking();
    full.next = () => words('Honestly the traffic this morning was ridiculous');
    await readGood(c);
    final saved = (await takes.forPerson(sam.id)).single;
    expect(saved.text, 'Honestly the traffic this morning was ridiculous');
    expect(saved.fromScript, isFalse);
  });

  test('an open prompt with nothing heard asks again', () async {
    final c = await asking();
    full.next = () => const [];
    await readGood(c);
    expect(c.hint, 'Speak a little louder.');
    expect(await takes.forPerson(sam.id), isEmpty);
  });

  test('a transcription failure still accepts a scripted take', () async {
    final c = controller();
    full.error = const TranscriberError(kTranscribeFailedMessage);
    await readGood(c);
    expect(c.index, 1);
    expect(await takes.forPerson(sam.id), hasLength(1));
  });

  test('finish builds conversational reference and marks person ready', () async {
    final c = await passageThenAsking();
    await readGood(c);
    expect(c.moreAnswers, isTrue, reason: 'one short answer: another question is offered');
    c.finishAnswers();
    expect(c.done, isTrue);
    final p = await c.finish();
    expect(p!.ready, isTrue);
    expect(c.person.ready, isTrue);
    expect((await people.all()).single.ready, isTrue);
    expect(p.refFor(Mood.conversational).seconds, inInclusiveRange(3, 15));
  });

  test('a mood session adds that mood to a ready person', () async {
    final core = controller();
    await readGood(core);
    await readGood(core);
    sam = (await core.finish())!;
    final c = controller(Mood.excited);
    expect(c.total, 3);
    await readGood(c);
    while (!c.done) {
      await c.skip();
    }
    final p = await c.finish();
    expect(p!.recorded(Mood.excited), isTrue);
  });

  Future<Person> withExcited() async {
    final core = controller();
    await readGood(core);
    await readGood(core);
    sam = (await core.finish())!;
    final m = controller(Mood.excited);
    await readGood(m);
    while (!m.done) {
      await m.skip();
    }
    return sam = (await m.finish())!;
  }

  test('abandoned re-record keeps the old voice', () async {
    final before = (await withExcited()).refFor(Mood.excited);
    final c = ReadingController(sam, Mood.excited, mic, follow, full, takes, people, builder, replace: true);
    full.next = () => words(c.line.text);
    await readGood(c);
    await c.abandon();
    final p = (await people.all()).single;
    expect(p.refFor(Mood.excited).clipFile, before.clipFile);
    expect((await takes.forPerson(sam.id)).where((t) => t.mood == Mood.excited), hasLength(2));
  });

  test('re-record replaces the mood once the new voice is built', () async {
    final before = (await withExcited()).refFor(Mood.excited);
    final c = ReadingController(sam, Mood.excited, mic, follow, full, takes, people, builder, replace: true);
    full.next = () => words(c.line.text);
    await readGood(c);
    while (!c.done) {
      await c.skip();
    }
    final p = await c.finish();
    expect(p!.refFor(Mood.excited).clipFile, isNot(before.clipFile));
    expect((await takes.forPerson(sam.id)).where((t) => t.mood == Mood.excited), hasLength(1));
  });

  test('re-record conversational replaces the core voice', () async {
    final core = controller();
    await readGood(core);
    full.next = () => words('First answer.');
    await readGood(core);
    sam = (await core.finish())!;
    final before = sam.refFor(Mood.conversational);
    final c = ReadingController(sam, Mood.conversational, mic, follow, full, takes, people, builder, replace: true);
    full.next = () => words(c.line.text);
    await readGood(c);
    await c.skip();
    final p = await c.finish();
    expect(p!.refFor(Mood.conversational).clipFile, isNot(before.clipFile));
    expect((await takes.forPerson(sam.id)).where((t) => t.mood == Mood.conversational), hasLength(1));
  });

  test('leaving an unfinished core session removes the person', () async {
    final c = controller();
    await readGood(c);
    await c.abandon();
    expect(await people.all(), isEmpty);
    expect(await takes.forPerson(sam.id), isEmpty);
  });

  test('leaving after the voice is built keeps the person', () async {
    final c = controller();
    await readGood(c);
    await readGood(c);
    await c.finish();
    await c.abandon();
    expect((await people.all()).single.ready, isTrue);
  });
}
