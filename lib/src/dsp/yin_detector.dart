import 'dart:typed_data';

import 'correlogram.dart';
import 'pitch_detector.dart';

/// YIN (de Cheveigné and Kawahara, 2002) over the shared correlogram.
///
/// Uses the cumulative mean normalized difference d', takes the first dip
/// below [threshold] and descends it to its local minimum. No fallback to the
/// global minimum: a window with no dip yields null rather than a noise pitch.
///
/// The search starts at the shortest lag, not at the lag of maxHz. A tone
/// above maxHz also dips at twice its period, so a search that skipped its
/// first dip would name it an octave low. Found first, it is out of range
/// and yields null.
class YinDetector implements PitchDetector {
  YinDetector({
    required int sampleRate,
    required this.windowSize,
    required this.minHz,
    required this.maxHz,
    this.threshold = 0.15,
  }) : _sampleRate = sampleRate.toDouble(),
       _correlogram = Correlogram(windowSize, (sampleRate / minHz).ceil()),
       _cmnd = Float64List((sampleRate / minHz).ceil() + 1);

  @override
  final int windowSize;
  final double minHz;
  final double maxHz;
  final double threshold;

  final double _sampleRate;
  final Correlogram _correlogram;
  final Float64List _cmnd;

  @override
  PitchEstimate? detect(Float32List window) {
    _correlogram.compute(window);
    final r = _correlogram.r;
    final m = _correlogram.m;
    final maxLag = _correlogram.maxLag;
    final cmnd = _cmnd;

    var running = 0.0;
    cmnd[0] = 1;
    for (var tau = 1; tau <= maxLag; tau++) {
      final d = m[tau] - 2 * r[tau];
      running += d;
      cmnd[tau] = running > 0 ? d * tau / running : 1;
    }

    var tau = 2;
    while (tau <= maxLag && cmnd[tau] >= threshold) {
      tau++;
    }
    if (tau > maxLag) return null;
    while (tau < maxLag && cmnd[tau + 1] < cmnd[tau]) {
      tau++;
    }

    var lag = tau.toDouble();
    var depth = cmnd[tau];
    if (tau < maxLag) {
      final y0 = cmnd[tau - 1];
      final y1 = cmnd[tau];
      final y2 = cmnd[tau + 1];
      final curvature = y0 - 2 * y1 + y2;
      if (curvature > 0) {
        final offset = 0.5 * (y0 - y2) / curvature;
        lag += offset;
        depth = y1 - 0.25 * (y0 - y2) * offset;
      }
    }

    final hz = _sampleRate / lag;
    if (hz < minHz || hz > maxHz) return null;
    return PitchEstimate(hz, (1 - depth).clamp(0.0, 1.0));
  }
}
