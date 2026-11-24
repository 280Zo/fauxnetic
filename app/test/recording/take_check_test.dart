import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/recording/take_check.dart';

import '../support/signals.dart';

const _rate = kRate;

void main() {
  test('quiet tone is tooQuiet', () {
    expect(checkTake(Float32List.fromList(tone(3, -50))), TakeProblem.tooQuiet);
  });

  test('clipped tone is clipping', () {
    final clipped = tone(3, -3).map((s) => s.clamp(-0.99, 0.99)).toList();
    expect(checkTake(Float32List.fromList(clipped)), TakeProblem.clipping);
  });

  test('a background close to the voice is noisy', () {
    expect(checkTake(bursts(-25, -40)), TakeProblem.noisy);
    expect(checkTake(bursts(-30, -42)), TakeProblem.noisy);
  });

  test('a steady hum under clear, close speech is fine', () {
    // Owner, 2026-11-23: an office HVAC rejected four takes spoken straight into the phone. The
    // check used a fixed limit for the room (-45 dBFS), not how far the voice stands out.
    expect(checkTake(bursts(-20, -42)), isNull);
    expect(checkTake(bursts(-15, -38)), isNull);
  });

  test('missed words', () {
    expect(
      checkTake(bursts(-20, -70), script: "It's a quiet morning on the farm today.", heard: "It's a quiet day."),
      TakeProblem.missedWords,
    );
  });

  test('good take', () {
    final pcm = bursts(-20, -70);
    expect(checkTake(pcm), isNull);
    expect(checkTake(pcm, script: "I'll call you back.", heard: ' i’ll call you back'), isNull);
    expect(takeHint(checkTake(pcm)), 'Good level. Room is quiet.');
  });

  test('a silent take is tooQuiet', () {
    expect(checkTake(Float32List(_rate * 2)), TakeProblem.tooQuiet);
    expect(checkTake(Float32List(0)), TakeProblem.tooQuiet);
  });

  test('hints use the exact copy', () {
    expect(takeHint(TakeProblem.tooQuiet), 'Speak a little louder.');
    expect(takeHint(TakeProblem.clipping), 'Move the phone a bit further away.');
    expect(takeHint(TakeProblem.noisy), "It's noisy here. Try a quieter spot.");
    expect(takeHint(TakeProblem.missedWords), 'We missed some words. Try that line again.');
  });

  test('word error rate matches the harness normalisation', () {
    expect(wordErrorRate('Hello, World!', 'hello world'), 0);
    expect(wordErrorRate('one two three four', 'one three four'), 0.25);
    expect(wordErrorRate('a b', 'x y z'), 1.5);
    expect(wordErrorRate('', 'anything'), 1);
    expect(wordErrorRate('one\ntwo', 'one two'), 0);
  });

  test('level meter bars are normalized', () {
    final m = LevelMeter();
    expect(m.recentBars(4), [0, 0, 0, 0]);
    m.add(Float32List.fromList(tone(0.05, -50)));
    m.add(Float32List.fromList(tone(0.05, -10)));
    m.add(Float32List.fromList(tone(0.05, 6)));
    expect(m.levelDb, closeTo(0, 0.01));
    final bars = m.recentBars(4);
    expect(bars.length, 4);
    expect(bars.every((b) => b >= 0 && b <= 1), isTrue);
    expect(bars[0], 0);
    expect(bars[1], lessThan(bars[2]));
    expect(bars[3], 1);
  });
}
