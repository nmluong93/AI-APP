import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'settings.dart';
import 'youtube_service.dart';

/// One video in the Home feed. Kept small and plain so the feed can be
/// saved and shown again on the next start before anything loads.
class FeedVideo {
  final String id;
  final String title;
  final String author;

  /// What YouTube shows, like "3 hours ago".
  final String? published;

  /// Roughly when it was uploaded, worked out from [published] when the
  /// feed was loaded. Null for live streams.
  final DateTime? uploaded;
  final Duration? duration;
  final int views;
  final bool isLive;

  /// The user's topics this video was found for.
  final List<String> topics;

  /// Its place in YouTube's newest-first list for its topic, used to keep
  /// that order when two videos have the same rough upload time.
  final int rank;

  const FeedVideo({
    required this.id,
    required this.title,
    required this.author,
    this.published,
    this.uploaded,
    this.duration,
    this.views = 0,
    this.isLive = false,
    this.topics = const [],
    this.rank = 0,
  });

  factory FeedVideo.fromVideo(Video v, String topic, int rank) => FeedVideo(
    id: v.id.value,
    title: v.title,
    author: v.author,
    published: v.uploadDateRaw,
    uploaded: _toMinute(v.uploadDate),
    duration: v.duration,
    views: v.engagement.viewCount,
    isLive: v.isLive,
    topics: [topic],
    rank: rank,
  );

  /// The upload time is worked out from "2 days ago" as each result is
  /// read, so two videos of the same age differ by microseconds. Cut that
  /// off so they count as the same age and keep YouTube's order.
  static DateTime? _toMinute(DateTime? t) => t == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(
          t.millisecondsSinceEpoch ~/ 60000 * 60000,
        );

  String get thumbnail => 'https://i.ytimg.com/vi/$id/mqdefault.jpg';

  FeedVideo _withTopics(List<String> t) => FeedVideo(
    id: id,
    title: title,
    author: author,
    published: published,
    uploaded: uploaded,
    duration: duration,
    views: views,
    isLive: isLive,
    topics: t,
    rank: rank,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'author': author,
    'published': published,
    'uploaded': uploaded?.millisecondsSinceEpoch,
    'seconds': duration?.inSeconds,
    'views': views,
    'live': isLive,
    'topics': topics,
    'rank': rank,
  };

  factory FeedVideo.fromJson(Map<String, dynamic> j) => FeedVideo(
    id: j['id'] as String,
    title: j['title'] as String,
    author: j['author'] as String,
    published: j['published'] as String?,
    uploaded: j['uploaded'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(j['uploaded'] as int),
    duration: j['seconds'] == null ? null : Duration(seconds: j['seconds'] as int),
    views: j['views'] as int? ?? 0,
    isLive: j['live'] as bool? ?? false,
    topics: (j['topics'] as List?)?.cast<String>() ?? const [],
    rank: j['rank'] as int? ?? 0,
  );
}

/// The newest videos for the topics in [AppSettings.topics], newest first.
///
/// Starts with the feed saved last time, so Home has something to show at
/// once. [load] then searches each topic in the background and swaps in
/// each topic's fresh videos as they arrive, so the screen never waits on
/// the slowest search.
class TopicFeed extends ChangeNotifier {
  TopicFeed(this._settings) {
    try {
      _videos = _settings.feedCache
          .map((s) => FeedVideo.fromJson(jsonDecode(s) as Map<String, dynamic>))
          .toList();
    } catch (_) {
      // A cache from an older version that doesn't parse: start empty.
      _videos = [];
    }
  }

  final AppSettings _settings;

  /// At most this many topic searches at once, so parsing YouTube's pages
  /// is spread out and doesn't make scrolling stutter.
  static const parallelSearches = 3;

  List<FeedVideo> _videos = [];
  List<FeedVideo> get videos => _videos;

  bool _loading = false;
  bool get loading => _loading;

