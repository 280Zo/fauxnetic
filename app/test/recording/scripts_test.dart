import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/recording/scripts.dart';
import 'package:fauxnetic/recording/takes.dart';

void main() {
  final contraction = RegExp(r"'s\b|'re\b|'m\b|'ll\b|'ve\b|'d\b|n't\b");
  int words(String s) => s.trim().split(RegExp(r'\s+')).length;
  test('stella is not included', () {
    expect(kPassages.where((p) => p.contains('Stella')), isEmpty);
  });

  // Owner, 2026-11-23: the old lists read like tongue twisters; a big set of natural messages and
  // small stories instead, picked at random.
  test('a big set of passages, each different', () {
    expect(kPassages.length, greaterThanOrEqualTo(15));
    expect(kPassages.toSet(), hasLength(kPassages.length));
    expect(kPassages.where((p) => p.contains('Please ring Martin') || p.contains('Ask Judy')), isEmpty);
  });

  test('every passage has the sounds that are easiest to miss', () {
    // Spelling stand-ins for the sounds (no pronunciation dictionary on the phone or here).
    final sounds = {
      'th as in think': RegExp(
        r"\b(think|thing|things|thank|thanks|three|thought|both|thursday|fourth|thrilled|birthday|thin|nothing|something|everything|theater|month|north|south|thousand|throw|threw|healthy|thick)\b",
      ),
      'th as in this': RegExp(
        r'\b(the|this|that|they|there|then|with|other|together|weather|either|than|those|these|them)\b',
      ),
      'sh': RegExp(r'sh|tion|\bsure'),
      'ch': RegExp(r'ch|tch'),
      'j': RegExp(r'j|dge|g[ei]'),
      'zh as in usually': RegExp(r'usually|measure|pleasure|treasure|garage|vision|casual|beige|television'),
      'ng': RegExp(r'ng'),
      'oy': RegExp(r'oy|oi'),
      'ow': RegExp(r'ou|ow'),
      'v': RegExp(r'v'),
      'y as in yes': RegExp(r"\b(you|your|you're|you'll|yes|yeah|year|years|yellow|yet|young|yesterday)\b"),
    };
    for (final p in kPassages) {
      final text = p.toLowerCase();
      for (final MapEntry(key: name, value: re) in sounds.entries) {
        expect(re.hasMatch(text), isTrue, reason: '$name missing: ${p.substring(0, 40)}');
      }
    }
  });

  test('passages are 45 to 75 words', () {
    for (final p in kPassages) {
      expect(words(p), inInclusiveRange(45, 75), reason: p);
    }
  });

  test('prompts are the approved icebreakers', () {
    expect(kPrompts, [
      'If you could have any superpower for just one day, what would you do with it?',
      "What's the best pizza topping, and why is everyone else wrong?",
      'If you had a walk-up song, what would it be?',
      'Which fictional world would you live in for a week?',
      "What's a food you'll never eat again, and what happened?",
      "You're stuck on a desert island. What three things do you bring?",
      "What's the most useless talent you have?",
      'If animals could talk, which one would be the rudest?',
      "What's your go-to karaoke song?",
      "What's the best concert or show you've ever been to?",
      'If you could instantly master one skill, what would you pick?',
      "What's a hill you'd die on that really doesn't matter?",
      'How would you spend a completely free Saturday?',
      "Tell me about the best meal you've had lately.",
      "What's the weirdest thing you believed as a kid?",
    ]);
  });

  test('no prompt mentions work', () {
    final work = RegExp(r'sprint|meeting|stand-up|retro|team|work', caseSensitive: false);
    expect(kPrompts.where(work.hasMatch), isEmpty);
  });

  test('pick is random but deterministic for a seeded Random', () {
    final a = pickCoreSession(Random(3)), b = pickCoreSession(Random(3));
    expect(a.passage, b.passage);
    expect(a.prompts, b.prompts);
    expect(a.prompts.toSet(), kPrompts.toSet());
    final seen = {for (var s = 0; s < 600; s++) pickCoreSession(Random(s)).passage};
    expect(seen, kPassages.toSet(), reason: 'every passage can come up');
    final firsts = {for (var s = 0; s < 40; s++) pickCoreSession(Random(s)).passage};
    expect(firsts.length, greaterThan(8), reason: 'a new voice does not start with the same one each time');
  });

  Take passageTake(String text) => Take(
    id: text.hashCode.toString(),
    personId: 'p',
    mood: Mood.conversational,
    text: text,
    fromScript: true,
    seconds: 15,
    score: 1,
    file: 'f',
  );
  Take answerTake(String prompt) => Take(
    id: prompt.hashCode.toString(),
    personId: 'p',
    mood: Mood.conversational,
    text: 'An answer.',
    fromScript: false,
    seconds: 9,
    score: 1,
    file: 'f',
    prompt: prompt,
  );

  test('a second session avoids the used passage and questions', () {
    final used = kPrompts.take(3).toList();
    final earlier = [passageTake(kPassages[0]), for (final p in used) answerTake(p)];
    for (var s = 0; s < 50; s++) {
      final c = pickCoreSession(Random(s), earlier: earlier);
      expect(c.passage, isNot(kPassages[0]));
      expect(c.prompts.toSet(), kPrompts.toSet(), reason: 'every question is still reachable');
      expect(used, isNot(contains(c.prompts.first)));
      expect(c.prompts.skip(kPrompts.length - 3).toSet(), used.toSet(), reason: 'used questions come last');
    }
    final firsts = {for (var s = 0; s < 300; s++) pickCoreSession(Random(s), earlier: earlier).passage};
    expect(firsts, kPassages.skip(1).toSet(), reason: 'still random among the unused');
  });

  test('when all passages are used the least used comes back', () {
    final earlier = [
      passageTake(kPassages[0]),
      for (final p in kPassages.skip(1)) ...[passageTake(p), passageTake(p)],
    ];
    for (var s = 0; s < 20; s++) {
      expect(pickCoreSession(Random(s), earlier: earlier).passage, kPassages[0]);
    }
  });

  test('storytelling keeps its pack of 3 lines', () {
    final pack = scriptFor(Mood.storytelling, Random(1));
    expect(pack.length, 3);
    expect(pack.every((l) => !l.openPrompt && l.phrase == null), isTrue);
    expect(pack.where((l) => contraction.hasMatch(l.text)).length / 3, greaterThanOrEqualTo(0.6));
    for (final l in pack) {
      expect(words(l.text), inInclusiveRange(6, 22), reason: l.text);
    }
  });

  String bare(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z ]'), '');

  test('each sentence set is one sentence said five ways, each with its scene', () {
    expect(kPhraseSets, hasLength(4));
    for (final set in kPhraseSets) {
      expect([for (final l in set) l.phrase], PhraseTone.values);
      expect({for (final l in set) bare(l.text)}, hasLength(1), reason: 'the same words: ${set.first.text}');
      expect(set[PhraseTone.question.index].text, endsWith('?'));
      expect(set[PhraseTone.excited.index].text, endsWith('!'));
      expect(set[PhraseTone.worried.index].text, endsWith('...'));
      for (final l in set) {
        expect(l.scene, isNotEmpty, reason: l.text);
        expect(words(l.text), inInclusiveRange(4, 8), reason: l.text);
      }
    }
    expect(PhraseTone.plain.mood, isNull);
    expect(PhraseTone.question.mood, isNull);
    expect(
      [PhraseTone.excited.mood, PhraseTone.annoyed.mood, PhraseTone.worried.mood],
      [Mood.excited, Mood.annoyed, Mood.worried],
    );
  });

  Take phraseTake(ScriptLine l) => Take(
    id: l.text.hashCode.toString(),
    personId: 'p',
    mood: l.phrase!.mood ?? Mood.conversational,
    text: l.text,
    fromScript: true,
    seconds: 2,
    score: 1,
    file: 'f',
    prompt: l.text,
    phrase: l.phrase!.name,
  );

  test('a feelings session brings one sentence set, the one used least', () {
    expect(kPhraseSets, contains(pickPhraseSet(Random(1))));
    final earlier = [for (final l in kPhraseSets[0]) phraseTake(l), for (final l in kPhraseSets[1]) phraseTake(l)];
    for (var s = 0; s < 30; s++) {
      expect([kPhraseSets[2], kPhraseSets[3]], contains(pickPhraseSet(Random(s), earlier: earlier)));
    }
  });

  test('resuming keeps the passage already read', () {
    for (var s = 0; s < 10; s++) {
      expect(resumeCoreSession(Random(s), earlier: [passageTake(kPassages[2])]).passage, kPassages[2]);
    }
    expect(kCoreLines, 1, reason: 'the passage alone (owner, 2026-11-23)');
  });

  Take storyTake(String line) => Take(
    id: line.hashCode.toString(),
    personId: 'p',
    mood: Mood.conversational,
    text: line,
    fromScript: true,
    seconds: 5,
    score: 1,
    file: 'f',
    prompt: line,
    story: true,
  );

  test('stories: four, five lines each, about a minute aloud', () {
    expect(kStories, hasLength(4));
    for (final s in kStories) {
      expect(s, hasLength(5));
      final n = s.fold<int>(0, (a, l) => a + words(l));
      expect(n, inInclusiveRange(90, 160), reason: s.first);
    }
  });

  test('a story session reads the story read least', () {
    final earlier = [for (final l in kStories[0]) storyTake(l), for (final l in kStories[2]) storyTake(l)];
    for (var s = 0; s < 30; s++) {
      final lines = storyLines(Random(s), earlier: earlier);
      expect([kStories[1].first, kStories[3].first], contains(lines.first.text));
      expect(lines, hasLength(5));
      expect(lines.every((l) => l.story && !l.openPrompt && l.phrase == null), isTrue);
    }
  });

  test('story takes do not count as the passage read', () {
    final earlier = [for (final s in kStories) ...s.map(storyTake)];
    final seen = {for (var s = 0; s < 600; s++) pickCoreSession(Random(s), earlier: earlier).passage};
    expect(seen, kPassages.toSet());
  });

  test('sentence takes do not count as the passage read', () {
    final earlier = [for (final set in kPhraseSets) ...set.map(phraseTake)];
    final seen = {for (var s = 0; s < 600; s++) pickCoreSession(Random(s), earlier: earlier).passage};
    expect(seen, kPassages.toSet());
  });

  test("excited, annoyed and worried sessions read that mood's sentence from 3 sets, least used first", () {
    for (final m in [Mood.excited, Mood.annoyed, Mood.worried]) {
      final lines = scriptFor(
        m,
        Random(2),
        earlier: [phraseTake(kPhraseSets[0].firstWhere((l) => l.phrase?.mood == m))],
      );
      expect(lines, hasLength(3));
      expect(lines.every((l) => l.phrase?.mood == m && (l.scene ?? '').isNotEmpty), isTrue);
      expect(lines.map((l) => l.text), isNot(contains(kPhraseSets[0].firstWhere((l) => l.phrase?.mood == m).text)));
    }
  });

  test('mood labels', () {
    expect(Mood.values.map((m) => m.label), ['Conversational', 'Excited', 'Annoyed', 'Worried', 'Storytelling']);
  });
}
