import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// One way to play a video: a video (or muxed/HLS) URL plus an optional
/// separate audio URL that gets attached as an external audio track.
class PlaybackSource {
  final String label;
  final int height;
  final String videoUrl;
  final String? audioUrl;
  final bool audioOnly;

  const PlaybackSource({
    required this.label,
    required this.height,
    required this.videoUrl,
    this.audioUrl,
    this.audioOnly = false,
  });

  /// HTTP headers the player must send when fetching these URLs.
  Map<String, String> get headers => YoutubeService.headersFor(videoUrl);
}

/// Thin wrapper over youtube_explode_dart. Talks to YouTube directly, so no
/// ad requests are ever made: we only fetch metadata and the raw media streams.
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

  // YouTube rejects (HTTP 403) or stalls stream requests whose User-Agent
  // doesn't match the client that asked for them. The client is named in the
  // URL's `c` parameter, so look up the matching User-Agent from there.
  static final Map<String, String> _userAgents = () {
    final map = <String, String>{
      // androidVr doesn't declare one in youtube_explode; this is yt-dlp's.
      'ANDROID_VR':
          'com.google.android.apps.youtube.vr.oculus/1.56.21 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip',
    };
    for (final client in [
      YoutubeApiClient.ios,
      YoutubeApiClient.androidSdkless,
      YoutubeApiClient.androidMusic,
      YoutubeApiClient.safari,
      YoutubeApiClient.tv,
      YoutubeApiClient.mweb,
    ]) {
      final c = client.payload['context']?['client'] as Map<String, dynamic>?;
      final name = c?['clientName'] as String?;
      final ua = c?['userAgent'] as String?;
      if (name != null && ua != null) map.putIfAbsent(name, () => ua);
    }
    return map;
  }();

  static const _browserUserAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15';

  static Map<String, String> headersFor(String url) {
    final client = Uri.tryParse(url)?.queryParameters['c'] ?? '';
    final ua = _userAgents[client] ?? _browserUserAgent;
    return {
      'User-Agent': ua,
      if (!client.startsWith('ANDROID') && client != 'IOS') ...{
        'Origin': 'https://www.youtube.com',
        'Referer': 'https://www.youtube.com/',
      },
    };
  }

  Future<StreamManifest> _manifest(String id) async {
    // The library default client works most of the time; if YouTube changes
    // something, fall back to other clients before giving up.
    final attempts = <List<YoutubeApiClient>?>[
      null,
      [YoutubeApiClient.androidVr],
      [YoutubeApiClient.tv, YoutubeApiClient.safari],
    ];
    Object? lastError;
    for (final clients in attempts) {
      try {
        final m = await _yt.videos.streams
            .getManifest(id, ytClients: clients)
            .timeout(const Duration(seconds: 20));
        if (m.streams.isNotEmpty) return m;
      } catch (e) {
        lastError = e;
      }
    }
    throw Exception('Could not load streams for this video. $lastError');
  }

  /// Builds the list of qualities to offer, best first.
  Future<List<PlaybackSource>> sources(String id) async {
    final manifest = await _manifest(id);
    final result = <PlaybackSource>[];

    final audios = manifest.audioOnly.toList()
      ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
    final bestAudio = audios.isEmpty
        ? null
        : audios.firstWhere((a) => a.container == StreamContainer.mp4,
            orElse: () => audios.first);

    if (bestAudio != null) {
      // One entry per resolution, preferring H.264 (mp4) for wide hardware
      // decoding support, then whatever has the highest bitrate.
      final byHeight = <int, VideoOnlyStreamInfo>{};
      for (final v in manifest.videoOnly) {
        final h = v.videoResolution.height;
        final current = byHeight[h];
        if (current == null || _better(v, current)) byHeight[h] = v;
      }
      final heights = byHeight.keys.toList()..sort((a, b) => b.compareTo(a));
      for (final h in heights) {
        final v = byHeight[h]!;
        result.add(PlaybackSource(
          label: '${h}p${v.framerate.framesPerSecond > 30 ? v.framerate.framesPerSecond.round() : ''}',
          height: h,
          videoUrl: v.url.toString(),
          audioUrl: bestAudio.url.toString(),
        ));
      }
    }

    for (final m in manifest.muxed.sortByVideoQuality()) {
      final h = m.videoResolution.height;
      if (result.any((s) => s.height == h)) continue;
      result.add(PlaybackSource(
        label: '${h}p',
        height: h,
        videoUrl: m.url.toString(),
      ));
    }

    if (manifest.hls.isNotEmpty) {
      final hls = manifest.hls.toList()
        ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
      result.add(PlaybackSource(
        label: 'Auto (HLS)',
        height: 0,
        videoUrl: hls.first.url.toString(),
      ));
    }

    if (bestAudio != null) {
      result.add(PlaybackSource(
        label: 'Audio only',
        height: -1,
        videoUrl: bestAudio.url.toString(),
        audioOnly: true,
      ));
    }

    if (result.isEmpty) throw Exception('No playable streams found.');
    return result;
  }

  static bool _better(VideoOnlyStreamInfo a, VideoOnlyStreamInfo b) {
    final aMp4 = a.container == StreamContainer.mp4;
    final bMp4 = b.container == StreamContainer.mp4;
    if (aMp4 != bMp4) return aMp4;
    return a.bitrate.compareTo(b.bitrate) > 0;
  }

  /// Picks the best source not above [preferredHeight].
  static PlaybackSource pick(List<PlaybackSource> sources, int preferredHeight) {
    final videos = sources.where((s) => s.height > 0).toList();
    if (videos.isEmpty) return sources.first;
    return videos.firstWhere((s) => s.height <= preferredHeight,
        orElse: () => videos.last);
  }

  void close() => _yt.close();
}
