import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:khuur_pitch/src/dsp/correlogram.dart';

void main() {
  for (final (n, maxLag) in [(64, 20), (2048, 800)]) {
    test('r and m match the direct sums for N=$n maxLag=$maxLag', () {
      final rng = Random(n);
      final x = Float32List.fromList([
        for (var i = 0; i < n; i++) rng.nextDouble() * 2 - 1,
      ]);
      final c = Correlogram(n, maxLag)..compute(x);
      for (var tau = 0; tau <= maxLag; tau++) {
        var r = 0.0;
        var m = 0.0;
        for (var j = 0; j + tau < n; j++) {
          final a = x[j].toDouble();
          final b = x[j + tau].toDouble();
          r += a * b;
          m += a * a + b * b;
        }
        expect(c.r[tau], closeTo(r, 1e-9 * n), reason: 'r[$tau]');
        expect(c.m[tau], closeTo(m, 1e-9 * n), reason: 'm[$tau]');
      }
    });
  }
}
