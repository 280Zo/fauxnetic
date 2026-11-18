import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../people/expiry.dart';
import '../people/person.dart';
import '../theme.dart';

/// Wraps a screen that uses [person]'s voice. With 5 minutes or less left it shows
/// "Sam's voice will be deleted in N min" above the screen; once the voice expires it calls
/// [onExpired] once (which deletes the voice and closes back to People).
class ExpiryGuard extends StatefulWidget {
  const ExpiryGuard({super.key, required this.person, required this.now, required this.onExpired, required this.child});

  final Person person;
  final DateTime Function() now;
  final Future<void> Function() onExpired;
  final Widget child;

  @override
  State<ExpiryGuard> createState() => _ExpiryGuardState();
}

const _warnAt = Duration(minutes: 5);

class _ExpiryGuardState extends State<ExpiryGuard> {
  Timer? _timer;
  var _fired = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _check());
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Duration? get _left {
    final e = widget.person.expiresAt;
    return e?.difference(widget.now());
  }

  void _check() {
    if (!mounted) return;
    final left = _left;
    if (left != null && left <= Duration.zero && !_fired) {
      _fired = true;
      _timer?.cancel();
      unawaited(widget.onExpired());
      return;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final left = _left;
    final warn = left != null && left > Duration.zero && left <= _warnAt;
    if (!warn) return widget.child;
    final c = context.colors;
    return Column(
      children: [
        Material(
          color: c.card,
          child: SafeArea(
            bottom: false,
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: c.clone, width: 2)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              child: Text(
                "${widget.person.name}'s voice will be ${timeLeft(left)}",
                style: TextStyle(color: c.ink, fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ),
        Expanded(
          child: MediaQuery.removePadding(context: context, removeTop: true, child: widget.child),
        ),
      ],
    );
  }
}
