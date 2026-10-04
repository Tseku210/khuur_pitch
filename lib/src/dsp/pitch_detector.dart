import 'dart:typed_data';

class PitchEstimate {
  const PitchEstimate(this.hz, this.clarity);

  final double hz;

  /// Periodicity confidence in [0, 1].
  final double clarity;
}

/// Estimates the pitch of one window. Built for a fixed sample rate and
/// window size; rebuild it when either changes.
abstract interface class PitchDetector {
  int get windowSize;

  /// Null when the window is not periodic enough to name a pitch.
  PitchEstimate? detect(Float32List window);
}

/// Window and hop (half a window) for pitches down to [minHz]: 2048 and
/// 1024 at 44.1 and 48 kHz. The window holds 2.5 periods of [minHz],
/// rounded up to a power of two, so the correlation at the longest lag
/// still overlaps 1.5 periods.
({int windowSize, int hop}) windowGeometry(int sampleRate, double minHz) {
  var windowSize = 2;
  while (windowSize < 2.5 * sampleRate / minHz) {
    windowSize *= 2;
  }
  return (windowSize: windowSize, hop: windowSize ~/ 2);
}
