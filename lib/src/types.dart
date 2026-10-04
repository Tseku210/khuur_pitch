import 'dart:typed_data';

/// Mono PCM from the microphone, samples in [-1, 1].
class AudioChunk {
  const AudioChunk(this.samples, this.sampleRate);

  final Float32List samples;
  final int sampleRate;
}

enum MicPermission {
  granted,
  denied,

  /// The OS will not prompt again. The user has to enable it in Settings.
  permanentlyDenied,
}

/// The analysis result for one window of audio.
class PitchFrame {
  const PitchFrame({
    required this.timestamp,
    required this.hz,
    required this.clarity,
    required this.rmsDb,
  });

  /// Position of the window's end, counted in samples since capture started.
  final Duration timestamp;

  /// Null when the window is not periodic enough to name a pitch.
  final double? hz;

  /// Periodicity confidence in [0, 1].
  final double clarity;

  /// Window loudness in dBFS, at most 0.
  final double rmsDb;
}
