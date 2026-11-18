import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/recording/align.dart';
import 'package:fauxnetic/recording/take_check.dart';

List<String> w(String s) => s.split(' ');

void main() {
  final script = w("I'm heading to the store later, do you need anything?");

  test('prefix advances with spoken words', () {
    expect(spokenPrefix(script, []), 0);
    expect(spokenPrefix(script, w('Im heading')), 2);
    expect(spokenPrefix(script, w("I'm heading to the store")), 5);
    expect(spokenPrefix(script, w("i'm heading to the store later do you need anything")), 10);
  });

  test('prefix ignores um and uh', () {
    expect(spokenPrefix(script, w("um I'm uh heading to, uh, the")), 4);
  });

  test('prefix tolerates one substituted word', () {
    expect(spokenPrefix(script, w("I'm heading to a store later")), 6);
    expect(spokenPrefix(script, w("I'm heading to store later")), 6, reason: 'one dropped word');
  });

  test('prefix does not run ahead on unrelated words', () {
    expect(spokenPrefix(script, w("I'm heading banana pancake waffle")), 3);
  });

  test('prefix never goes backwards', () {
    final heard = w("um I'm heading to a uh store later do you you need anything thanks");
    var last = 0;
    for (var n = 0; n <= heard.length; n++) {
      final p = spokenPrefix(script, heard.sublist(0, n));
      expect(p, greaterThanOrEqualTo(last));
      expect(p, lessThanOrEqualTo(script.length));
      last = p;
    }
    expect(last, script.length);
  });

  test('digits for spoken numbers do not stall the prefix', () {
    final s = w('The coffee place opens at seven on weekdays.');
    expect(spokenPrefix(s, w('The coffee place opens at 7 on weekdays')), 8);
  });

  test('wer matches harness examples', () {
    expect(wordErrorRate('the cat sat down', 'the dog sat down'), 0.25);
  });
}
