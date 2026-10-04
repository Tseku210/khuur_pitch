import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:khuur_pitch/khuur_pitch.dart';

import 'support/corpus.dart';

/// The tracker's documented geometry at 44.1 and 48 kHz.
const windowSize = 2048;
const hop = 1024;

/// Groups the tracker must name within a cent. snr20 only has to keep
/// detecting without octave errors.
const tightGroups = ['bowed', 'bowed-weak', 'snr30'];
const trackedGroups = [...tightGroups, 'snr20'];

List<AudioChunk> chunked(Float32List samples, int sampleRate, int chunkSize) =>
    [
      for (var start = 0; start < samples.length; start += chunkSize)
        AudioChunk(
          Float32List.sublistView(
            samples,
            start,
            min(start + chunkSize, samples.length),
          ),
          sampleRate,
        ),
    ];

Future<List<PitchFrame>> track(
  Iterable<AudioChunk> chunks, {
  PitchTracker? tracker,
}) => (tracker ?? PitchTracker()).track(Stream.fromIterable(chunks)).toList();

PitchCase caseFor(String group, {int sampleRate = 48000}) => synthCorpus()
    .firstWhere((c) => c.group == group && c.sampleRate == sampleRate);

Float32List sine(double hz, int sampleRate, int length, double amplitude) =>
    Float32List.fromList([
      for (var i = 0; i < length; i++)
        amplitude * sin(2 * pi * hz * i / sampleRate),
    ]);

Duration duration(int samples, int sampleRate) => Duration(
  microseconds: (samples * Duration.microsecondsPerSecond / sampleRate).round(),
);

int windowCentre(PitchFrame f, int sampleRate) =>
    (f.timestamp.inMicroseconds * sampleRate / Duration.microsecondsPerSecond)
        .round() -
    windowSize ~/ 2;

double cents(double hz, double truth) => 1200 * log(hz / truth) / ln2;

bool isOctaveError(double cents) =>
    [1200.0, 1901.955].any((ratio) => (cents.abs() - ratio).abs() <= 50);

double percentile(List<double> sorted, double q) =>
    sorted[((sorted.length - 1) * q).round()];

(Duration, double?, double, double) fields(
  PitchFrame f, [
  Duration shift = Duration.zero,
]) => (f.timestamp + shift, f.hz, f.clarity, f.rmsDb);

