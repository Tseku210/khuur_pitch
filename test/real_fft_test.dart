import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:khuur_pitch/src/dsp/real_fft.dart';

Float64List randomSignal(int n, int seed) {
  final rng = Random(seed);
  return Float64List.fromList([
    for (var i = 0; i < n; i++) rng.nextDouble() * 2 - 1,
  ]);
}

/// O(n^2) DFT of real input, bins 0..n/2, using an exact twiddle index so
/// the reference does not accumulate its own phase error.
(Float64List, Float64List) naiveDft(Float64List x) {
  final n = x.length;
  final cosT = Float64List(n);
  final sinT = Float64List(n);
  for (var i = 0; i < n; i++) {
    cosT[i] = cos(2 * pi * i / n);
    sinT[i] = sin(2 * pi * i / n);
  }
  final re = Float64List(n ~/ 2 + 1);
  final im = Float64List(n ~/ 2 + 1);
  for (var k = 0; k <= n ~/ 2; k++) {
    var sr = 0.0;
    var si = 0.0;
    for (var t = 0; t < n; t++) {
      final idx = (k * t) % n;
      sr += x[t] * cosT[idx];
      si -= x[t] * sinT[idx];
    }
    re[k] = sr;
    im[k] = si;
  }
  return (re, im);
}

double maxAbsDiff(Float64List a, Float64List b) {
  var worst = 0.0;
  for (var i = 0; i < a.length; i++) {
    worst = max(worst, (a[i] - b[i]).abs());
  }
  return worst;
}

double maxAbs(Float64List a) => a.fold(0.0, (m, v) => max(m, v.abs()));

void main() {
  for (final n in [8, 64, 2048, 4096]) {
    test('forward matches naive DFT for n=$n', () {
      final x = randomSignal(n, n);
      final fft = RealFft(n);
      final re = Float64List(n ~/ 2 + 1);
      final im = Float64List(n ~/ 2 + 1);
      fft.forward(x, re, im);
      final (refRe, refIm) = naiveDft(x);
      final scale = max(maxAbs(refRe), maxAbs(refIm));
      expect(maxAbsDiff(re, refRe) / scale, lessThan(1e-9));
      expect(maxAbsDiff(im, refIm) / scale, lessThan(1e-9));
    });

    test('inverse(forward(x)) round-trips for n=$n', () {
      final x = randomSignal(n, n + 1);
      final fft = RealFft(n);
      final re = Float64List(n ~/ 2 + 1);
      final im = Float64List(n ~/ 2 + 1);
      final y = Float64List(n);
      fft.forward(x, re, im);
      fft.inverse(re, im, y);
      expect(maxAbsDiff(x, y), lessThan(1e-12));
    });
  }

  test('a repeated call on one instance does not see the previous input', () {
    const n = 256;
    final fft = RealFft(n);
    final a = randomSignal(n, 1);
    final b = randomSignal(n, 2);
    final re1 = Float64List(n ~/ 2 + 1);
    final im1 = Float64List(n ~/ 2 + 1);
    final re2 = Float64List(n ~/ 2 + 1);
    final im2 = Float64List(n ~/ 2 + 1);
    final reB = Float64List(n ~/ 2 + 1);
    final imB = Float64List(n ~/ 2 + 1);
    final out = Float64List(n);
    fft.forward(a, re1, im1);
    fft.forward(b, reB, imB);
    fft.inverse(reB, imB, out);
    fft.forward(a, re2, im2);
    expect(re2, equals(re1));
    expect(im2, equals(im1));
  });

  test('a cosine at bin k lands only in bin k', () {
    const n = 1024;
    const k = 37;
    final x = Float64List(n);
    for (var t = 0; t < n; t++) {
      x[t] = cos(2 * pi * k * t / n);
    }
    final fft = RealFft(n);
    final re = Float64List(n ~/ 2 + 1);
    final im = Float64List(n ~/ 2 + 1);
    fft.forward(x, re, im);
    expect(re[k], closeTo(n / 2, 1e-9));
    expect(im[k], closeTo(0, 1e-9));
    for (var bin = 0; bin <= n ~/ 2; bin++) {
      if (bin == k) continue;
      expect(re[bin].abs() + im[bin].abs(), lessThan(1e-9), reason: 'bin $bin');
    }
  });
}
