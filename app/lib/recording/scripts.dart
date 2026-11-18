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
  const ScriptLine(this.text, {this.openPrompt = false});
  final String text;

  /// Answered in the person's own words instead of read; transcribed on the phone.
  final bool openPrompt;
}

const _packs = {
  Mood.excited: [
    ScriptLine("No way, you got the tickets? That's amazing, I can't believe it!"),
    ScriptLine("We actually won! I've been waiting all season for this!"),
    ScriptLine("Oh, this is the best news I've heard all year!"),
  ],
  Mood.annoyed: [
    ScriptLine("Seriously? I've asked you three times to put the dishes away."),
    ScriptLine("I'm not waiting another hour just because they can't get organized."),
    ScriptLine("Great, the printer's jammed again, right before the meeting."),
  ],
  Mood.worried: [
    ScriptLine("Has anyone heard from her? She's usually home by now."),
    ScriptLine("I don't know, the doctor said they'd call yesterday and they haven't."),
    ScriptLine("What if the bridge is closed and we can't get back tonight?"),
  ],
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

/// One random passage and the prompts in a random order (the first is shown first).
class CoreSession {
  const CoreSession(this.passage, this.prompts);
  final String passage;
  final List<String> prompts;
}

/// Prefers the passage and questions this person hasn't used in [earlier] takes, picking at random
/// among them; once all are used, the least used come back. Used questions go to the end.
CoreSession pickCoreSession(Random r, {List<Take> earlier = const []}) {
  // A cut passage take holds only part of the passage; prompt is the full line shown.
  final read = [
    for (final t in earlier)
      if (t.fromScript) t.prompt ?? t.text,
  ];
  final asked = [
    for (final t in earlier)
      if (!t.fromScript && t.prompt != null) t.prompt!,
  ];
  final passages = leastUsed(kPassages, read, r);
  return CoreSession(passages[r.nextInt(passages.length)], byUse(kPrompts, asked, r));
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

/// The short pack for a mood. The conversational voice uses [pickCoreSession] instead.
List<ScriptLine> scriptFor(Mood m) =>
    _packs[m] ?? (throw ArgumentError.value(m, 'm', 'the conversational session uses pickCoreSession'));
