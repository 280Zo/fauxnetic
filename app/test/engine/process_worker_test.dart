import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/engine/crispasr_engine.dart';
import 'package:fauxnetic/engine/voice_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('fauxnetic/engine-test');
  late Directory dir;
  late List<String> calls;
  late Future<Object?> Function(MethodCall c) answer;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('process_worker');
    calls = [];
    answer = (_) async => null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (c) {
      calls.add('${c.method} ${c.arguments}');
      return answer(c);
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    dir.deleteSync(recursive: true);
  });

  File samples(List<double> v) {
    final f = File('${dir.path}/line.f32');
    f.writeAsBytesSync(Float32List.fromList(v).buffer.asUint8List());
    return f;
  }

  test('requests carry the same arguments the isolate worker used', () async {
    final w = ProcessWorker(channel);
    await w.open('m.gguf', 'c.gguf', 'qwen3-tts');
    await w.setVoice('v.wav', 'Hello.');
    expect(calls, [
      'open {model: m.gguf, codec: c.gguf, backend: qwen3-tts, threads: $kThreads}',
      'setVoice {path: v.wav, refText: Hello.}',
    ]);
  });

  test('synthesize reads and deletes the samples file', () async {
    final f = samples([0.5, -0.25, 1]);
    answer = (c) async => c.method == 'synthesize' ? {'path': f.path, 'rate': 24000} : 24000;
    final w = ProcessWorker(channel);
    expect(await w.synthesize('Hi.', 7, maxFrames: 168), Float32List.fromList([0.5, -0.25, 1]));
    expect(calls.single, 'synthesize {text: Hi., seed: 7, maxFrames: 168}');
    expect(f.existsSync(), isFalse);
  });

  test('engine refusals map to engine errors', () async {
    for (final code in ['open', 'voice', 'synth']) {
      answer = (_) async => throw PlatformException(code: code, message: 'nope $code');
      await expectLater(
        ProcessWorker(channel).open('m', '', 'b'),
        throwsA(
          isA<EngineError>()
              .having((e) => e.kind, 'kind', EngineErrorKind.synthesisFailed)
              .having((e) => e.message, 'message', 'nope $code'),
        ),
      );
    }
  });

  test('a died engine is out of memory', () async {
    answer = (_) async => throw PlatformException(code: 'died', message: 'gone');
    await expectLater(
      ProcessWorker(channel).synthesize('x', 1),
      throwsA(isA<EngineError>().having((e) => e.kind, 'kind', EngineErrorKind.outOfMemory)),
    );
  });

  test('a line the engine stopped as a runaway maps to ranAway', () async {
    answer = (_) async => throw PlatformException(code: 'ranaway', message: 'ranaway: stall');
    await expectLater(
      ProcessWorker(channel).synthesize('Hi.', 7, maxFrames: 240),
      throwsA(
        isA<EngineError>()
            .having((e) => e.kind, 'kind', EngineErrorKind.ranAway)
            .having((e) => e.message, 'message', 'ranaway: stall'),
      ),
    );
  });

  test('a killed engine is cancelled', () async {
    answer = (_) async => throw PlatformException(code: 'cancelled', message: 'Stopped.');
    await expectLater(
      ProcessWorker(channel).synthesize('x', 1),
      throwsA(isA<EngineError>().having((e) => e.kind, 'kind', EngineErrorKind.cancelled)),
    );
  });

  test('a missing samples file is an engine error', () async {
    answer = (_) async => {'path': '${dir.path}/gone.f32', 'rate': 24000};
    await expectLater(
      ProcessWorker(channel).synthesize('x', 1),
      throwsA(isA<EngineError>().having((e) => e.kind, 'kind', EngineErrorKind.synthesisFailed)),
    );
  });

  test('kill and close reach the engine', () async {
    final w = ProcessWorker(channel);
    await w.kill();
    await w.close();
    expect(calls, ['kill null', 'close null']);
  });
}