  /// Set when the last load found nothing because every search failed.
  String? _error;
  String? get error => _error;

  /// Topics whose search failed in the last load; their videos, if any,
  /// are the ones saved from before.
  List<String> _failedTopics = const [];
  List<String> get failedTopics => _failedTopics;

  DateTime? _loadedAt;

  /// When the last load finished with at least one topic loaded.
  DateTime? get loadedAt => _loadedAt;

  int _generation = 0;
  bool _disposed = false;

  /// The feed's videos found for [topic], or all of them when it's null.
  List<FeedVideo> videosFor(String? topic) => topic == null
      ? _videos
      : _videos.where((v) => v.topics.contains(topic)).toList();

  /// Loads the newest videos for every topic. Calling it again while it
  /// runs (say, after the topics change) supersedes the earlier load.
  Future<void> load() async {
    final generation = ++_generation;
    final topics = _settings.topics;
    if (topics.isEmpty) {
      _videos = [];
      _settings.feedCache = const [];
      _loading = false;
      _error = null;
      _failedTopics = const [];
      _notify();
      return;
    }
    final old = _videos;
    final fresh = <String, List<Video>>{};
    final failures = <String>[];
    Object? lastError;
    _loading = true;
    _error = null;
    // Drop saved videos for topics that are gone straight away.
    _videos = _merge(topics, fresh, old);
    _notify();

    var next = 0;
    Future<void> worker() async {
      while (next < topics.length) {
        final topic = topics[next++];
        try {
          final page = await YoutubeService.instance.latest(topic);
          if (generation != _generation || _disposed) return;
          fresh[topic] = page.toList();
          _videos = _merge(topics, fresh, old);
          _notify();
        } catch (e) {
          if (generation != _generation || _disposed) return;
          failures.add(topic);
          lastError = e;
        }
      }
    }

    await Future.wait([
      for (var i = 0; i < min(parallelSearches, topics.length); i++) worker(),
    ]);
    if (generation != _generation || _disposed) return;

    _loading = false;
    _failedTopics = [
      for (final t in topics)
        if (failures.contains(t)) t,
    ];
    if (fresh.isEmpty) {
      _error = '$lastError';
    } else {
      _loadedAt = DateTime.now();
      _settings.feedCache = _videos.map((v) => jsonEncode(v.toJson())).toList();
    }
    _notify();
  }

  /// Fresh videos for the topics in [fresh], plus the [old] ones for the
  /// other topics still in [topics], each video once, newest first.
  static List<FeedVideo> _merge(
    List<String> topics,
    Map<String, List<Video>> fresh,
    List<FeedVideo> old,
  ) {
    final byId = <String, FeedVideo>{};
    void add(FeedVideo v) {
      final seen = byId[v.id];
      byId[v.id] = seen == null
          ? v
          : seen._withTopics({...seen.topics, ...v.topics}.toList());
    }

    for (final t in topics) {
      final list = fresh[t];
      if (list != null) {
        for (var i = 0; i < list.length; i++) {
          add(FeedVideo.fromVideo(list[i], t, i));
        }
      } else {
        for (final v in old) {
          if (v.topics.contains(t)) add(v._withTopics([t]));
        }
      }
    }
    final order = {for (var i = 0; i < topics.length; i++) topics[i]: i};
    int topicOrder(FeedVideo v) =>
        v.topics.map((t) => order[t] ?? topics.length).reduce(min);
    return byId.values.toList()..sort((a, b) {
      // Newest first, undated (live now) last; within the same rough time
      // keep YouTube's order, taking the topics in turn.
      final au = a.uploaded, bu = b.uploaded;
      if (au != null && bu != null && au != bu) return bu.compareTo(au);
      if ((au == null) != (bu == null)) return au == null ? 1 : -1;
      if (a.rank != b.rank) return a.rank.compareTo(b.rank);
      return topicOrder(a).compareTo(topicOrder(b));
    });
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
