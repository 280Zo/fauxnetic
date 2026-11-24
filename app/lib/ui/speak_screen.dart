import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../audio/word_timing.dart';
import '../cues/cue.dart';
import '../engine/voice_engine.dart';
import '../engine/tts_models.dart';
import '../models/download_center.dart';
import '../models/model_store.dart' show formatSize;
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

  /// The dock when nothing is selected: the text box, then the moods, then model and Generate.
  Widget _compose(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Expanded(
        // The box fills the dock's height (kept for the player), so long lines have room.
        child: TextField(
          controller: _input,
          expands: true,
          minLines: null,
          maxLines: null,
          textAlignVertical: TextAlignVertical.top,
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
      if (c.moods.isNotEmpty) ...[const SizedBox(height: 8), _Moods(controller: c)],
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
                          'Type something for ${c.person.name} to say.',
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

/// The moods recorded for this voice, on one row of their own under the text box. Owner,
/// 2026-11-23: beside the model picker they wrapped onto several rows, and the bold label of the
/// picked one re-wrapped them and squashed the text box. Here the picked one changes only color,
/// never size, and a row too narrow for them scrolls sideways instead of wrapping.
class _Moods extends StatelessWidget {
  const _Moods({required this.controller});
  final SpeakController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final m in c.moods) ...[
            if (m != c.moods.first) const SizedBox(width: 6),
            ChoiceChip(
              label: Text(
                m.label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: c.mood == m ? context.colors.paper : context.colors.ink,
                ),
              ),
              selected: c.mood == m,
              showCheckmark: false,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              labelPadding: const EdgeInsets.symmetric(horizontal: 6),
              selectedColor: _moodColor(context, m) ?? context.colors.ink,
              shape: StadiumBorder(side: BorderSide(color: _moodColor(context, m) ?? context.colors.rule)),
              onSelected: (_) => c.setMood(m),
            ),
          ],
        ],
      ),
    );
  }
}

/// The row under the moods: the model picker and [trailing] (Generate).
class _Tools extends StatelessWidget {
  const _Tools({required this.controller, required this.trailing});
  final SpeakController controller;
  final Widget trailing;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const Spacer(),
      _ModelPicker(controller: controller),
      const SizedBox(width: 8),
      trailing,
    ],
  );
}

/// "Model Qwen3-TTS ▾". Picking a model that isn't downloaded shows its size and licence note
/// first, then downloads it; the choice applies from the next line and is kept for this voice.
class _ModelPicker extends StatelessWidget {
  const _ModelPicker({required this.controller, this.label = 'Model'});
  final SpeakController controller;

  /// The caption before the model: "Model" by the text box, "Again:" in the player (the model its
  /// Again button will use).
  final String label;

