import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../people/person.dart';
import '../platform/app_settings.dart' as settings;
import '../recording/reading_controller.dart';
import '../recording/reference_builder.dart';
import '../recording/scripts.dart';
import '../recording/takes.dart';
import '../theme.dart';
import 'check_words_screen.dart';

/// The person reads one line at a time; words they've said turn teal (their real voice).
class ReadingScreen extends StatefulWidget {
  const ReadingScreen({
    super.key,
    required this.controller,
    required this.onFinished,
    this.openSettings = settings.openAppSettings,
  });

  final ReadingController controller;
  final void Function(Person p) onFinished;
  final Future<void> Function() openSettings;

  @override
  State<ReadingScreen> createState() => _ReadingScreenState();
}

class _ReadingScreenState extends State<ReadingScreen> {
  late final AppLifecycleListener _lifecycle;
  var _finishing = false;
  var _finished = false;

  ReadingController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    // A call or switching apps mid-take: the take is dropped and the session waits, paused.
    _lifecycle = AppLifecycleListener(onHide: () => unawaited(c.onInterrupted()));
    c.addListener(_maybeFinish);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    c.removeListener(_maybeFinish);
    if (!_finished) unawaited(c.abandon());
    super.dispose();
  }

  Future<void> _maybeFinish() async {
    if (!c.done || _finishing || c.error != null || c.needsWordCheck) return;
    _finishing = true;
    Person? p;
    try {
      p = await c.finish();
    } finally {
      _finishing = false;
    }
    if (p != null && mounted) {
      _finished = true;
      widget.onFinished(p);
    }
  }

  /// One half of the split Pause | Stop button: square on the inner edge, rounded on the outer.
  static ButtonStyle _half(Color color, {required bool left}) {
    const r = Radius.circular(28);
    return FilledButton.styleFrom(
      backgroundColor: color,
      minimumSize: const Size.fromHeight(56),
      padding: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: left
            ? const BorderRadius.only(topLeft: r, bottomLeft: r)
            : const BorderRadius.only(topRight: r, bottomRight: r),
      ),
    );
  }

  String get _subtitle {
    if (c.line.openPrompt) return 'answer in your own words';
    if (c.mood == Mood.conversational) return "say it like you'd say it to a friend";
    return '${c.mood.label} · say it like you mean it';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: Text(c.person.name, style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
            child: c.done ? _buildDone(context) : _buildLine(context),
          ),
        ),
      ),
    );
  }

  /// Tap a word to fix it; the fixed words become the voice's transcript.
  Future<void> _fixWord(Take take, List<String> words, int i) async {
    final fixed = await showDialog<String>(
      context: context,
      builder: (_) => FixWordDialog(word: words[i]),
    );
    if (fixed == null || !mounted) return;
    final parts = fixed.trim().split(RegExp(r'\s+'))..removeWhere((w) => w.isEmpty);
    final next = [...words]..replaceRange(i, i + 1, parts);
    await c.setAnswerText(take, next.join(' '));
  }

  Widget _checkWords(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Check what you said', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          'The phone wrote down your answers. Tap any word it got wrong; the voice needs the exact words.',
          style: TextStyle(color: context.colors.muted),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: ListView(
            children: [
              for (final take in c.answersToCheck)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final (i, w) in take.text.split(RegExp(r'\s+')).indexed)
                        InkWell(
                          onTap: () => _fixWord(take, take.text.split(RegExp(r'\s+')), i),
                          borderRadius: BorderRadius.circular(6),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                            decoration: BoxDecoration(
                              color: context.colors.card,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: context.colors.rule),
                            ),
                            child: Text(w, style: const TextStyle(fontSize: 18)),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        FilledButton(
          onPressed: c.confirmWords,
          style: FilledButton.styleFrom(backgroundColor: context.colors.ink, minimumSize: const Size.fromHeight(52)),
          child: const Text('Build the voice'),
        ),
      ],
    );
  }

  Widget _buildDone(BuildContext context) {
    if (c.needsWordCheck) return _checkWords(context);
    if (c.error == null) {
      return Center(child: CircularProgressIndicator(color: context.colors.real));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Spacer(),
        Text(c.error!, style: Theme.of(context).textTheme.titleLarge),
        const Spacer(),
        FilledButton(
          onPressed: c.restart,
          style: FilledButton.styleFrom(backgroundColor: context.colors.ink, minimumSize: const Size.fromHeight(52)),
          child: const Text('Start again'),
        ),
      ],
    );
  }

  Widget _buildLine(BuildContext context) {
    final big = Theme.of(context).textTheme.headlineMedium!.copyWith(fontWeight: FontWeight.w700, height: 1.3);
    final words = c.lineWords;
    final spoken = c.line.openPrompt ? 0 : c.spokenWords.clamp(0, words.length);
    final said = words.take(spoken).join(' ');
    final rest = words.skip(spoken).join(' ');
    final next = c.next;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Line ${c.index + 1} of ${c.total}', style: TextStyle(color: context.colors.muted)),
        const SizedBox(height: 4),
        Text(
          _subtitle,
          style: TextStyle(color: context.colors.muted, fontStyle: FontStyle.italic),
        ),
        if (c.moreAnswers && c.line.openPrompt) ...[
          const SizedBox(height: 8),
          Text('Answer one more for a better voice', style: TextStyle(color: context.colors.real)),
        ],
        const SizedBox(height: 12),
        Expanded(
          child: _ScriptText(said: said.isEmpty ? '' : (rest.isEmpty ? said : '$said '), rest: rest, style: big),
        ),
        if (c.core != null && c.line.openPrompt) _VoiceMeter(seconds: c.answerSeconds, fill: c.fill),
        if (next != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text('Next: ${next.text}', style: TextStyle(color: context.colors.muted)),
          ),
        SizedBox(
          height: 36,
          child: _LevelMeter(bars: c.levelBars, live: c.recording),
        ),
        const SizedBox(height: 8),
        if (c.checking)
          Text('Checking…', style: TextStyle(color: context.colors.muted))
        else if (c.paused && !c.recording && c.error == null)
          Text(
            c.hasPausedTake ? 'Paused. Tap Resume to go on.' : 'Paused. Tap Record to go on.',
            style: TextStyle(color: context.colors.muted),
          )
        else if (c.hint != null)
          Text(c.hint!, style: TextStyle(color: context.colors.muted)),
        if (c.error != null) ...[
          Text(c.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: widget.openSettings, child: const Text('Open settings')),
          ),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextButton(onPressed: c.checking ? null : c.redo, child: const Text('Redo')),
            ),
            Expanded(
              flex: 2,
              // While recording the button splits: Pause on the left, Stop on the right.
              child: c.recording
                  ? Row(
                      children: [
                        Expanded(
                          child: FilledButton(
                            onPressed: c.pause,
                            style: _half(context.colors.real, left: true),
                            child: const Text('Pause', style: TextStyle(fontSize: 17)),
                          ),
                        ),
                        const SizedBox(width: 2),
                        Expanded(
                          child: FilledButton(
                            onPressed: c.stopAndCheck,
                            style: _half(context.colors.real, left: false),
                            child: const Text('Stop', style: TextStyle(fontSize: 17)),
                          ),
                        ),
                      ],
                    )
                  : FilledButton(
                      onPressed: c.checking ? null : c.record,
                      style: FilledButton.styleFrom(
                        backgroundColor: context.colors.ink,
                        minimumSize: const Size.fromHeight(56),
                      ),
                      child: Text(c.hasPausedTake ? 'Resume' : 'Record', style: const TextStyle(fontSize: 18)),
                    ),
            ),
            Expanded(
              child: TextButton(onPressed: c.checking ? null : c.skip, child: const Text('Skip')),
            ),
          ],
        ),
        if (c.core != null) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: c.line.openPrompt
                      ? (c.recording || c.checking ? null : c.nextPrompt)
                      : (c.canChangePassage ? c.changePassage : null),
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  child: Text(c.line.openPrompt ? 'Another question' : 'Try a different passage'),
                ),
              ),
              if (c.moreAnswers && c.line.openPrompt) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: c.recording || c.checking ? null : c.finishAnswers,
                    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    child: const Text('Finish'),
                  ),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }
}

