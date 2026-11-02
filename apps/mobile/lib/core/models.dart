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

int _indexOfBytes(List<int> source, List<int> pattern, int start) {
  for (var index = start; index <= source.length - pattern.length; index++) {
    var match = true;
    for (var offset = 0; offset < pattern.length; offset++) {
      if (source[index + offset] != pattern[offset]) {
        match = false;
        break;
      }
    }
    if (match) {
      return index;
    }
  }
  return -1;
}

bool _matchesBytes(List<int> source, List<int> pattern, int start) {
  if (start < 0 || start + pattern.length > source.length) {
    return false;
  }
  for (var offset = 0; offset < pattern.length; offset++) {
    if (source[start + offset] != pattern[offset]) {
      return false;
    }
  }
  return true;
}

Map<String, String> _multipartHeaders(Uint8List bytes) {
  final headers = <String, String>{};
  for (final line in ascii.decode(bytes).split('\r\n')) {
    final separator = line.indexOf(':');
    if (separator <= 0) {
      throw const FormatException('The server returned an invalid response.');
    }
    headers[line.substring(0, separator).trim().toLowerCase()] = line
        .substring(separator + 1)
        .trim();
  }
  return headers;
}

class TranslationResult {
  const TranslationResult({
    required this.statusCode,
    required this.translation,
    required this.transcript,
    required this.sourceLanguage,
    required this.targetLanguage,
    required this.audioBytes,
    required this.audioMime,
  });

  final int statusCode;
  final String translation;
  final String transcript;
  final String sourceLanguage;
  final String targetLanguage;
  final Uint8List audioBytes;
  final String audioMime;

  factory TranslationResult.fromMultipartResponse({
    required Uint8List body,
    required String contentType,
  }) {
    final boundaryMatch = RegExp(
      r'(?:^|;)\s*boundary=(?:"([^"]+)"|([^;]+))',
      caseSensitive: false,
    ).firstMatch(contentType);
    final boundary = (boundaryMatch?.group(1) ?? boundaryMatch?.group(2))
        ?.trim();
    if (boundary == null || boundary.isEmpty) {
      throw const FormatException('The server returned an invalid response.');
    }

    final initialBoundary = ascii.encode('--$boundary\r\n');
    if (!_matchesBytes(body, initialBoundary, 0)) {
      throw const FormatException('The server returned an invalid response.');
    }
    final headerSeparator = <int>[13, 10, 13, 10];
    final nextBoundary = ascii.encode('\r\n--$boundary');
    var cursor = initialBoundary.length;
    Uint8List? metadataBytes;
    Uint8List? audioBytes;
    String? audioMime;

    for (var part = 0; part < 2; part++) {
      final headersEnd = _indexOfBytes(body, headerSeparator, cursor);
      if (headersEnd < 0) {
        throw const FormatException('The server returned an invalid response.');
      }
      final headers = _multipartHeaders(body.sublist(cursor, headersEnd));
      final disposition = headers['content-disposition'] ?? '';
      final name = RegExp(r'name="([^"]+)"').firstMatch(disposition)?.group(1);
      final partContentType = headers['content-type']?.split(';').first.trim();
      final dataStart = headersEnd + headerSeparator.length;
      final dataEnd = _indexOfBytes(body, nextBoundary, dataStart);
      if (dataEnd < 0) {
        throw const FormatException('The server returned an invalid response.');
      }
      final partBytes = Uint8List.fromList(body.sublist(dataStart, dataEnd));
      if (name == 'metadata' &&
          partContentType?.toLowerCase() == 'application/json' &&
          metadataBytes == null) {
        metadataBytes = partBytes;
      } else if (name == 'audio' &&
          partContentType?.toLowerCase().startsWith('audio/') == true &&
          audioBytes == null) {
        audioBytes = partBytes;
        audioMime = partContentType!.toLowerCase();
      } else {
        throw const FormatException('The server returned an invalid response.');
      }

      final boundaryEnd = dataEnd + nextBoundary.length;
      if (part == 0) {
        if (!_matchesBytes(body, <int>[13, 10], boundaryEnd)) {
          throw const FormatException(
            'The server returned an invalid response.',
          );
        }
        cursor = boundaryEnd + 2;
      } else if (!_matchesBytes(body, <int>[45, 45, 13, 10], boundaryEnd) ||
          boundaryEnd + 4 != body.length) {
        throw const FormatException('The server returned an invalid response.');
      }
    }

    final metadataContent = metadataBytes;
    final audioContent = audioBytes;
    final mime = audioMime;
    if (metadataContent == null ||
        audioContent == null ||
        audioContent.isEmpty ||
        mime == null) {
      throw const FormatException('The server returned an invalid response.');
    }
    final decoded = jsonDecode(utf8.decode(metadataContent));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('The server returned an invalid response.');
    }
    final statusCode = decoded['status_code'];
    if (statusCode is! int || statusCode != 200) {
      throw const FormatException('The server returned an invalid response.');
    }
    return TranslationResult(
      statusCode: statusCode,
      translation: _requiredString(decoded, 'translation'),
      transcript: _requiredString(decoded, 'transcript'),
      sourceLanguage: _requiredString(decoded, 'source_language'),
      targetLanguage: _requiredString(decoded, 'target_language'),
      audioBytes: audioContent,
      audioMime: mime,
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
