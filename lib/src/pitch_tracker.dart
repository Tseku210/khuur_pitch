import 'dart:math';
import 'dart:typed_data';

import 'dsp/pitch_detector.dart';
import 'dsp/yin_detector.dart';
import 'types.dart';

/// Turns a PCM stream into pitch frames over overlapping windows.
///
/// Windows follow [windowGeometry] (2048 samples, hop 1024, at 44.1 and
/// 48 kHz for the default [minHz]), each frame stamped at its last sample.
/// `hz` is null and `clarity` 0 when YIN finds no pitch inside
/// [minHz, maxHz], which includes a tone above [maxHz]. `rmsDb` is floored
/// at -120.
class PitchTracker {
  PitchTracker({this.minHz = 60, this.maxHz = 1400, this.threshold = 0.15});

  final double minHz;
  final double maxHz;

  /// How much aperiodic power YIN tolerates in a pitched window, in (0, 1).
  /// A pitched frame's clarity is above 1 - [threshold]. Lower it to drop
  /// noisier windows, raise it to keep them.
  final double threshold;

  Stream<PitchFrame> track(Stream<AudioChunk> audio) =>
      audio.expand(_Tracking(minHz, maxHz, threshold).push);
}

/// The state of one [PitchTracker.track] call.
class _Tracking {
  _Tracking(this.minHz, this.maxHz, this.threshold);

  final double minHz;
  final double maxHz;
  final double threshold;

  int _sampleRate = 0;
  late YinDetector _detector;
  late Float32List _window;
  late int _hop;
  int _fill = 0;
  int _consumed = 0;
  Duration _epochStart = Duration.zero;

  List<PitchFrame> push(AudioChunk chunk) {
    if (chunk.sampleRate != _sampleRate) _restart(chunk.sampleRate);
    final samples = chunk.samples;
    final frames = <PitchFrame>[];
    var offset = 0;
    while (offset < samples.length) {
      final n = min(_window.length - _fill, samples.length - offset);
      _window.setRange(_fill, _fill + n, samples, offset);
      _fill += n;
      offset += n;
      _consumed += n;
      if (_fill == _window.length) {
        frames.add(_frame());
        _window.setRange(0, _window.length - _hop, _window, _hop);
        _fill -= _hop;
      }
    }
    return frames;
  }

  void _restart(int sampleRate) {
    if (_sampleRate != 0) _epochStart = _now;
    _sampleRate = sampleRate;
    _consumed = 0;
    _fill = 0;
    final (:windowSize, :hop) = windowGeometry(sampleRate, minHz);
    _hop = hop;
    _window = Float32List(windowSize);
    _detector = YinDetector(
      sampleRate: sampleRate,
      windowSize: windowSize,
      minHz: minHz,
      maxHz: maxHz,
      threshold: threshold,
    );
  }

  Duration get _now =>
      _epochStart +
      Duration(
        microseconds: (_consumed * Duration.microsecondsPerSecond / _sampleRate)
            .round(),
      );

  PitchFrame _frame() {
    var energy = 0.0;
    for (final v in _window) {
      energy += v * v;
    }
    final rms = sqrt(energy / _window.length);
    final estimate = _detector.detect(_window);
    return PitchFrame(
      timestamp: _now,
      hz: estimate?.hz,
      clarity: estimate?.clarity ?? 0,
      rmsDb: max(-120.0, 20 * log(rms) / ln10),
    );
  }
}
