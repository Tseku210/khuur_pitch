import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:khuur_pitch/khuur_pitch.dart';

void main() => runApp(const MaterialApp(home: ExamplePage()));

class ExamplePage extends StatefulWidget {
  const ExamplePage({super.key});

  @override
  State<ExamplePage> createState() => _ExamplePageState();
}

class _ExamplePageState extends State<ExamplePage> {
  final PitchSource _source = MicPitchSource();
  final ClickTrack _clicks = DeviceClickTrack();

  StreamSubscription<PitchFrame>? _frames;
  StreamSubscription<int>? _beats;
  MicPermission? _permission;
  PitchFrame? _frame;
  int? _beat;
  String? _error;

  @override
  void dispose() {
    _frames?.cancel();
    _beats?.cancel();
    super.dispose();
  }

  // The mic and the clicks each set their own audio session on iOS, so one
  // stops before the other starts.
  Future<void> _toggleMic() async {
    if (_frames != null) return _stopMic();
    await _stopClicks();
    final permission = await _source.requestPermission();
    if (!mounted) return;
    setState(() {
      _permission = permission;
      _error = null;
      if (permission == MicPermission.granted) {
        _frames = _source.frames().listen(
          (frame) => setState(() => _frame = frame),
          onError: _onError,
        );
      }
    });
  }

  Future<void> _toggleClicks() async {
    if (_beats != null) return _stopClicks();
    await _stopMic();
    await _clicks.configure(bpm: 80, beatsPerBar: 4);
    if (!mounted) return;
    setState(() {
      _error = null;
      _beats = _clicks.beats().listen(
        (beat) => setState(() => _beat = beat),
        onError: _onError,
        onDone: _stopClicks,
      );
    });
  }

  Future<void> _stopMic() async {
    await _frames?.cancel();
    if (mounted) setState(() => _frames = _frame = null);
  }

  Future<void> _stopClicks() async {
    await _beats?.cancel();
    if (mounted) setState(() => _beats = _beat = null);
  }

  void _onError(Object error) => setState(
    () => _error = error is PlatformException ? error.code : '$error',
  );

  @override
  Widget build(BuildContext context) {
    final frame = _frame;
    final hz = frame?.hz;
    return Scaffold(
      appBar: AppBar(title: const Text('khuur_pitch')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            Text(
              hz == null ? '—' : '${hz.toStringAsFixed(1)} Hz',
              style: Theme.of(context).textTheme.displayMedium,
            ),
            Text('Clarity: ${frame?.clarity.toStringAsFixed(2) ?? '-'}'),
            Text('Level: ${frame?.rmsDb.toStringAsFixed(0) ?? '-'} dBFS'),
            Text('Permission: ${_permission?.name ?? '-'}'),
            Text('Beat: ${_beat == null ? '-' : _beat! + 1}'),
            Text('Last error: ${_error ?? 'none'}'),
            FilledButton(
              onPressed: _toggleMic,
              child: Text(_frames == null ? 'Listen' : 'Stop listening'),
            ),
            FilledButton.tonal(
              onPressed: _toggleClicks,
              child: Text(_beats == null ? 'Play clicks' : 'Stop clicks'),
            ),
            if (_permission == MicPermission.permanentlyDenied)
              OutlinedButton(
                onPressed: _source.openAppSettings,
                child: const Text('Open Settings'),
              ),
          ],
        ),
      ),
    );
  }
}
