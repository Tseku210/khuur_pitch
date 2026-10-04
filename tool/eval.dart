// ignore_for_file: avoid_print

/// Runs YIN and MPM over the synthetic corpus and prints per-group accuracy
/// and cost tables. Deterministic apart from timings, which are JIT numbers.
///
///   dart run tool/eval.dart [yin=0.15] [k=0.9] [clarity=0.5]
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:khuur_pitch/src/dsp/correlogram.dart';
import 'package:khuur_pitch/src/dsp/pitch_detector.dart';
import 'package:khuur_pitch/src/dsp/yin_detector.dart';

import '../test/support/corpus.dart';
import 'mpm_detector.dart';

const minHz = 60.0;
const maxHz = 600.0;
const warmUpRounds = 40;

/// The analysis windows of [samples] at the tracker's geometry, each with
/// its start sample.
Iterable<(int, Float32List)> windows(
  Float32List samples,
  int sampleRate,
) sync* {
  final (:windowSize, :hop) = windowGeometry(sampleRate, minHz);
  for (var start = 0; start + windowSize <= samples.length; start += hop) {
    yield (start, Float32List.sublistView(samples, start, start + windowSize));
  }
}

class _Stats {
  int windows = 0;
  int detected = 0;
  int octave = 0;
  int gross = 0;
  int micros = 0;
  final cents = <double>[];
  final clarity = <double>[];

  /// Highest clarity the detector would report with its gate off, over the
  /// windows that must not detect (no pitch, or centred before the onset).
  double ungatedMax = 0;

  double get detectedPct => 100 * detected / max(windows, 1);
  double get octavePct => 100 * octave / max(detected, 1);
  double get grossPct => 100 * gross / max(detected, 1);
  double get microsPerWindow => micros / max(windows, 1);

  void add(_Stats other) {
    windows += other.windows;
    detected += other.detected;
    octave += other.octave;
    gross += other.gross;
    micros += other.micros;
    cents.addAll(other.cents);
    clarity.addAll(other.clarity);
    ungatedMax = max(ungatedMax, other.ungatedMax);
  }
}

typedef _UngatedClarity = double Function(Float32List window, int sampleRate);

_UngatedClarity _mpmUngated(double k) {
  final byRate = <int, MpmDetector>{};
  return (window, sampleRate) {
    final detector = byRate.putIfAbsent(
      sampleRate,
      () => MpmDetector(
        sampleRate: sampleRate,
        windowSize: window.length,
        minHz: minHz,
        maxHz: maxHz,
        k: k,
        minClarity: 0,
      ),
    );
    return detector.detect(window)?.clarity ?? 0;
  };
}

/// 1 - min d' over the lag range: the most clarity YIN could report at any
/// threshold. Recomputed here from the correlogram since YinDetector keeps
/// d' private.
_UngatedClarity _yinUngated() {
  final byRate = <int, Correlogram>{};
  return (window, sampleRate) {
    final maxLag = (sampleRate / minHz).ceil();
    final minLag = sampleRate ~/ maxHz;
    final c = byRate.putIfAbsent(
      sampleRate,
      () => Correlogram(window.length, maxLag),
    )..compute(window);
    var running = 0.0;
    var lowest = 1.0;
    for (var tau = 1; tau <= maxLag; tau++) {
      final d = c.m[tau] - 2 * c.r[tau];
      running += d;
      final cmnd = running > 0 ? d * tau / running : 1.0;
      if (tau >= minLag && cmnd < lowest) lowest = cmnd;
    }
    return 1 - lowest;
  };
}

double percentile(List<double> sorted, double q) =>
    sorted[((sorted.length - 1) * q).round()];

bool isOctaveError(double cents) {
  for (final ratio in [1200.0, 1901.955]) {
    if ((cents.abs() - ratio).abs() <= 50) return true;
  }
  return false;
}

/// Per (group, sampleRate) stats for one detector.
class _Run {
  _Run(this.name, this.build, this.ungated);

  final String name;
  final PitchDetector Function(int sampleRate) build;
  final _UngatedClarity ungated;
  final _detectors = <int, PitchDetector>{};
  final byGroupAndRate = <(String, int), _Stats>{};

  PitchDetector detectorFor(int sampleRate) =>
      _detectors.putIfAbsent(sampleRate, () => build(sampleRate));

  void evaluate(PitchCase c) {
    final detector = detectorFor(c.sampleRate);
    final stats = byGroupAndRate.putIfAbsent((
      c.group,
      c.sampleRate,
    ), _Stats.new);
    final samples = c.samples;
    final clock = Stopwatch()..start();
    for (final (start, window) in windows(samples, c.sampleRate)) {
      final centre = start + window.length ~/ 2;
      final truth = c.truthHz(centre);
      final before = clock.elapsedMicroseconds;
      final estimate = detector.detect(window);
      stats.micros += clock.elapsedMicroseconds - before;
      stats.windows++;
      if (truth == null || centre < c.onsetSample) {
        stats.ungatedMax = max(stats.ungatedMax, ungated(window, c.sampleRate));
      }
      if (estimate == null) continue;
      stats.detected++;
      stats.clarity.add(estimate.clarity);
      if (truth == null) continue;
      final cents = 1200 * log(estimate.hz / truth) / ln2;
      stats.cents.add(cents.abs());
      if (isOctaveError(cents)) stats.octave++;
      if (cents.abs() > 100) stats.gross++;
    }
  }

  Map<String, _Stats> pooled() {
    final out = <String, _Stats>{};
    for (final entry in byGroupAndRate.entries) {
      out.putIfAbsent(entry.key.$1, _Stats.new).add(entry.value);
    }
    return out;
  }
}

