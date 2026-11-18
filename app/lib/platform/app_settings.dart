import 'package:flutter/services.dart';

const _channel = MethodChannel('fauxnetic/settings');

/// Opens Android's settings page for this app (to allow the microphone again).
Future<void> openAppSettings() => _channel.invokeMethod<void>('openAppSettings');
