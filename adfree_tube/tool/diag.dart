// Diagnostic: which clients/headers give stream URLs that actually download.
import 'dart:io';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

const uaAndroid = 'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip';
const uaVr = 'com.google.android.apps.youtube.vr.oculus/1.56.21 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip';
const uaSafari = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)';

Future<String> probe(String url, String? ua, {String range = 'bytes=0-'}) async {
  final c = HttpClient();
  try {
    final req = await c.getUrl(Uri.parse(url));
    if (ua != null) req.headers.set('User-Agent', ua);
    req.headers.set('Range', range);
    final res = await req.close();
    var n = 0;
    final sw = Stopwatch()..start();
    await for (final chunk in res) {
      n += chunk.length;
      if (n > 3 * 1024 * 1024 || sw.elapsed.inSeconds > 8) break;
    }
    return '${res.statusCode} ${(n / 1024).round()}KB in ${sw.elapsedMilliseconds}ms';
  } catch (e) {
    return 'ERR $e';
  } finally {
    c.close(force: true);
  }
}

Future<void> main(List<String> args) async {
  final id = args.isNotEmpty ? args[0] : 'aqz-KE-bpKQ';
  final yt = YoutubeExplode();
  final clients = <String, List<YoutubeApiClient>?>{
    'default': null,
    'androidVr': [YoutubeApiClient.androidVr],
    'androidSdkless': [YoutubeApiClient.androidSdkless],
    'safari': [YoutubeApiClient.safari],
    'tv': [YoutubeApiClient.tv],
  };
  final urlsFile = File('urls.txt').openWrite();
  for (final e in clients.entries) {
    try {
      final m = await yt.videos.streams.getManifest(id, ytClients: e.value);
      print('== ${e.key}: muxed ${m.muxed.length} video ${m.videoOnly.length} audio ${m.audioOnly.length} hls ${m.hls.length}');
      final tests = <String, String>{};
      final vids = m.videoOnly.where((v) => v.container == StreamContainer.mp4 && v.videoResolution.height <= 720).toList()
        ..sort((a, b) => b.videoResolution.height.compareTo(a.videoResolution.height));
      if (vids.isNotEmpty) tests['video${vids.first.videoResolution.height}'] = vids.first.url.toString();
      if (m.audioOnly.isNotEmpty) tests['audio'] = m.audioOnly.withHighestBitrate().url.toString();
      if (m.muxed.isNotEmpty) tests['muxed'] = m.muxed.first.url.toString();
      if (m.hls.isNotEmpty) tests['hls'] = m.hls.first.url.toString();
      for (final t in tests.entries) {
        urlsFile.writeln('${e.key} ${t.key} ${t.value}');
        for (final ua in {'none': null, 'mpv': 'libmpv', 'android': uaAndroid, 'vr': uaVr, 'safari': uaSafari}.entries) {
          print('  ${t.key} ua=${ua.key}: ${await probe(t.value, ua.value)}');
        }
        print('  ${t.key} ua=mpv range=10MB-: ${await probe(t.value, 'libmpv', range: 'bytes=10000000-')}');
      }
    } catch (err) {
      print('== ${e.key}: FAILED $err');
    }
  }
  await urlsFile.close();
  yt.close();
}
