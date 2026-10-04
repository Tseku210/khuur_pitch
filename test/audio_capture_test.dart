import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:khuur_pitch/khuur_pitch.dart';

const _control = MethodChannel('khuur_pitch/control');
const _audio = EventChannel('khuur_pitch/audio');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final capture = AudioCapture();

  test('each permission method parses its own native answer', () async {
    const wire = {
      'granted': MicPermission.granted,
      'denied': MicPermission.denied,
      'permanentlyDenied': MicPermission.permanentlyDenied,
    };
    final names = wire.keys.toList();
    for (var i = 0; i < names.length; i++) {
      final checked = names[i];
      final requested = names[(i + 1) % names.length];
      messenger.setMockMethodCallHandler(
        _control,
        (call) async => switch (call.method) {
          'checkPermission' => checked,
          'requestPermission' => requested,
          _ => throw MissingPluginException(call.method),
        },
      );

      expect(await capture.checkPermission(), wire[checked]);
      expect(await capture.requestPermission(), wire[requested]);
    }
  });

  test('openAppSettings invokes the native openAppSettings method', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(_control, (call) async {
      calls.add(call.method);
      return null;
    });

    await capture.openAppSettings();

    expect(calls, ['openAppSettings']);
  });

  test('a native chunk decodes to an AudioChunk', () async {
    messenger.setMockStreamHandler(
      _audio,
      MockStreamHandler.inline(
        onListen: (_, events) => events.success({
          'sampleRate': 48000,
          'samples': Float32List.fromList([0.5, -0.25, 1]),
        }),
      ),
    );

    final chunk = await capture.stream().first;

    expect(chunk.sampleRate, 48000);
    expect(chunk.samples, [0.5, -0.25, 1]);
  });

  test('listeners share one capture that stops on the last cancel', () async {
    var listens = 0;
    var cancels = 0;
    messenger.setMockStreamHandler(
      _audio,
      MockStreamHandler.inline(
        onListen: (_, _) => listens++,
        onCancel: (_) => cancels++,
      ),
    );

    final stream = capture.stream();
    await pumpEventQueue();
    expect(listens, 0, reason: 'creating the stream must not start the mic');

    final first = stream.listen(null);
    final second = stream.listen(null);
    await pumpEventQueue();
    expect((listens, cancels), (1, 0));

    await first.cancel();
    await pumpEventQueue();
    expect(cancels, 0, reason: 'a remaining listener keeps the mic running');

    await second.cancel();
    await pumpEventQueue();
    expect((listens, cancels), (1, 1));
  });

  test('a native failure arrives as a PlatformException stream error', () {
    messenger.setMockStreamHandler(
      _audio,
      MockStreamHandler.inline(
        onListen: (_, events) {
          events.error(code: 'noInput', message: 'no microphone');
          events.endOfStream();
        },
      ),
    );

    expect(
      capture.stream(),
      emitsError(
        isA<PlatformException>().having((e) => e.code, 'code', 'noInput'),
      ),
    );
  });
}
