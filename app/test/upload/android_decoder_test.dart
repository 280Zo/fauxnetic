import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/storage/temp_sweeper.dart';
import 'package:fauxnetic/upload/android_decoder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('fauxnetic/decode');
  late Directory dir;
  late TempSweeper temp;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('decode');
    temp = TempSweeper(dir);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    dir.deleteSync(recursive: true);
  });

  void native(Future<Object?> Function(MethodCall call) handler) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, handler);

  test('decodes through the platform and resamples to 16 kHz, leaving no plain file', () async {
    String? out;
    native((call) async {
      expect(call.method, 'decodeToPcm16');
      final args = call.arguments as Map<Object?, Object?>;
      expect(args['path'], '/x/talk.m4a');
      out = args['out']! as String;
      expect(out, startsWith(temp.dir.path));
      final b = ByteData(48000 * 2);
      for (var i = 0; i < 48000; i++) {
        b.setInt16(i * 2, (8000 * sin(2 * pi * 440 * i / 48000)).round(), Endian.little);
      }
      File(out!).writeAsBytesSync(b.buffer.asUint8List());
      return 48000;
    });
    final pcm = await AndroidDecoder(temp).decode16k(File('/x/talk.m4a'));
    expect(pcm.length, 16000);
    expect(File(out!).existsSync(), isFalse);
  });

  test('only the first five minutes are decoded', () async {
    native((call) async {
      final args = call.arguments as Map<Object?, Object?>;
      expect(args['maxSeconds'], kUploadMaxSeconds);
      expect(kUploadMaxSeconds, 300);
      // A decoder that ignored the cap: 301 s at 8 kHz.
      File(args['out']! as String).writeAsBytesSync(Uint8List(301 * 8000 * 2));
      return 8000;
    });
    final pcm = await AndroidDecoder(temp).decode16k(File('/x/podcast.mp3'));
    expect(pcm.length / 16000, closeTo(300, 0.01));
  });

  test('a platform failure becomes a DecodeFailed and leaves no file', () async {
    native((call) async => throw PlatformException(code: 'decode', message: 'no audio track'));
    await expectLater(AndroidDecoder(temp).decode16k(File('/x/notes.pdf')), throwsA(isA<DecodeFailed>()));
    expect(temp.dir.existsSync() ? temp.dir.listSync() : const [], isEmpty);
  });
}
