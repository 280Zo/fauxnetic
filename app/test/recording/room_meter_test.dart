import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/recording/room_meter.dart';

import '../support/signals.dart';

void main() {
  RoomLevel heard(Float32List pcm) => (RoomMeter()..add(pcm)).level;

  test('nothing heard yet is unknown', () {
    expect(RoomMeter().level, RoomLevel.unknown);
    expect(heard(Float32List(800)), RoomLevel.unknown, reason: 'under half a second');
  });

  test('a quiet room, an HVAC hum and a loud room', () {
    final r = Random(3);
    expect(heard(Float32List.fromList(noise(2, -62, r))), RoomLevel.quiet);
    expect(heard(Float32List.fromList(noise(2, -45, r))), RoomLevel.someNoise);
    expect(heard(Float32List.fromList(noise(2, -35, r))), RoomLevel.noisy);
  });

  test('speech does not make a quiet room look noisy: the pauses measure the room', () {
    expect(heard(bursts(-20, -65)), RoomLevel.quiet);
    expect(heard(bursts(-20, -36)), RoomLevel.noisy);
  });

  test('it follows the room: a fan switched on shows within a few seconds', () {
    final m = RoomMeter();
    final r = Random(4);
    m.add(Float32List.fromList(noise(3, -62, r)));
    expect(m.level, RoomLevel.quiet);
    m.add(Float32List.fromList(noise(3, -35, r)));
    expect(m.level, RoomLevel.noisy);
  });
}
