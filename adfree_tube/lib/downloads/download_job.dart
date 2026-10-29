import 'package:flutter/foundation.dart';

enum DownloadKind { video, audio }

enum DownloadState { queued, downloading, processing, done, failed, cancelled }

/// What to download.
@immutable
class DownloadRequest {
  final String url;
  final String title;
  final DownloadKind kind;

  /// Highest video height (e.g. 1080), or null for the best available.
  final int? maxHeight;

  /// MP3 bitrate in kbit/s.
  final int audioKbps;

  const DownloadRequest({
    required this.url,
    required this.title,
    required this.kind,
    this.maxHeight,
    this.audioKbps = 192,
  });

  Map<String, Object?> toMap() => {
    'url': url,
    'title': title,
    'kind': kind.name,
    'maxHeight': maxHeight,
    'audioKbps': audioKbps,
  };
}

/// One entry in the download queue.
@immutable
class DownloadJob {
  final int id;
  final String url;
  final String title;
  final DownloadKind kind;
  final DownloadState state;

  /// 0 to 1 for the current step.
  final double progress;

  /// Speed and time left while downloading, the step while processing, the
  /// saved location when done, or the error when failed.
  final String detail;

  /// Android: the saved file's content:// address, for opening it.
  final String? savedUri;
  final String? savedMime;

  /// Where the file was saved, for showing to people.
  final String? savedPath;

  const DownloadJob({
    required this.id,
    required this.url,
    required this.title,
    required this.kind,
    this.state = DownloadState.queued,
    this.progress = 0,
    this.detail = '',
    this.savedUri,
    this.savedMime,
    this.savedPath,
  });

  bool get isFinished =>
      state == DownloadState.done ||
      state == DownloadState.failed ||
      state == DownloadState.cancelled;

  bool get isActive =>
      state == DownloadState.downloading || state == DownloadState.processing;

  DownloadJob copyWith({
    DownloadState? state,
    double? progress,
    String? detail,
    String? savedPath,
  }) => DownloadJob(
    id: id,
    url: url,
    title: title,
    kind: kind,
    state: state ?? this.state,
    progress: progress ?? this.progress,
    detail: detail ?? this.detail,
    savedUri: savedUri,
    savedMime: savedMime,
    savedPath: savedPath ?? this.savedPath,
  );

  @override
  String toString() => 'DownloadJob($id, ${state.name}, $progress, $detail)';

  /// Reads a job as sent by the Android side (Models.kt, `toJson`).
  factory DownloadJob.fromJson(Map<String, dynamic> j) => DownloadJob(
    id: (j['id'] as num).toInt(),
    url: j['url'] as String? ?? '',
    title: j['title'] as String? ?? '',
    kind: j['kind'] == 'audio' ? DownloadKind.audio : DownloadKind.video,
    state: DownloadState.values.firstWhere(
      (s) => s.name == j['state'],
      orElse: () => DownloadState.queued,
    ),
    progress: (j['progress'] as num?)?.toDouble() ?? 0,
    detail: j['detail'] as String? ?? '',
    savedUri: j['savedUri'] as String?,
    savedMime: j['savedMime'] as String?,
    savedPath: j['savedPath'] as String?,
  );
}
