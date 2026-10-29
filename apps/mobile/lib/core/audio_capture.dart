import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

import 'audio_file_validator.dart';
import 'models.dart';

class AudioCaptureException implements Exception {
  const AudioCaptureException(this.message, {this.openSettings = false});

  final String message;
  final bool openSettings;

  @override
  String toString() => message;
}

class AudioCapture {
  AudioCapture() : _recorder = AudioRecorder();

  final AudioRecorder _recorder;
  String? _path;
  DateTime? _startedAt;

  Future<void> start() async {
    final permission = await Permission.microphone.request();
    if (!permission.isGranted) {
      throw AudioCaptureException(
        permission.isPermanentlyDenied || permission.isRestricted
            ? 'Microphone access is blocked. Enable it in Settings to record audio.'
            : 'Microphone permission is needed to record audio.',
        openSettings: permission.isPermanentlyDenied || permission.isRestricted,
      );
    }
    if (!await _recorder.hasPermission(request: false)) {
      throw const AudioCaptureException('Microphone access is not available.');
    }

    final directory = await getTemporaryDirectory();
    _path =
        '${directory.path}${Platform.pathSeparator}voice-${const Uuid().v4()}.m4a';
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc, numChannels: 1),
      path: _path!,
    );
    _startedAt = DateTime.now();
  }

  Future<AudioClip> stop() async {
    final path = await _recorder.stop() ?? _path;
    final startedAt = _startedAt;
    _path = null;
    _startedAt = null;
    if (path == null || startedAt == null) {
      throw const AudioCaptureException(
        'The recording could not be saved. Please try again.',
      );
    }

    final file = File(path);
    late final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } finally {
      if (await file.exists()) {
        await file.delete();
      }
    }
    final duration = DateTime.now().difference(startedAt);
    final validationError = validateAudioFile(
      fileName: path,
      sizeBytes: bytes.length,
      contentType: 'audio/mp4',
    );
    if (validationError != null) {
      throw AudioCaptureException(validationError);
    }
    return AudioClip(
      bytes: bytes,
      fileName: 'recording.m4a',
      contentType: 'audio/mp4',
      duration: duration,
    );
  }

  Future<void> cancel() async {
    final path = _path;
    _path = null;
    _startedAt = null;
    try {
      await _recorder.cancel();
    } finally {
      if (path != null) {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      }
    }
  }

  Future<void> dispose() async {
    try {
      if (_path != null) {
        await cancel();
      }
    } finally {
      await _recorder.dispose();
    }
  }
}