String _row(String label, _Stats s) {
  final sorted = s.cents..sort();
  final pitched = sorted.isNotEmpty;
  String f(double v, [int digits = 1]) => v.toStringAsFixed(digits);
  return '| $label | ${s.windows} | ${f(s.detectedPct)} | '
      '${pitched ? f(percentile(sorted, 0.5), 2) : '-'} | '
      '${pitched ? f(percentile(sorted, 0.95), 2) : '-'} | '
      '${pitched ? f(s.octavePct) : '-'} | '
      '${pitched ? f(s.grossPct) : '-'} | '
      '${f(s.microsPerWindow, 0)} |';
}

/// Rates disagree enough to be worth a second table.
bool _ratesDiffer(_Stats a, _Stats b) {
  final ca = a.cents..sort();
  final cb = b.cents..sort();
  if ((a.detectedPct - b.detectedPct).abs() > 2) return true;
  if ((a.octavePct - b.octavePct).abs() > 1) return true;
  if ((a.grossPct - b.grossPct).abs() > 1) return true;
  if (ca.isEmpty || cb.isEmpty) return false;
  if ((percentile(ca, 0.5) - percentile(cb, 0.5)).abs() > 0.5) return true;
  return (percentile(ca, 0.95) - percentile(cb, 0.95)).abs() > 1;
}

void _report(_Run run) {
  const header =
      '| group | n | det% | med c | p95 c | oct% | gross% | us/win |\n'
      '|---|---|---|---|---|---|---|---|';
  print('\n### ${run.name}\n');
  print(header);
  final pooled = run.pooled();
  for (final entry in pooled.entries) {
    print(_row(entry.key, entry.value));
  }
  final clean = _Stats();
  for (final group in cleanGroups) {
    clean.add(pooled[group]!);
  }
  final sorted = clean.cents..sort();
  print(
    '\nclean groups (${cleanGroups.join(', ')}): '
    'median ${percentile(sorted, 0.5).toStringAsFixed(2)} c, '
    'p95 ${percentile(sorted, 0.95).toStringAsFixed(2)} c',
  );
  final cleanClarity = clean.clarity..sort();
  final snr10Clarity = pooled['snr10']!.clarity..sort();
  String f(double v) => v.toStringAsFixed(3);
  print(
    'clarity: clean p5 ${f(percentile(cleanClarity, 0.05))}, '
    'snr10 min ${f(snr10Clarity.first)}, '
    'ungated max on noise ${f(pooled['noise']!.ungatedMax)}, '
    'on windows centred before the onset ${f(pooled['onset']!.ungatedMax)}',
  );

  final differing = [
    for (final group in pooled.keys)
      if (_ratesDiffer(
        run.byGroupAndRate[(group, sampleRates[0])]!,
        run.byGroupAndRate[(group, sampleRates[1])]!,
      ))
        group,
  ];
  if (differing.isEmpty) {
    print('44100 and 48000 agree per group; no per-rate breakdown.');
    return;
  }
  print('\nper-rate breakdown where the rates differ:\n');
  print(header);
  for (final group in differing) {
    for (final rate in sampleRates) {
      print(_row('$group @$rate', run.byGroupAndRate[(group, rate)]!));
    }
  }
}

void main(List<String> args) {
  final options = {
    for (final arg in args)
      if (arg.contains('='))
        arg.split('=').first: double.parse(arg.split('=').last),
  };
  final yinThreshold = options['yin'] ?? 0.15;
  final mpmK = options['k'] ?? 0.9;
  final mpmClarity = options['clarity'] ?? 0.5;

  final runs = [
    _Run(
      'YIN (threshold $yinThreshold)',
      (sampleRate) => YinDetector(
        sampleRate: sampleRate,
        windowSize: windowGeometry(sampleRate, minHz).windowSize,
        minHz: minHz,
        maxHz: maxHz,
        threshold: yinThreshold,
      ),
      _yinUngated(),
    ),
    _Run(
      'MPM (k $mpmK, min clarity $mpmClarity)',
      (sampleRate) => MpmDetector(
        sampleRate: sampleRate,
        windowSize: windowGeometry(sampleRate, minHz).windowSize,
        minHz: minHz,
        maxHz: maxHz,
        k: mpmK,
        minClarity: mpmClarity,
      ),
      _mpmUngated(mpmK),
    ),
  ];

  final warmUp = [
    for (final rate in sampleRates)
      synthCorpus().firstWhere(
        (c) => c.group == 'bowed' && c.sampleRate == rate,
      ),
  ];
  for (final run in runs) {
    for (final c in warmUp) {
      final detector = run.detectorFor(c.sampleRate);
      for (var round = 0; round < warmUpRounds; round++) {
        for (final (_, window) in windows(c.samples, c.sampleRate)) {
          detector.detect(window);
        }
      }
    }
  }

  final clock = Stopwatch()..start();
  var cases = 0;
  for (final c in synthCorpus()) {
    cases++;
    for (final run in runs) {
      run.evaluate(c);
    }
  }
  final geometry = [
    for (final rate in sampleRates)
      'window ${windowGeometry(rate, minHz).windowSize} '
          'hop ${windowGeometry(rate, minHz).hop} @$rate',
  ].join(', ');
  print(
    '$cases cases, $geometry, '
    'range $minHz-$maxHz Hz, ${clock.elapsed.inSeconds} s wall (JIT). '
    'det% is the false-positive rate for silence and noise.',
  );
  for (final run in runs) {
    _report(run);
  }
}
