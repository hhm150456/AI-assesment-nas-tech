const maxAudioBytes = 20 * 1024 * 1024;
const minAudioBytes = 1024;
const maxRecordingDuration = Duration(minutes: 2);

const supportedAudioExtensions = <String>{
  'mp3',
  'mp4',
  'mpeg',
  'mpga',
  'm4a',
  'wav',
  'webm',
  'ogg',
  'flac',
};

const supportedAudioContentTypes = <String>{
  'application/ogg',
  'audio/flac',
  'audio/mp3',
  'audio/mp4',
  'audio/mpeg',
  'audio/mpga',
  'audio/ogg',
  'audio/wav',
  'audio/webm',
  'audio/x-flac',
  'audio/x-m4a',
  'audio/x-wav',
  'video/mp4',
};

const _contentTypesByExtension = <String, Set<String>>{
  'flac': {'audio/flac', 'audio/x-flac'},
  'm4a': {'audio/mp4', 'audio/x-m4a'},
  'mp3': {'audio/mp3', 'audio/mpeg'},
  'mp4': {'audio/mp4', 'video/mp4'},
  'mpeg': {'audio/mpeg', 'audio/mp3'},
  'mpga': {'audio/mpga', 'audio/mpeg', 'audio/mp3'},
  'ogg': {'audio/ogg', 'application/ogg'},
  'wav': {'audio/wav', 'audio/x-wav'},
  'webm': {'audio/webm'},
};

String? validateAudioFile({
  required String fileName,
  required int sizeBytes,
  String? contentType,
}) {
  final normalizedName = fileName.replaceAll('\\', '/').split('/').last;
  final dot = normalizedName.lastIndexOf('.');
  final extension = dot < 0
      ? ''
      : normalizedName.substring(dot + 1).toLowerCase();
  if (!supportedAudioExtensions.contains(extension)) {
    return 'Choose an MP3, MP4, M4A, WAV, WEBM, OGG, MPEG, MPGA, or FLAC audio file.';
  }
  if (sizeBytes < minAudioBytes) {
    return 'The audio file is empty or too short.';
  }
  if (sizeBytes > maxAudioBytes) {
    return 'The audio file must be 20 MB or smaller.';
  }
  final normalizedType = contentType?.split(';').first.trim().toLowerCase();
  if (normalizedType != null &&
      normalizedType.isNotEmpty &&
      !(_contentTypesByExtension[extension]?.contains(normalizedType) ?? false)) {
    return 'Choose a supported audio file.';
  }
  return null;
}

String audioMimeTypeForName(String fileName) {
  final normalizedName = fileName.replaceAll('\\', '/').split('/').last;
  final dot = normalizedName.lastIndexOf('.');
  final extension = dot < 0
      ? ''
      : normalizedName.substring(dot + 1).toLowerCase();
  return switch (extension) {
    'mp3' || 'mpeg' || 'mpga' => 'audio/mpeg',
    'mp4' => 'audio/mp4',
    'm4a' => 'audio/mp4',
    'wav' => 'audio/wav',
    'webm' => 'audio/webm',
    'ogg' => 'audio/ogg',
    'flac' => 'audio/flac',
    _ => 'application/octet-stream',
  };
}
