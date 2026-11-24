import 'dart:math';

import 'takes.dart';

enum Mood {
  conversational('Conversational'),
  excited('Excited'),
  annoyed('Annoyed'),
  worried('Worried'),
  storytelling('Storytelling');

  const Mood(this.label);
  final String label;
}

class ScriptLine {
  const ScriptLine(this.text, {this.openPrompt = false, this.scene, this.phrase});
  final String text;

  /// Answered in the person's own words instead of read; transcribed on the phone.
  final bool openPrompt;

  /// Shown before a sentence line: the moment to say it in.
  final String? scene;

  /// For one sentence said several ways: which way this is.
  final PhraseTone? phrase;
}

/// The ways one sentence is said in the core session (owner, 2026-11-23). Plain and question go
/// with the conversational voice; the others make that mood's voice.
enum PhraseTone {
  plain(null),
  question(null),
  excited(Mood.excited),
  annoyed(Mood.annoyed),
  worried(Mood.worried);

  const PhraseTone(this.mood);
  final Mood? mood;
}

/// One sentence said five ways, each after a scene that sets it up. A session uses one set.
const kPhraseSets = [
  [
    ScriptLine(
      "You're coming home tonight.",
      scene: 'Telling a friend the plan, matter-of-fact',
      phrase: PhraseTone.plain,
    ),
    ScriptLine(
      "You're coming home tonight?",
      scene: "Your friend just said it, and you're surprised. Ask them",
      phrase: PhraseTone.question,
    ),
    ScriptLine("You're coming home tonight!", scene: "You've missed them for months", phrase: PhraseTone.excited),
    ScriptLine(
      "You're coming home tonight.",
      scene: 'They promised to stay and help you move',
      phrase: PhraseTone.annoyed,
    ),
    ScriptLine(
      "You're coming home tonight...",
      scene: "There's a storm warning on the roads",
      phrase: PhraseTone.worried,
    ),
  ],
  [
    ScriptLine(
      'They moved the meeting to Friday.',
      scene: 'Telling a coworker the news, matter-of-fact',
      phrase: PhraseTone.plain,
    ),
    ScriptLine(
      'They moved the meeting to Friday?',
      scene: "A coworker just told you, and you can't believe it. Ask them",
      phrase: PhraseTone.question,
    ),
    ScriptLine(
      'They moved the meeting to Friday!',
      scene: 'Friday means you get the long weekend you wanted',
      phrase: PhraseTone.excited,
    ),
    ScriptLine(
      'They moved the meeting to Friday.',
      scene: 'You already cancelled your Friday plans for them once',
      phrase: PhraseTone.annoyed,
    ),
    ScriptLine(
      'They moved the meeting to Friday...',
      scene: "Your big presentation isn't ready yet",
      phrase: PhraseTone.worried,
    ),
  ],
  [
    ScriptLine(
      'She sold the old car.',
      scene: "Telling a friend what's new with your sister",
      phrase: PhraseTone.plain,
    ),
    ScriptLine(
      'She sold the old car?',
      scene: "You thought she'd never part with it. Ask",
      phrase: PhraseTone.question,
    ),
    ScriptLine('She sold the old car!', scene: "She's been saving for a new one for years", phrase: PhraseTone.excited),
    ScriptLine('She sold the old car.', scene: 'She promised it to you first', phrase: PhraseTone.annoyed),
    ScriptLine(
      'She sold the old car...',
      scene: 'It was the only way she could get to work',
      phrase: PhraseTone.worried,
    ),
  ],
  [
    ScriptLine(
      "We're going to the beach tomorrow.",
      scene: 'Telling your family the weekend plan',
      phrase: PhraseTone.plain,
    ),
    ScriptLine(
      "We're going to the beach tomorrow?",
      scene: 'Your partner just announced it out of nowhere. Ask',
      phrase: PhraseTone.question,
    ),
    ScriptLine(
      "We're going to the beach tomorrow!",
      scene: "You've been begging to go all summer",
      phrase: PhraseTone.excited,
    ),
    ScriptLine(
      "We're going to the beach tomorrow.",
      scene: 'You have a huge deadline and nobody asked you',
      phrase: PhraseTone.annoyed,
    ),
    ScriptLine(
      "We're going to the beach tomorrow...",
      scene: 'The forecast says a big storm is coming in',
      phrase: PhraseTone.worried,
    ),
  ],
];

/// The sentence sets from least to most used in [earlier] takes (shuffled within each count).
List<List<ScriptLine>> _setsByUse(Random r, List<Take> earlier) {
  final used = [
    for (final t in earlier)
      if (t.phrase != null) t.prompt ?? t.text,
  ];
  final count = [for (final s in kPhraseSets) used.where((u) => s.any((l) => l.text == u)).length];
  final order = List.generate(kPhraseSets.length, (i) => i)..shuffle(r);
  order.sort((a, b) => count[a].compareTo(count[b]));
  return [for (final i in order) kPhraseSets[i]];
}

