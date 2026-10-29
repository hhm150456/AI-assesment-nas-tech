import 'dart:typed_data';

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

  test('parses a successful translation response and audio payload', () {
    final result = TranslationResult.fromJson({
      'status': 'success',
      'translation': 'Bonjour',
      'transcript': 'Hello',
      'source_language': 'English',
      'target_language': 'French',
      'audio_base64': 'AQID',
      'audio_mime': 'audio/mpeg',
    });

    expect(result.translation, 'Bonjour');
    expect(result.transcript, 'Hello');
    expect(result.sourceLanguage, 'English');
    expect(result.targetLanguage, 'French');
    expect(result.audioBytes, Uint8List.fromList([1, 2, 3]));
    expect(result.audioMime, 'audio/mpeg');
  });
}
