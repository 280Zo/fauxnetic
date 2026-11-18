import 'package:flutter/services.dart';

/// Where reports of generated lines go; also the store listing's public contact address.
const kReportEmail = 'zosmedia@gmail.com';

const _channel = MethodChannel('fauxnetic/settings');

/// Settings' "Report a generated line" (Google Play's AI-generated content policy asks for an in-app
/// way to report offensive content). False when there is no email app.
Future<bool> reportGeneratedLine() => openReportEmail(
  'Fauxnetic: report a generated line',
  "Which line, and what's wrong with it? (Hold a line to copy its text.)\n\n\n---\n"
      'No audio or voice recording is attached.',
);

/// Opens the phone's email app with a draft to [kReportEmail]; nothing is sent until the user does.
/// False when there is no email app.
Future<bool> openReportEmail(String subject, String body) async =>
    await _channel.invokeMethod<bool>('emailReport', {'to': kReportEmail, 'subject': subject, 'body': body}) ?? false;
