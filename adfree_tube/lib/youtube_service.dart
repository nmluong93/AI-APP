import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'js_solver.dart';

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

  // Stream manifests need YouTube's JavaScript challenges solved, so they use
  // a second instance with the WebView solver. It starts on first use.
  Future<YoutubeExplode>? _streamsYt;

  /// Why the JavaScript solver isn't available, if it isn't.
  String? solverError;

  Future<YoutubeExplode> _streamsClient() => _streamsYt ??= () async {
        final solver = await WebViewEJSSolver.tryInit();
        if (solver == null) {
          solverError = 'JavaScript solver failed to start';
          _streamsYt = null; // try again next time
          return _yt;
        }
        solverError = null;
        return YoutubeExplode(jsSolver: solver);
      }();

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

  /// YouTube clients to ask for streams, in order of preference. If a
  /// client's streams don't play, the player moves on to the next one.
  /// As of Oct 2026, on a real phone: ANDROID and IOS stream URLs return
  /// HTTP 403 (they need a "PO token" only the official apps can make),
  /// ANDROID_VR and TV report many videos as unplayable, and WEB needs the
  /// JavaScript challenge solver.
  static final clientOrder = <List<YoutubeApiClient>?>[
    // Web (Safari) gives HLS playlists that don't need a PO token once the
    // JavaScript challenges are solved. This is what yt-dlp relies on too.
    [YoutubeApiClient.safari],
    [YoutubeApiClient.tv],
    [YoutubeApiClient.androidVr],
    [YoutubeApiClient.ios],
    null, // library default (androidSdkless)
  ];

  /// Why clients were skipped while fetching manifests, for error messages.
  final manifestErrors = <String>[];

  static String clientName(List<YoutubeApiClient>? clients) => clients == null
      ? 'default'
      : clients
          .map((c) => c.payload['context']?['client']?['clientName'] ?? '?')
          .join('+');

  /// Fetches a manifest from the first client at or after [from] that
  /// returns any streams.
  Future<(StreamManifest, int)> _manifest(String id, int from) async {
    final yt = await _streamsClient();
    Object? lastError;
    for (var i = from; i < clientOrder.length; i++) {
      try {
        final m = await yt.videos.streams
            .getManifest(id, ytClients: clientOrder[i])
            .timeout(const Duration(seconds: 20));
        if (m.streams.isNotEmpty) return (m, i);
        manifestErrors.add('${clientName(clientOrder[i])}: no streams');
      } catch (e) {
        lastError = e;
        // Keep the first line and YouTube's stated reason, if any.
        final lines = '$e'.split('\n');
        final why = lines.where((l) => l.startsWith('Reason:')).join(' ');
        final reason = [lines.first, if (why.isNotEmpty) why].join(' ');
        manifestErrors.add('${clientName(clientOrder[i])}: $reason');
      }
    }
    throw Exception('Could not load streams for this video. $lastError');
  }

  /// Builds the list of qualities to offer, best first, using the first
  /// working client at or after index [from] of [clientOrder]. Also returns
  /// the index of the client used.
  Future<(List<PlaybackSource>, int)> sources(String id, {int from = 0}) async {
    final (manifest, client) = await _manifest(id, from);
    final result = <PlaybackSource>[];

    // HLS playlists, one per resolution, each with a matching HLS audio
    // playlist. For the web client these are the only streams that play
    // without a PO token, so they go first and replace the others.
    final hls = _hlsSources(manifest);
    final isWeb = clientOrder[client]
            ?.any((c) => c.payload['context']?['client']?['clientName'] == 'WEB') ??
        false;
    if (isWeb && hls.isNotEmpty) return (hls, client);

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

    if (bestAudio != null) {
      result.add(PlaybackSource(
        label: 'Audio only',
        height: -1,
        videoUrl: bestAudio.url.toString(),
        audioOnly: true,
      ));
    }

    for (final h in hls) {
      if (!result.any((s) => s.height == h.height)) result.add(h);
    }

    if (result.isEmpty) throw Exception('No playable streams found.');
    return (result, client);
  }

  static List<PlaybackSource> _hlsSources(StreamManifest manifest) {
    final audios = manifest.hls.whereType<HlsAudioStreamInfo>().toList()
      ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
    final byHeight = <int, PlaybackSource>{};
    for (final v in manifest.hls.whereType<HlsVideoStreamInfo>()) {
      final h = v.videoResolution.height;
      if (h <= 0 || byHeight.containsKey(h)) continue;
      final audio = audios.where((a) => a.tag == v.audioItag).firstOrNull ??
          audios.firstOrNull;
      if (audio == null) continue;
      byHeight[h] = PlaybackSource(
        label: '${h}p',
        height: h,
        videoUrl: v.url.toString(),
        audioUrl: audio.url.toString(),
      );
    }
    for (final m in manifest.hls.whereType<HlsMuxedStreamInfo>()) {
      final h = m.videoResolution.height;
      if (h <= 0 || byHeight.containsKey(h)) continue;
      byHeight[h] = PlaybackSource(label: '${h}p', height: h, videoUrl: m.url.toString());
    }
    final result = byHeight.values.toList()
      ..sort((a, b) => b.height.compareTo(a.height));
    if (audios.isNotEmpty) {
      result.add(PlaybackSource(
        label: 'Audio only',
        height: -1,
        videoUrl: audios.first.url.toString(),
        audioOnly: true,
      ));
    }
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
