import 'package:flutter/services.dart';

/// No connection, mobile data (or another metered network), or Wi-Fi (unmetered).
enum NetKind { none, metered, unmetered }

const _channel = MethodChannel('fauxnetic/settings');

/// The phone's connection now, from Android's ConnectivityManager. If it can't be read, it counts
/// as unmetered, so downloads aren't blocked by a missing answer.
Future<NetKind> currentNetwork() async {
  try {
    final r = await _channel.invokeMapMethod<String, Object?>('network');
    if (r == null) return NetKind.unmetered;
    if (r['connected'] != true) return NetKind.none;
    return r['metered'] == true ? NetKind.metered : NetKind.unmetered;
  } catch (_) {
    return NetKind.unmetered;
  }
}
