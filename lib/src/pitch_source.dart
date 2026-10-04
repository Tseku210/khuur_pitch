import 'audio_capture.dart';
import 'pitch_tracker.dart';
import 'types.dart';

/// What the app needs from a pitch input. Tests substitute a fake.
abstract interface class PitchSource {
  Future<MicPermission> checkPermission();
  Future<MicPermission> requestPermission();
  Future<void> openAppSettings();

  /// Listening starts the mic, cancelling stops it. Each call tracks pitch
  /// on its own, so listen to one call's stream once.
  Stream<PitchFrame> frames();
}

class MicPitchSource implements PitchSource {
  MicPitchSource({AudioCapture? capture, PitchTracker? tracker})
    : _capture = capture ?? AudioCapture(),
      _tracker = tracker ?? PitchTracker();

  final AudioCapture _capture;
  final PitchTracker _tracker;

  @override
  Future<MicPermission> checkPermission() => _capture.checkPermission();

  @override
  Future<MicPermission> requestPermission() => _capture.requestPermission();

  @override
  Future<void> openAppSettings() => _capture.openAppSettings();

  @override
  Stream<PitchFrame> frames() => _tracker.track(_capture.stream());
}