  Future<void> _pick(BuildContext context, String id) async {
    final c = controller;
    if (id == c.modelId) return;
    if (!await c.modelReady(id)) {
      // 2026-11-18: it downloads in the background; it can be picked once it is here.
      final j = c.downloadOf(id);
      final m = ttsModel(id);
      // Waiting for Wi-Fi: asks before letting it use mobile data.
      if (j?.state == JobState.waitingWifi && context.mounted) {
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('Use mobile data for ${m.label}?'),
            content: Text('About ${formatSize(j!.left)} is left to download. Your data plan may charge for it.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Wait for Wi-Fi')),
              TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Use mobile data')),
            ],
          ),
        );
        if (ok == true) c.allowMobileData(id);
        return;
      }
      if (!context.mounted || (j != null && j.pending)) return;
      final messenger = ScaffoldMessenger.of(context);
      // A failed download was agreed to already: it is just tried again.
      if (j?.state == JobState.failed) {
        await c.startDownload(id);
        messenger.showSnackBar(SnackBar(content: Text('Trying ${m.label} again')));
        return;
      }
      if (!await confirmDownload(context, m)) return;
      await c.startDownload(id);
      messenger.showSnackBar(SnackBar(content: Text('Downloading ${m.label} in the background')));
      return;
    }
    if (!context.mounted || !await _enoughMemory(context, ttsModel(id))) return;
    if (!context.mounted) return;
    // Chosen at once for new lines, with no loading screen (owner, 2026-11-23: with lines queued it
    // sat there until the line being made finished). With nothing waiting it loads quietly now, so
    // the next line starts sooner; otherwise the queue loads it when its first line comes up. A
    // failure shows on that line.
    final messenger = ScaffoldMessenger.of(context);
    final busy = c.items.any((i) => i.status == CueStatus.queued || i.status == CueStatus.preparing);
    await c.setModel(id);
    if (busy) {
      messenger.showSnackBar(SnackBar(content: Text('New lines will use ${ttsModel(id).label}')));
      return;
    }
    try {
      await c.loadModel(id);
    } on EngineError {
      // The first line reports it.
    }
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
        Text(label, style: TextStyle(color: context.colors.muted, fontSize: 12)),
        const SizedBox(width: 6),
        PopupMenuButton<String>(
          tooltip: 'Choose the voice model',
          onSelected: (id) => _pick(context, id),
          itemBuilder: (_) => [for (final m in kTtsModels) _menuItem(context, m)],
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

  /// A model in the menu, with a second line when there's something to know (owner-approved mockup,
  /// 2026-11-23): not downloaded (its size), downloading (can't be picked yet), waiting for Wi-Fi in
  /// amber (tap: use mobile data), failed in coral (tap: try again).
  PopupMenuItem<String> _menuItem(BuildContext context, TtsModel m) {
    final colors = context.colors;
    final j = controller.downloadOf(m.id);
    final (String? line, Color? color, bool enabled) = switch (j?.state) {
      JobState.failed => ('Download failed · tap to try again', colors.failed, true),
      JobState.waitingWifi => ('Waiting for Wi-Fi · tap to use mobile data', colors.making, true),
      JobState.waitingNetwork => ('Waiting for a connection', colors.soft, false),
      JobState.queued ||
      JobState.downloading => ('Downloading ${j!.received * 100 ~/ (j.total == 0 ? 1 : j.total)}%', colors.soft, false),
      _ =>
        controller.onPhone(m.id)
            ? (null, null, true)
            : ('Not downloaded · ${formatSize(m.downloadBytes)}', colors.soft, true),
    };
    return CheckedPopupMenuItem(
      value: m.id,
      checked: m.id == controller.modelId,
      enabled: enabled,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(m.label),
          if (line != null)
            Text(
              line,
              style: TextStyle(
                color: color,
                fontSize: 13.5,
                fontWeight: color == colors.failed || color == colors.making ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
        ],
      ),
    );
  }
}

/// The shown take's waveform; bars up to [progress] (0–1) are drawn in the clone color.
class _Waveform extends StatelessWidget {
  const _Waveform({super.key, required this.peaks, required this.progress});
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

