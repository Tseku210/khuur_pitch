import 'dart:math';
import 'dart:typed_data';

/// One synthetic recording with a known pitch track.
class PitchCase {
  PitchCase({
    required this.group,
    required this.sampleRate,
    required this.truthHz,
    required this._render,
    this.onsetSample = 0,
  });

  final String group;
  final int sampleRate;

  /// Instantaneous frequency at a sample, or null where there is no pitch.
  final double? Function(int sampleIndex) truthHz;

  /// First sample with signal. A window centred before it holds silence and
  /// at most a partial attack.
  final int onsetSample;

  final Float32List Function() _render;
  late final Float32List samples = _render();
}

const sampleRates = [44100, 48000];

/// Groups where a detector is expected to be near-perfect.
const cleanGroups = ['sine', 'bowed', 'bowed-weak', 'snr30'];

/// Groups with no pitch, where any detection is a false positive.
const unpitchedGroups = ['silence', 'noise'];

const _peak = 0.3;

/// Handling noise and wind: a DC offset plus a sub-audio sine, added on top
/// of the normalized tone.
const _rumbleDc = 0.05;
const _rumbleAmp = 0.10;
const _rumbleHz = 12;

/// 2048 + 40 hops of 1024: 41 windows at either sample rate.
const _steadyLength = 43008;
const _sweepSeconds = 10;

/// F3 and A#3 against A4 = 440 and 442, at 0, +-5, +-20 and +-100 cents.
final targetFrequencies = <double>[
  for (final ref in [440.0, 442.0])
    for (final semitones in [-16, -11])
      for (final cents in [0, 5, -5, 20, -20, 100, -100])
        ref * pow(2, (semitones * 100 + cents) / 1200),
];

final _bowedAmps = [for (var n = 1; n <= 20; n++) 1 / n];

/// Fundamental 12 dB below the second harmonic.
final _weakAmps = [_bowedAmps[1] / 4, ..._bowedAmps.skip(1)];

enum _Envelope { flat, jitter, onset }

class _Timbre {
  _Timbre(
    this.name, {
    List<double>? amps,
    this.snrDb,
    this.envelope = _Envelope.flat,
    this.vibratoCents = 0,
    this.rumble = false,
  }) : amps = amps ?? _bowedAmps;

  final String name;
  final List<double> amps;
  final double? snrDb;
  final _Envelope envelope;
  final double vibratoCents;
  final bool rumble;
}

final _pitchedTimbres = [
  _Timbre('sine', amps: [1.0]),
  _Timbre('bowed'),
  _Timbre('bowed-weak', amps: _weakAmps),
  _Timbre('vibrato', vibratoCents: 10),
  _Timbre('jitter', envelope: _Envelope.jitter),
  _Timbre('snr30', snrDb: 30),
  _Timbre('snr20', snrDb: 20),
  _Timbre('snr10', snrDb: 10),
  _Timbre('onset', envelope: _Envelope.onset),
  _Timbre('rumble', rumble: true),
];

/// Every case, at both sample rates. Samples render on first access, so a
/// filtered subset only pays for what it uses. Deterministic per case.
Iterable<PitchCase> synthCorpus() sync* {
  for (var g = 0; g < _pitchedTimbres.length; g++) {
    final timbre = _pitchedTimbres[g];
    for (var r = 0; r < sampleRates.length; r++) {
      for (var f = 0; f < targetFrequencies.length; f++) {
        yield _pitched(
          timbre,
          sampleRates[r],
          targetFrequencies[f],
          seed: g * 10000 + r * 1000 + f,
        );
      }
    }
  }
  for (var r = 0; r < sampleRates.length; r++) {
    final sampleRate = sampleRates[r];
    yield _sweep(sampleRate, seed: 90000 + r);
    yield PitchCase(
      group: 'silence',
      sampleRate: sampleRate,
      truthHz: (_) => null,
      render: () => Float32List(_steadyLength),
    );
    yield PitchCase(
      group: 'noise',
      sampleRate: sampleRate,
      truthHz: (_) => null,
      render: () => _whiteNoise(_steadyLength, Random(91000 + r)),
    );
  }
}

