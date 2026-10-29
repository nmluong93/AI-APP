import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'download_job.dart';
import 'downloader.dart';

/// Talks to the download queue in the Android app
/// (android/.../downloads/DownloadsChannel.kt), which runs yt-dlp and
/// ffmpeg inside the app and saves to Movies/ and Music/ "AdFree Tube".
class AndroidDownloader extends Downloader {
  static const _methods = MethodChannel('adfree_tube/downloads');
  static const _events = EventChannel('adfree_tube/downloads/jobs');

  List<DownloadJob> _jobs = const [];
  StreamSubscription<dynamic>? _sub;

  AndroidDownloader() {
    _sub = _events.receiveBroadcastStream().listen((event) {
      final list = jsonDecode(event as String) as List<dynamic>;
      _jobs = [
        for (final j in list) DownloadJob.fromJson(j as Map<String, dynamic>),
      ];
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  List<DownloadJob> get jobs => _jobs;

  @override
  String get saveLocation => 'Movies/AdFree Tube and Music/AdFree Tube';

  @override
  Future<String> engineStatus() async =>
      await _methods.invokeMethod<String>('engineStatus') ?? '';

  @override
  Future<String> updateEngine() async =>
      await _methods.invokeMethod<String>('updateEngine') ?? '';

  @override
  Future<int> enqueue(DownloadRequest request) async =>
      await _methods.invokeMethod<int>('enqueue', request.toMap()) ?? -1;

  @override
  Future<void> cancel(int id) => _methods.invokeMethod('cancel', id);

  @override
  Future<void> retry(int id) => _methods.invokeMethod('retry', id);

  @override
  Future<void> remove(int id) => _methods.invokeMethod('remove', id);

  @override
  Future<void> clearFinished() => _methods.invokeMethod('clearFinished');

  @override
  Future<bool> open(DownloadJob job) async {
    if (job.savedUri == null) return false;
    return await _methods.invokeMethod<bool>('open', {
          'uri': job.savedUri,
          'mime': job.savedMime,
        }) ??
        false;
  }
}
