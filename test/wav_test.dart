import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../tool/wav.dart';

/// A WAVE file of [frames], each a list of one sample per channel in [-1, 1].
Uint8List wav(
  List<List<double>> frames, {
  required int format,
  required int bits,
  int sampleRate = 48000,
  List<int> extraChunk = const [],
}) {
  final channels = frames.first.length;
  final width = bits ~/ 8;
  final body = ByteData(frames.length * channels * width);
  var at = 0;
  for (final frame in frames) {
    for (final v in frame) {
      switch ((format, bits)) {
        case (1, 16):
          body.setInt16(at, (v * 32767).round(), Endian.little);
        case (1, 24):
          final n = (v * 8388607).round();
          body.setUint16(at, n & 0xFFFF, Endian.little);
          body.setInt8(at + 2, n >> 16);
        case (1, 32):
          body.setInt32(at, (v * 2147483647).round(), Endian.little);
        case (3, 32):
          body.setFloat32(at, v, Endian.little);
      }
      at += width;
    }
  }
  final fmt = ByteData(16)
    ..setUint16(0, format, Endian.little)
    ..setUint16(2, channels, Endian.little)
    ..setUint32(4, sampleRate, Endian.little)
    ..setUint32(8, sampleRate * channels * width, Endian.little)
    ..setUint16(12, channels * width, Endian.little)
    ..setUint16(14, bits, Endian.little);
  List<int> chunk(String id, List<int> bytes) => [
    ...id.codeUnits,
    ...(ByteData(
      4,
    )..setUint32(0, bytes.length, Endian.little)).buffer.asUint8List(),
    ...bytes,
    if (bytes.length.isOdd) 0,
  ];
  final chunks = [
    ...chunk('fmt ', fmt.buffer.asUint8List()),
    ...extraChunk,
    ...chunk('data', body.buffer.asUint8List()),
  ];
  return Uint8List.fromList([
    ...'RIFF'.codeUnits,
    ...(ByteData(
      4,
    )..setUint32(0, chunks.length + 4, Endian.little)).buffer.asUint8List(),
    ...'WAVE'.codeUnits,
    ...chunks,
  ]);
}

void main() {
  const values = [0.0, 0.5, -0.5, 0.25, -1.0];

  for (final (format, bits, tolerance) in [
    (1, 16, 1e-4),
    (1, 24, 1e-6),
    (1, 32, 1e-6),
    (3, 32, 1e-7),
  ]) {
    test('reads format $format at $bits bits', () {
      final (:samples, :sampleRate) = readWav(
        wav(
          [
            for (final v in values) [v],
          ],
          format: format,
          bits: bits,
          sampleRate: 44100,
        ),
      );
      expect(sampleRate, 44100);
      expect(samples, hasLength(values.length));
      for (var i = 0; i < values.length; i++) {
        expect(samples[i], closeTo(values[i], tolerance));
      }
    });
  }

  test('takes the first channel of a stereo file', () {
    final (:samples, sampleRate: _) = readWav(
      wav(
        [
          for (final v in values) [v, -v / 2],
        ],
        format: 1,
        bits: 16,
      ),
    );
    expect(samples, hasLength(values.length));
    expect(samples[1], closeTo(0.5, 1e-4));
    expect(samples[4], closeTo(-1, 1e-4));
  });

  test('skips chunks it does not know, odd-sized ones included', () {
    final (:samples, sampleRate: _) = readWav(
      wav(
        [
          for (final v in values) [v],
        ],
        format: 3,
        bits: 32,
        extraChunk: [...'LIST'.codeUnits, 3, 0, 0, 0, 1, 2, 3, 0],
      ),
    );
    expect(samples[3], closeTo(0.25, 1e-7));
  });

  test('refuses a file that is not a WAVE', () {
    expect(() => readWav(Uint8List(64)), throwsFormatException);
  });

  test('refuses a format it cannot read', () {
    expect(
      () => readWav(
        wav(
          [
            [0.0],
          ],
          format: 1,
          bits: 16,
        )..[20] = 7,
      ),
      throwsFormatException,
    );
  });
}
