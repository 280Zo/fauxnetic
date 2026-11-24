import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/engine/spoken_numbers.dart';

void main() {
  // What Qwen hears for numbers (stall-guard design, 2026-11-17). The user's text is shown unchanged.
  const cases = {
    '1 2 3 4 5 6 7 8 9 10 11 12 13 14 15':
        'one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen',
    'My card is 4532 7189 0263 5547.':
        'My card is four five three two, seven one eight nine, zero two six three, five five four seven.',
    'Call 555-867-5309 now': 'Call five five five, eight six seven, five three zero nine now',
    'Call (555) 867-5309': 'Call five five five, eight six seven, five three zero nine',
    'Code 48213': 'Code four eight two one three',
    'send me \$200 real quick': 'send me two hundred dollars real quick',
    '\$4.50': 'four dollars and fifty cents',
    '\$1': 'one dollar',
    '[excited] I won \$1,200!': '[excited] I won one thousand two hundred dollars!',
    'about 12,500 people': 'about twelve thousand five hundred people',
    'at 7:30': 'at seven thirty',
    'at 7:05': 'at seven oh five',
    'at 7:00': "at seven o'clock",
    '3.5 stars': 'three point five stars',
    '20% off': 'twenty percent off',
    'in 1999': 'in nineteen ninety-nine',
    'since 2024': 'since twenty twenty-four',
    'ends in 4111': 'ends in four thousand one hundred eleven',
    'Room 101': 'Room one hundred one',
    'I have 2 kids and 45 cats': 'I have two kids and forty-five cats',
    'Hello there, how are you?': 'Hello there, how are you?',
    // Review 2026-11-17.
    'at 7:30pm': 'at seven thirty p m',
    'at 7:30 AM': 'at seven thirty a m',
    'the 1st, 2nd, 3rd and 4th': 'the first, second, third and fourth',
    'my 21st birthday': 'my twenty-first birthday',
    'pi is 3.14159': 'pi is three point one four one five nine',
    // Long digit runs are said in groups, with a pause between (2026-11-23): one unbroken chain of
    // 10 or 16 digits is hard to follow and gives the model nowhere to breathe.
    '\$1,000,000,000,000': 'one zero zero, zero zero zero, zero zero zero, zero zero zero zero dollars',
    'about 123456789012345678901234': 'about one two three four, five six seven eight, nine zero one two, three four five six, seven eight nine zero, one two three four',
    'My card is 4532718902635547.':
        'My card is four five three two, seven one eight nine, zero two six three, five five four seven.',
    'Call 5558675309 now': 'Call five five five, eight six seven, five three zero nine now',
    'Order 1234567': 'Order one two three, four five six seven',
    'Call 555 8675309': 'Call five five five, eight six seven, five three zero nine',
    'PIN 123456': 'PIN one two three, four five six',
  };

  for (final MapEntry(key: input, value: output) in cases.entries) {
    test('"$input"', () => expect(spokenNumbers(input), output));
  }

  test('every long run is said whole, in order, in groups of three or four', () {
    for (var n = 6; n <= 40; n++) {
      final digits = List.generate(n, (i) => '${(i * 7 + 3) % 10}').join();
      final groups = spokenNumbers(digits).split(', ');
      expect(groups.map((g) => g.split(' ').length), everyElement(inInclusiveRange(3, 4)), reason: '$n digits');
      expect(groups.join(' '), spokenNumbers(digits.split('').join(' ')), reason: '$n digits, every one in order');
    }
  });
}