/// Label and line under the voice meter.
(String, String) meterCopy(VoiceFill f) => switch (f) {
  VoiceFill.basic => ('Basic', 'Keep going'),
  VoiceFill.good => ('Good', 'Good — you can stop any time'),
  VoiceFill.full => ('Full', "Full — that's all a voice can use"),
};

/// How much answer speech the voice has: a bar over 0–15 s with a mark at 7 s, where answers
/// start to beat the passage.
class _VoiceMeter extends StatelessWidget {
  const _VoiceMeter({required this.seconds, required this.fill});
  final double seconds;
  final VoiceFill fill;

  @override
  Widget build(BuildContext context) {
    final (label, line) = meterCopy(fill);
    final color = fill == VoiceFill.basic ? context.colors.muted : context.colors.real;
    return Padding(
      key: const Key('voiceMeter'),
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                label,
                style: TextStyle(color: color, fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(line, style: TextStyle(color: context.colors.muted, fontSize: 13)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          LayoutBuilder(
            builder: (context, box) => Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: (seconds / kRefMaxSeconds).clamp(0.0, 1.0),
                    minHeight: 6,
                    color: color,
                    backgroundColor: context.colors.rule,
                  ),
                ),
                Positioned(
                  left: box.maxWidth * kAnswerMinSeconds / kRefMaxSeconds - 1,
                  top: 0,
                  bottom: 0,
                  child: Container(width: 2, color: context.colors.ink),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The line being read, so the reader never has to stop and scroll: the text shrinks (down to
/// [_minFontSize]) until it all fits, and if it still doesn't, it scrolls to keep the spoken
/// word in the top third.
class _ScriptText extends StatefulWidget {
  const _ScriptText({required this.said, required this.rest, required this.style});
  final String said;
  final String rest;
  final TextStyle style;

  @override
  State<_ScriptText> createState() => _ScriptTextState();
}

const _minFontSize = 16.0;

class _ScriptTextState extends State<_ScriptText> {
  final _scroll = ScrollController();
  var _lastTarget = 0.0;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  TextSpan _span(double size) => TextSpan(
    style: widget.style.copyWith(fontSize: size),
    children: [
      TextSpan(
        text: widget.said,
        style: TextStyle(color: context.colors.real),
      ),
      TextSpan(
        text: widget.rest,
        style: TextStyle(color: context.colors.ink),
      ),
    ],
  );

  TextPainter _layout(double size, double width, TextScaler scaler) =>
      TextPainter(text: _span(size), textDirection: TextDirection.ltr, textScaler: scaler)..layout(maxWidth: width);

  void _follow(TextPainter painter, double viewport) {
    final caret = painter.getOffsetForCaret(TextPosition(offset: widget.said.length), Rect.zero).dy;
    final target = (caret - viewport / 3).clamp(0.0, (painter.height - viewport).clamp(0.0, double.infinity));
    if ((target - _lastTarget).abs() < 1) return;
    _lastTarget = target;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      unawaited(_scroll.animateTo(target, duration: const Duration(milliseconds: 250), curve: Curves.easeOut));
    });
  }

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, box) {
        var size = widget.style.fontSize ?? 28;
        var painter = _layout(size, box.maxWidth, scaler);
        while (painter.height > box.maxHeight && size > _minFontSize) {
          painter.dispose();
          size = (size - 1).clamp(_minFontSize, size);
          painter = _layout(size, box.maxWidth, scaler);
        }
        if (painter.height > box.maxHeight) _follow(painter, box.maxHeight);
        painter.dispose();
        return SingleChildScrollView(
          controller: _scroll,
          child: RichText(key: const Key('script-line'), textScaler: scaler, text: _span(size)),
        );
      },
    );
  }
}

class _LevelMeter extends StatelessWidget {
  const _LevelMeter({required this.bars, required this.live});
  final List<double> bars;
  final bool live;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Input level',
      child: Row(
        children: [
          for (final b in bars)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1.5),
                child: FractionallySizedBox(
                  heightFactor: (0.1 + 0.9 * b).clamp(0.0, 1.0),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: live ? context.colors.real : context.colors.rule,
                      borderRadius: const BorderRadius.all(Radius.circular(2)),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
