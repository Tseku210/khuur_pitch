import 'dart:typed_data';

import 'package:khuur_pitch/src/dsp/correlogram.dart';
import 'package:khuur_pitch/src/dsp/pitch_detector.dart';

/// McLeod Pitch Method (McLeod and Wyvill, 2005) over the shared correlogram.
///
/// Finds the key maxima of the normalized square difference function, one per
/// positive lobe, and picks the first one at least [k] times the highest so a
/// strong second harmonic does not pull the estimate up an octave.
class MpmDetector implements PitchDetector {
  MpmDetector({
    required int sampleRate,
    required this.windowSize,
    required double minHz,
    required double maxHz,
    this.k = 0.9,
    this.minClarity = 0.5,
  }) : _sampleRate = sampleRate.toDouble(),
       _minHz = minHz,
       _maxHz = maxHz,
       _minLag = sampleRate ~/ maxHz,
       _correlogram = Correlogram(windowSize, (sampleRate / minHz).ceil()),
       _nsdf = Float64List((sampleRate / minHz).ceil() + 1),
       _peakLag = Int32List((sampleRate / minHz).ceil() ~/ 2 + 1),
       _peakHeight = Float64List((sampleRate / minHz).ceil() ~/ 2 + 1);

  @override
  final int windowSize;
  final double k;
  final double minClarity;

  final double _sampleRate;
  final double _minHz;
  final double _maxHz;
  final int _minLag;
  final Correlogram _correlogram;
  final Float64List _nsdf;
  final Int32List _peakLag;
  final Float64List _peakHeight;

  @override
  PitchEstimate? detect(Float32List window) {
    _correlogram.compute(window);
    final r = _correlogram.r;
    final m = _correlogram.m;
    final maxLag = _correlogram.maxLag;
    final nsdf = _nsdf;
    for (var tau = 0; tau <= maxLag; tau++) {
      nsdf[tau] = m[tau] > 0 ? 2 * r[tau] / m[tau] : 0;
    }

    var count = 0;
    var tau = 1;
    while (tau <= maxLag && nsdf[tau] > 0) {
      tau++;
    }
    while (tau <= maxLag) {
      while (tau <= maxLag && nsdf[tau] <= 0) {
        tau++;
      }
      var peak = tau;
      while (tau <= maxLag && nsdf[tau] > 0) {
        if (nsdf[tau] > nsdf[peak]) peak = tau;
        tau++;
      }
      if (peak >= _minLag && peak < maxLag) {
        _peakLag[count] = peak;
        _peakHeight[count] = nsdf[peak];
        count++;
      }
    }
    if (count == 0) return null;

    var highest = 0.0;
    for (var i = 0; i < count; i++) {
      if (_peakHeight[i] > highest) highest = _peakHeight[i];
    }
    final cutoff = k * highest;
    var pick = 0;
    while (_peakHeight[pick] < cutoff) {
      pick++;
    }

    final t = _peakLag[pick];
    var lag = t.toDouble();
    var height = nsdf[t];
    final y0 = nsdf[t - 1];
    final y2 = nsdf[t + 1];
    final curvature = y0 - 2 * height + y2;
    if (curvature < 0) {
      final offset = 0.5 * (y0 - y2) / curvature;
      lag += offset;
      height -= 0.25 * (y0 - y2) * offset;
    }

    final clarity = height.clamp(0.0, 1.0);
    if (clarity < minClarity) return null;
    final hz = _sampleRate / lag;
    if (hz < _minHz || hz > _maxHz) return null;
    return PitchEstimate(hz, clarity);
  }
}
