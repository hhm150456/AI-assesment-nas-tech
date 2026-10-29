import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/api_client.dart';
import '../../core/audio_capture.dart';
import '../../core/audio_file_validator.dart';
import '../../core/models.dart';
import '../../widgets/audio_playback_tile.dart';
import '../../widgets/language_picker.dart';
import '../../widgets/request_error_panel.dart';
import '../../widgets/status_banner.dart';

class TranslateScreen extends StatefulWidget {
  const TranslateScreen({super.key});

  @override
  State<TranslateScreen> createState() => _TranslateScreenState();
}

class _TranslateScreenState extends State<TranslateScreen> {
  final _api = ApiClient();
  final _capture = AudioCapture();
  Timer? _recordingTimer;
  AudioClip? _clip;
  TranslationResult? _result;
  String _targetLanguage = 'French';
  String? _requestError;
  String? _inputMessage;
  Duration _recordingDuration = Duration.zero;
  bool _isRecording = false;
  bool _isProcessing = false;

  @override
  void dispose() {
    _recordingTimer?.cancel();
    unawaited(_capture.dispose());
    _api.close();
    super.dispose();
  }

  Future<void> _startRecording() async {
    if (_isProcessing || _isRecording) {
      return;
    }
    setState(() {
      _inputMessage = null;
      _requestError = null;
    });
    try {
      await _capture.start();
      if (!mounted) {
        return;
      }
      setState(() {
        _isRecording = true;
        _recordingDuration = Duration.zero;
        _clip = null;
        _result = null;
      });
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || !_isRecording) {
          return;
        }
        final next = _recordingDuration + const Duration(seconds: 1);
        if (next >= maxRecordingDuration) {
          unawaited(_stopRecording());
        } else {
          setState(() => _recordingDuration = next);
        }
      });
    } on AudioCaptureException catch (error) {
      if (mounted) {
        setState(() => _inputMessage = error.message);
        if (error.openSettings) {
          await _showMicrophoneSettingsDialog();
        }
      }
    } on Exception {
      if (mounted) {
        setState(
          () => _inputMessage = 'Could not start recording. Please try again.',
        );
      }
    }
  }

  Future<void> _stopRecording() async {
    if (!_isRecording) {
      return;
    }
    _recordingTimer?.cancel();
    setState(() => _isRecording = false);
    try {
      final clip = await _capture.stop();
      if (!mounted) {
        return;
      }
      setState(() {
        _clip = clip;
        _result = null;
        _requestError = null;
        _inputMessage = null;
      });
    } on AudioCaptureException catch (error) {
      if (mounted) {
        setState(() => _inputMessage = error.message);
      }
    } on Exception {
      if (mounted) {
        setState(
          () =>
              _inputMessage = 'Could not save the recording. Please try again.',
        );
      }
    }
  }

  Future<void> _pickAudio() async {
    if (_isProcessing || _isRecording) {
      return;
    }
    setState(() {
      _inputMessage = null;
      _requestError = null;
    });
    try {
      final selection = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: supportedAudioExtensions.toList(),
      );
      if (selection.isEmpty || !mounted) {
        return;
      }
      final file = selection.single;
      final knownSize = file.lengthSync();
      if (knownSize != null && knownSize > maxAudioBytes) {
        setState(
          () => _inputMessage = 'The audio file must be 20 MB or smaller.',
        );
        return;
      }
      final bytes = await file.readAsBytes();
      final mimeType = audioMimeTypeForName(file.name);
      final validationError = validateAudioFile(
        fileName: file.name,
        sizeBytes: bytes.length,
        contentType: mimeType,
      );
      if (validationError != null) {
        setState(() => _inputMessage = validationError);
        return;
      }
      setState(() {
        _clip = AudioClip(
          bytes: bytes,
          fileName: file.name,
          contentType: mimeType,
        );
        _result = null;
        _requestError = null;
        _inputMessage = null;
      });
    } on Exception {
      if (mounted) {
        setState(
          () => _inputMessage =
              'Could not read that audio file. Try another file.',
        );
      }
    }
  }

  Future<void> _submit() async {
    final clip = _clip;
    if (clip == null || _isProcessing) {
      return;
    }
    setState(() {
      _isProcessing = true;
      _requestError = null;
      _result = null;
      _inputMessage = null;
    });
    try {
      final result = await _api.translate(
        audio: clip,
        targetLanguage: _targetLanguage,
      );
      if (mounted) {
        setState(() => _result = result);
      }
    } on ApiException catch (error) {
      if (mounted) {
        setState(() => _requestError = error.message);
      }
    } on Exception {
      if (mounted) {
        setState(
          () =>
              _requestError = 'Something went wrong. Please retry the request.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  Future<void> _reset() async {
    _recordingTimer?.cancel();
    if (_isRecording) {
      await _capture.cancel();
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _clip = null;
      _result = null;
      _requestError = null;
      _inputMessage = null;
      _recordingDuration = Duration.zero;
      _isRecording = false;
      _isProcessing = false;
    });
  }

  Future<void> _showMicrophoneSettingsDialog() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Microphone access needed'),
        content: const Text(
          'Allow microphone access in your device settings to record audio. You can still upload an audio file.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context);
              await openAppSettings();
            },
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  String _durationLabel(Duration duration) {
    final minutes = duration.inMinutes.toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final clip = _clip;
    final result = _result;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Voice translation'),
        actions: [
          IconButton(
            tooltip: 'Reset',
            onPressed: _isProcessing ? null : _reset,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                'Speak or upload a clip',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              const Text(
                'Translate audio into one of the supported languages.',
              ),
              const SizedBox(height: 20),
              LanguagePicker(
                label: 'Translate to',
                value: _targetLanguage,
                enabled: !_isProcessing,
                onChanged: _isProcessing
                    ? (_) {}
                    : (language) => setState(() => _targetLanguage = language),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed: _isProcessing
                        ? null
                        : _isRecording
                        ? _stopRecording
                        : _startRecording,
                    icon: Icon(_isRecording ? Icons.stop : Icons.mic),
                    label: Text(
                      _isRecording
                          ? 'Stop recording  ${_durationLabel(_recordingDuration)}'
                          : 'Record audio',
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _isProcessing || _isRecording
                        ? null
                        : _pickAudio,
                    icon: const Icon(Icons.upload_file),
                    label: const Text('Upload audio'),
                  ),
                ],
              ),
              if (_isRecording) ...[
                const SizedBox(height: 12),
                const StatusBanner(
                  message:
                      'Recording… Keep speaking; the 2-minute limit is enforced.',
                ),
              ],
              if (_inputMessage != null) ...[
                const SizedBox(height: 12),
                StatusBanner(message: _inputMessage!, isError: true),
              ],
              if (clip != null) ...[
                const SizedBox(height: 12),
                AudioPlaybackTile(
                  key: ValueKey(identityHashCode(clip.bytes)),
                  audioBytes: clip.bytes,
                  mimeType: clip.contentType,
                  title: clip.fileName,
                  duration: clip.duration,
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: _isProcessing
                        ? null
                        : () => setState(() => _clip = null),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Discard audio'),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: clip == null || _isProcessing || _isRecording
                    ? null
                    : _submit,
                icon: _isProcessing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.translate),
                label: Text(_isProcessing ? 'Translating…' : 'Translate audio'),
              ),
              if (_requestError != null && clip != null) ...[
                const SizedBox(height: 16),
                RequestErrorPanel(
                  message: _requestError!,
                  onRetry: _submit,
                  onReset: _reset,
                ),
              ],
              if (result != null) ...[
                const SizedBox(height: 16),
                StatusBanner(
                  message:
                      'Translated from ${result.sourceLanguage} to ${result.targetLanguage}.',
                ),
                const SizedBox(height: 8),
                AudioPlaybackTile(
                  key: ValueKey(identityHashCode(result.audioBytes)),
                  audioBytes: result.audioBytes,
                  mimeType: result.audioMime,
                  title: 'Translated audio',
                ),
                Card(
                  child: ExpansionTile(
                    title: const Text('Transcript and translation'),
                    childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    children: [
                      _TextSection(
                        label: 'Detected language',
                        text: result.sourceLanguage,
                      ),
                      _TextSection(
                        label: 'Transcript',
                        text: result.transcript,
                      ),
                      _TextSection(
                        label: 'Translation',
                        text: result.translation,
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 20),
              Text(
                'Audio files up to 20 MB · recordings up to 2 minutes',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TextSection extends StatelessWidget {
  const _TextSection({required this.label, required this.text});

  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            Text(text),
          ],
        ),
      ),
    );
  }
}
