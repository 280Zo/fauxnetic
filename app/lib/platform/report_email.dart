import 'package:flutter/services.dart';

/// Where reports of generated lines go; also the store listing's public contact address.
const kReportEmail = 'zosmedia@gmail.com';

const _channel = MethodChannel('fauxnetic/settings');

/// Opens the phone's email app with a draft to [kReportEmail]; nothing is sent until the user does.
/// False when there is no email app.
Future<bool> openReportEmail(String subject, String body) async =>
    await _channel.invokeMethod<bool>('emailReport', {'to': kReportEmail, 'subject': subject, 'body': body}) ?? false;
