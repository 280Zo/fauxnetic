import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../audio/word_timing.dart';
import '../cues/cue.dart';
import '../engine/voice_engine.dart';
import '../engine/tts_models.dart';
import '../recording/scripts.dart';
import '../storage/storage_report.dart';
import '../theme.dart';
import 'adjust_sheet.dart';
import 'download_dialog.dart';
import 'speak_controller.dart';

/// Lines in a clone's voice. The list (newest at the bottom) sits above one magenta-edged dock that
/// is the text box, or the player for the selected line (owner, 2026-11-18). The audience hears the
/// phone but doesn't see it, so the screen serves whoever is running the demo.
class SpeakScreen extends StatefulWidget {
  const SpeakScreen({super.key, required this.controller});
  final SpeakController controller;

  @override
  State<SpeakScreen> createState() => _SpeakScreenState();
}

class _SpeakScreenState extends State<SpeakScreen> {
  final _input = TextEditingController();

  SpeakController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadVoiceModel());
  }

  /// Opening a voice whose model isn't the one loaded: load it quietly now so the first line doesn't
  /// pay for it. No loading screen: nothing has been asked for yet (owner, 2026-11-17). A failure
  /// here shows on the first line instead.
  Future<void> _loadVoiceModel() async {
    await c.modelSettled;
    final id = c.modelId;
    if (!mounted || c.loadedModel == id || !await c.modelReady(id) || !mounted) return;
    try {
      await c.loadModel(id);
    } on EngineError {
      // The first line reports it.
    }
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  /// The dock when nothing is selected: the text box, then moods, model and Generate.
  Widget _compose(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Expanded(
        child: TextField(
          controller: _input,
          minLines: 1,
          maxLines: 3,
          textInputAction: TextInputAction.send,
          onSubmitted: (_) => _add(),
          decoration: InputDecoration(
            hintText: 'Type what ${c.person.name} should say',
            filled: true,
            fillColor: context.colors.paper,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: context.colors.rule),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: context.colors.rule),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
        ),
      ),
      const SizedBox(height: 6),
      _Tools(
        controller: c,
        trailing: FilledButton(
          onPressed: _add,
          style: FilledButton.styleFrom(
            backgroundColor: context.colors.clone,
            foregroundColor: context.colors.paper,
            visualDensity: VisualDensity.compact,
          ),
          child: const Text('Generate', style: TextStyle(fontWeight: FontWeight.w700)),
        ),
      ),
    ],
  );

  Future<void> _add() async {
    final text = _input.text;
    // The keyboard goes away on Generate and only comes back when the text box is tapped.
    FocusScope.of(context).unfocus();
    if (text.trim().isEmpty) return;
    _input.clear();
    await c.add(text);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: Row(
            children: [
              Text(
                c.person.name,
                style: TextStyle(color: context.colors.clone, fontWeight: FontWeight.w700),
              ),
              Text('  voice clone', style: TextStyle(color: context.colors.muted)),
            ],
          ),
        ),
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: c.items.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
                        child: Text(
                          'No lines yet. Type one below; it prepares in the background.',
                          style: TextStyle(color: context.colors.muted),
                        ),
                      )
                    // Reversed: the newest line sits at the bottom, by the dock, and the list
                    // opens scrolled there. A tap between or beside the lines goes back to typing
                    // (a tap on a line is the line's own).
                    : GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: c.shown == null ? null : c.newLine,
                        child: ListView(
                          reverse: true,
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                          children: [for (final item in c.items.reversed) _CueRow(item: item, controller: c)],
                        ),
                      ),
              ),
              _Dock(controller: c, compose: _compose(context)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The row above the text box: small mood buttons (recorded moods only) and the model picker.
class _Tools extends StatelessWidget {
  const _Tools({required this.controller, required this.trailing});
  final SpeakController controller;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Padding(
      padding: EdgeInsets.zero,
      child: Row(
        children: [
          Expanded(
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final m in c.moods)
                  ChoiceChip(
                    label: Text(
                      m.label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: c.mood == m ? FontWeight.w700 : FontWeight.w400,
                        color: c.mood == m ? context.colors.paper : context.colors.ink,
                      ),
                    ),
                    selected: c.mood == m,
                    showCheckmark: false,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                    selectedColor: context.colors.clone,
                    shape: StadiumBorder(side: BorderSide(color: context.colors.rule)),
                    onSelected: (_) => c.setMood(m),
                  ),
              ],
            ),
          ),
          _ModelPicker(controller: c),
          const SizedBox(width: 8),
          trailing,
        ],
      ),
    );
  }
}

