import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../app_services.dart';
import '../people/person.dart';
import '../recording/scripts.dart';
import 'about_screen.dart';
import 'check_words_screen.dart';
import 'expiry_guard.dart';
import 'from_file_screen.dart';
import 'new_voice_screen.dart';
import 'reading_screen.dart';
import 'settings_screen.dart';
import 'speak_screen.dart';
import 'voice_ready_screen.dart';

/// Navigation between the screens. [home] is the People screen's context; every flow ends back
/// there, with Speak opened on top when a voice was made.
class Flows {
  Flows(this.s, this.home);
  final AppServices s;
  final BuildContext home;

  NavigatorState get _nav => Navigator.of(home);

  /// Warns at 5 minutes left; at expiry deletes the voice and closes back to People, which says so.
  Widget _guard(Person p, Widget child) => ExpiryGuard(
    person: p,
    now: () => DateTime.now().toUtc(),
    onExpired: () async {
      await s.enforceExpiry(DateTime.now().toUtc());
      _nav.popUntil((r) => r.isFirst);
    },
    child: child,
  );

  Future<void> openSpeak(Person p) async {
    final c = s.speakController(p);
    await _nav.push(MaterialPageRoute<void>(builder: (_) => _guard(p, SpeakScreen(controller: c))));
    c.dispose();
  }

  void _finishWith(Person p) {
    _nav.popUntil((r) => r.isFirst);
    unawaited(openSpeak(p));
  }

  Future<void> recordNew() => _nav.push(
    MaterialPageRoute<void>(
      builder: (_) => NewVoiceScreen(
        onStart: (name) async {
          final p = await s.people.create(name, PersonSource.recorded, keepFor: s.settings.value.keepFor);
          unawaited(
            _nav.push(
              MaterialPageRoute<void>(
                builder: (_) => _guard(
                  p,
                  _ReadingHost(
                    services: s,
                    person: p,
                    mood: Mood.conversational,
                    onFinished: (ctx, ready) => Navigator.of(ctx).pushReplacement(
                      MaterialPageRoute<void>(
                        builder: (_) => _guard(ready, _VoiceReadyHost(flows: this, person: ready)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    ),
  );

  Future<void> settings({required VoidCallback onModelsRemoved}) => _nav.push(
    MaterialPageRoute<void>(
      builder: (ctx) => SettingsScreen(
        settings: s.settings.value,
        onTheme: s.setTheme,
        onKeepFor: s.setKeepFor,
        voicesOlderThan: s.countVoicesOlderThan,
        onClearLines: s.clearLines,
        onDeleteEverything: s.deleteEverything,
        storage: s.storage,
        onRemoveModels: () async {
          await s.removeModels();
          if (ctx.mounted) Navigator.of(ctx).pop();
          onModelsRemoved();
        },
        onAbout: () => Navigator.of(ctx).push(MaterialPageRoute<void>(builder: (_) => const AboutScreen())),
        models: s.modelInfo,
        onDefaultModel: s.setDefaultModel,
        onDeleteModel: s.deleteModel,
        downloadModel: s.downloadModel,
      ),
    ),
  );

  Future<void> moods(Person p) => _nav.push(
    MaterialPageRoute<void>(
      builder: (_) => _guard(p, _VoiceReadyHost(flows: this, person: p)),
    ),
  );

  Future<void> fromFile() => _nav.push(
    MaterialPageRoute<void>(
      builder: (_) => FromFileScreen(
        pickFile: s.pickUploadFile,
        analyze: s.analyzeUpload,
        play: s.playSample,
        onChosen: (name, v) => _nav.push(
          MaterialPageRoute<void>(
            builder: (_) => CheckWordsScreen(
              name: name,
              voice: v,
              transcribe: s.upload.transcribe,
              build: (words, own, spoken) =>
                  s.upload.buildFromUpload(name, v, words, ownVoice: own, spokenConsent: spoken),
              play: s.playPcm16k,
              onBuilt: _finishWith,
            ),
          ),
        ),
      ),
    ),
  );
}

/// Owns one reading session: the controller and its transcribers live exactly as long as the screen.
class _ReadingHost extends StatefulWidget {
  const _ReadingHost({
    required this.services,
    required this.person,
    required this.mood,
    required this.onFinished,
    this.replace = false,
  });
  final AppServices services;
  final Person person;
  final Mood mood;
  final bool replace;
  final void Function(BuildContext context, Person p) onFinished;

  @override
  State<_ReadingHost> createState() => _ReadingHostState();
}

class _ReadingHostState extends State<_ReadingHost> {
  ReadingSession? _session;
  var _disposed = false;

  @override
  void initState() {
    super.initState();
    unawaited(
      widget.services.readingSession(widget.person, widget.mood, replace: widget.replace).then((s) async {
        if (_disposed) {
          // Left during the spinner: same as leaving the reading screen (an unfinished new
          // person is removed).
          await s.controller.abandon();
          return s.close();
        }
        setState(() => _session = s);
      }),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    final s = _session;
    if (s != null) unawaited(s.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _session;
    // Reading the person's earlier takes takes a moment; the session is shown once they're in.
    if (s == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return ReadingScreen(controller: s.controller, onFinished: (p) => widget.onFinished(context, p));
  }
}

/// The ready screen, refreshed after each session started from it.
class _VoiceReadyHost extends StatefulWidget {
  const _VoiceReadyHost({required this.flows, required this.person});
  final Flows flows;
  final Person person;

  @override
  State<_VoiceReadyHost> createState() => _VoiceReadyHostState();
}

class _VoiceReadyHostState extends State<_VoiceReadyHost> {
  late Person _person = widget.person;

  Future<void> _record(Mood m, {bool replace = false}) async {
    final updated = await Navigator.of(context).push<Person>(
      MaterialPageRoute(
        builder: (_) => widget.flows._guard(
          _person,
          _ReadingHost(
            services: widget.flows.s,
            person: _person,
            mood: m,
            replace: replace,
            onFinished: (ctx, p) => Navigator.of(ctx).pop(p),
          ),
        ),
      ),
    );
    if (updated != null && mounted) setState(() => _person = updated);
  }

  @override
  Widget build(BuildContext context) => VoiceReadyScreen(
    person: _person,
    onAddMore: _record,
    onReRecord: (m) => _record(m, replace: true),
    onStartTyping: () => widget.flows._finishWith(_person),
  );
}