  /// Room for the approved player (2026-11-23): who made it, up to three rows of the line, the
  /// transport and the four actions. Typing uses the same height, so the list never jumps.
  static const height = 312.0;

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
    final colors = context.colors;
    final playing = c.playingId == item.id;
    final engine = _currentClip(item)?.engine;
    final length = c.lengthSeconds;
    final progress = playing && length > 0 ? (c.playedSeconds / length).clamp(0.0, 1.0) : 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Who made it: the clone's name, its mood, the take, and the model for Again.
        SizedBox(
          height: 34,
          child: Row(
            children: [
              Flexible(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: c.person.name,
                        style: TextStyle(color: colors.clone, fontWeight: FontWeight.w700),
                      ),
                      const TextSpan(text: ' synthetic'),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.soft, fontSize: 14),
                ),
              ),
              if (item.mood != Mood.conversational) ...[const SizedBox(width: 8), _moodTag(context, item.mood)],
              if (item.clips.length > 1) _takeSwitcher(context, item, c),
              // On a narrow phone the picker shrinks rather than push the row off the edge.
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: colors.raised, borderRadius: BorderRadius.circular(10)),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: _ModelPicker(controller: c, label: 'Again:'),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        // The model that made the shown take, on its own line so the takes and mood can't push it
        // off, and always, even when it's the picker's (owner-approved mockup, 2026-11-23).
        if (engine != null)
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: item.clips.length > 1
                      ? 'Take ${item.current.clamp(0, item.clips.length - 1) + 1} made with '
                      : 'Made with ',
                ),
                TextSpan(
                  text: engine,
                  style: TextStyle(color: colors.ink, fontWeight: FontWeight.w700),
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: colors.soft, fontSize: 14),
          ),
        const SizedBox(height: 8),
        _SpokenLine(
          words: c.words.isNotEmpty ? c.words : item.text.split(RegExp(r'\s+')),
          active: playing ? activeWord(c.wordStarts, c.playedSeconds) : -1,
        ),
        const Spacer(),
        // The transport: the big Play at the end of a slim waveform, then the time.
        Container(
          padding: const EdgeInsets.fromLTRB(6, 6, 16, 6),
          decoration: BoxDecoration(color: colors.paper, borderRadius: BorderRadius.circular(999)),
          child: Row(
            children: [
              SizedBox.square(
                dimension: 60,
                child: IconButton.filled(
                  tooltip: playing ? 'Stop' : 'Play',
                  style: IconButton.styleFrom(backgroundColor: colors.clone, foregroundColor: colors.paper),
                  icon: Icon(playing ? Icons.stop_rounded : Icons.play_arrow_rounded, size: 32),
                  onPressed: () => playing ? c.stop() : c.play(item),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 28,
                  child: _Waveform(key: const Key('waveform'), peaks: c.waveform, progress: progress),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${_clock(playing ? c.playedSeconds : 0)} / ${_clock(length)}',
                style: TextStyle(color: colors.ink, fontSize: 15, fontFeatures: const [FontFeature.tabularFigures()]),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              flex: 10,
              child: _Action(
                label: 'Share',
                icon: Icons.ios_share_rounded,
                onTap: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  await c.share(item);
                  final why = c.shareError;
                  if (why != null) messenger.showSnackBar(SnackBar(content: Text(why)));
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 10,
              child: _Action(
                label: 'Adjust',
                icon: Icons.tune_rounded,
                marked: !c.adjustOf(item).isDefault,
                onTap: () => showAdjustSheet(context, c, item),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 10,
              child: _Action(label: 'Again', icon: Icons.refresh_rounded, onTap: () => c.tryAgain(item)),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 13,
              child: _Action(label: 'New line', icon: Icons.edit_rounded, primary: true, onTap: c.newLine),
            ),
          ],
        ),
      ],
    );
  }
}

