import 'package:flutter/services.dart';

/// No connection, mobile data (or another metered network), or Wi-Fi (unmetered).
enum NetKind { none, metered, unmetered }

const _channel = MethodChannel('fauxnetic/settings');

/// The phone's connection now, from Android's ConnectivityManager. If it can't be read, it counts
/// as metered: a download then waits for Wi-Fi or "Use mobile data" rather than risk the person's
/// data plan (review minor, 2026-11-19; it counted as Wi-Fi before).
Future<NetKind> currentNetwork() async {
  try {
    final r = await _channel.invokeMapMethod<String, Object?>('network');
    if (r == null) return NetKind.metered;
    if (r['connected'] != true) return NetKind.none;
    return r['metered'] == true ? NetKind.metered : NetKind.unmetered;
  } catch (_) {
    return NetKind.metered;
  }
}
