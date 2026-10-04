import 'dart:typed_data';

/// The first channel of a RIFF WAVE file as samples in [-1, 1].
///
/// Reads PCM of 16, 24 or 32 bits and 32-bit float, the formats recorders
/// write. Throws a [FormatException] on anything else.
({Float32List samples, int sampleRate}) readWav(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  String tag(int at) => String.fromCharCodes(bytes, at, at + 4);
  if (bytes.length < 12 || tag(0) != 'RIFF' || tag(8) != 'WAVE') {
    throw const FormatException('Not a RIFF WAVE file');
  }

  int? format, channels, sampleRate, bits;
  var at = 12;
  while (at + 8 <= bytes.length) {
    final id = tag(at);
    final size = data.getUint32(at + 4, Endian.little);
    final body = at + 8;
    if (id == 'fmt ') {
      format = data.getUint16(body, Endian.little);
      channels = data.getUint16(body + 2, Endian.little);
      sampleRate = data.getUint32(body + 4, Endian.little);
      bits = data.getUint16(body + 14, Endian.little);
      // WAVE_FORMAT_EXTENSIBLE keeps the real format in its sub-format GUID.
      if (format == 0xFFFE) format = data.getUint16(body + 24, Endian.little);
    } else if (id == 'data') {
      if (format == null) throw const FormatException('data before fmt');
      final width = bits! ~/ 8;
      final stride = width * channels!;
      final end = body + size < bytes.length ? body + size : bytes.length;
      final samples = Float32List((end - body) ~/ stride);
      for (var i = 0; i < samples.length; i++) {
        final p = body + i * stride;
        samples[i] = switch ((format, bits)) {
          (1, 16) => data.getInt16(p, Endian.little) / 32768,
          (1, 24) =>
            ((data.getInt8(p + 2) << 16) | data.getUint16(p, Endian.little)) /
                8388608,
          (1, 32) => data.getInt32(p, Endian.little) / 2147483648,
          (3, 32) => data.getFloat32(p, Endian.little),
          _ => throw FormatException(
            'Unsupported WAV: format $format, $bits bits',
          ),
        };
      }
      return (samples: samples, sampleRate: sampleRate!);
    }
    at = body + size + (size & 1);
  }
  throw const FormatException('No data chunk');
}
