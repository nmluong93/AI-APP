import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// A tiny HTTP server on 127.0.0.1 that the player reads from instead of
/// opening YouTube's stream URLs directly.
///
/// YouTube stalls or rejects a stream when it is requested in one big piece,
/// or with headers it doesn't expect. Here every request from the player is
/// forwarded to YouTube in chunks of at most ~10 MB, with the same headers
/// and range style that youtube_explode_dart uses for its own (working)
/// downloads. It also records YouTube's HTTP errors so the app can show them.
class StreamProxy {
  StreamProxy._();
  static final instance = StreamProxy._();

  static const _chunkSize = 10 * 1024 * 1024;

  HttpServer? _server;
  final _client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  final _streams = <String, Uri>{};
  final _lengths = <String, int>{};
  var _nextId = 0;

  /// The last upstream error, e.g. "HTTP 403 from YouTube (ANDROID, itag 134)".
  String? lastError;

  /// Returns a local URL that serves [remote].
  Future<String> register(String remote) async {
    final server = _server ??=
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
          ..listen(_handle);
    final id = '${_nextId++}';
    _streams[id] = Uri.parse(remote);
    // Keep the map small: only the last few streams can still be playing.
    if (_streams.length > 8) {
      final oldest = _streams.keys.first;
      _streams.remove(oldest);
      _lengths.remove(oldest);
    }
    return 'http://127.0.0.1:${server.port}/s/$id';
  }

  static bool canProxy(String url) {
    final uri = Uri.tryParse(url);
    return uri != null &&
        uri.host.endsWith('googlevideo.com') &&
        uri.path.contains('videoplayback');
  }

  String _describe(Uri url) =>
      '${url.queryParameters['c'] ?? '?'}, itag ${url.queryParameters['itag'] ?? '?'}';

  Future<int?> _length(String id, Uri url) async {
    final known = _lengths[id] ?? int.tryParse(url.queryParameters['clen'] ?? '');
    if (known != null) return _lengths[id] = known;
    try {
      final req = await _client.headUrl(url);
      _applyHeaders(req);
      final res = await req.close();
      await res.drain<void>();
      if (res.statusCode >= 400) {
        lastError = 'HTTP ${res.statusCode} from YouTube (${_describe(url)})';
        return null;
      }
      if (res.contentLength > 0) return _lengths[id] = res.contentLength;
    } catch (e) {
      lastError = '$e';
    }
    return null;
  }

  void _applyHeaders(HttpClientRequest req) {
    YoutubeHttpClient.defaultHeaders.forEach(req.headers.set);
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final segments = request.uri.pathSegments;
      final id = segments.length == 2 ? segments[1] : null;
      final url = id == null ? null : _streams[id];
      if (url == null) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      final length = await _length(id!, url);
      if (length == null) {
        response.statusCode = HttpStatus.badGateway;
        await response.close();
        return;
      }

      // Parse "Range: bytes=start-[end]" from the player.
      var start = 0;
      var end = length - 1;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      final match = range == null
          ? null
          : RegExp(r'bytes=(\d*)-(\d*)').firstMatch(range);
      if (match != null) {
        if (match[1]!.isNotEmpty) start = int.parse(match[1]!);
        if (match[2]!.isNotEmpty) end = min(int.parse(match[2]!), length - 1);
      }
      if (start >= length) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
        await response.close();
        return;
      }

      // Open the first chunk before answering, so a YouTube error turns
      // into an error status for the player instead of a broken body.
      var pos = start;
      var upstream = await _open(url, pos, min(pos + _chunkSize - 1, end));
      if (upstream == null) {
        response.statusCode = HttpStatus.badGateway;
        await response.close();
        return;
      }

      response.statusCode =
          match != null ? HttpStatus.partialContent : HttpStatus.ok;
      response.headers
        ..contentType = ContentType.parse(
            url.queryParameters['mime'] ?? 'application/octet-stream')
        ..contentLength = end - start + 1
        ..set(HttpHeaders.acceptRangesHeader, 'bytes');
      if (match != null) {
        response.headers
            .set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$length');
      }
      if (request.method == 'HEAD') {
        await upstream.drain<void>();
        await response.close();
        return;
      }

      while (upstream != null) {
        await response.addStream(upstream.map((data) {
          pos += data.length;
          return data;
        }));
        if (pos > end) break;
        upstream = await _open(url, pos, min(pos + _chunkSize - 1, end));
      }
      await response.close();
    } catch (e) {
      // The player closing the connection (seeking, stopping) lands here.
      debugPrint('StreamProxy: $e');
      try {
        await response.close();
      } catch (_) {}
    }
  }

  /// Requests bytes [from]..[to] of [url] from YouTube, retrying network
  /// errors. Returns null (and sets [lastError]) if YouTube refuses.
  Future<HttpClientResponse?> _open(Uri url, int from, int to) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        // Same scheme as youtube_explode_dart: ANDROID streams take a Range
        // header, the others a `range` query parameter.
        final isAndroid = url.queryParameters['c'] == 'ANDROID';
        final target = isAndroid
            ? url
            : url.replace(queryParameters: {
                ...url.queryParameters,
                'range': '$from-$to',
              });
        final req = await _client.getUrl(target);
        _applyHeaders(req);
        if (isAndroid) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-$to');
        final res = await req.close();
        if (res.statusCode < 400) return res;
        await res.drain<void>();
        lastError = 'HTTP ${res.statusCode} from YouTube (${_describe(url)})';
        debugPrint('StreamProxy: $lastError');
        if (res.statusCode < 500) return null;
      } on SocketException catch (e) {
        lastError = 'Network error: ${e.message}';
      } on HttpException catch (e) {
        lastError = 'Network error: ${e.message}';
      }
    }
    return null;
  }
}
