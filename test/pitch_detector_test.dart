import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:khuur_pitch/src/dsp/pitch_detector.dart';
import 'package:khuur_pitch/src/dsp/yin_detector.dart';

import 'support/corpus.dart';

const windowSize = 2048;
const hop = 1024;

PitchCase caseFor(String group) =>
    synthCorpus().firstWhere((c) => c.group == group && c.sampleRate == 48000);

List<PitchEstimate?> estimates(PitchDetector detector, PitchCase c) => [
  for (var start = 0; start + windowSize <= c.samples.length; start += hop)
    detector.detect(
      Float32List.sublistView(c.samples, start, start + windowSize),
    ),
];

YinDetector yin(int sampleRate) => YinDetector(
  sampleRate: sampleRate,
  windowSize: windowSize,
  minHz: 60,
  maxHz: 600,
);

void main() {
  test('names a weak-fundamental F3 within 1 cent in every window', () {
    final c = caseFor('bowed-weak');
    final truth = c.truthHz(0)!;
    for (final e in estimates(yin(c.sampleRate), c)) {
      expect(e, isNotNull);
      final cents = 1200 * log(e!.hz / truth) / ln2;
      expect(cents.abs(), lessThan(1));
      expect(e.clarity, inInclusiveRange(0, 1));
    }
  });

  for (final group in unpitchedGroups) {
    test('reports no pitch on $group', () {
      final c = caseFor(group);
      expect(estimates(yin(c.sampleRate), c), everyElement(isNull));
    });
  }
}
