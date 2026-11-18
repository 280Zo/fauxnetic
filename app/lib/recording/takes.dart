import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../audio/wav.dart';
import '../storage/vault.dart';
import 'scripts.dart';

const kTakeRate = 16000;

/// One recorded line, kept encrypted (16 kHz WAV) until the profile is finalized.
class Take {
  const Take({
    required this.id,
    required this.personId,
    required this.mood,
    required this.text,
    required this.fromScript,
    required this.seconds,
    required this.score,
    required this.file,
    this.prompt,
  });

  final String id;
  final String personId;
  final Mood mood;

  /// The script text for read lines, else the on-phone transcript.
  final String text;
  final bool fromScript;
  final double seconds;

  /// Higher is better; the reference uses the best takes first.
  final double score;

  /// Encrypted clip, relative to the store directory.
  final String file;

  /// The line shown while recording: the full passage or line read, or the question answered.
  /// A later session uses it to ask for text not used yet. Null for takes stored before it existed.
  final String? prompt;

  Map<String, Object?> toJson() => {
    'id': id,
    'personId': personId,
    'mood': mood.name,
    'text': text,
    'fromScript': fromScript,
    'seconds': seconds,
    'score': score,
    'file': file,
    'prompt': prompt,
  };

  factory Take.fromJson(Map<String, Object?> j) => Take(
    id: j['id']! as String,
    personId: j['personId']! as String,
    mood: Mood.values.byName(j['mood']! as String),
    text: j['text']! as String,
    fromScript: j['fromScript']! as bool,
    seconds: (j['seconds']! as num).toDouble(),
    score: (j['score']! as num).toDouble(),
    file: j['file']! as String,
    prompt: j['prompt'] as String?,
  );
}

class TakeStore {
  TakeStore(this.dir, this._vault);

  final Directory dir;
  final Vault _vault;
  final _random = Random.secure();
  Future<void> _tail = Future.value();

  File get _index => File('${dir.path}/takes.json');

  Future<T> _locked<T>(Future<T> Function() fn) {
    final result = _tail.then((_) => fn());
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<List<Take>> _all() async {
    if (!await _index.exists()) return [];
    final raw = jsonDecode(utf8.decode(await _vault.decryptFile(_index))) as List<Object?>;
    return raw.map((e) => Take.fromJson(e! as Map<String, Object?>)).toList();
  }

  Future<void> _save(List<Take> takes) =>
      _vault.encryptBytes(utf8.encode(jsonEncode(takes.map((t) => t.toJson()).toList())), _index);

  String _newId() => List.generate(8, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

  Future<Take> save(
    String personId,
    Mood mood,
    Float32List pcm16k, {
    required String text,
    required bool fromScript,
    required double score,
    String? prompt,
  }) async {
    final id = _newId();
    final rel = 'takes/$id.bin';
    await _vault.encryptBytes(encodeWav(pcm16k, kTakeRate), File('${dir.path}/$rel'));
    final t = Take(
      id: id,
      personId: personId,
      mood: mood,
      text: text.trim(),
      fromScript: fromScript,
      seconds: pcm16k.length / kTakeRate,
      score: score,
      file: rel,
      prompt: prompt,
    );
    await _locked(() async => _save([...await _all(), t]));
    return t;
  }

  /// Fixes an answer's words (the phone's transcript can slip); the audio stays.
  Future<Take> setText(Take take, String text) => _locked(() async {
    final all = await _all();
    final fixed = Take(
      id: take.id,
      personId: take.personId,
      mood: take.mood,
      text: text.trim(),
      fromScript: take.fromScript,
      seconds: take.seconds,
      score: take.score,
      file: take.file,
      prompt: take.prompt,
    );
    await _save([for (final t in all) t.id == take.id ? fixed : t]);
    return fixed;
  });

  /// In the order they were recorded.
  Future<List<Take>> forPerson(String personId) async => (await _all()).where((t) => t.personId == personId).toList();

  Future<Float32List> samples(Take t) async => wavSamples(await _vault.decryptFile(File('${dir.path}/${t.file}')));

  Future<void> delete(Take take) => _deleteWhere((t) => t.id == take.id);

  Future<void> deleteFor(String personId, Mood mood) => _deleteWhere((t) => t.personId == personId && t.mood == mood);

  Future<void> _deleteWhere(bool Function(Take t) gone) => _locked(() async {
    final all = await _all();
    for (final t in all.where(gone)) {
      final f = File('${dir.path}/${t.file}');
      if (await f.exists()) await f.delete();
    }
    await _save(all.where((t) => !gone(t)).toList());
  });

  /// At launch: removes takes of people who no longer exist (left by leaving a session while a
  /// take was being saved) and take files the index doesn't list (a crash before indexing).
  Future<int> sweepOrphans(Set<String> personIds) => _locked(() async {
    final all = await _all();
    final keep = all.where((t) => personIds.contains(t.personId)).toList();
    final files = {for (final t in keep) '${dir.path}/${t.file}'};
    var n = 0;
    final folder = Directory('${dir.path}/takes');
    if (await folder.exists()) {
      await for (final e in folder.list()) {
        if (e is File && !files.contains(e.path)) {
          await e.delete();
          n++;
        }
      }
    }
    if (keep.length != all.length) await _save(keep);
    return n;
  });

  Future<void> deleteForPerson(String personId) => _locked(() async {
    final all = await _all();
    for (final t in all.where((t) => t.personId == personId)) {
      final f = File('${dir.path}/${t.file}');
      if (await f.exists()) await f.delete();
    }
    await _save(all.where((t) => t.personId != personId).toList());
  });
}
