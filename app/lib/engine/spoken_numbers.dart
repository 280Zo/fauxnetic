/// Numbers written out the way they should be said, for every voice model (English). The user's text is
/// shown and saved unchanged; only the engine sees this. Card and phone numbers are read digit by
/// digit; money, times, percentages, decimals, years and counts as words (stall-guard design,
/// 2026-11-17). Everything else, including tags like [excited], is left alone.
String spokenNumbers(String text) {
  var t = text;
  // Money: $200, $4.50, $1,200.
  t = t.replaceAllMapped(RegExp(r'\$(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d{2}))?(?!\d)'), (m) {
    final digits = m[1]!.replaceAll(',', '');
    final dollars = int.tryParse(digits);
    final cents = m[2] == null ? 0 : int.parse(m[2]!);
    final d = '${_count(digits)} ${dollars == 1 ? 'dollar' : 'dollars'}';
    return cents == 0 ? d : '$d and ${numberWords(cents)} ${cents == 1 ? 'cent' : 'cents'}';
  });
  // Times: 7:30, 7:05, 7:00, 7:30pm, 7:30 AM.
  t = t.replaceAllMapped(RegExp(r'\b(\d{1,2}):(\d{2})(?!\d)(?:\s?([AaPp])\.?[Mm]\.?(?![A-Za-z]))?'), (m) {
    final h = numberWords(int.parse(m[1]!));
    final min = int.parse(m[2]!);
    final time = min == 0
        ? "$h o'clock"
        : min < 10
        ? '$h oh ${numberWords(min)}'
        : '$h ${numberWords(min)}';
    final half = m[3];
    if (half == null) return time;
    return '${min == 0 ? h : time} ${half.toLowerCase()} m';
  });
  // Ordinals: 1st, 2nd, 3rd, 21st, 100th.
  t = t.replaceAllMapped(
    RegExp(r'\b(\d{1,9})(st|nd|rd|th)\b', caseSensitive: false),
    (m) => _ordinal(numberWords(int.parse(m[1]!))),
  );
  // Percentages: 20%, 2.5%.
  t = t.replaceAllMapped(RegExp(r'\b(\d+(?:\.\d+)?)%'), (m) => '${_plain(m[1]!)} percent');
  // Decimals: 3.5, 3.14159 (before digit runs, so the digits after the point stay with it).
  t = t.replaceAllMapped(RegExp(r'\b(\d+)\.(\d+)\b'), (m) => _plain(m[0]!));
  // Cards, phone numbers, codes: groups of 3+ digits joined by spaces or dashes (parentheses
  // allowed), or one run of 5+ digits. Read digit by digit, a pause between groups.
  t = t.replaceAllMapped(RegExp(r'\(?\b\d{3,}\b\)?(?:[ -]\(?\b\d{3,}\b\)?)+|\b\d{5,}\b'), (m) {
    return RegExp(r'\d+').allMatches(m[0]!).map((g) => _digits(g[0]!)).join(', ');
  });
  // Thousands with commas: 12,500.
  t = t.replaceAllMapped(RegExp(r'\b\d{1,3}(?:,\d{3})+\b'), (m) => _count(m[0]!.replaceAll(',', '')));
  // Years after in/since/from/by: 1999, 2024.
  t = t.replaceAllMapped(
    RegExp(r'\b(in|since|from|by|In|Since|From|By) (19\d\d|20\d\d)\b'),
    (m) => '${m[1]} ${_year(int.parse(m[2]!))}',
  );
  // Everything else: counts and plain numbers.
  return t.replaceAllMapped(RegExp(r'\b\d+\b'), (m) => _count(m[0]!));
}

/// [digits] as a number in words, or digit by digit when it is too big to say as one (a trillion or
/// more): "one zero zero …".
String _count(String digits) {
  final n = digits.length <= 12 ? int.tryParse(digits) : null;
  if (n == null || n > 999999999999) return _digits(digits);
  return numberWords(n);
}

/// [digits] said one by one. A run longer than 5 is split into groups with a pause between, the way
/// people say them (2026-11-23): 10 as a phone number (3-3-4), a multiple of 4 in fours (a card),
/// otherwise threes, ending in one or two fours.
String _digits(String digits) {
  String say(String g) => g.split('').map((d) => _ones[int.parse(d)]).join(' ');
  final n = digits.length;
  if (n <= 5) return say(digits);
  final sizes = n == 10
      ? [3, 3, 4]
      : n % 4 == 0
      ? List.filled(n ~/ 4, 4)
      : [...List.filled((n - 4 * (n % 3)) ~/ 3, 3), ...List.filled(n % 3, 4)];
  final groups = <String>[];
  var at = 0;
  for (final s in sizes) {
    groups.add(say(digits.substring(at, at + s)));
    at += s;
  }
  return groups.join(', ');
}

/// "twenty-one" → "twenty-first", "one hundred" → "one hundredth".
String _ordinal(String words) {
  const special = {'one': 'first', 'two': 'second', 'three': 'third', 'five': 'fifth', 'eight': 'eighth'};
  final cut = words.lastIndexOf(RegExp(r'[ -]'));
  final head = cut < 0 ? '' : words.substring(0, cut + 1);
  final last = words.substring(cut + 1);
  final irregular =
      special[last] ??
      (last == 'nine'
          ? 'ninth'
          : last == 'twelve'
          ? 'twelfth'
          : null);
  if (irregular != null) return '$head$irregular';
  if (last.endsWith('y')) return '$head${last.substring(0, last.length - 1)}ieth';
  return '$head${last}th';
}

const _ones = ['zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine'];
const _teens = [
  'ten', 'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen', 'sixteen', 'seventeen', 'eighteen', 'nineteen', //
];
const _tens = ['', '', 'twenty', 'thirty', 'forty', 'fifty', 'sixty', 'seventy', 'eighty', 'ninety'];

String _plain(String s) {
  final parts = s.split('.');
  final whole = numberWords(int.parse(parts[0]));
  if (parts.length == 1) return whole;
  return '$whole point ${parts[1].split('').map((d) => _ones[int.parse(d)]).join(' ')}';
}

String _under100(int n) {
  if (n < 10) return _ones[n];
  if (n < 20) return _teens[n - 10];
  return n % 10 == 0 ? _tens[n ~/ 10] : '${_tens[n ~/ 10]}-${_ones[n % 10]}';
}

String _under1000(int n) {
  if (n < 100) return _under100(n);
  final rest = n % 100;
  return '${_ones[n ~/ 100]} hundred${rest == 0 ? '' : ' ${_under100(rest)}'}';
}

/// [n] (0 to 999,999,999,999) in words: 1200 → "one thousand two hundred".
String numberWords(int n) {
  if (n == 0) return 'zero';
  final parts = <String>[];
  for (final (size, name) in [(1000000000, 'billion'), (1000000, 'million'), (1000, 'thousand')]) {
    if (n >= size) {
      parts.add('${_under1000(n ~/ size)} $name');
      n %= size;
    }
  }
  if (n > 0) parts.add(_under1000(n));
  return parts.join(' ');
}

String _year(int y) {
  if (y >= 2000 && y < 2010) return numberWords(y);
  final hi = y ~/ 100, lo = y % 100;
  return '${_under100(hi)} ${lo == 0
      ? 'hundred'
      : lo < 10
      ? 'oh ${_ones[lo]}'
      : _under100(lo)}';
}
