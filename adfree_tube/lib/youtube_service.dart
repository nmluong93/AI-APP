import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// Search, video details and related videos, via youtube_explode_dart.
/// Playback itself goes through YouTube's own player (see yt_web_player.dart).
class YoutubeService {
  YoutubeService._();
  static final instance = YoutubeService._();

  final _yt = YoutubeExplode();

  /// Returns a video id if [input] is a YouTube URL or an 11-char id.
  static String? parseVideoId(String input) {
    final text = input.trim();
    if (text.isEmpty) return null;
    return VideoId.parseVideoId(text);
  }

  Future<VideoSearchList> search(String query) => _yt.search.search(query);

  Future<Video> getVideo(String id) => _yt.videos.get(id);

  Future<List<Video>> related(Video video) async {
    try {
      final list = await _yt.videos.getRelatedVideos(video);
      return list?.toList() ?? const [];
    } catch (_) {
      return const [];
    }
  }

  void close() => _yt.close();
}
