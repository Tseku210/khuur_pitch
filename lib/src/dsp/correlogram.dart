import 'dart:typed_data';

import 'real_fft.dart';

/// Linear autocorrelation [r] and the matching energy term [m] of one window,
/// over lags 0..[maxLag]. Shared by YIN (d = m - 2r) and MPM (nsdf = 2r / m).
///
/// r is computed through a zero-padded FFT so no lag wraps around; m comes
/// from prefix sums of squares. All buffers are reused across [compute] calls.
class Correlogram {
  Correlogram(this.windowSize, this.maxLag)
    : assert(maxLag < windowSize),
      r = Float64List(maxLag + 1),
      m = Float64List(maxLag + 1),
      _fft = RealFft(2 * windowSize),
      _x = Float64List(2 * windowSize),
      _ac = Float64List(2 * windowSize),
      _re = Float64List(windowSize + 1),
      _im = Float64List(windowSize + 1),
      _prefix = Float64List(windowSize + 1);

  final int windowSize;
  final int maxLag;

  /// r[tau] = sum over j of x[j] * x[j + tau].
  final Float64List r;

  /// m[tau] = sum over j of x[j]^2 + x[j + tau]^2.
  final Float64List m;

  final RealFft _fft;
  final Float64List _x;
  final Float64List _ac;
  final Float64List _re;
  final Float64List _im;
  final Float64List _prefix;

  void compute(Float32List window) {
    assert(window.length == windowSize);
    final n = windowSize;
    for (var j = 0; j < n; j++) {
      final v = window[j].toDouble();
      _x[j] = v;
      _prefix[j + 1] = _prefix[j] + v * v;
    }
    _fft.forward(_x, _re, _im);
    for (var k = 0; k <= n; k++) {
      _re[k] = _re[k] * _re[k] + _im[k] * _im[k];
      _im[k] = 0;
    }
    _fft.inverse(_re, _im, _ac);
    final total = _prefix[n];
    for (var tau = 0; tau <= maxLag; tau++) {
      r[tau] = _ac[tau];
      m[tau] = _prefix[n - tau] + total - _prefix[tau];
    }
  }
}
