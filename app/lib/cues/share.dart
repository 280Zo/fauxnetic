import 'dart:io';

import 'package:share_plus/share_plus.dart';

import 'cue.dart';
import 'cue_repo.dart';

/// Hands a file to the share sheet and completes when the sheet is closed.
typedef ShareSink = Future<void> Function(File f);

Future<void> systemShareSink(File f) async {
  await SharePlus.instance.share(ShareParams(files: [XFile(f.path, mimeType: 'audio/wav')]));
}

/// Shares one generated line as a normal WAV (CrispASR's watermark stays in the audio). Our plain
/// file exists only in [shareDir] while the share sheet is open. share_plus copies it into
/// [pluginDir] (`<cache>/share_plus`) and keeps that copy until the next share, so [sweepStale]
/// removes copies older than [kShareCopyLife] and [sweepShares] removes all of them.
class ShareService {
  ShareService(this._cues, this.shareDir, {this.pluginDir, this._sink = systemShareSink, DateTime Function()? clock})
    : _clock = clock ?? (() => DateTime.now().toUtc());

  final CueRepo _cues;
  final Directory shareDir;
  final Directory? pluginDir;
  final ShareSink _sink;
  final DateTime Function() _clock;

  /// Long enough for a receiver (SMS reads the file after the sheet closes), short enough that a
  /// plain copy doesn't linger.
  static const kShareCopyLife = Duration(minutes: 10);

  /// Letters and digits only, so a typed name can never leave [shareDir] or upset the receiver;
  /// capped so a long name still makes a valid file name.
  static String _safe(String name) {
    var s = name.replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    if (s.runes.length > 40) s = String.fromCharCodes(s.runes.take(40));
    return s.isEmpty ? 'line' : s;
  }

  /// Returns false, sharing nothing, when the line has no clip or it has expired.
  Future<bool> share(CueItem c, String personName) async {
    if (!c.hasClip || isExpired(c, _clock())) return false;
    final bytes = await _cues.clipBytes(c);
    await shareDir.create(recursive: true);
    final file = File('${shareDir.path}/${_safe(personName)}-${c.id.substring(0, 6)}.wav');
    try {
      await file.writeAsBytes(bytes, flush: true);
      await _sink(file);
    } finally {
      if (await file.exists()) await file.delete();
    }
    return true;
  }

  /// At launch and when a person is deleted: removes every plain copy, ours and the plugin's.
  Future<int> sweepShares() async {
    var n = 0;
    for (final d in [shareDir, ?pluginDir]) {
      if (!await d.exists()) continue;
      await for (final e in d.list()) {
        await e.delete(recursive: true);
        n++;
      }
    }
    return n;
  }

  /// Periodically: removes the plugin's copies once they are [kShareCopyLife] old.
  Future<int> sweepStale() async {
    final d = pluginDir;
    if (d == null || !await d.exists()) return 0;
    final cutoff = _clock().subtract(kShareCopyLife);
    var n = 0;
    await for (final e in d.list()) {
      final stat = await e.stat();
      if (stat.modified.toUtc().isAfter(cutoff)) continue;
      await e.delete(recursive: true);
      n++;
    }
    return n;
  }
}
