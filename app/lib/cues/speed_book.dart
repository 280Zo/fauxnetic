import 'dart:convert';
import 'dart:io';

/// How long each voice model takes per word on this phone, learned from finished lines, so the
/// Speak screen's time guess fits slow models too (VoxCPM sat at a fixed-rule "95%" for minutes,
/// 2026-11-16). A small plain JSON file; nothing in it is sensitive. Unreadable means empty.
class SpeedBook {
  SpeedBook(this.file);
  final File file;
  Map<String, double> _rates = {};

  Future<void> load() async {
    try {
      final j = jsonDecode(await file.readAsString()) as Map<String, Object?>;
      _rates = {
        for (final e in j.entries)
          if (e.value is num) e.key: (e.value! as num).toDouble(),
      };
    } catch (_) {
      _rates = {};
    }
  }

  double? secondsPerWord(String model) => _rates[model];

  /// Half the old rate, half this line's, so it follows a phone that warms up or slows down.
  Future<void> record(String model, int words, double seconds) async {
    if (words <= 0 || seconds <= 0) return;
    final sample = seconds / words;
    final old = _rates[model];
    _rates[model] = old == null ? sample : 0.5 * old + 0.5 * sample;
    try {
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(_rates), flush: true);
      await tmp.rename(file.path);
    } catch (_) {
      // A guess that isn't saved only costs a less accurate guess next launch.
    }
  }
}

/// Words in a line, as the time guess counts them.
int wordCount(String text) => text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
