import 'dart:convert';
import 'dart:typed_data';

class ApiException implements Exception {
  const ApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AudioClip {
  const AudioClip({
    required this.bytes,
    required this.fileName,
    required this.contentType,
    this.duration,
  });

  final Uint8List bytes;
  final String fileName;
  final String contentType;
  final Duration? duration;
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw const FormatException('The server returned an invalid response.');
  }
  return value;
}

Uint8List _audioBytes(Map<String, dynamic> json) {
  try {
    final audio = base64Decode(_requiredString(json, 'audio_base64'));
    if (audio.isEmpty) {
      throw const FormatException('The server returned empty audio data.');
    }
    return audio;
  } on FormatException {
    throw const FormatException('The server returned invalid audio data.');
  }
}

class TranslationResult {
  const TranslationResult({
    required this.translation,
    required this.transcript,
    required this.sourceLanguage,
    required this.targetLanguage,
    required this.audioBytes,
    required this.audioMime,
  });

  final String translation;
  final String transcript;
  final String sourceLanguage;
  final String targetLanguage;
  final Uint8List audioBytes;
  final String audioMime;

  factory TranslationResult.fromJson(Map<String, dynamic> json) {
    if (json['status'] != 'success') {
      throw const FormatException('The server returned an invalid response.');
    }
    return TranslationResult(
      translation: _requiredString(json, 'translation'),
      transcript: _requiredString(json, 'transcript'),
      sourceLanguage: _requiredString(json, 'source_language'),
      targetLanguage: _requiredString(json, 'target_language'),
      audioBytes: _audioBytes(json),
      audioMime: _requiredString(json, 'audio_mime'),
    );
  }
}

class ConversationSession {
  const ConversationSession({
    required this.sessionId,
    required this.languageA,
    required this.languageB,
  });

  final String sessionId;
  final String languageA;
  final String languageB;

  factory ConversationSession.fromJson(Map<String, dynamic> json) {
    if (json['status'] != 'started') {
      throw const FormatException('The server returned an invalid response.');
    }
    return ConversationSession(
      sessionId: _requiredString(json, 'session_id'),
      languageA: _requiredString(json, 'lang_a'),
      languageB: _requiredString(json, 'lang_b'),
    );
  }
}

class ConversationTurnResult {
  const ConversationTurnResult({
    required this.translation,
    required this.transcript,
    required this.speaker,
    required this.sourceLanguage,
    required this.targetLanguage,
    required this.sequence,
    required this.audioBytes,
    required this.audioMime,
  });

  final String translation;
  final String transcript;
  final String speaker;
  final String sourceLanguage;
  final String targetLanguage;
  final String sequence;
  final Uint8List audioBytes;
  final String audioMime;

  factory ConversationTurnResult.fromJson(Map<String, dynamic> json) {
    if (json['status'] != 'success') {
      throw const FormatException('The server returned an invalid response.');
    }
    final sequence = json['seq'];
    if (sequence is! String && sequence is! num) {
      throw const FormatException('The server returned an invalid response.');
    }
    return ConversationTurnResult(
      translation: _requiredString(json, 'translation'),
      transcript: _requiredString(json, 'transcript'),
      speaker: _requiredString(json, 'speaker'),
      sourceLanguage: _requiredString(json, 'source_lang'),
      targetLanguage: _requiredString(json, 'target_lang'),
      sequence: sequence.toString(),
      audioBytes: _audioBytes(json),
      audioMime: _requiredString(json, 'audio_mime'),
    );
  }
}

class ConversationSummary {
  const ConversationSummary({
    required this.summaryA,
    required this.summaryB,
    required this.languageA,
    required this.languageB,
    required this.closed,
  });

  final String summaryA;
  final String summaryB;
  final String languageA;
  final String languageB;
  final bool closed;

  factory ConversationSummary.fromJson(Map<String, dynamic> json) {
    if (json['status'] != 'success') {
      throw const FormatException('The server returned an invalid response.');
    }
    final closedValue = _requiredString(json, 'closed');
    if (closedValue != 'yes' && closedValue != 'no') {
      throw const FormatException('The server returned an invalid response.');
    }
    return ConversationSummary(
      summaryA: _requiredString(json, 'summary_a'),
      summaryB: _requiredString(json, 'summary_b'),
      languageA: _requiredString(json, 'lang_a'),
      languageB: _requiredString(json, 'lang_b'),
      closed: closedValue == 'yes',
    );
  }
}

Map<String, dynamic> decodeJsonObject(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('The server returned an invalid response.');
  }
  return decoded;
}
