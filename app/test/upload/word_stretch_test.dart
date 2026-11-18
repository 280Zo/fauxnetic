import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/recording/transcriber.dart';
import 'package:fauxnetic/ui/check_words_screen.dart';

void main() {
  // Owner, 2026-11-18: tapping a word plays it with the words either side. Word times can be up to a
  // second off (2026-11-16), so the stretch takes the neighbors plus a 0.15 s margin.
  const rate = 16000;
  final clip = Float32List(rate * 4); // 4 s
  const words = [TimedWord('one', 1.0, 1.4, 0.9), TimedWord('two', 1.5, 2.0, 0.4), TimedWord('three', 2.1, 2.5, 0.9)];

  test('stretch covers the word and its neighbors', () {
    final s = wordStretch(clip, rate, words, 1);
    expect(s.length, ((2.65 - 0.85) * rate).round());
  });

  test('stretch at the edges stays inside the clip', () {
    const edge = [TimedWord('first', 0.05, 0.4, 0.9), TimedWord('last', 3.7, 3.95, 0.9)];
    expect(
      wordStretch(clip, rate, edge, 0).length,
      (4.0 * rate).round(),
      reason: '0 to the end of the next word + margin, clamped',
    );
    expect(wordStretch(clip, rate, edge, 1).length, ((4.0 - 0.0) * rate).round());
  });

  test('a word added by a fix has no audio', () {
    expect(wordStretch(clip, rate, [words[0], null, words[2]], 1), isEmpty);
  });
}
