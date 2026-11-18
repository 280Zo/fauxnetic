import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/audio/word_timing.dart';

/// [n] frames: loud where [loud] says so, else silent.
List<double> levels(int n, bool Function(int i) loud) => [for (var i = 0; i < n; i++) loud(i) ? 0.8 : 0.0];

void main() {
  test('words share the speech by their length', () {
    final s = estimateWordStarts(['to', 'four'], levels(60, (_) => true), 6);
    expect(s[0], 0);
    expect(s[1], closeTo(2, 0.11), reason: '2 of 6 letters');
  });

  test('silence before the first word is skipped', () {
    final s = estimateWordStarts(['hello'], levels(100, (i) => i >= 25), 4);
    expect(s.single, closeTo(1, 0.05));
  });

  test('a pause holds the next word back instead of drifting', () {
    final s = estimateWordStarts(['hello', 'there'], levels(100, (i) => i < 40 || i >= 60), 5);
    expect(s[1], closeTo(3, 0.06), reason: 'starts after the pause (60%), not at half way');
  });

  test('a gap shorter than a syllable is not a pause', () {
    final s = estimateWordStarts(['ab', 'cd'], levels(100, (i) => i != 30 && i != 31), 2);
    expect(s[1], closeTo(1, 0.05));
  });

  test('numbers count as their spoken words', () {
    final s = estimateWordStarts(['15', 'ok'], levels(90, (_) => true), 9);
    expect(s[1], closeTo(7, 0.11), reason: '"fifteen" is 7 letters, "ok" 2');
  });

  test('a silent clip spreads the words evenly', () {
    final s = estimateWordStarts(['ab', 'cd'], levels(10, (_) => false), 2);
    expect(s, [0, 1]);
  });

  test('no words, no starts', () {
    expect(estimateWordStarts([], levels(10, (_) => true), 1), isEmpty);
  });

  test('the active word is the last one started', () {
    const starts = [0.5, 1.0, 2.0];
    expect(activeWord(starts, 0.2), -1);
    expect(activeWord(starts, 0.5), 0);
    expect(activeWord(starts, 1.9), 1);
    expect(activeWord(starts, 9), 2);
  });
}
