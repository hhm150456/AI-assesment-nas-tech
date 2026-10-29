import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

class AudioPlaybackTile extends StatefulWidget {
  const AudioPlaybackTile({
    required this.audioBytes,
    required this.mimeType,
    required this.title,
    this.duration,
    this.autoPlay = false,
    super.key,
  });

  final Uint8List audioBytes;
  final String mimeType;
  final String title;
  final Duration? duration;
  final bool autoPlay;

  @override
  State<AudioPlaybackTile> createState() => _AudioPlaybackTileState();
}

class _AudioPlaybackTileState extends State<AudioPlaybackTile> {
  final _player = AudioPlayer();
  StreamSubscription<PlayerState>? _stateSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  String? _audioPath;
  Duration? _playerDuration;
  bool _isPlaying = false;
  bool _isLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _stateSubscription = _player.onPlayerStateChanged.listen((state) {
      if (mounted) {
        setState(() => _isPlaying = state == PlayerState.playing);
      }
    });
    _durationSubscription = _player.onDurationChanged.listen((duration) {
      if (mounted) {
        setState(() => _playerDuration = duration);
      }
    });
    if (widget.autoPlay) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _play());
    }
  }

  @override
  void didUpdateWidget(covariant AudioPlaybackTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.audioBytes, widget.audioBytes) ||
        oldWidget.mimeType != widget.mimeType) {
      unawaited(_resetSource());
    } else if (oldWidget.autoPlay && !widget.autoPlay) {
      unawaited(_player.stop());
    }
  }

  Future<void> _resetSource() async {
    await _player.stop();
    final path = _audioPath;
    _audioPath = null;
    _playerDuration = null;
    if (path != null) {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  Future<String> _ensureAudioFile() async {
    final existing = _audioPath;
    if (existing != null) {
      return existing;
    }
    final extension = switch (widget.mimeType.toLowerCase()) {
      'audio/wav' || 'audio/x-wav' => 'wav',
      'audio/mp4' || 'audio/x-m4a' => 'm4a',
      'audio/ogg' || 'application/ogg' => 'ogg',
      'audio/webm' => 'webm',
      'audio/flac' || 'audio/x-flac' => 'flac',
      _ => 'mp3',
    };
    final directory = await getTemporaryDirectory();
    final file = File(
      '${directory.path}${Platform.pathSeparator}playback-${const Uuid().v4()}.$extension',
    );
    await file.writeAsBytes(widget.audioBytes, flush: true);
    _audioPath = file.path;
    return file.path;
  }

  Future<void> _play() async {
    if (_isLoading) {
      return;
    }
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final path = await _ensureAudioFile();
      await _player.setSource(DeviceFileSource(path));
      await _player.resume();
    } on Exception {
      if (mounted) {
        setState(() => _error = 'Audio could not be played.');
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _togglePlayback() async {
    if (_isLoading) {
      return;
    }
    try {
      if (_isPlaying) {
        await _player.pause();
      } else {
        await _play();
      }
    } on Exception {
      if (mounted) {
        setState(() => _error = 'Audio could not be played.');
      }
    }
  }

  Future<void> _cleanup() async {
    await _stateSubscription?.cancel();
    await _durationSubscription?.cancel();
    await _player.dispose();
    final path = _audioPath;
    if (path != null) {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  @override
  void dispose() {
    unawaited(_cleanup());
    super.dispose();
  }

  String _durationLabel(Duration? duration) {
    if (duration == null) {
      return 'Audio clip';
    }
    final minutes = duration.inMinutes.toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final duration = widget.duration ?? _playerDuration;
    return Card(
      child: ListTile(
        leading: IconButton(
          tooltip: _isPlaying
              ? 'Pause ${widget.title}'
              : 'Play ${widget.title}',
          onPressed: _togglePlayback,
          icon: _isLoading
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(_isPlaying ? Icons.pause_circle : Icons.play_circle),
        ),
        title: Text(widget.title),
        subtitle: Text(_error ?? _durationLabel(duration)),
        trailing: const Icon(Icons.graphic_eq),
      ),
    );
  }
}
