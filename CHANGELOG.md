## 0.1.1

- `AudioCapture(withPlayback: true)` lets the app play sound while the mic
  listens. On iOS the session is `.playAndRecord` in `.measurement` mode, to
  the speaker, instead of `.record`.

## 0.1.0

- Microphone capture as mono float PCM on iOS and Android.
- Pitch tracking with YIN in pure Dart, with a clarity and a level for each frame.
- A range of 60 to 1400 Hz by default, set with `PitchTracker(minHz:, maxHz:)`.
  A tone outside the range reads as no pitch.
- `PitchTracker(threshold:)` sets how periodic a window must be.
