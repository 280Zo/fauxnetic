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
  const ScriptLine(this.text, {this.openPrompt = false, this.scene, this.phrase, this.story = false});
  final String text;

  /// A line of a story read to make the main voice sound more like the person.
  final bool story;

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
  // Owner, 2026-11-23: natural everyday messages and small stories, not tongue twisters. Each has
  // the sounds easiest to miss (see scripts_test).
  "Hi, it's me. I'm running about ten minutes late, the traffic on the bridge is terrible again. Could you start the "
      "oven? Set it to three-fifty and put in the lasagna dish, it's on the kitchen counter. Oh, and if Mia calls, tell her "
      "the soccer game moved to Sunday. The boys will be thrilled. Thanks, I'll usually park in the garage, so leave "
      'the door open for me.',
  'So we finally tried that little Thai place on Fourth Street. The noodles were great, but the real treasure was '
      "dessert: mango with sticky rice. The owner's boy brought it over with a huge grin. You should come with us next "
      "time, maybe Thursday? I think they're closed on Mondays, so check before you drive over.",
  'Good morning! Quick reminder that the plumber is coming between nine and noon. He needs to get under the kitchen '
      'sink, so please move the dish soap and cleaning stuff out of that cabinet. He usually takes about an hour. The dog will bark '
      "the whole time, which is annoying but fine. I'll be back around lunch with juice and groceries. Thank you!",
  'Guess what? Grandma finally learned to video call. She held the phone so close that all we could see was her nose '
      "and one eyebrow, and we couldn't stop laughing. She showed us her garden and a giant zucchini she wants us to "
      "measure. She really enjoys it now. Next month you'll have to join us, she asks about you every time.",
  "Hey, are you still up for the hike on Saturday? The weather looks perfect, sunny and cool. I'll just bring sandwiches, "
      'water and that trail mix with the chocolate chips. We should leave by seven, the parking lot usually fills up '
      "fast. Tell Roy he's welcome too, there's room for both of you. Text me if you'd rather do a shorter climb.",
  "Okay, the movie last night was way better than I expected. I won't spoil it, but there's a scene on a frozen lake "
      'that had the whole theater gasping and shouting. Usually I fall asleep during these things, but not this time. '
      "Let's watch the first one together, you choose the drinks and I'll just bring the popcorn.",
  'Hi, this is a message for Jenny. Your package arrived, but it was too big for the mailbox, so the driver left it '
      "with me next door. It's in my garage, just knock when you get home, no rush. Oh, and your sunflowers look amazing "
      'this year. My boys keep asking how you get them so tall. Thanks again for the eggs, by the way, they were so much '
      'better than the store ones.',
  "Morning! I'm at the farmers market and they have those peaches you love, the really juicy ones. Should I grab a "
      'dozen? They also have fresh bread, goat cheese and a jar of honey that smells like flowers. The line is long, but '
      "I'm enjoying the music, a man playing guitar under a tree. They usually sell out by noon, and I thought of you.",
  'So the car made that strange noise again this morning, a loud clunk every time I turned left. I took it to the '
      "garage on Main Street and they think it's something with the steering. They'll check it and call by four. Until "
      "then, could you just pick up the kids from school? I'm sure it's nothing big. I'll owe you, and dinner's on me.",
  "Happy birthday! I hope you're having the best day. I wish I could be there to sing badly and eat way too much cake "
      "with you. Your present is on its way, a little late, but I think you'll enjoy it. Let's celebrate properly next "
      "weekend, maybe that jazz bar you mentioned? It would be a pleasure. Call me tonight, I want to hear everything.",
  'Hey, quick question about the trip. Do we still need to book the cabin by Friday? I checked and there are only two '
      'left with a view of the lake. They usually go fast. One has a hot tub, the other has a huge fireplace and a porch '
      "with rocking chairs. Honestly, I'd enjoy the fireplace more. Just let me know what you think and I'll book it "
      'tonight.',
  "Remember that bakery near the old train station? It's open again! The new owners kept the same recipes, so the "
      "cinnamon rolls taste the way they usually did. Their young son helps at the counter, and he's a joy. I bought "
      "four this morning and ate two in the car, no shame. Let's go together after lunch on Tuesday, I think you'd "
      'love it.',
  "Hi, it's your neighbor from across the street. Your cat is sitting on my porch again, looking very pleased with "
      "himself. He's fine, just a bit muddy. I gave him some water and now he's asleep in the sun. He usually goes home "
      "by six, but I'm happy to bring him over after dinner. Good boy, honestly. Thanks, and no hurry at all, I'm sure "
      'you have a busy evening.',
  'Guess who finally fixed the bike? Me! It took a whole afternoon, a video, and way too much coffee, but the chain is '
      'back on and the brakes actually work. I rode it to the beach and back without a single problem. Next weekend both '
      "of us should ride the coast road together, the views are a real treasure. You'll enjoy it. Bring a jacket, it "
      'gets chilly.',
  "Hey, it's me again. I found your sunglasses! They were under the seat in my car the whole time. I'll drop them off "
      'tomorrow on my way to the gym, around seven. If you\'re not up yet, I\'ll leave them in your mailbox. Oh, and I '
      'usually have no choice but to shout through the window, so this time I\'ll just text you. Thanks for the ride '
      'home yesterday.',
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

