import 'package:flutter/services.dart';

/// What the app needs from a metronome's sound. Tests substitute a fake.
abstract interface class ClickTrack {
  /// Sets the tempo and the bar length, for the next [beats] and for one that
  /// is playing. A new bar length starts the bar again.
  Future<void> configure({required int bpm, required int beatsPerBar});

  /// Listening starts the clicks and cancelling stops them. Each event is the
  /// place in the bar of the beat that sounds now, from 0, which is accented.
  /// The stream ends when the OS takes the audio away, and a failure to start
  /// arrives as a [PlatformException] error whose code is `audioFailed`.
  Stream<int> beats();
}

/// Clicks the device plays itself, so their timing is the audio clock's and
/// not a Dart timer's.
class DeviceClickTrack implements ClickTrack {
  static const _control = MethodChannel('khuur_pitch/click');
  static const _beats = EventChannel('khuur_pitch/beats');

  @override
  Future<void> configure({required int bpm, required int beatsPerBar}) =>
      _control.invokeMethod<void>('configure', {
        'bpm': bpm,
        'beatsPerBar': beatsPerBar,
      });

  @override
  Stream<int> beats() => _beats.receiveBroadcastStream().map(
    (event) => switch (event) {
      final int beat => beat,
      _ => throw FormatException('Unexpected beat event', event),
    },
  );
}