/// One of the player's four actions: a big labeled button (62 high). [primary] is New line, in
/// solid ink so it doesn't compete with the magenta Play; [marked] shows a dot (Adjust: changed).
class _Action extends StatelessWidget {
  const _Action({
    required this.label,
    required this.icon,
    required this.onTap,
    this.primary = false,
    this.marked = false,
  });
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool primary, marked;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final fg = primary ? colors.paper : colors.ink;
    return Material(
      key: Key('act-$label'),
      color: primary ? colors.ink : colors.raised,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: SizedBox(
          height: 62,
          child: Stack(
            children: [
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 22, color: fg),
                    const SizedBox(height: 4),
                    Text(
                      label,
                      maxLines: 1,
                      style: TextStyle(
                        color: fg,
                        fontSize: 14,
                        fontWeight: primary ? FontWeight.w700 : FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
              if (marked)
                Positioned(
                  top: 8,
                  right: 10,
                  child: Container(
                    key: const Key('adjusted'),
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(color: colors.clone, shape: BoxShape.circle),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Each mood's own color (conversational has none: neutral).
Color? _moodColor(BuildContext context, Mood m) => switch (m) {
  Mood.excited => context.colors.excited,
  Mood.annoyed => context.colors.annoyed,
  Mood.worried => context.colors.worried,
  _ => null,
};

/// A mood's name in its color, on a tint of it.
Widget _moodTag(BuildContext context, Mood m) {
  final color = _moodColor(context, m) ?? context.colors.soft;
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
    decoration: BoxDecoration(color: color.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(99)),
    child: Text(
      m.label,
      style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w700),
    ),
  );
}

/// The line in the player, wrapped on up to three rows: while it plays, the word being spoken is
/// magenta and a longer line scrolls down to keep it in view (word times are estimates, see
/// estimateWordStarts). Until 2026-11-23 it was one sliding row, which cut most lines off.
class _SpokenLine extends StatefulWidget {
  const _SpokenLine({required this.words, required this.active});
  final List<String> words;

  /// Index of the word being spoken; -1 when none (not playing, or before the first word).
  final int active;

  static const style = TextStyle(fontWeight: FontWeight.w700, fontSize: 20, height: 1.3);
  static const rows = 3;

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

  /// Keeps the row with the spoken word in view, one row from the top; back to the start when it stops.
  void _follow() {
    if (!mounted || !_scroll.hasClients) return;
    final pos = _scroll.position;
    var target = 0.0;
    final width = context.size?.width;
    if (widget.active >= 0 && width != null) {
      final style = DefaultTextStyle.of(context).style.merge(_SpokenLine.style);
      final all = [for (var k = 0; k < widget.words.length; k++) _piece(k)];
      final painter = TextPainter(
        text: TextSpan(style: style, text: all.join()),
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: width);
      final at = all.take(widget.active).fold<int>(0, (n, p) => n + p.length);
      final y = painter.getOffsetForCaret(TextPosition(offset: at), Rect.zero).dy;
      final row = painter.preferredLineHeight;
      target = (y - row).clamp(0.0, pos.maxScrollExtent);
      painter.dispose();
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
    final row = MediaQuery.textScalerOf(context).scale(_SpokenLine.style.fontSize!) * _SpokenLine.style.height!;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: row * _SpokenLine.rows + 1),
      child: SingleChildScrollView(
        key: const Key('spoken-line'),
        controller: _scroll,
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
          style: _SpokenLine.style,
        ),
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
    final colors = context.colors;
    final selected = c.shownId == item.id && item.hasClip;
    final played = item.status == CueStatus.played;
    final playing = c.playingId == item.id;
    final statusColor = switch (item.status) {
      CueStatus.failed => colors.failed,
      CueStatus.preparing => colors.making,
      _ => colors.soft,
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
        borderRadius: BorderRadius.circular(16),
        child: Material(
          color: selected ? Color.alphaBlend(colors.clone.withValues(alpha: 0.14), colors.card) : colors.card,
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
                border: Border(left: BorderSide(color: selected ? colors.clone : Colors.transparent, width: 4)),
              ),
              padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Full strength always: grey text for played lines looked disabled.
                        Text(item.text, style: TextStyle(color: colors.ink, fontSize: 18, height: 1.38)),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            if (item.status == CueStatus.failed && item.error != null)
                              Text('${item.error} Tap to retry.', style: TextStyle(color: statusColor, fontSize: 14))
                            else if (!item.hasClip)
                              Text(c.statusOf(item), style: TextStyle(color: statusColor, fontSize: 14))
                            else if (playing)
                              Text(
                                'Playing',
                                style: TextStyle(color: colors.clone, fontSize: 14, fontWeight: FontWeight.w700),
                              )
                            else if (played)
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.check_rounded, size: 16, color: colors.soft),
                                  const SizedBox(width: 4),
                                  Text('Played', style: TextStyle(color: colors.soft, fontSize: 14)),
                                ],
                              )
                            else
                              Text(
                                'Ready',
                                style: TextStyle(color: colors.clone, fontSize: 14, fontWeight: FontWeight.w700),
                              ),
                            if (item.mood != Mood.conversational) _moodTag(context, item.mood),
                            if (takes > 1) Text('$takes takes', style: TextStyle(color: colors.soft, fontSize: 14)),
                          ],
                        ),
                        if (making)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: c.progressOf(item),
                                minHeight: 4,
                                color: colors.making,
                                backgroundColor: colors.rule,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (item.hasClip) ...[
                    const SizedBox(width: 12),
                    SizedBox.square(
                      key: Key('play-${item.id}'),
                      dimension: 44,
                      child: IconButton.filled(
                        tooltip: playing ? 'Stop ${item.text}' : 'Play ${item.text}',
                        padding: EdgeInsets.zero,
                        style: IconButton.styleFrom(
                          backgroundColor: playing ? colors.clone : colors.raised,
                          foregroundColor: playing ? colors.paper : colors.ink,
                        ),
                        icon: Icon(playing ? Icons.stop_rounded : Icons.play_arrow_rounded, size: 24),
                        onPressed: () => playing ? c.stop() : c.play(item),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
