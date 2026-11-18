import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../people/people_repo.dart';
import '../people/person.dart';
import '../recording/transcriber.dart';
import '../theme.dart';
import '../upload/upload_pipeline.dart';

/// The stretch of [clip] around word [i]: from the word before to the word after, plus [margin]
/// seconds each side, inside the clip. Word times can be up to a second off (2026-11-16), hence the
/// neighbors. Empty when word [i] has no time (it was added by a fix).
Float32List wordStretch(Float32List clip, int rate, List<TimedWord?> times, int i, {double margin = 0.15}) {
  final w = times[i];
  if (w == null) return Float32List(0);
  final before = i > 0 ? times[i - 1] : null;
  final after = i + 1 < times.length ? times[i + 1] : null;
  final from = (((before?.start ?? w.start) - margin) * rate).round().clamp(0, clip.length);
  final to = (((after?.end ?? w.end) + margin) * rate).round().clamp(from, clip.length);
  return Float32List.sublistView(clip, from, max(from, to));
}

/// Fix one word (or replace it with several). Owns its text controller so it is disposed only after
/// the closing animation. Pops the new text, or null on Cancel. [onPlay], when set, adds Play again.
class FixWordDialog extends StatefulWidget {
  const FixWordDialog({super.key, required this.word, this.onPlay});
  final String word;
  final VoidCallback? onPlay;

  @override
  State<FixWordDialog> createState() => _FixWordDialogState();
}

class _FixWordDialogState extends State<FixWordDialog> {
  late final _edit = TextEditingController(text: widget.word);

  @override
  void dispose() {
    _edit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Fix the word'),
    content: TextField(controller: _edit, autofocus: true),
    actions: [
      if (widget.onPlay != null) TextButton(onPressed: widget.onPlay, child: const Text('Play again')),
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      TextButton(onPressed: () => Navigator.pop(context, _edit.text), child: const Text('Save')),
    ],
  );
}

/// The chosen voice's words, transcribed on the phone. The owner fixes any word, confirms
/// consent, and builds the voice. The words become the reference transcript.
class CheckWordsScreen extends StatefulWidget {
  const CheckWordsScreen({
    super.key,
    required this.name,
    required this.voice,
    required this.transcribe,
    required this.build,
    required this.onBuilt,
    this.play,
  });

  final String name;
  final VoiceCluster voice;

  /// Plays 16 kHz audio (a word's stretch of the clip); null: no playback.
  final Future<void> Function(Float32List pcm16k)? play;
  final Future<List<TimedWord>> Function(VoiceCluster v) transcribe;
  final Future<Person> Function(String words, bool ownVoice, bool spokenConsent) build;
  final void Function(Person p) onBuilt;

  @override
  State<CheckWordsScreen> createState() => _CheckWordsScreenState();
}

class _CheckWordsScreenState extends State<CheckWordsScreen> {
  List<String>? _words;

  /// Each word's time in the clip, parallel to [_words]; null for words added by a fix.
  List<TimedWord?> _times = const [];
  final _uncertain = <int>{};
  var _spoken = false;
  var _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final heard = await widget.transcribe(widget.voice);
      if (!mounted) return;
      setState(() {
        _words = [for (final w in heard) w.text];
        _times = [...heard];
        _uncertain
          ..clear()
          ..addAll([
            for (final (i, w) in heard.indexed)
              if (isUncertain(w)) i,
          ]);
      });
    } on TranscriberError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _fix(int i) async {
    final play = widget.play;
    final stretch = play == null ? Float32List(0) : wordStretch(widget.voice.clip, 16000, _times, i);
    void hear() {
      if (play != null && stretch.isNotEmpty) unawaited(play(stretch));
    }

    hear();
    final fixed = await showDialog<String>(
      context: context,
      builder: (_) => FixWordDialog(word: _words![i], onPlay: stretch.isEmpty ? null : hear),
    );
    if (fixed == null || !mounted) return;
    setState(() {
      final parts = fixed.trim().split(RegExp(r'\s+'))..removeWhere((w) => w.isEmpty);
      _words!.replaceRange(i, i + 1, parts);
      // The first part keeps the word's time; any added words have none.
      _times = [..._times]..replaceRange(i, i + 1, [_times[i], for (var k = 1; k < parts.length; k++) null]);
      // Positions after the edit shift; the owner has now looked at this stretch.
      _uncertain.removeWhere((u) => u >= i);
    });
  }

  Future<void> _build() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final p = await widget.build(_words!.join(' '), false, _spoken);
      if (mounted) widget.onBuilt(p);
    } on NotEnoughSpeechFrom catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } on PersonInvalid catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't build the voice. Try again.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final words = _words;
    final canBuild = words != null && words.isNotEmpty && _spoken && !_busy;
    return Scaffold(
      appBar: AppBar(title: const Text('Check the words')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Transcribed on the phone. Tap a word to fix it.', style: TextStyle(color: context.colors.muted)),
              const SizedBox(height: 16),
              Expanded(
                child: SingleChildScrollView(
                  child: words == null
                      ? (_error == null ? const LinearProgressIndicator() : const SizedBox.shrink())
                      : Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final (i, w) in words.indexed)
                              InkWell(
                                key: _uncertain.contains(i) ? Key('uncertain-$i') : null,
                                onTap: () => _fix(i),
                                borderRadius: BorderRadius.circular(6),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: _uncertain.contains(i) ? context.colors.uncertainFill : context.colors.card,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: _uncertain.contains(i)
                                          ? context.colors.uncertainBorder
                                          : context.colors.rule,
                                    ),
                                  ),
                                  child: Text(w, style: const TextStyle(fontSize: 18)),
                                ),
                              ),
                          ],
                        ),
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
              // One box (owner, 2026-11-17); it covers the owner's own voice too.
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _spoken,
                onChanged: (v) => setState(() => _spoken = v ?? false),
                title: const Text("I have this person's spoken consent to clone their voice"),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: canBuild ? _build : null,
                style: FilledButton.styleFrom(
                  backgroundColor: context.colors.ink,
                  minimumSize: const Size.fromHeight(52),
                ),
                child: Text("Build ${widget.name}'s voice"),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
