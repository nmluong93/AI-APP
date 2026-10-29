import 'package:flutter/foundation.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'search_input.dart';

/// Search, video details and related videos, via youtube_explode_dart.
/// Playback itself goes through YouTube's own player (see yt_web_player.dart).
class YoutubeService {
  YoutubeService._(this._yt);

  static YoutubeService instance = YoutubeService._(YoutubeExplode());

  /// Lets tests answer YouTube's requests themselves.
  @visibleForTesting
  static void useClient(YoutubeExplode yt) => instance = YoutubeService._(yt);

  final YoutubeExplode _yt;

  /// Returns a video id if [input] is a YouTube URL or an 11-char id.
  static String? parseVideoId(String input) => switch (parseSearchInput(input)) {
    VideoInput(:final id) => id,
    _ => null,
  };

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
