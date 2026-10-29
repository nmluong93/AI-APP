import 'dart:io';

import 'package:flutter/foundation.dart';

import 'android_downloader.dart';
import 'desktop_downloader.dart';
import 'download_job.dart';

/// The download queue: video (MP4) or audio (MP3) downloads of YouTube
/// videos with yt-dlp, one at a time.
///
/// Adapted from the YT Downloader apps in this repo (YTDownloaderAndroid/
/// and YTDownloader/). The code is copied, not shared, so the apps don't
/// depend on each other.
abstract class Downloader extends ChangeNotifier {
  static Downloader? _instance;

  /// Android runs yt-dlp inside the app (youtubedl-android, see
  /// android/.../downloads/); macOS runs the yt-dlp and ffmpeg installed
  /// with Homebrew.
  static Downloader get instance => _instance ??= Platform.isAndroid
      ? AndroidDownloader()
      : DesktopDownloader();

  @visibleForTesting
  static set instance(Downloader d) => _instance = d;

  /// Newest last.
  List<DownloadJob> get jobs;

  /// A line about yt-dlp: its version, or why it can't run.
  Future<String> engineStatus();

  /// Updates yt-dlp, returning what happened.
  Future<String> updateEngine();

  Future<int> enqueue(DownloadRequest request);
  Future<void> cancel(int id);
  Future<void> retry(int id);
  Future<void> remove(int id);
  Future<void> clearFinished();

  /// Opens a finished download (Android), or shows it in Finder (macOS).
  /// Returns false if nothing could open it.
  Future<bool> open(DownloadJob job);

  /// Where downloads are saved, for showing to people.
  String get saveLocation;

  int get activeCount => jobs.where((j) => !j.isFinished).length;
}
