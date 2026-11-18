import 'package:material_ui/material_ui.dart';

import '../audio/take_adjust.dart';
import '../cues/cue.dart';
import '../theme.dart';
import 'speak_controller.dart';

/// The shown take's Speed, Pitch, Pauses and Volume, "Even out loudness" and Reset. Each change is
/// saved when a slider is let go, and the take then plays and shares that way.
Future<void> showAdjustSheet(BuildContext context, SpeakController c, CueItem item) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  // Taller than the default 9/16 of the screen when it needs to be; scrolls on a short one.
  isScrollControlled: true,
  builder: (_) => SingleChildScrollView(
    child: _AdjustSheet(controller: c, item: item),
  ),
);

class _AdjustSheet extends StatefulWidget {
  const _AdjustSheet({required this.controller, required this.item});
  final SpeakController controller;
  final CueItem item;

  @override
  State<_AdjustSheet> createState() => _AdjustSheetState();
}

String _times(double v, int digits) {
  var s = v.toStringAsFixed(digits);
  if (digits == 2 && s.endsWith('0')) s = s.substring(0, s.length - 1);
  return '$s×';
}

String _signed(double v, String unit) {
  if (v == 0) return '0 $unit';
  final n = v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);
  return '${v > 0 ? '+' : ''}$n $unit';
}

class _AdjustSheetState extends State<_AdjustSheet> {
  late TakeAdjust _a = widget.controller.adjustOf(widget.item);

  Future<void> _save(TakeAdjust a) async {
    setState(() => _a = a);
    await widget.controller.adjust(widget.item, a);
  }

  Widget _slider({
    required String key,
    required String label,
    required String value,
    required double v,
    required double min,
    required double max,
    required double step,
    required TakeAdjust Function(double v) apply,
  }) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Row(
      children: [
        SizedBox(width: 72, child: Text(label)),
        Expanded(
          child: Slider(
            key: Key('adjust-$key'),
            value: v,
            min: min,
            max: max,
            divisions: ((max - min) / step).round(),
            activeColor: context.colors.clone,
            onChanged: (x) => setState(() => _a = apply(x)),
            onChangeEnd: (x) => _save(apply(x)),
          ),
        ),
        SizedBox(
          width: 56,
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: TextStyle(color: context.colors.muted),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final a = _a;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _slider(
              key: 'speed',
              label: 'Speed',
              value: _times(a.speed, 2),
              v: a.speed,
              min: TakeAdjust.minSpeed,
              max: TakeAdjust.maxSpeed,
              step: 0.05,
              apply: (x) => a.copyWith(speed: x),
            ),
            _slider(
              key: 'pitch',
              label: 'Pitch',
              value: _signed(a.pitch, 'st'),
              v: a.pitch,
              min: -TakeAdjust.maxPitch,
              max: TakeAdjust.maxPitch,
              step: 0.5,
              apply: (x) => a.copyWith(pitch: x),
            ),
            _slider(
              key: 'pauses',
              label: 'Pauses',
              value: _times(a.pauses, 1),
              v: a.pauses,
              min: TakeAdjust.minPauses,
              max: TakeAdjust.maxPauses,
              step: 0.1,
              apply: (x) => a.copyWith(pauses: x),
            ),
            _slider(
              key: 'volume',
              label: 'Volume',
              value: _signed(a.gainDb, 'dB'),
              v: a.gainDb,
              min: -TakeAdjust.maxGainDb,
              max: TakeAdjust.maxGainDb,
              step: 1,
              apply: (x) => a.copyWith(gainDb: x),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Even out loudness'),
              value: a.normalize,
              activeThumbColor: context.colors.clone,
              onChanged: (v) => _save(a.copyWith(normalize: v)),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: a.isDefault ? null : () => _save(TakeAdjust.defaults),
                style: TextButton.styleFrom(foregroundColor: context.colors.clone),
                child: const Text('Reset', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
