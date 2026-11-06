import 'package:flutter/foundation.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'search_input.dart';

/// Search, video details, related videos and comments, via youtube_explode_dart.
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

  /// YouTube's search filter for videos only, newest first: protobuf
  /// {1: 2 (sort by upload date), 2: {2: 1 (type video)}}, base64.
  static const newestVideos = SearchFilter('CAISAhAB');

  /// The newest videos about [topic], for the Home feed.
  Future<VideoSearchList> latest(String topic) =>
      _yt.search.search(topic, filter: newestVideos);

  Future<Video> getVideo(String id) => _yt.videos.get(id);

  Future<List<Video>> related(Video video) async {
    try {
      final list = await _yt.videos.getRelatedVideos(video);
      return list?.toList() ?? const [];
    } catch (_) {
      return const [];
    }
  }

  /// The first page of [video]'s comments, or null if it has none or they
  /// are turned off. Use [CommentsList.nextPage] for more.
  Future<CommentsList?> comments(Video video) =>
      // Marked deprecated upstream because YouTube's new comment format
      // broke it; our patched copy reads that format (bug 20).
      // ignore: deprecated_member_use
      _yt.videos.commentsClient.getComments(video);

  void close() => _yt.close();
}
