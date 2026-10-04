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

  StreamSubscription<PitchFrame>? _frames;
  MicPermission? _permission;
  PitchFrame? _frame;
  String? _error;

  @override
  void dispose() {
    _frames?.cancel();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_frames != null) return _stop();
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

  Future<void> _stop() async {
    await _frames?.cancel();
    if (mounted) setState(() => _frames = _frame = null);
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
            Text('Last error: ${_error ?? 'none'}'),
            FilledButton(
              onPressed: _toggle,
              child: Text(_frames == null ? 'Listen' : 'Stop listening'),
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
