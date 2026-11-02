import 'dart:typed_data';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_translate/core/audio_file_validator.dart';
import 'package:voice_translate/core/languages.dart';
import 'package:voice_translate/core/models.dart';

void main() {
  group('supportedLanguages', () {
    test('contains all 57 languages in the specified order', () {
      expect(supportedLanguages, hasLength(57));
      expect(supportedLanguages.first, 'Afrikaans');
      expect(supportedLanguages[13], 'English');
      expect(supportedLanguages.last, 'Welsh');
      expect(supportedLanguages.toSet(), hasLength(57));
    });
  });

  group('validateAudioFile', () {
    test('accepts a supported file under the size limit', () {
      expect(
        validateAudioFile(
          fileName: 'speech.m4a',
          sizeBytes: 2048,
          contentType: 'audio/mp4',
        ),
        isNull,
      );
    });

    test(
      'rejects unsupported extensions, empty files, and oversized files',
      () {
        expect(
          validateAudioFile(fileName: 'notes.txt', sizeBytes: 2048),
          isNotNull,
        );
        expect(
          validateAudioFile(fileName: 'empty.wav', sizeBytes: 20),
          contains('empty'),
        );
        expect(
          validateAudioFile(
            fileName: 'large.mp3',
            sizeBytes: maxAudioBytes + 1,
          ),
          contains('20 MB'),
        );
      },
    );

    test('rejects an unsupported content type for an allowed extension', () {
      expect(
        validateAudioFile(
          fileName: 'speech.mp3',
          sizeBytes: 2048,
          contentType: 'text/plain',
        ),
        isNotNull,
      );
    });
  });

  test('parses translation metadata and raw audio from a multipart response', () {
    const boundary = 'translation-boundary';
    final metadata =
        '''
{"status_code":200,"translation":"Bonjour","transcript":"Hello","source_language":"English","target_language":"French"}
'''
            .trim();
    final prefix =
        '--$boundary\r\n'
        'Content-Type: application/json; charset=utf-8\r\n'
        'Content-Disposition: form-data; name="metadata"\r\n\r\n'
        '$metadata\r\n'
        '--$boundary\r\n'
        'Content-Type: audio/mpeg\r\n'
        'Content-Disposition: attachment; name="audio"; filename="translation.mp3"\r\n\r\n';
    final body = Uint8List.fromList([
      ...prefix.codeUnits,
      1,
      2,
      3,
      ...'\r\n--$boundary--\r\n'.codeUnits,
    ]);

    final result = TranslationResult.fromMultipartResponse(
      body: body,
      contentType: 'multipart/mixed; boundary="$boundary"',
    );

    expect(result.statusCode, 200);
    expect(result.translation, 'Bonjour');
    expect(result.transcript, 'Hello');
    expect(result.sourceLanguage, 'English');
    expect(result.targetLanguage, 'French');
    expect(result.audioBytes, Uint8List.fromList([1, 2, 3]));
    expect(result.audioMime, 'audio/mpeg');
  });

  test('parses a Dify conversation turn after the API prepares its audio', () {
    final result = ConversationTurnResult.fromJson({
      'status': 'success',
      'translation': '这是一个英语录音。',
      'transcript': 'This is a recording in English.',
      'speaker': 'A',
      'source_lang': 'English',
      'target_lang': 'Chinese',
      'seq': 0,
      'audio_base64': base64Encode([1, 2, 3]),
      'audio_mime': 'audio/mpeg',
    });

    expect(result.sequence, '0');
    expect(result.translation, '这是一个英语录音。');
    expect(result.transcript, 'This is a recording in English.');
    expect(result.speaker, 'A');
    expect(result.sourceLanguage, 'English');
    expect(result.targetLanguage, 'Chinese');
    expect(result.audioBytes, Uint8List.fromList([1, 2, 3]));
    expect(result.audioMime, 'audio/mpeg');
  });

  test('parses a normalized Dify conversation start', () {
    final result = ConversationSession.fromJson({
      'status': 'started',
      'session_id': '09tJVYMfCKFHuSAtwTxc',
      'lang_a': 'English',
      'lang_b': 'Bosnian',
    });

    expect(result.sessionId, '09tJVYMfCKFHuSAtwTxc');
    expect(result.languageA, 'English');
    expect(result.languageB, 'Bosnian');
  });

  test('parses a normalized Dify conversation summary', () {
    final result = ConversationSummary.fromJson({
      'status': 'success',
      'summary_a': 'Participant A mentioned that the recording is in English.',
      'summary_b': 'المشارك أ ذكر أن التسجيل باللغة الإنجليزية.',
      'lang_a': 'English',
      'lang_b': 'Arabic',
      'closed': 'yes',
    });

    expect(result.summaryA, contains('recording is in English'));
    expect(result.summaryB, contains('التسجيل باللغة الإنجليزية'));
    expect(result.languageA, 'English');
    expect(result.languageB, 'Arabic');
    expect(result.closed, isTrue);
  });
}