/// The questions for a story session, least asked in [earlier] first (shuffled within each count).
List<String> pickPrompts(Random r, {List<Take> earlier = const []}) => byUse(kPrompts, [
  for (final t in earlier)
    if (!t.fromScript && t.prompt != null) t.prompt!,
], r);

/// The sentence said five ways for a feelings session: the set used least in [earlier].
List<ScriptLine> pickPhraseSet(Random r, {List<Take> earlier = const []}) => _setsByUse(r, earlier).first;

/// Short stories, read after the main voice to make it sound more like the person (owner,
/// 2026-11-23). About a minute each, relaxed and natural.
const kStories = [
  [
    'Last summer my uncle took us fishing on a little lake up north, and he swore it was the best spot in the whole state.',
    'We rowed out before sunrise, wrapped in blankets, while the fog was still sitting on the water like smoke.',
    'For two hours, nothing. Not a single bite. My cousin fell asleep with his fishing rod in his lap.',
    'Then, just as we were giving up, something pulled so hard that my uncle nearly went over the side.',
    'It turned out to be his own hat, which had blown off the day before. He still tells everyone it was a fish.',
  ],
  [
    "When I was about eight, our neighbor's goat got loose and decided our garden was the perfect place for breakfast.",
    'My mom ran out in her bathrobe, waving a broom, and the goat just looked at her and kept chewing the lettuce.',
    'My brother tried to lure it away with an apple, but it ate the apple and then started on his shoelaces.',
    'In the end it was our old dog who solved it. He barked once, very politely, and the goat trotted home.',
    'We never got our lettuce back, but every summer after that, the neighbor brought us a basket of tomatoes.',
  ],
  [
    'The first time I tried to bake bread, I followed the recipe exactly, or at least I thought I did.',
    'I mixed everything, covered the bowl with a towel, and went out for a long walk while it rose.',
    'When I came back, the dough had climbed out of the bowl, over the counter, and halfway down the cupboard.',
    'I scraped it all into a pan, baked it anyway, and it came out shaped like a giant mushroom.',
    "It was honestly delicious. Now every time I bake, my friends ask if I'm making the mushroom again.",
  ],
  [
    'On my first day in a new city, I got completely lost looking for a coffee shop a friend swore was around the corner.',
    'I walked in circles for almost an hour, past the same little bakery three times, until the man inside started waving.',
    'Finally I gave up and went in to ask for directions, mostly because I was too embarrassed to walk past him again.',
    'He laughed, handed me a warm croissant, and told me the coffee shop had closed years ago.',
    'I still go to that bakery every week. It turns out it makes the best coffee in town anyway.',
  ],
];

/// The story for a story session: the one read least in [earlier] (random among equals).
List<ScriptLine> storyLines(Random r, {List<Take> earlier = const []}) {
  final read = [
    for (final t in earlier)
      if (t.story) t.prompt ?? t.text,
  ];
  final order = List.generate(kStories.length, (i) => i)..shuffle(r);
  int used(int i) => read.where(kStories[i].contains).length;
  order.sort((a, b) => used(a).compareTo(used(b)));
  return [for (final l in kStories[order.first]) ScriptLine(l, story: true)];
}

/// Prefers the passage and questions this person hasn't used in [earlier] takes, picking at random
/// among them; once all are used, the least used come back. Used questions go to the end.
CoreSession pickCoreSession(Random r, {List<Take> earlier = const []}) {
  // A cut passage take holds only part of the passage; prompt is the full line shown.
  final read = [
    for (final t in earlier)
      if (t.isPassage) t.prompt ?? t.text,
  ];
  final asked = [
    for (final t in earlier)
      if (!t.fromScript && t.prompt != null) t.prompt!,
  ];
  final passages = leastUsed(kPassages, read, r);
  return CoreSession(passages[r.nextInt(passages.length)], byUse(kPrompts, asked, r));
}

/// Lines in a core session: the passage alone (owner, 2026-11-23: the story, with a question in
/// the person's own words, and the feelings are offered after the voice is made).
const kCoreLines = 1;

/// Continuing a core session that was cut short (2026-11-23: an install killed the app mid-session):
/// the passage already read in [earlier], so the take kept fits the line shown.
CoreSession resumeCoreSession(Random r, {List<Take> earlier = const []}) {
  final fresh = pickCoreSession(r, earlier: earlier);
  final read = [
    for (final t in earlier)
      if (t.isPassage) t.prompt ?? t.text,
  ].where(kPassages.contains);
  return CoreSession(read.lastOrNull ?? fresh.passage, fresh.prompts);
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