PitchCase _pitched(
  _Timbre timbre,
  int sampleRate,
  double hz, {
  required int seed,
}) {
  double hzAt(double t) => timbre.vibratoCents == 0
      ? hz
      : hz * pow(2, timbre.vibratoCents / 1200 * sin(2 * pi * 5 * t));
  final rng = Random(seed);
  final onset = timbre.envelope == _Envelope.onset
      ? 256 + rng.nextInt(1536)
      : 0;
  return PitchCase(
    group: timbre.name,
    sampleRate: sampleRate,
    truthHz: (i) => hzAt(i / sampleRate),
    onsetSample: onset,
    render: () => _tone(
      sampleRate: sampleRate,
      length: _steadyLength,
      amps: timbre.amps,
      hzAt: hzAt,
      rng: rng,
      gain: switch (timbre.envelope) {
        _Envelope.flat => null,
        _Envelope.jitter => _gainWalk(sampleRate, _steadyLength, rng),
        _Envelope.onset => _attack(sampleRate, _steadyLength, onset),
      },
      snrDb: timbre.snrDb,
      rumble: timbre.rumble,
    ),
  );
}

PitchCase _sweep(int sampleRate, {required int seed}) {
  double hzAt(double t) => 60 * pow(10, t / _sweepSeconds).toDouble();
  final length = sampleRate * _sweepSeconds;
  return PitchCase(
    group: 'sweep',
    sampleRate: sampleRate,
    truthHz: (i) => hzAt(i / sampleRate),
    render: () => _tone(
      sampleRate: sampleRate,
      length: length,
      amps: _bowedAmps,
      hzAt: hzAt,
      rng: Random(seed),
    ),
  );
}

/// Harmonics of an integrated instantaneous phase, with random fixed phases,
/// peak-normalized before optional white noise at [snrDb] and the optional
/// [rumble] are added.
Float32List _tone({
  required int sampleRate,
  required int length,
  required List<double> amps,
  required double Function(double t) hzAt,
  required Random rng,
  Float64List? gain,
  double? snrDb,
  bool rumble = false,
}) {
  final phases = [for (final _ in amps) rng.nextDouble() * 2 * pi];
  final out = Float64List(length);
  var phase = 0.0;
  for (var i = 0; i < length; i++) {
    phase += 2 * pi * hzAt(i / sampleRate) / sampleRate;
    var v = 0.0;
    for (var n = 0; n < amps.length; n++) {
      v += amps[n] * sin((n + 1) * phase + phases[n]);
    }
    out[i] = gain == null ? v : v * gain[i];
  }
  _normalizePeak(out);
  if (rumble) {
    for (var i = 0; i < length; i++) {
      out[i] +=
          _rumbleDc + _rumbleAmp * sin(2 * pi * _rumbleHz * i / sampleRate);
    }
  }
  if (snrDb != null) {
    var energy = 0.0;
    for (final v in out) {
      energy += v * v;
    }
    final noiseRms = sqrt(energy / length) / pow(10, snrDb / 20);
    for (var i = 0; i < length; i++) {
      out[i] += noiseRms * _gaussian(rng);
    }
  }
  return Float32List.fromList(out);
}

/// Slow gain drift: a leaky random walk in dB with a 20 ms time constant and
/// about 1.5 dB standard deviation, clamped to +-3 dB.
Float64List _gainWalk(int sampleRate, int length, Random rng) {
  final tau = 0.02 * sampleRate;
  final sigma = 1.5 * sqrt(2 / tau);
  final gain = Float64List(length);
  var db = 0.0;
  for (var i = 0; i < length; i++) {
    db += -db / tau + sigma * _gaussian(rng);
    gain[i] = pow(10, db.clamp(-3.0, 3.0) / 20).toDouble();
  }
  return gain;
}

/// Silence until [onset], then an exponential attack with a 30 ms time
/// constant.
Float64List _attack(int sampleRate, int length, int onset) {
  final tau = 0.03 * sampleRate;
  final gain = Float64List(length);
  for (var i = onset; i < length; i++) {
    gain[i] = 1 - exp(-(i - onset) / tau);
  }
  return gain;
}

Float32List _whiteNoise(int length, Random rng) {
  final out = Float64List(length);
  for (var i = 0; i < length; i++) {
    out[i] = _gaussian(rng);
  }
  _normalizePeak(out);
  return Float32List.fromList(out);
}

void _normalizePeak(Float64List x) {
  var peak = 0.0;
  for (final v in x) {
    peak = max(peak, v.abs());
  }
  final scale = _peak / peak;
  for (var i = 0; i < x.length; i++) {
    x[i] *= scale;
  }
}

double _gaussian(Random rng) =>
    sqrt(-2 * log(1 - rng.nextDouble())) * cos(2 * pi * rng.nextDouble());
