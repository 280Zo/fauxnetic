import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/main.dart';
import 'package:fauxnetic/storage/vault.dart';

void main() {
  testWidgets('a lost vault key explains itself', (t) async {
    await t.pumpWidget(const StartupErrorApp(error: VaultKeyLost()));
    expect(find.textContaining('lost the key that protects saved voices'), findsOneWidget);
  });

  testWidgets('any other startup failure shows a generic message', (t) async {
    await t.pumpWidget(StartupErrorApp(error: StateError('boom')));
    expect(find.text(kStartupFailedMessage), findsOneWidget);
    expect(find.textContaining('boom'), findsNothing);
  });
}
