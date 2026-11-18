import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/cues/cue.dart';
import 'package:fauxnetic/recording/scripts.dart';

void main() {
  final ready = DateTime.utc(2026, 11, 14, 12);
  CueItem item(CueStatus s) => CueItem(
    id: 'c1',
    personId: 'p1',
    text: 'Hi.',
    status: s,
    readyAt: s == CueStatus.ready || s == CueStatus.played ? ready : null,
  );

  test('expired after 24 hours', () {
    expect(isExpired(item(CueStatus.ready), ready.add(const Duration(hours: 23, minutes: 59, seconds: 59))), isFalse);
    expect(isExpired(item(CueStatus.ready), ready.add(const Duration(hours: 24))), isTrue);
  });

  test('a ready time in the future counts as expired (clock moved back)', () {
    expect(isExpired(item(CueStatus.ready), ready.subtract(const Duration(minutes: 5))), isTrue);
  });

  test('played lines expire after 24 h', () {
    expect(isExpired(item(CueStatus.played), ready.add(const Duration(hours: 23))), isFalse);
    expect(isExpired(item(CueStatus.played), ready.add(const Duration(hours: 24))), isTrue);
  });

  test('only lines with a clip expire', () {
    expect(isExpired(item(CueStatus.queued), ready.add(const Duration(days: 3))), isFalse);
    expect(isExpired(item(CueStatus.failed), ready.add(const Duration(days: 3))), isFalse);
  });

  test('json round trip', () {
    final c = CueItem(
      id: 'c1',
      personId: 'p1',
      text: 'Hi.',
      status: CueStatus.failed,
      attempts: 2,
      error: 'boom',
      readyAt: ready,
      mood: Mood.worried,
      seed: 4242,
      clips: const [CueClip('cues/c1-0.bin', 7), CueClip('cues/c1-1.bin', 4242)],
      current: 0,
    );
    expect(CueItem.fromJson(c.toJson()).toJson(), c.toJson());
    expect(CueItem.fromJson(c.toJson()).mood, Mood.worried);
    expect(CueItem.fromJson(c.toJson()).clipFile, 'cues/c1-0.bin');
  });

  test('old json with clipFile reads as one take', () {
    final j = {...item(CueStatus.ready).toJson(), 'seed': 9, 'clipFile': 'cues/c1.bin'}
      ..remove('clips')
      ..remove('current');
    final c = CueItem.fromJson(j);
    expect(c.clips.map((k) => (k.file, k.seed)), [('cues/c1.bin', 9)]);
    expect(c.current, 0);
    expect(c.clipFile, 'cues/c1.bin');
  });

  test('a stored delete time decides expiry', () {
    final c = CueItem(
      id: 'c1',
      personId: 'p1',
      text: 'Hi.',
      status: CueStatus.ready,
      readyAt: ready,
      expiresAt: ready.add(const Duration(hours: 1)),
    );
    expect(isExpired(c, ready.add(const Duration(minutes: 59))), isFalse);
    expect(isExpired(c, ready.add(const Duration(hours: 1))), isTrue);
    expect(CueItem.fromJson(c.toJson()).expiresAt, c.expiresAt);
  });

  test('a line stored before moods existed reads as conversational', () {
    final j = item(CueStatus.ready).toJson()..remove('mood');
    expect(CueItem.fromJson(j).mood, Mood.conversational);
  });

  test('a line with no takes has no clip file', () {
    expect(item(CueStatus.queued).clipFile, isNull);
  });

  test('a line stored before seeds existed reads with seed 1', () {
    final j = item(CueStatus.ready).toJson()..remove('seed');
    expect(CueItem.fromJson(j).seed, 1);
  });

  test('new lines default to conversational', () {
    expect(item(CueStatus.queued).mood, Mood.conversational);
  });

  test('old cue json with quality still reads', () {
    final j = {...item(CueStatus.ready).toJson(), 'quality': 'fast'};
    final c = CueItem.fromJson(j);
    expect(c.text, 'Hi.');
    expect(c.toJson().containsKey('quality'), isFalse);
  });
}
