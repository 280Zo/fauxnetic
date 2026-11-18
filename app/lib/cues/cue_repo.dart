import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../recording/scripts.dart';
import '../storage/temp_sweeper.dart';
import '../storage/vault.dart';
import 'cue.dart';

const kFailedTwiceMessage =
    'Preparing this line failed twice, likely because the phone ran out of memory. Close other apps and retry.';

/// The cue list. Each line keeps every take; takes are encrypted, stay replayable after playing,
/// and are all wiped when the line is removed, when the list is cleared, or [kRetention] after the
/// line's first take was generated.
class CueRepo {
  CueRepo(this.dir, this._vault);

  final Directory dir;
  final Vault _vault;
  final _random = Random.secure();
  Future<void> _tail = Future.value();

  File get _index => File('${dir.path}/cues.json');

  /// Every read-modify-write of the index runs one at a time, so a line added while another is
  /// being prepared is never overwritten.
  Future<T> _locked<T>(Future<T> Function() fn) {
    final result = _tail.then((_) => fn());
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<List<CueItem>> all() async {
    if (!await _index.exists()) return [];
    final raw = jsonDecode(utf8.decode(await _vault.decryptFile(_index))) as List<Object?>;
    return raw.map((e) => CueItem.fromJson(e! as Map<String, Object?>)).toList();
  }

  Future<void> _save(List<CueItem> items) =>
      _vault.encryptBytes(utf8.encode(jsonEncode(items.map((c) => c.toJson()).toList())), _index);

  Future<void> _wipe(CueItem c) async {
    for (final clip in c.clips) {
      final f = File('${dir.path}/${clip.file}');
      if (await f.exists()) await f.delete();
    }
  }

  Future<CueItem> add(String personId, String text, {Mood mood = Mood.conversational, String? model}) =>
      _locked(() async {
        final id = List.generate(8, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
        final c = CueItem(
          id: id,
          personId: personId,
          text: text.trim(),
          status: CueStatus.queued,
          mood: mood,
          seed: newSeed(),
          model: model,
        );
        await _save([...await all(), c]);
        return c;
      });

  Future<void> _replace(CueItem c) async => _save([for (final x in await all()) x.id == c.id ? c : x]);

  Future<void> update(CueItem c) => _locked(() => _replace(c));

  /// Adds the prepared clip as the line's newest take, shows it and marks the line ready. Returns
  /// null, and leaves no clip, when the line was removed (or expired) while it was preparing.
  /// [expiresAt] is used for the line's first take only; later takes keep the first delete time.
  Future<CueItem?> storeClip(CueItem c, List<int> wav, DateTime now, {DateTime? expiresAt, String? engine}) async {
    final rel = 'cues/${c.id}-${c.clips.length}.bin';
    final file = File('${dir.path}/$rel');
    await _vault.encryptBytes(wav, file);
    return _locked(() async {
      if (!(await all()).any((x) => x.id == c.id)) {
        if (await file.exists()) await file.delete();
        return null;
      }
      final clips = [...c.clips, CueClip(rel, c.seed, engine: engine, madeAt: now)];
      final ready = c.copyWith(
        status: CueStatus.ready,
        clips: clips,
        current: clips.length - 1,
        readyAt: c.readyAt ?? now,
        expiresAt: c.expiresAt ?? expiresAt,
        clearError: true,
      );
      await _replace(ready);
      return ready;
    });
  }

  /// Decrypted clip in a temp file; release it through the TempSweeper after playback.
  Future<File> decryptedClip(CueItem c, TempSweeper temp) =>
      _vault.decryptToTemp(File('${dir.path}/${c.clipFile}'), temp, '.wav');

  /// Decrypted WAV bytes, for sharing.
  Future<List<int>> clipBytes(CueItem c) => _vault.decryptFile(File('${dir.path}/${c.clipFile}'));

  /// Played lines keep their clip so they can be replayed until retention removes them.
  Future<void> markPlayed(String id) => _locked(() async {
    await _save([
      for (final c in await all()) c.id == id && c.status == CueStatus.ready ? c.copyWith(status: CueStatus.played) : c,
    ]);
  });

  /// A random sampling seed, never 0 (CrispASR treats 0 as its fixed default).
  int newSeed() => _random.nextInt(0x7fffffff) + 1;

  /// "Re-generate": keeps the line's takes and queues it with [seed] for a new, different one, made
  /// with [model] when given (else the model the line had).
  Future<void> regenerate(String id, int seed, {String? model}) => _locked(() async {
    await _save([
      for (final c in await all())
        c.id == id && c.hasClip
            ? c.copyWith(status: CueStatus.queued, seed: seed, attempts: 0, clearError: true, model: model)
            : c,
    ]);
  });

  /// Shows take [index] of the line; an index out of range is ignored.
  Future<void> select(String id, int index) => _locked(() async {
    await _save([
      for (final c in await all()) c.id == id && index >= 0 && index < c.clips.length ? c.copyWith(current: index) : c,
    ]);
  });

  /// Queues a failed line again on a new seed: the same seed would take the same path.
  Future<void> retry(String id) => _locked(() async {
    await _save([
      for (final c in await all())
        c.id == id && c.status == CueStatus.failed
            ? c.copyWith(status: CueStatus.queued, seed: newSeed(), attempts: 0, clearError: true)
            : c,
    ]);
  });

  Future<void> remove(String id) => _locked(() async {
    final items = await all();
    for (final c in items.where((c) => c.id == id)) {
      await _wipe(c);
    }
    await _save(items.where((c) => c.id != id).toList());
  });

  /// Deleting a person also deletes every line in their voice.
  Future<void> removeForPerson(String personId) => _locked(() async {
    final items = await all();
    for (final c in items.where((c) => c.personId == personId)) {
      await _wipe(c);
    }
    await _save(items.where((c) => c.personId != personId).toList());
  });

  Future<void> clear() => _locked(() async {
    for (final c in await all()) {
      await _wipe(c);
    }
    final clips = Directory('${dir.path}/cues');
    if (await clips.exists()) {
      await for (final f in clips.list()) {
        await f.delete(recursive: true);
      }
    }
    await _save([]);
  });

  Future<int> enforceRetention(DateTime now) => _locked(() async {
    final items = await all();
    final expired = items.where((c) => isExpired(c, now)).toList();
    for (final c in expired) {
      await _wipe(c);
    }
    if (expired.isNotEmpty) await _save(items.where((c) => !isExpired(c, now)).toList());
    return expired.length;
  });

  /// Removes lines (and their takes) whose person is no longer on the phone.
  Future<int> removeOrphans(Set<String> personIds) => _locked(() async {
    final items = await all();
    final gone = items.where((c) => !personIds.contains(c.personId)).toList();
    for (final c in gone) {
      await _wipe(c);
    }
    if (gone.isNotEmpty) await _save(items.where((c) => personIds.contains(c.personId)).toList());
    return gone.length;
  });

  /// A shorter keep-for moves delete times earlier (to readyAt + [keepFor]); it never moves one later.
  Future<int> shorten(Duration keepFor) => _locked(() async {
    final items = await all();
    var n = 0;
    final out = <CueItem>[];
    for (final c in items) {
      final ready = c.readyAt;
      final current = c.expiresAt ?? ready?.add(kRetention);
      if (ready != null && current != null && ready.add(keepFor).isBefore(current)) {
        out.add(c.copyWith(expiresAt: ready.add(keepFor)));
        n++;
      } else {
        out.add(c);
      }
    }
    if (n > 0) await _save(out);
    return n;
  });

  /// At launch: deletes clip files no line refers to (a crash between writing and indexing one).
  Future<int> sweepUnindexedClips() => _locked(() async {
    final folder = Directory('${dir.path}/cues');
    if (!await folder.exists()) return 0;
    final known = {
      for (final c in await all())
        for (final k in c.clips) '${dir.path}/${k.file}',
    };
    var n = 0;
    await for (final e in folder.list()) {
      if (e is File && !known.contains(e.path)) {
        await e.delete();
        n++;
      }
    }
    return n;
  });

  Future<void> recoverAfterRestart() => _locked(() async {
    await _save([
      for (final c in await all())
        if (c.status != CueStatus.preparing)
          c
        else if (c.attempts >= 2)
          c.copyWith(status: CueStatus.failed, error: kFailedTwiceMessage)
        else
          c.copyWith(status: CueStatus.queued),
    ]);
  });
}
