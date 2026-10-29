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
import '../../widgets/status_banner.dart';

class ConversationScreen extends StatefulWidget {
  const ConversationScreen({super.key});

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  final _api = ApiClient();
  final _capture = AudioCapture();
  final List<ConversationTurnResult> _turns = [];
  Timer? _recordingTimer;
  ConversationSession? _session;
  ConversationSummary? _summary;
  AudioClip? _pendingClip;
  String _languageA = 'English';
  String _languageB = 'French';
  String? _pendingSpeaker;
  String? _pendingError;
  String? _setupError;
  String? _summaryError;
  String? _inputError;
  String? _recordingSpeaker;
  Duration _recordingDuration = Duration.zero;
  bool _isStarting = false;
  bool _isStartingRecording = false;
  bool _isStoppingRecording = false;
  bool _isTurnProcessing = false;
  bool _isSummaryProcessing = false;
  bool _sessionUnavailable = false;

  bool get _hasPendingTurn => _pendingClip != null && _pendingSpeaker != null;

  @override
  void dispose() {
    _recordingTimer?.cancel();
    unawaited(_capture.dispose());
    _api.close();
    super.dispose();
  }

  Future<void> _startConversation() async {
    if (_isStarting || _languageA == _languageB) {
      return;
    }
    setState(() {
      _isStarting = true;
      _setupError = null;
    });
    try {
      final session = await _api.startConversation(
        languageA: _languageA,
        languageB: _languageB,
      );
      if (mounted) {
        setState(() {
          _session = session;
          _turns.clear();
          _summary = null;
          _summaryError = null;
          _sessionUnavailable = false;
        });
      }
    } on ApiException catch (error) {
      if (mounted) {
        setState(() => _setupError = error.message);
      }
    } on Exception {
      if (mounted) {
        setState(
          () => _setupError =
              'Could not start the conversation. Please try again.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isStarting = false);
      }
    }
  }

  Future<void> _toggleRecording(String speaker) async {
    if (_isTurnProcessing ||
        _isSummaryProcessing ||
        _hasPendingTurn ||
        _sessionUnavailable) {
      return;
    }
    if (_recordingSpeaker == speaker) {
      await _stopRecording();
      return;
    }
    if (_recordingSpeaker != null || _isStartingRecording) {
      return;
    }
    _isStartingRecording = true;
    setState(() => _inputError = null);
    try {
      await _capture.start();
      if (!mounted) {
        return;
      }
      setState(() {
        _recordingSpeaker = speaker;
        _recordingDuration = Duration.zero;
      });
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || _recordingSpeaker == null) {
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
        setState(() => _inputError = error.message);
        if (error.openSettings) {
          await _showMicrophoneSettingsDialog();
        }
      }
    } on Exception {
      if (mounted) {
        setState(
          () => _inputError = 'Could not start recording. Please try again.',
        );
      }
    } finally {
      _isStartingRecording = false;
    }
  }

