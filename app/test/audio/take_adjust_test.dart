import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/audio/take_adjust.dart';

void main() {
  test('defaults are not adjusted', () {
    expect(TakeAdjust.defaults.isDefault, isTrue);
    expect(const TakeAdjust(speed: 1.1).isDefault, isFalse);
    expect(const TakeAdjust(normalize: false).isDefault, isFalse);
  });

  test('json round trip', () {
    const a = TakeAdjust(speed: 1.25, pitch: -2, pauses: 1.5, gainDb: 3, normalize: false);
    expect(TakeAdjust.fromJson(a.toJson()), a);
  });

  test('out of range values are clamped', () {
    final a = TakeAdjust.clamped(speed: 3, pitch: -9, pauses: 0, gainDb: 30);
    expect(a.speed, 1.5);
    expect(a.pitch, -3);
    expect(a.pauses, 0.5);
    expect(a.gainDb, 20, reason: 'owner: a much higher volume max');
  });

  test('values snap to the slider steps', () {
    final a = TakeAdjust.clamped(speed: 1.0000001, pitch: 0.24, pauses: 1.0499, gainDb: 2.6);
    expect(a.speed, 1.0);
    expect(a.pitch, 0.0);
    expect(a.pauses, 1.0);
    expect(a.gainDb, 3.0);
    expect(TakeAdjust.clamped(speed: 1 + 1e-9).isDefault, isTrue, reason: 'back at the middle counts as default');
  });

  test('values from storage are clamped too', () {
    expect(TakeAdjust.fromJson({'speed': 9, 'gainDb': -40}).speed, 1.5);
    expect(TakeAdjust.fromJson({'speed': 9, 'gainDb': -40}).gainDb, -12);
  });
}