/// "Model Qwen3-TTS ▾". Picking a model that isn't downloaded shows its size and licence note
/// first, then downloads it; the choice applies from the next line and is kept for this voice.
class _ModelPicker extends StatelessWidget {
  const _ModelPicker({required this.controller, this.label = true});
  final SpeakController controller;

  /// The "Model" caption; the player leaves it out to fit Re-generate on one line.
  final bool label;

  Future<void> _pick(BuildContext context, String id) async {
    final c = controller;
    if (id == c.modelId) return;
    if (!await c.modelReady(id)) {
      if (!context.mounted) return;
      if (!await confirmAndDownload(context, ttsModel(id), () => c.downloadModel(id))) return;
    }
    if (!context.mounted || !await _enoughMemory(context, ttsModel(id))) return;
    if (!context.mounted) return;
    final got = await showModelLoading(context, c, id);
    if (got != null) await c.setModel(got);
  }

  /// A model bigger than the memory free right now makes Android swap and lines crawl (VoxCPM:
  /// over 5 minutes on the A54); say so first and point to a lighter copy if there is one.
  Future<bool> _enoughMemory(BuildContext context, TtsModel m) async {
    final need = m.memoryBytes;
    final free = need == null ? null : await controller.freeMemory();
    if (need == null || free == null || free >= need || !context.mounted) return true;
    final lighter = kTtsModels
        .where((o) => o.id != m.id && o.backend == m.backend && (o.memoryBytes ?? 0) < need)
        .firstOrNull;
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('${m.label} may be very slow here'),
            content: Text(
              'It needs about ${formatBytes(need)} of free memory and this phone has ${formatBytes(free)} free '
              'right now, so a line can take many minutes. Closing other apps helps'
              '${lighter == null ? '.' : ', or try ${lighter.label}.'}',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Use anyway')),
            ],
          ),
        ) ==
        true;
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label) ...[
          Text('Model', style: TextStyle(color: context.colors.muted, fontSize: 12)),
          const SizedBox(width: 6),
        ],
        PopupMenuButton<String>(
          tooltip: 'Choose the voice model',
          onSelected: (id) => _pick(context, id),
          itemBuilder: (_) => [
            for (final m in kTtsModels)
              CheckedPopupMenuItem(value: m.id, checked: m.id == controller.modelId, child: Text(m.label)),
          ],
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(ttsModel(controller.modelId).label, style: const TextStyle(fontWeight: FontWeight.w700)),
              const Icon(Icons.arrow_drop_down),
            ],
          ),
        ),
      ],
    );
  }
}

/// Loads [id] behind a loading screen ("Loading VoxCPM 2… 0:12", Cancel). Returns the model to
/// use: [id] once loaded, Qwen if the owner takes that offer after a failure, or null (cancelled or
/// closed: keep the current one).
Future<String?> showModelLoading(BuildContext context, SpeakController c, String id) => showDialog<String?>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _LoadingDialog(controller: c, model: ttsModel(id)),
);

class _LoadingDialog extends StatefulWidget {
  const _LoadingDialog({required this.controller, required this.model});
  final SpeakController controller;
  final TtsModel model;

  @override
  State<_LoadingDialog> createState() => _LoadingDialogState();
}