  Future<void> _stopRecording() async {
    final speaker = _recordingSpeaker;
    if (speaker == null) {
      return;
    }
    _recordingTimer?.cancel();
    setState(() {
      _recordingSpeaker = null;
      _isStoppingRecording = true;
    });
    try {
      final clip = await _capture.stop();
      if (mounted) {
        await _sendTurn(speaker, clip);
      }
    } on AudioCaptureException catch (error) {
      if (mounted) {
        setState(() => _inputError = error.message);
      }
    } on Exception {
      if (mounted) {
        setState(
          () => _inputError = 'Could not save the recording. Please try again.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isStoppingRecording = false);
      }
    }
  }

  Future<void> _pickAudio(String speaker) async {
    if (_isTurnProcessing ||
        _isSummaryProcessing ||
        _hasPendingTurn ||
        _recordingSpeaker != null ||
        _sessionUnavailable) {
      return;
    }
    setState(() => _inputError = null);
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
          () => _inputError = 'The audio file must be 20 MB or smaller.',
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
        setState(() => _inputError = validationError);
        return;
      }
      await _sendTurn(
        speaker,
        AudioClip(bytes: bytes, fileName: file.name, contentType: mimeType),
      );
    } on Exception {
      if (mounted) {
        setState(
          () =>
              _inputError = 'Could not read that audio file. Try another file.',
        );
      }
    }
  }

  Future<void> _sendTurn(String speaker, AudioClip clip) async {
    final session = _session;
    if (session == null || _isTurnProcessing || _hasPendingTurn) {
      return;
    }
    setState(() {
      _pendingSpeaker = speaker;
      _pendingClip = clip;
      _pendingError = null;
      _inputError = null;
      _summaryError = null;
    });
    await _retryPendingTurn();
  }

  Future<void> _retryPendingTurn() async {
    final session = _session;
    final speaker = _pendingSpeaker;
    final clip = _pendingClip;
    if (session == null ||
        speaker == null ||
        clip == null ||
        _isTurnProcessing ||
        _sessionUnavailable) {
      return;
    }
    setState(() {
      _isTurnProcessing = true;
      _pendingError = null;
    });
    try {
      final result = await _api.sendConversationTurn(
        sessionId: session.sessionId,
        speaker: speaker,
        audio: clip,
      );
      if (mounted) {
        setState(() {
          _turns.add(result);
          _pendingSpeaker = null;
          _pendingClip = null;
          _pendingError = null;
          _sessionUnavailable = false;
        });
      }
    } on ApiException catch (error) {
      if (mounted) {
        setState(() {
          _pendingError = error.message;
          _sessionUnavailable = _isUnavailableMessage(error.message);
        });
      }
    } on Exception {
      if (mounted) {
        setState(
          () => _pendingError =
              'The turn failed. Retry to send this recording again.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isTurnProcessing = false);
      }
    }
  }

  bool _isUnavailableMessage(String message) {
    final normalized = message.toLowerCase();
    return normalized.contains('closed') || normalized.contains('not found');
  }

  Future<void> _showSummary({required bool closeAfter}) async {
    final session = _session;
    if (session == null || _isSummaryProcessing || _hasPendingTurn) {
      return;
    }
    setState(() {
      _isSummaryProcessing = true;
      _summaryError = null;
    });
    try {
      final summary = await _api.getConversationSummary(
        sessionId: session.sessionId,
        closeAfter: closeAfter,
      );
      if (mounted) {
        setState(() {
          _summary = summary;
          _sessionUnavailable = false;
        });
      }
    } on ApiException catch (error) {
      if (mounted) {
        setState(() {
          _summaryError = error.message;
          _sessionUnavailable = _isUnavailableMessage(error.message);
        });
      }
    } on Exception {
      if (mounted) {
        setState(
          () => _summaryError =
              'Could not get the conversation summary. Please try again.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSummaryProcessing = false);
      }
    }
  }

  Future<void> _confirmNewConversation() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Start a new conversation?'),
        content: const Text(
          'This clears the current conversation from this device. A new session will start without its history.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Start new'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    _recordingTimer?.cancel();
    if (_recordingSpeaker != null) {
      await _capture.cancel();
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _session = null;
      _turns.clear();
      _summary = null;
      _pendingClip = null;
      _pendingSpeaker = null;
      _pendingError = null;
      _setupError = null;
      _summaryError = null;
      _inputError = null;
      _recordingSpeaker = null;
      _recordingDuration = Duration.zero;
      _sessionUnavailable = false;
    });
  }

  Future<void> _showMicrophoneSettingsDialog() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Microphone access needed'),
        content: const Text(
          'Allow microphone access in Settings to record. You can also upload a clip instead.',
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

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Conversation'),
        actions: [
          if (_session != null)
            IconButton(
              tooltip: 'New conversation',
              onPressed: _isTurnProcessing || _isSummaryProcessing
                  ? null
                  : _confirmNewConversation,
              icon: const Icon(Icons.add_comment_outlined),
            ),
        ],
      ),
      body: _session == null ? _buildSetup() : _buildConversation(_session!),
    );
  }

  Widget _buildSetup() {
    final sameLanguage = _languageA == _languageB;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              'Set up a conversation',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            const Text(
              'Each participant speaks their own language. Their voice is translated for the other person.',
            ),
            const SizedBox(height: 20),
            LanguagePicker(
              label: 'Participant A',
              value: _languageA,
              enabled: !_isStarting,
              onChanged: (value) => setState(() {
                _languageA = value;
                _setupError = null;
              }),
            ),
            const SizedBox(height: 12),
            LanguagePicker(
              label: 'Participant B',
              value: _languageB,
              enabled: !_isStarting,
              onChanged: (value) => setState(() {
                _languageB = value;
                _setupError = null;
              }),
            ),
            if (sameLanguage) ...[
              const SizedBox(height: 8),
              Text(
                'Choose two different languages.',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (_setupError != null) ...[
              const SizedBox(height: 16),
              StatusBanner(message: _setupError!, isError: true),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: sameLanguage || _isStarting
                  ? null
                  : _startConversation,
              icon: _isStarting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.forum_outlined),
              label: Text(_isStarting ? 'Starting…' : 'Start conversation'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConversation(ConversationSession session) {
    final locked = sessionUnavailableOrClosed;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _ConversationHeader(
              languageA: session.languageA,
              languageB: session.languageB,
              turnCount: _turns.length,
              isClosed: locked,
            ),
            if (_sessionUnavailable) ...[
              const SizedBox(height: 12),
              StatusBanner(
                message:
                    _pendingError ??
                    _summaryError ??
                    'This conversation is closed or unavailable.',
                isError: true,
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _confirmNewConversation,
                icon: const Icon(Icons.add_comment_outlined),
                label: const Text('Start new conversation'),
              ),
            ],
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth < 680
                    ? constraints.maxWidth
                    : (constraints.maxWidth - 12) / 2;
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    SizedBox(
                      width: width,
                      child: _ParticipantControls(
                        participant: 'A',
                        language: session.languageA,
                        isRecording: _recordingSpeaker == 'A',
                        recordingDuration: _recordingDuration,
                        busy:
                            _isTurnProcessing ||
                            _isSummaryProcessing ||
                            _isStoppingRecording ||
                            _hasPendingTurn ||
                            locked ||
                            _recordingSpeaker == 'B' ||
                            _isStartingRecording,
                        onRecord: () => _toggleRecording('A'),
                        onUpload: () => _pickAudio('A'),
                      ),
                    ),
                    SizedBox(
                      width: width,
                      child: _ParticipantControls(
                        participant: 'B',
                        language: session.languageB,
                        isRecording: _recordingSpeaker == 'B',
                        recordingDuration: _recordingDuration,
                        busy:
                            _isTurnProcessing ||
                            _isSummaryProcessing ||
                            _isStoppingRecording ||
                            _hasPendingTurn ||
                            locked ||
                            _recordingSpeaker == 'A' ||
                            _isStartingRecording,
                        onRecord: () => _toggleRecording('B'),
                        onUpload: () => _pickAudio('B'),
                      ),
                    ),
                  ],
                );
              },
            ),
            if (_inputError != null) ...[
              const SizedBox(height: 12),
              StatusBanner(message: _inputError!, isError: true),
            ],
            if (_recordingSpeaker != null) ...[
              const SizedBox(height: 12),
              StatusBanner(
                message:
                    'Recording for participant $_recordingSpeaker… '
                    '${_formatDuration(_recordingDuration)}',
              ),
            ],
            const SizedBox(height: 20),
            if (_turns.isEmpty && !_hasPendingTurn)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(18),
                  child: Text('Turns will appear here after someone speaks.'),
                ),
              ),
            for (var index = 0; index < _turns.length; index++)
              _TurnBubble(
                turn: _turns[index],
                alignRight: _turns[index].speaker == 'B',
                autoPlay: index == _turns.length - 1 && !_hasPendingTurn,
              ),
            if (_hasPendingTurn)
              _PendingTurnBubble(
                speaker: _pendingSpeaker!,
                clip: _pendingClip!,
                isProcessing: _isTurnProcessing,
                error: _pendingError,
                onRetry: _retryPendingTurn,
                showNewConversation: _sessionUnavailable,
                onNewConversation: _confirmNewConversation,
              ),
            if (_summaryError != null) ...[
              const SizedBox(height: 12),
              StatusBanner(message: _summaryError!, isError: true),
            ],
            if (_summary != null) ...[
              const SizedBox(height: 12),
              _SummaryCard(summary: _summary!),
            ],
            const SizedBox(height: 20),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed:
                      _isTurnProcessing ||
                          _isSummaryProcessing ||
                          _hasPendingTurn ||
                          locked
                      ? null
                      : () => _showSummary(closeAfter: false),
                  icon: _isSummaryProcessing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.summarize_outlined),
                  label: const Text('Summary'),
                ),
                FilledButton.icon(
                  onPressed:
                      _isTurnProcessing ||
                          _isSummaryProcessing ||
                          _hasPendingTurn ||
                          locked
                      ? null
                      : () => _showSummary(closeAfter: true),
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('End and summarize'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: _isTurnProcessing || _isSummaryProcessing
                  ? null
                  : _confirmNewConversation,
              icon: const Icon(Icons.restart_alt),
              label: const Text('New conversation'),
            ),
          ],
        ),
      ),
    );
  }

  bool get sessionUnavailableOrClosed =>
      _sessionUnavailable || (_summary?.closed ?? false);
}

