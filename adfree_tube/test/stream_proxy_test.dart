import 'dart:io';
import 'dart:math';

import 'package:adfree_tube/stream_proxy.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake "YouTube" that serves [data] honouring the `range` query parameter,
/// like googlevideo.com does.
Future<HttpServer> _fakeUpstream(List<int> data, List<String> ranges) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) {
    final range = req.uri.queryParameters['range']!;
    ranges.add(range);
    final parts = range.split('-').map(int.parse).toList();
    req.response
      ..statusCode = 200
      ..add(data.sublist(parts[0], min(parts[1] + 1, data.length)))
      ..close();
  });
  return server;
}

void main() {
  final data = List<int>.generate(25 * 1024 * 1024, (i) => i % 251);

  test('serves byte ranges, fetching upstream in chunks of at most 10 MB',
      () async {
    final ranges = <String>[];
    final upstream = await _fakeUpstream(data, ranges);
    final remote =
        'http://127.0.0.1:${upstream.port}/videoplayback?c=ANDROID_VR&itag=1&clen=${data.length}';
    final local = await StreamProxy.instance.register(remote);

    final client = HttpClient();
    final req = await client.getUrl(Uri.parse(local));
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=1000-');
    final res = await req.close();
    final body = await res.fold<List<int>>([], (a, b) => a..addAll(b));

    expect(res.statusCode, 206);
    expect(res.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 1000-${data.length - 1}/${data.length}');
    expect(body.length, data.length - 1000);
    expect(body.take(5), data.skip(1000).take(5));
    expect(body.last, data.last);
    expect(ranges, [
      '1000-10486759',
      '10486760-20972519',
      '20972520-26214399',
    ]);
    client.close();
    await upstream.close(force: true);
  });

  test('reports upstream HTTP errors', () async {
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((req) {
      req.response
        ..statusCode = 403
        ..close();
    });
    final local = await StreamProxy.instance.register(
        'http://127.0.0.1:${upstream.port}/videoplayback?c=ANDROID&itag=134&clen=100');
    final client = HttpClient();
    final res = await (await client.getUrl(Uri.parse(local))).close();
    await res.drain<void>();
    expect(StreamProxy.instance.lastError,
        'HTTP 403 from YouTube (ANDROID, itag 134)');
    client.close();
    await upstream.close(force: true);
  });
}