class _LoadingDialogState extends State<_LoadingDialog> {
  var _seconds = 0;
  late final Timer _tick;
  EngineError? _error;
  var _done = false;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() => _seconds++));
    widget.controller
        .loadModel(widget.model.id)
        .then(
          (_) => _close(widget.model.id),
          onError: (Object e) {
            if (e is EngineError && e.kind != EngineErrorKind.cancelled) {
              if (mounted) setState(() => _error = e);
              _tick.cancel();
            } else {
              _close(null);
            }
          },
        );
  }

  void _close(String? result) {
    if (_done || !mounted) return;
    _done = true;
    Navigator.pop(context, result);
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.model;
    final e = _error;
    if (e != null) {
      final fallback = kTtsModels.first;
      return AlertDialog(
        title: Text("Couldn't load ${m.label}"),
        content: Text(
          e.kind == EngineErrorKind.outOfMemory
              ? "There's not enough free memory for ${m.label} right now. Close other apps and try again"
                    '${m.id == fallback.id ? '.' : ', or use ${fallback.label}.'}'
              : e.message,
        ),
        actions: [
          if (m.id != fallback.id)
            TextButton(onPressed: () => _close(fallback.id), child: Text('Use ${fallback.label}')),
          TextButton(onPressed: () => _close(null), child: const Text('Close')),
        ],
      );
    }
    final s = _seconds;
    return AlertDialog(
      title: Text('Loading ${m.label}…'),
      content: Row(
        children: [
          const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3)),
          const SizedBox(width: 16),
          Text('${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}', style: TextStyle(color: context.colors.muted)),
        ],
      ),
      // Closes at once and keeps the current model, even when the load can't stop yet (it waits for a
      // line being made); a load that finishes later is ignored (owner, 2026-11-17).
      actions: [
        TextButton(
          onPressed: () {
            unawaited(widget.controller.cancelLoad());
            _close(null);
          },
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

/// The shown take's waveform; bars up to [progress] (0–1) are drawn in the clone color.
class _Waveform extends StatelessWidget {
  const _Waveform({required this.peaks, required this.progress});
  final List<double> peaks;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final played = (progress * peaks.length).floor();
    return Semantics(
      label: 'Waveform',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (final (i, p) in peaks.indexed)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1),
                child: FractionallySizedBox(
                  heightFactor: (0.12 + 0.88 * p).clamp(0.0, 1.0),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: i < played ? context.colors.clone : context.colors.rule,
                      borderRadius: const BorderRadius.all(Radius.circular(1)),
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

/// "0:03".
String _clock(double seconds) {
  final s = seconds.isFinite ? seconds.floor() : 0;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// The one interaction area at the bottom: [compose] when nothing is selected, else the player.
/// Always the same height, so the list never jumps.
class _Dock extends StatelessWidget {
  const _Dock({required this.controller, required this.compose});
  final SpeakController controller;
  final Widget compose;

  static const height = 176.0;

  @override
  Widget build(BuildContext context) {
    final shown = controller.shown;
    return Container(
      key: const Key('dock'),
      height: height,
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: BoxDecoration(
        color: context.colors.card,
        borderRadius: BorderRadius.circular(18),
        border: Border(top: BorderSide(color: context.colors.clone, width: 4)),
      ),
      child: shown != null && shown.hasClip ? _Player(item: shown, controller: controller) : compose,
    );
  }
}

class _Player extends StatelessWidget {
  const _Player({required this.item, required this.controller});
  final CueItem item;
  final SpeakController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final playing = c.playingId == item.id;
    final muted = TextStyle(color: context.colors.muted, fontSize: 13);
    final extras = [?_currentClip(item)?.engine, if (item.mood != Mood.conversational) item.mood.label];
    final length = c.lengthSeconds;
    final progress = playing && length > 0 ? (c.playedSeconds / length).clamp(0.0, 1.0) : 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 32,
          child: Row(
            children: [
              if (item.clips.length > 1)
                _takeSwitcher(context, item, c)
              else if (!c.adjustOf(item).isDefault)
                Padding(padding: const EdgeInsets.only(left: 4), child: _adjustedMark(context)),
              // Model and Re-generate shrink together rather than wrap on a narrow phone.
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _ModelPicker(controller: c, label: false),
                        TextButton(
                          onPressed: () => c.tryAgain(item),
                          style: TextButton.styleFrom(
                            foregroundColor: context.colors.clone,
                            visualDensity: VisualDensity.compact,
                          ),
                          child: const Text(
                            '↻ Re-generate',
                            maxLines: 1,
                            softWrap: false,
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        _SpokenLine(
          words: c.words.isNotEmpty ? c.words : item.text.split(RegExp(r'\s+')),
          active: playing ? activeWord(c.wordStarts, c.playedSeconds) : -1,
        ),
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: c.person.name,
                style: TextStyle(color: context.colors.clone, fontWeight: FontWeight.w700),
              ),
              TextSpan(text: ' · synthetic${extras.map((e) => ' · $e').join()}'),
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: muted,
        ),
        const SizedBox(height: 4),
        Expanded(
          child: _Waveform(peaks: c.waveform, progress: progress),
        ),
        // Share at the left, play in the center under its time, New at the right.
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Share',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.share_outlined, size: 20),
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      await c.share(item);
                      final why = c.shareError;
                      if (why != null) messenger.showSnackBar(SnackBar(content: Text(why)));
                    },
                  ),
                  IconButton(
                    tooltip: 'Adjust',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.tune, size: 20),
                    onPressed: () => showAdjustSheet(context, c, item),
                  ),
                ],
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${_clock(playing ? c.playedSeconds : 0)} / ${_clock(length)}',
                  style: muted.copyWith(fontSize: 12),
                ),
                IconButton.filled(
                  tooltip: playing ? 'Stop' : 'Play',
                  visualDensity: VisualDensity.compact,
                  style: IconButton.styleFrom(
                    backgroundColor: context.colors.clone,
                    foregroundColor: context.colors.paper,
                  ),
                  icon: Icon(playing ? Icons.stop : Icons.play_arrow),
                  onPressed: () => playing ? c.stop() : c.play(item),
                ),
              ],
            ),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: c.newLine,
                  style: TextButton.styleFrom(foregroundColor: context.colors.clone),
                  child: const Text('✎ New', style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The line in the player, on one row: while it plays, the word being spoken is magenta and the
/// row slides along to keep it in view (word times are estimates, see estimateWordStarts).
class _SpokenLine extends StatefulWidget {
  const _SpokenLine({required this.words, required this.active});
  final List<String> words;

  /// Index of the word being spoken; -1 when none (not playing, or before the first word).
  final int active;

  static const style = TextStyle(fontWeight: FontWeight.w700, fontSize: 16);

  @override
  State<_SpokenLine> createState() => _SpokenLineState();
}

class _SpokenLineState extends State<_SpokenLine> {
  final _scroll = ScrollController();

  String _piece(int k) {
    final w = widget.words;
    return '${k == 0 ? '“' : ' '}${w[k]}${k == w.length - 1 ? '”' : ''}';
  }

  @override
  void didUpdateWidget(_SpokenLine old) {
    super.didUpdateWidget(old);
    if (widget.active != old.active || widget.words != old.words) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _follow());
    }
  }

  /// Keeps the spoken word about a third of the way in; back to the start when it stops.
  void _follow() {
    if (!mounted || !_scroll.hasClients) return;
    final pos = _scroll.position;
    var target = 0.0;
    if (widget.active >= 0) {
      final before = TextPainter(
        text: TextSpan(
          style: DefaultTextStyle.of(context).style.merge(_SpokenLine.style),
          text: [for (var k = 0; k < widget.active; k++) _piece(k)].join(),
        ),
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      target = (before.width - pos.viewportDimension / 3).clamp(0.0, pos.maxScrollExtent);
      before.dispose();
    }
    if ((target - pos.pixels).abs() > 1) {
      _scroll.animateTo(target, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final clone = context.colors.clone;
    return SingleChildScrollView(
      key: const Key('spoken-line'),
      controller: _scroll,
      scrollDirection: Axis.horizontal,
      child: Text.rich(
        key: const Key('spoken-words'),
        TextSpan(
          children: [
            for (var k = 0; k < widget.words.length; k++)
              TextSpan(
                text: _piece(k),
                style: k == widget.active ? TextStyle(color: clone) : null,
              ),
          ],
        ),
        maxLines: 1,
        softWrap: false,
        style: _SpokenLine.style,
      ),
    );
  }
}

CueClip? _currentClip(CueItem item) =>
    item.clips.isEmpty ? null : item.clips[item.current.clamp(0, item.clips.length - 1)];

/// The tiny sliders glyph on a take whose speed, pitch, pauses or volume were changed.
Widget _adjustedMark(BuildContext context) =>
    Icon(Icons.tune, size: 12, color: context.colors.clone, semanticLabel: 'Adjusted');

/// ‹ n/m ›: picks which take Say it and Share use.
Widget _takeSwitcher(BuildContext context, CueItem item, SpeakController controller) {
  final n = item.current.clamp(0, item.clips.length - 1);
  Widget arrow(IconData icon, String tip, int to) => IconButton(
    tooltip: tip,
    visualDensity: VisualDensity.compact,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
    icon: Icon(icon, size: 20),
    onPressed: to >= 0 && to < item.clips.length ? () => controller.showTake(item, to) : null,
  );
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      arrow(Icons.chevron_left, 'Previous take', n - 1),
      Text('${n + 1}/${item.clips.length}', style: TextStyle(color: context.colors.muted, fontSize: 13)),
      if (!controller.adjustOf(item).isDefault)
        Padding(padding: const EdgeInsets.only(left: 2), child: _adjustedMark(context)),
      arrow(Icons.chevron_right, 'Next take', n + 1),
    ],
  );
}

/// A line's card, 8 apart from the next, that swipes left to remove.
Widget _removable(BuildContext context, CueItem item, SpeakController controller, Widget child) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 4),
  child: Dismissible(
    key: ValueKey(item.id),
    direction: DismissDirection.endToStart,
    onDismissed: (_) => controller.remove(item),
    background: Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: 16),
      decoration: BoxDecoration(color: context.colors.rule, borderRadius: BorderRadius.circular(12)),
      child: const Text('Remove'),
    ),
    // Dismissible stacks the row on its background, which would let a short line shrink to its
    // words; full width keeps the whole card tappable and highlighted.
    child: SizedBox(width: double.infinity, child: child),
  ),
);