void main() {
  test('names F3 and A#3 within a cent through track()', () async {
    final tight = <double>[];
    var windows = 0;
    var detected = 0;
    var octaveErrors = 0;
    for (final c in synthCorpus().where(
      (c) => trackedGroups.contains(c.group),
    )) {
      for (final f in await track(chunked(c.samples, c.sampleRate, 1000))) {
        windows++;
        final hz = f.hz;
        if (hz == null) continue;
        detected++;
        final offset = cents(hz, c.truthHz(windowCentre(f, c.sampleRate))!);
        if (isOctaveError(offset)) octaveErrors++;
        if (tightGroups.contains(c.group)) tight.add(offset.abs());
      }
    }
    tight.sort();
    expect(percentile(tight, 0.5), lessThanOrEqualTo(1));
    expect(percentile(tight, 0.95), lessThanOrEqualTo(3));
    expect(octaveErrors, 0);
    expect(detected / windows, greaterThanOrEqualTo(0.99));
  });

  test('frames do not depend on how the samples are chunked', () async {
    final c = caseFor('bowed');
    final reference = await track(chunked(c.samples, c.sampleRate, 128));
    expect(reference, hasLength(41));
    for (final chunkSize in [1000, 4800]) {
      final frames = await track(chunked(c.samples, c.sampleRate, chunkSize));
      expect(
        frames.map(fields).toList(),
        equals(reference.map(fields).toList()),
        reason: 'chunks of $chunkSize',
      );
    }
  });

  for (final sampleRate in sampleRates) {
    test(
      'stamps frames at the window end, one hop apart, at $sampleRate',
      () async {
        final c = caseFor('bowed', sampleRate: sampleRate);
        final frames = await track(chunked(c.samples, sampleRate, 1000));
        expect(frames.first.timestamp, duration(windowSize, sampleRate));
        final spacing = duration(hop, sampleRate).inMicroseconds;
        for (var i = 1; i < frames.length; i++) {
          final delta = frames[i].timestamp - frames[i - 1].timestamp;
          expect(delta.inMicroseconds, closeTo(spacing, 1));
          expect(delta, lessThanOrEqualTo(const Duration(milliseconds: 34)));
        }
      },
    );
  }

  test(
    'a sample-rate change restarts the window and keeps the clock',
    () async {
      final at44 = caseFor('bowed', sampleRate: 44100);
      final at48 = caseFor('bowed', sampleRate: 48000);
      final first = chunked(at44.samples, 44100, 1000);
      final second = chunked(at48.samples, 48000, 1000);
      final frames = await track([...first, ...second]);
      final before = await track(first);
      final after = await track(second);

      for (var i = 1; i < frames.length; i++) {
        expect(frames[i].timestamp, greaterThan(frames[i - 1].timestamp));
      }
      final truth = at44.truthHz(0)!;
      for (final f in frames) {
        expect(cents(f.hz!, truth).abs(), lessThan(1));
      }
      final switchAt = duration(at44.samples.length, 44100);
      expect(
        frames[before.length].timestamp - frames[before.length - 1].timestamp,
        greaterThanOrEqualTo(duration(windowSize, 48000)),
      );
      expect(
        frames.take(before.length).map(fields).toList(),
        equals(before.map(fields).toList()),
      );
      expect(
        frames.skip(before.length).map(fields).toList(),
        equals(after.map((f) => fields(f, switchAt)).toList()),
      );
    },
  );

  test('reports no pitch, clarity 0 and -120 dB on digital silence', () async {
    final c = caseFor('silence');
    final frames = await track(chunked(c.samples, c.sampleRate, 1000));
    expect(frames, isNotEmpty);
    for (final f in frames) {
      expect(f.hz, isNull);
      expect(f.clarity, 0);
      expect(f.rmsDb, -120);
    }
  });

  test('reports no pitch on white noise', () async {
    final c = caseFor('noise');
    final frames = await track(chunked(c.samples, c.sampleRate, 1000));
    expect(frames, isNotEmpty);
    expect(frames.map((f) => f.hz), everyElement(isNull));
  });

  test('rmsDb is 20 log10 of the window RMS', () async {
    final tone = sine(220, 48000, 48000, 0.3);
    final frames = await track(chunked(tone, 48000, 1000));
    final expected = 20 * log(0.3 / sqrt2) / ln10;
    expect(frames, isNotEmpty);
    for (final f in frames) {
      expect(f.rmsDb, closeTo(expected, 0.1));
    }
  });

  test('never names a pitch below minHz, not even a harmonic of it', () async {
    final f3 = caseFor('bowed', sampleRate: 44100);
    final frames = await track(
      chunked(f3.samples, 44100, 1000),
      tracker: PitchTracker(minHz: 200, maxHz: 600),
    );
    expect(frames, isNotEmpty);
    expect(frames.map((f) => f.hz), everyElement(isNull));
  });

  for (final (name, amps) in [
    ('sine', [1.0]),
    ('bowed tone', [for (var n = 1; n <= 20; n++) 1 / n]),
  ]) {
    test('never names a $name above maxHz as a note an octave below', () async {
      const e5 = 659.26;
      final samples = Float32List.fromList([
        for (var i = 0; i < 48000; i++)
          0.1 *
              [
                for (var n = 0; n < amps.length; n++)
                  amps[n] * sin(2 * pi * (n + 1) * e5 * i / 48000),
              ].reduce((a, b) => a + b),
      ]);
      final frames = await track(
        chunked(samples, 48000, 1000),
        tracker: PitchTracker(minHz: 60, maxHz: 600),
      );
      expect(frames, isNotEmpty);
      expect(frames.map((f) => f.hz), everyElement(isNull));
    });
  }

  test('the default range names notes from B1 to E6', () async {
    for (final hz in [61.74, 174.61, 659.26, 1318.51]) {
      final frames = await track(
        chunked(sine(hz, 48000, 24000, 0.3), 48000, 1000),
      );
      expect(frames, isNotEmpty);
      for (final f in frames) {
        expect(f.hz, isNotNull, reason: '$hz Hz');
        expect(cents(f.hz!, hz).abs(), lessThan(3), reason: '$hz Hz');
      }
    }
  });

  test('a lower threshold drops windows a higher one keeps', () async {
    final noisy = caseFor('snr10');
    final chunks = chunked(noisy.samples, noisy.sampleRate, 1000);
    final strict = await track(chunks, tracker: PitchTracker(threshold: 0.02));
    final loose = await track(chunks, tracker: PitchTracker(threshold: 0.15));
    expect(loose.map((f) => f.hz), everyElement(isNotNull));
    expect(strict.map((f) => f.hz), contains(isNull));
    for (final f in strict.where((f) => f.hz != null)) {
      expect(f.clarity, greaterThan(0.98));
    }
  });

  group('lifecycle', () {
    test(
      'listens to the audio only when listened to, cancels with it',
      () async {
        var listened = false;
        var cancelled = false;
        final audio = StreamController<AudioChunk>(
          onListen: () => listened = true,
          onCancel: () => cancelled = true,
        );
        final frames = PitchTracker().track(audio.stream);
        expect(listened, isFalse);
        final subscription = frames.listen(null);
        expect(listened, isTrue);
        expect(cancelled, isFalse);
        await subscription.cancel();
        expect(cancelled, isTrue);
      },
    );

    test('forwards audio errors to the caller', () async {
      final audio = StreamController<AudioChunk>();
      final error = Completer<Object>();
      PitchTracker().track(audio.stream).listen(null, onError: error.complete);
      audio.addError(StateError('mic lost'));
      expect(await error.future, isA<StateError>());
    });

    test(
      'completes when the audio closes, dropping a partial window',
      () async {
        final audio = StreamController<AudioChunk>();
        final frames = PitchTracker().track(audio.stream).toList();
        audio.add(AudioChunk(Float32List(windowSize - 1), 48000));
        await audio.close();
        expect(await frames, isEmpty);
      },
    );
  });

  test('spends under 2 ms per frame', () async {
    final chunks = chunked(caseFor('sweep').samples, 48000, 1000);
    final clock = Stopwatch()..start();
    final frames = await track(chunks);
    clock.stop();
    expect(frames.length, greaterThanOrEqualTo(300));
    expect(clock.elapsedMicroseconds / frames.length, lessThan(2000));
  });
}