/// Moods without a way of saying the sentence keep a pack of their own (excited, annoyed and
/// worried read from [kPhraseSets] since 2026-11-23).
const _packs = {
  Mood.storytelling: [
    ScriptLine("So there I was, halfway up the mountain, and it's starting to snow."),
    ScriptLine("My grandfather used to say he'd once outrun a bear, and we believed him."),
    ScriptLine("Anyway, we finally find the cabin, and guess who's sitting on the porch?"),
  ],
};

/// Passages for the core session, each covering (nearly) every English sound. One is picked at random per person.
/// All three cloned the owner's voice as well as the "Please call Stella" research passage in a 100-clone test
/// (2026-11-15), so the app needs no third-party text.
const kPassages = [
  "Hey, it's me. Could you grab the big yellow jug of oat milk on your way home? Actually, never mind, I think "
      "there's enough. Oh, and the thing about Joseph's birthday? It's usually this Thursday, but the boy wants it "
      'all pushed to Friday, so check with the shop about the cake!',
  'Please ring Martin. Tell him to pick up these things on his way from the market: three crisp green apples, two '
      "jars of fresh strawberry jam, and a large sack of brown rice for his sister Grace. We'll also need a thick wool "
      'scarf, a cheap toy drum, and some splashy paint for the boys. He can usually pack it all into six blue boxes and '
      'meet us Thursday at the bus stop.',
  'Ask Judy to call the shop before noon. She needs to order these items for the party on Saturday: four bags of '
      'frozen shrimp, a dozen thin slices of smoked ham, and a big jug of orange juice for her nephew Paul. We should '
      "also bring a small blue tablecloth and a pair of plastic toy swords for the children. She'll measure everything "
      'twice, then drive it around to the old church at three.',
];

/// Fun, general icebreakers answered in the person's own words; the person can skip to the next one.
const kPrompts = [
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
];

/// One random passage, one sentence set, and the prompts in a random order (the first is shown first).
class CoreSession {
  const CoreSession(this.passage, this.prompts, this.phrases);
  final String passage;
  final List<String> prompts;

  /// One sentence said five ways, between the passage and the question.
  final List<ScriptLine> phrases;
}

/// Prefers the passage and questions this person hasn't used in [earlier] takes, picking at random
/// among them; once all are used, the least used come back. Used questions go to the end.
CoreSession pickCoreSession(Random r, {List<Take> earlier = const []}) {
  // A cut passage take holds only part of the passage; prompt is the full line shown.
  final read = [
    for (final t in earlier)
      if (t.fromScript && t.phrase == null) t.prompt ?? t.text,
  ];
  final asked = [
    for (final t in earlier)
      if (!t.fromScript && t.prompt != null) t.prompt!,
  ];
  final passages = leastUsed(kPassages, read, r);
  return CoreSession(passages[r.nextInt(passages.length)], byUse(kPrompts, asked, r), _setsByUse(r, earlier).first);
}

/// The [options] used the fewest times in [used].
List<String> leastUsed(List<String> options, List<String> used, Random r) {
  final byCount = byUse(options, used, r);
  final least = used.where((u) => u == byCount.first).length;
  return byCount.where((o) => used.where((u) => u == o).length == least).toList();
}

/// [options] from least to most used in [used], shuffled within each count.
List<String> byUse(List<String> options, List<String> used, Random r) {
  final groups = <int, List<String>>{};
  for (final o in options) {
    groups.putIfAbsent(used.where((u) => u == o).length, () => []).add(o);
  }
  return [for (final n in groups.keys.toList()..sort()) ...(groups[n]!..shuffle(r))];
}

/// The lines for a mood session. Excited, annoyed and worried read their way of saying the
/// sentence from three sets, least used in [earlier] first; storytelling has its own pack. The
/// conversational voice uses [pickCoreSession] instead.
List<ScriptLine> scriptFor(Mood m, Random r, {List<Take> earlier = const []}) {
  if (m == Mood.conversational) {
    throw ArgumentError.value(m, 'm', 'the conversational session uses pickCoreSession');
  }
  final tone = PhraseTone.values.where((t) => t.mood == m).firstOrNull;
  if (tone == null) return _packs[m]!;
  // Plain and annoyed share their words, so use is counted per way of saying it.
  final used = [
    for (final t in earlier)
      if (t.phrase == tone.name) t.prompt ?? t.text,
  ];
  final lines = [for (final s in kPhraseSets) s[tone.index]]..shuffle(r);
  lines.sort((a, b) => used.where((u) => u == a.text).length.compareTo(used.where((u) => u == b.text).length));
  return lines.take(3).toList();
}
