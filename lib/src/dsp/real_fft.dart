import 'dart:math';
import 'dart:typed_data';

/// FFT of real input of a fixed power-of-two [size], done as a half-size
/// complex FFT (even samples in re, odd in im) plus a split step.
///
/// The spectrum is half-complex: bins 0..size/2 as separate re and im lists.
/// All buffers are allocated here; [forward] and [inverse] do not allocate.
class RealFft {
  RealFft(this.size)
    : assert(size >= 2 && (size & (size - 1)) == 0, 'size must be 2^k'),
      _half = size >> 1,
      _cos = Float64List(size ~/ 2 + 1),
      _sin = Float64List(size ~/ 2 + 1),
      _rev = Int32List(size ~/ 2),
      _re = Float64List(size ~/ 2),
      _im = Float64List(size ~/ 2) {
    for (var k = 0; k <= _half; k++) {
      _cos[k] = cos(2 * pi * k / size);
      _sin[k] = sin(2 * pi * k / size);
    }
    final bits = _half.bitLength - 1;
    for (var i = 0; i < _half; i++) {
      var r = 0;
      for (var b = 0; b < bits; b++) {
        r = (r << 1) | ((i >> b) & 1);
      }
      _rev[i] = r;
    }
  }

  final int size;
  final int _half;
  final Float64List _cos;
  final Float64List _sin;
  final Int32List _rev;
  final Float64List _re;
  final Float64List _im;

  /// [x] has length [size]; [re] and [im] have length size/2 + 1.
  void forward(Float64List x, Float64List re, Float64List im) {
    final m = _half;
    for (var k = 0; k < m; k++) {
      _re[k] = x[2 * k];
      _im[k] = x[2 * k + 1];
    }
    _fft(inverse: false);
    final mask = m - 1;
    for (var k = 0; k <= m; k++) {
      final a = k & mask;
      final b = (m - k) & mask;
      final er = 0.5 * (_re[a] + _re[b]);
      final ei = 0.5 * (_im[a] - _im[b]);
      final or = 0.5 * (_im[a] + _im[b]);
      final oi = 0.5 * (_re[b] - _re[a]);
      final c = _cos[k];
      final s = _sin[k];
      re[k] = er + or * c + oi * s;
      im[k] = ei + oi * c - or * s;
    }
  }

  /// Inverse of [forward], scaled so that inverse(forward(x)) == x.
  void inverse(Float64List re, Float64List im, Float64List x) {
    final m = _half;
    for (var k = 0; k < m; k++) {
      final j = m - k;
      final er = 0.5 * (re[k] + re[j]);
      final ei = 0.5 * (im[k] - im[j]);
      final dr = 0.5 * (re[k] - re[j]);
      final di = 0.5 * (im[k] + im[j]);
      final c = _cos[k];
      final s = _sin[k];
      final or = dr * c - di * s;
      final oi = dr * s + di * c;
      _re[k] = er - oi;
      _im[k] = ei + or;
    }
    _fft(inverse: true);
    final scale = 1 / m;
    for (var k = 0; k < m; k++) {
      x[2 * k] = _re[k] * scale;
      x[2 * k + 1] = _im[k] * scale;
    }
  }

  void _fft({required bool inverse}) {
    final re = _re;
    final im = _im;
    final m = _half;
    for (var i = 0; i < m; i++) {
      final j = _rev[i];
      if (j > i) {
        final tr = re[i];
        re[i] = re[j];
        re[j] = tr;
        final ti = im[i];
        im[i] = im[j];
        im[j] = ti;
      }
    }
    final sign = inverse ? 1.0 : -1.0;
    for (var span = 2; span <= m; span <<= 1) {
      final half = span >> 1;
      final stride = size ~/ span;
      for (var j = 0; j < half; j++) {
        final wr = _cos[j * stride];
        final wi = sign * _sin[j * stride];
        for (var a = j; a < m; a += span) {
          final b = a + half;
          final tr = re[b] * wr - im[b] * wi;
          final ti = re[b] * wi + im[b] * wr;
          re[b] = re[a] - tr;
          im[b] = im[a] - ti;
          re[a] += tr;
          im[a] += ti;
        }
      }
    }
  }
}
