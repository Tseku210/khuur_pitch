import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:khuur_pitch/khuur_pitch.dart';

const _control = MethodChannel('khuur_pitch/click');
const _beats = EventChannel('khuur_pitch/beats');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final clicks = DeviceClickTrack();

  test('configure sends the tempo and the bar length to the device', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(_control, (call) async {
      calls.add(call);
      return null;
    });

    await clicks.configure(bpm: 96, beatsPerBar: 3);

    expect(calls, [
      isMethodCall('configure', arguments: {'bpm': 96, 'beatsPerBar': 3}),
    ]);
  });

  test(
    'the clicks start on listen, report each beat and stop on cancel',
    () async {
      var listens = 0;
      var cancels = 0;
      messenger.setMockStreamHandler(
        _beats,
        MockStreamHandler.inline(
          onListen: (_, events) {
            listens++;
            events
              ..success(0)
              ..success(1);
          },
          onCancel: (_) => cancels++,
        ),
      );

      final stream = clicks.beats();
      await pumpEventQueue();
      expect(
        listens,
        0,
        reason: 'creating the stream must not start the clicks',
      );

      final heard = <int>[];
      final subscription = stream.listen(heard.add);
      await pumpEventQueue();
      expect((listens, cancels), (1, 0));
      expect(heard, [0, 1]);

      await subscription.cancel();
      await pumpEventQueue();
      expect(cancels, 1);
    },
  );

  test('a device that cannot play arrives as a PlatformException', () {
    messenger.setMockStreamHandler(
      _beats,
      MockStreamHandler.inline(
        onListen: (_, events) {
          events.error(code: 'audioFailed', message: 'no output');
          events.endOfStream();
        },
      ),
    );

    expect(
      clicks.beats(),
      emitsError(
        isA<PlatformException>().having((e) => e.code, 'code', 'audioFailed'),
      ),
    );
  });
}
