const _fillers = {'um', 'uh', 'er', 'erm', 'ah', 'hmm', 'mm'};

String _norm(String w) => w.toLowerCase().replaceAll(RegExp('[^a-z]'), '');

/// How many script words the reader has covered, for follow-along highlighting.
///
/// Reads [heardWords] left to right and only ever moves forward, so hearing more words never
/// lowers the result. Fillers and repeated words are ignored. A wrong word counts as a substitute
/// for the expected one, and a skipped word is passed over, but two wrong words in a row do not
/// advance: unrelated talk never runs ahead of the reader. Words that normalise to nothing (digits
/// for a spoken number) are skipped and the next word catches up.
int spokenPrefix(List<String> scriptWords, List<String> heardWords) {
  final script = scriptWords.map(_norm).toList();
  var i = 0;
  var lastMatched = true;
  for (final raw in heardWords) {
    if (i >= script.length) break;
    final w = _norm(raw);
    if (w.isEmpty || _fillers.contains(w)) continue;
    if (w == script[i]) {
      i++;
      lastMatched = true;
    } else if (i + 1 < script.length && w == script[i + 1]) {
      i += 2;
      lastMatched = true;
    } else if (i > 0 && w == script[i - 1]) {
      continue;
    } else if (lastMatched) {
      i++;
      lastMatched = false;
    }
  }
  return i;
}
