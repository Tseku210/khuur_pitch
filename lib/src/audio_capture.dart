import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'types.dart';

/// Streams mono PCM from the device microphone.
class AudioCapture {
  static const _control = MethodChannel('khuur_pitch/control');
  static const _audio = EventChannel('khuur_pitch/audio');

  Future<MicPermission> checkPermission() => _permission('checkPermission');

  /// Prompts when the OS still allows it, otherwise returns the current state.
  Future<MicPermission> requestPermission() => _permission('requestPermission');

  Future<void> openAppSettings() =>
      _control.invokeMethod<void>('openAppSettings');

  /// Listening starts the mic and cancelling stops it. The stream is broadcast:
  /// its listeners share one capture, which stops when the last one cancels.
  /// Failures arrive as a [PlatformException] error whose code is
  /// `permissionDenied`, `noInput` or `audioFailed`.
  Stream<AudioChunk> stream() => _audio.receiveBroadcastStream().map(
    (event) => switch (event) {
      {'sampleRate': final int rate, 'samples': final Float32List samples} =>
        AudioChunk(samples, rate),
      _ => throw FormatException('Unexpected audio event', event),
    },
  );

  Future<MicPermission> _permission(String method) async => MicPermission.values
      .byName((await _control.invokeMethod<String>(method))!);
}
