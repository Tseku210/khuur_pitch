// ignore_for_file: avoid_print

/// Scores the tracker on recordings of real instruments.
///
///   dart run tool/eval_recordings.dart recordings/ min=60 max=1400
///
/// Each file is one held note, named for it: `khuur-fa_174.6hz.wav` is a
/// note near 174.6 Hz. A real string is never exactly on its nominal pitch,
/// so the name only says which octave is right. Steadiness is measured
/// against the file's own median.
library;

import 'dart:io';
import 'dart:math';

import 'package:khuur_pitch/src/pitch_tracker.dart';
import 'package:khuur_pitch/src/types.dart';

import 'wav.dart';

final _name = RegExp(r'_(\d+(?:\.\d+)?)hz\.wav$', caseSensitive: false);

double cents(double hz, double reference) => 1200 * log(hz / reference) / ln2;

double percentile(List<double> sorted, double q) =>
    sorted[((sorted.length - 1) * q).round()];

/// Within 50 cents of an octave or a twelfth from [nominal], up or down, or
/// of two octaves.
bool isOctaveError(double hz, double nominal) => [
  1200.0,
  1901.955,
  2400.0,
].any((interval) => (cents(hz, nominal).abs() - interval).abs() <= 50);

class Score {
  Score(
    this.frames,
    this.sounding,
    this.pitched,
    this.octave,
    this.stray,
    this.medianHz,
    this.medianCents,
    this.spreadP95,
  );

  final int frames;

  /// Frames louder than [gateDb], the ones a note could be read from.
  final int sounding;
  final int pitched;
  final int octave;

  /// More than 100 cents from the nominal pitch without being an octave error.
  final int stray;
  final double? medianHz;
  final double? medianCents;

  /// 95th percentile distance from the median, over the frames on the note.
  final double? spreadP95;
}

const gateDb = -50.0;

Score score(List<PitchFrame> frames, double nominal) {
  final sounding = frames.where((f) => f.rmsDb > gateDb).toList();
  final pitched = [
    for (final f in sounding)
      if (f.hz != null) f.hz!,
  ];
  final octave = pitched.where((hz) => isOctaveError(hz, nominal)).length;
  final onNote = [
    for (final hz in pitched)
      if (cents(hz, nominal).abs() <= 100) hz,
  ]..sort();
  final median = onNote.isEmpty ? null : percentile(onNote, 0.5);
  final spread = median == null
      ? null
      : percentile(
          [for (final hz in onNote) cents(hz, median).abs()]..sort(),
          0.95,
        );
  return Score(
    frames.length,
    sounding.length,
    pitched.length,
    octave,
    pitched.length - octave - onNote.length,
    median,
    median == null ? null : cents(median, nominal),
    spread,
  );
}

Future<void> main(List<String> args) async {
  final paths = args.where((a) => !a.contains('=')).toList();
  final options = {
    for (final a in args)
      if (a.contains('=')) a.split('=').first: double.parse(a.split('=').last),
  };
  if (paths.length != 1) {
    print(
      'usage: dart run tool/eval_recordings.dart <directory> [min=60] [max=1400]',
    );
    exitCode = 64;
    return;
  }
  final minHz = options['min'] ?? 60;
  final maxHz = options['max'] ?? 1400;
  final files =
      Directory(paths.single)
          .listSync()
          .whereType<File>()
          .where((f) => _name.hasMatch(f.path))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  if (files.isEmpty) {
    print('No files named like note_174.6hz.wav in ${paths.single}');
    exitCode = 66;
    return;
  }

  print('range $minHz-$maxHz Hz, frames louder than $gateDb dBFS\n');
  print(
    '| file | sounding | pitched% | octave% | stray% | median Hz | from nominal | spread p95 |',
  );
  print('|---|---|---|---|---|---|---|---|');
  var octaves = 0;
  for (final file in files) {
    final nominal = double.parse(_name.firstMatch(file.path)!.group(1)!);
    final (:samples, :sampleRate) = readWav(file.readAsBytesSync());
    final frames = await PitchTracker(
      minHz: minHz,
      maxHz: maxHz,
    ).track(Stream.value(AudioChunk(samples, sampleRate))).toList();
    final s = score(frames, nominal);
    octaves += s.octave;
    String pct(int n, int of) =>
        of == 0 ? '-' : (100 * n / of).toStringAsFixed(1);
    print(
      '| ${file.uri.pathSegments.last} | ${s.sounding} | '
      '${pct(s.pitched, s.sounding)} | ${pct(s.octave, s.pitched)} | '
      '${pct(s.stray, s.pitched)} | ${s.medianHz?.toStringAsFixed(2) ?? '-'} | '
      '${s.medianCents == null ? '-' : '${s.medianCents!.toStringAsFixed(1)} c'} | '
      '${s.spreadP95 == null ? '-' : '${s.spreadP95!.toStringAsFixed(2)} c'} |',
    );
  }
  print('\n${files.length} files, $octaves octave errors');
}
