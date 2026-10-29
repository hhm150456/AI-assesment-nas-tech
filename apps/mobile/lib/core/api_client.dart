import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'audio_file_validator.dart';
import 'config.dart';
import 'models.dart';

class ApiClient {
  ApiClient({String? baseUrl, http.Client? client})
    : _baseUrl = (baseUrl ?? ApiConfig.apiBaseUrl).trim().replaceAll(
        RegExp(r'/+$'),
        '',
      ),
      _client = client ?? http.Client();

  static const requestTimeout = Duration(seconds: 150);
  static const _deviceIdKey = 'anonymous_device_id';

  final String _baseUrl;
  final http.Client _client;
  Future<String>? _deviceIdFuture;

  Future<TranslationResult> translate({
    required AudioClip audio,
    required String targetLanguage,
  }) async {
    final validationError = validateAudioFile(
      fileName: audio.fileName,
      sizeBytes: audio.bytes.length,
      contentType: audio.contentType,
    );
    if (validationError != null) {
      throw ApiException(validationError);
    }
    final json = await _postMultipart(
      '/api/translate',
      fields: {'target_language': targetLanguage},
      audio: audio,
    );
    try {
      return TranslationResult.fromJson(json);
    } on FormatException catch (error) {
      throw ApiException(error.message);
    }
  }

  Future<ConversationSession> startConversation({
    required String languageA,
    required String languageB,
  }) async {
    final json = await _postJson('/api/conversation/start', {
      'lang_a': languageA,
      'lang_b': languageB,
    });
    try {
      return ConversationSession.fromJson(json);
    } on FormatException catch (error) {
      throw ApiException(error.message);
    }
  }

  Future<ConversationTurnResult> sendConversationTurn({
    required String sessionId,
    required String speaker,
    required AudioClip audio,
  }) async {
    final validationError = validateAudioFile(
      fileName: audio.fileName,
      sizeBytes: audio.bytes.length,
      contentType: audio.contentType,
    );
    if (validationError != null) {
      throw ApiException(validationError);
    }
    final json = await _postMultipart(
      '/api/conversation/turn',
      fields: {'session_id': sessionId, 'speaker': speaker},
      audio: audio,
    );
    try {
      return ConversationTurnResult.fromJson(json);
    } on FormatException catch (error) {
      throw ApiException(error.message);
    }
  }

  Future<ConversationSummary> getConversationSummary({
    required String sessionId,
    required bool closeAfter,
  }) async {
    final json = await _postJson('/api/conversation/summary', {
      'session_id': sessionId,
      'close_after': closeAfter ? 'yes' : 'no',
    });
    try {
      return ConversationSummary.fromJson(json);
    } on FormatException catch (error) {
      throw ApiException(error.message);
    }
  }

  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, Object> body,
  ) async {
    final uri = _endpoint(path);
    try {
      final response = await _client
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'X-Device-Id': await _deviceId(),
            },
            body: jsonEncode(body),
          )
          .timeout(requestTimeout);
      return _parseResponse(response);
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw const ApiException(
        'The request timed out. Check your connection and try again.',
      );
    } on SocketException {
      throw const ApiException(
        'You appear to be offline. Check your connection and try again.',
      );
    } on http.ClientException {
      throw const ApiException(
        'Could not reach the translation service. Check your connection.',
      );
    } on FormatException catch (error) {
      throw ApiException(error.message);
    }
  }

  Future<Map<String, dynamic>> _postMultipart(
    String path, {
    required Map<String, String> fields,
    required AudioClip audio,
  }) async {
    final request = http.MultipartRequest('POST', _endpoint(path))
      ..headers['X-Device-Id'] = await _deviceId()
      ..fields.addAll(fields)
      ..files.add(
        http.MultipartFile.fromBytes(
          'audio',
          audio.bytes,
          filename: audio.fileName,
          contentType: MediaType.parse(audio.contentType),
        ),
      );

    try {
      final streamed = await _client.send(request).timeout(requestTimeout);
      final response = await http.Response.fromStream(
        streamed,
      ).timeout(requestTimeout);
      return _parseResponse(response);
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw const ApiException(
        'The request timed out. Check your connection and try again.',
      );
    } on SocketException {
      throw const ApiException(
        'You appear to be offline. Check your connection and try again.',
      );
    } on http.ClientException {
      throw const ApiException(
        'Could not reach the translation service. Check your connection.',
      );
    } on FormatException catch (error) {
      throw ApiException(error.message);
    }
  }

  Map<String, dynamic> _parseResponse(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = switch (response.statusCode) {
        413 =>
          'The audio upload is too large. Choose a file smaller than 20 MB.',
        429 => 'Too many requests. Please wait a moment and try again.',
        502 || 503 || 504 =>
          'The translation service is temporarily unavailable. Please try again.',
        400 || 422 =>
          _errorMessage(response.body) ?? 'The request could not be processed.',
        _ => 'The translation service returned an unexpected error.',
      };
      throw ApiException(message);
    }

    final json = decodeJsonObject(response.body);
    if (json['status'] == 'error') {
      final message = json['message'];
      throw ApiException(
        message is String && message.trim().isNotEmpty
            ? message.trim()
            : 'The translation service could not process this request.',
      );
    }
    return json;
  }

  String? _errorMessage(String body) {
    try {
      final json = decodeJsonObject(body);
      final message = json['message'];
      return message is String && message.trim().isNotEmpty
          ? message.trim()
          : null;
    } on FormatException {
      return null;
    }
  }

  Uri _endpoint(String path) {
    if (_baseUrl.isEmpty) {
      throw const ApiException(
        'Set API_BASE_URL when launching the app, for example --dart-define=API_BASE_URL=https://your-service.onrender.com.',
      );
    }
    final base = Uri.tryParse(_baseUrl);
    if (base == null ||
        !base.hasAuthority ||
        (base.scheme != 'https' && base.scheme != 'http')) {
      throw const ApiException(
        'API_BASE_URL must be an absolute HTTP or HTTPS URL.',
      );
    }
    return base.resolve(path);
  }

  Future<String> _deviceId() {
    return _deviceIdFuture ??= _loadDeviceId();
  }

  Future<String> _loadDeviceId() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final existing = preferences.getString(_deviceIdKey);
      if (existing != null && existing.isNotEmpty) {
        return existing;
      }
      const uuid = Uuid();
      final generated = uuid.v4().replaceAll('-', '');
      final saved = await preferences.setString(_deviceIdKey, generated);
      if (!saved) {
        throw const ApiException(
          'Could not initialize this device. Please restart the app.',
        );
      }
      return generated;
    } on ApiException {
      rethrow;
    } catch (_) {
      throw const ApiException(
        'Could not initialize this device. Please restart the app.',
      );
    }
  }

  void close() => _client.close();
}