/// One line in the list. Tapping a line with audio selects it into the dock's player (again: back to
/// typing); a failed line retries; a line still being made shows its progress.
class _CueRow extends StatelessWidget {
  const _CueRow({required this.item, required this.controller});
  final CueItem item;
  final SpeakController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final selected = c.shownId == item.id && item.hasClip;
    final played = item.status == CueStatus.played;
    final statusColor = switch (item.status) {
      CueStatus.ready => context.colors.clone,
      CueStatus.failed => Theme.of(context).colorScheme.error,
      _ => context.colors.muted,
    };
    final onTap = switch (item.status) {
      CueStatus.ready || CueStatus.played => () => selected ? c.newLine() : c.select(item),
      CueStatus.failed => () => c.retry(item),
      _ => null,
    };
    final making = item.status == CueStatus.preparing;
    final takes = item.clips.length;
    return _removable(
      context,
      item,
      c,
      ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Material(
          color: selected
              ? Color.alphaBlend(context.colors.clone.withValues(alpha: 0.12), context.colors.card)
              : context.colors.card,
          child: InkWell(
            key: selected ? Key('selected-${item.id}') : null,
            onTap: onTap,
            onLongPress: () async {
              final messenger = ScaffoldMessenger.of(context);
              await Clipboard.setData(ClipboardData(text: item.text));
              messenger.showSnackBar(const SnackBar(content: Text('Copied'), duration: Duration(seconds: 2)));
            },
            child: Container(
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: selected ? context.colors.clone : Colors.transparent, width: 3)),
              ),
              padding: const EdgeInsets.fromLTRB(10, 10, 8, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.text,
                    style: TextStyle(color: played && !selected ? context.colors.muted : context.colors.ink),
                  ),
                  if (item.status == CueStatus.failed && item.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('${item.error} Tap to retry.', style: TextStyle(color: statusColor, fontSize: 13)),
                    )
                  else if (!item.hasClip)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(c.statusOf(item), style: TextStyle(color: statusColor, fontSize: 13)),
                    )
                  else if (takes > 1)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text('$takes takes', style: TextStyle(color: context.colors.muted, fontSize: 12)),
                    ),
                  if (making)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: c.progressOf(item),
                          minHeight: 3,
                          color: context.colors.muted,
                          backgroundColor: context.colors.rule,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
