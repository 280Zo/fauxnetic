import 'package:material_ui/material_ui.dart';

import '../people/people_repo.dart';
import '../theme.dart';

/// Names the person, then hands the phone over for the guided reading.
class NewVoiceScreen extends StatefulWidget {
  const NewVoiceScreen({super.key, required this.onStart});
  final Future<void> Function(String name) onStart;

  @override
  State<NewVoiceScreen> createState() => _NewVoiceScreenState();
}

class _NewVoiceScreenState extends State<NewVoiceScreen> {
  final _name = TextEditingController();
  String? _error;
  var _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onStart(_name.text.trim());
    } on PersonInvalid catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = _name.text.trim();
    return Scaffold(
      appBar: AppBar(title: const Text('New voice')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: 'Their name', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 20),
              Text(
                'Hand the phone to ${name.isEmpty ? 'them' : name}. They read one short passage and answer one '
                'question, about 30 seconds. Speaking is their consent.',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
              const Spacer(),
              FilledButton(
                onPressed: name.isEmpty || _busy ? null : _start,
                style: FilledButton.styleFrom(
                  backgroundColor: context.colors.ink,
                  minimumSize: const Size.fromHeight(52),
                ),
                child: const Text('Start reading'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