class _ConversationHeader extends StatelessWidget {
  const _ConversationHeader({
    required this.languageA,
    required this.languageB,
    required this.turnCount,
    required this.isClosed,
  });

  final String languageA;
  final String languageB;
  final int turnCount;
  final bool isClosed;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Chip(label: Text('A · $languageA')),
                const Icon(Icons.swap_horiz, size: 20),
                Chip(label: Text('B · $languageB')),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${isClosed ? 'Closed' : 'In progress'} · $turnCount ${turnCount == 1 ? 'turn' : 'turns'}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _ParticipantControls extends StatelessWidget {
  const _ParticipantControls({
    required this.participant,
    required this.language,
    required this.isRecording,
    required this.recordingDuration,
    required this.busy,
    required this.onRecord,
    required this.onUpload,
  });

  final String participant;
  final String language;
  final bool isRecording;
  final Duration recordingDuration;
  final bool busy;
  final VoidCallback onRecord;
  final VoidCallback onUpload;

  String _duration(Duration duration) {
    final minutes = duration.inMinutes.toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Participant $participant',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(language),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: busy ? null : onRecord,
              icon: Icon(isRecording ? Icons.stop : Icons.mic),
              label: Text(
                isRecording
                    ? 'Stop · ${_duration(recordingDuration)}'
                    : 'Record in $language',
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: busy ? null : onUpload,
              icon: const Icon(Icons.upload_file),
              label: const Text('Upload audio'),
            ),
            Text(
              'Tap to start recording; tap again to send.',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _TurnBubble extends StatelessWidget {
  const _TurnBubble({
    required this.turn,
    required this.alignRight,
    required this.autoPlay,
  });

  final ConversationTurnResult turn;
  final bool alignRight;
  final bool autoPlay;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Align(
      alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: Card(
          color: alignRight ? colorScheme.secondaryContainer : null,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Participant ${turn.speaker} · ${turn.sourceLanguage} → ${turn.targetLanguage}',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 10),
                Text(turn.transcript),
                const Divider(height: 22),
                Text(turn.translation),
                const SizedBox(height: 8),
                AudioPlaybackTile(
                  key: ValueKey(
                    'turn-${turn.sequence}-${identityHashCode(turn.audioBytes)}',
                  ),
                  audioBytes: turn.audioBytes,
                  mimeType: turn.audioMime,
                  title: 'Play translation',
                  autoPlay: autoPlay,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PendingTurnBubble extends StatelessWidget {
  const _PendingTurnBubble({
    required this.speaker,
    required this.clip,
    required this.isProcessing,
    required this.error,
    required this.onRetry,
    required this.showNewConversation,
    required this.onNewConversation,
  });

  final String speaker;
  final AudioClip clip;
  final bool isProcessing;
  final String? error;
  final VoidCallback onRetry;
  final bool showNewConversation;
  final VoidCallback onNewConversation;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (isProcessing)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  const Icon(Icons.error_outline),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    error == null
                        ? 'Participant $speaker · Processing turn…'
                        : 'Participant $speaker · Turn failed',
                  ),
                ),
              ],
            ),
            AudioPlaybackTile(
              key: ValueKey(identityHashCode(clip.bytes)),
              audioBytes: clip.bytes,
              mimeType: clip.contentType,
              title: 'Recording to send',
              duration: clip.duration,
            ),
            if (error != null) ...[
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: isProcessing ? null : onRetry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry turn'),
                  ),
                  if (showNewConversation)
                    OutlinedButton(
                      onPressed: onNewConversation,
                      child: const Text('Start new conversation'),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary});

  final ConversationSummary summary;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Conversation summary',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            Text(
              summary.languageA,
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 4),
            SelectableText(summary.summaryA),
            const Divider(height: 24),
            Text(
              summary.languageB,
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 4),
            SelectableText(summary.summaryB),
            if (summary.closed) ...[
              const SizedBox(height: 12),
              const StatusBanner(message: 'This conversation has ended.'),
            ],
          ],
        ),
      ),
    );
  }
}
