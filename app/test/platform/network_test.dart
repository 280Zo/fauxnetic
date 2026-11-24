import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/platform/network.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('fauxnetic/settings');
  void answer(Object? Function(MethodCall c) f) => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (c) async => f(c));
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
  );

  test('maps connected and metered', () async {
    answer((c) => c.method == 'network' ? {'connected': true, 'metered': true} : null);
    expect(await currentNetwork(), NetKind.metered);
    answer((c) => {'connected': true, 'metered': false});
    expect(await currentNetwork(), NetKind.unmetered);
  });

  test('no connection is none', () async {
    answer((c) => {'connected': false, 'metered': false});
    expect(await currentNetwork(), NetKind.none);
  });

  test('an error or no answer counts as metered, so mobile data is never used unasked', () async {
    // Review minor (2026-11-19): it counted as Wi-Fi. Metered waits for Wi-Fi or "Use mobile data".
    answer((c) => throw PlatformException(code: 'x'));
    expect(await currentNetwork(), NetKind.metered);
    answer((c) => null);
    expect(await currentNetwork(), NetKind.metered);
  });
}
