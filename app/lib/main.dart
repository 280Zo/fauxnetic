import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'app_services.dart';
import 'models/model_store.dart';
import 'settings/settings_store.dart';
import 'storage/vault.dart';
import 'theme.dart';
import 'ui/about_screen.dart';
import 'ui/download_screen.dart';
import 'ui/flows.dart';
import 'ui/people_screen.dart';

const kStartupFailedMessage =
    "Fauxnetic couldn't start. Restart the app; if it keeps happening, clear the app's data in Settings.";

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await registerLicences();
    final services = await AppServices.create();
    final missing = await services.models.missing();
    runApp(VoiceCloneApp(services: services, modelsReady: missing.isEmpty, missing: missing));
  } catch (e) {
    runApp(StartupErrorApp(error: e));
  }
}

/// Shown instead of a blank screen when the app cannot start (for example a lost vault key).
class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({super.key, required this.error});
  final Object error;

  @override
  Widget build(BuildContext context) {
    final message = error is VaultKeyLost ? error.toString() : kStartupFailedMessage;
    return MaterialApp(
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.dark,
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Center(child: Text(message, style: Theme.of(context).textTheme.titleMedium)),
          ),
        ),
      ),
    );
  }
}

class VoiceCloneApp extends StatefulWidget {
  const VoiceCloneApp({super.key, required this.services, required this.modelsReady, this.missing});
  final AppServices services;
  final bool modelsReady;

  /// Models missing at launch (an update after a model changed); null when not known.
  final List<PinnedModel>? missing;

  @override
  State<VoiceCloneApp> createState() => _VoiceCloneAppState();
}

class _VoiceCloneAppState extends State<VoiceCloneApp> {
  late bool _ready = widget.modelsReady;

  // After Settings → Remove voice models, everything is missing: a first download again.
  late List<PinnedModel>? _missing = widget.missing;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppSettings>(
      valueListenable: widget.services.settings,
      builder: (context, settings, _) => _app(themeModeOf(settings.theme)),
    );
  }

  Widget _app(ThemeMode mode) {
    return MaterialApp(
      title: 'Fauxnetic',
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: mode,
      home: _ready
          ? Builder(
              builder: (context) {
                final s = widget.services;
                final flows = Flows(s, context);
                return PeopleScreen(
                  load: s.people.all,
                  onRecordNew: flows.recordNew,
                  onFromFile: flows.fromFile,
                  onOpen: flows.openSpeak,
                  onMoods: flows.moods,
                  onDelete: (p) => s.deletePerson(p.id),
                  takeExpired: s.takeExpired,
                  onSettings: () => flows.settings(
                    onModelsRemoved: () => setState(() {
                      _ready = false;
                      _missing = null;
                    }),
                  ),
                );
              },
            )
          : DownloadScreen(
              start: widget.services.downloadModels,
              missing: _missing,
              onDone: () {
                setState(() => _ready = true);
                // Lines queued before the models were removed carry on.
                unawaited(widget.services.preparer.runUntilEmpty());
              },
            ),
    );
  }
}
