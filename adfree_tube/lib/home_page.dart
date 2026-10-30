import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'downloads/downloads_button.dart';
import 'mini_player.dart';
import 'player_page.dart';
import 'search_input.dart';
import 'settings.dart';
import 'topic_feed.dart';
import 'topics_page.dart';
import 'widgets.dart';
import 'youtube_service.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _query = TextEditingController();
  final _scroll = ScrollController();

  VideoSearchList? _page;
  final _results = <Video>[];
  bool _loading = false;
  bool _loadingMore = false;
  String? _error;
  String _lastQuery = '';

  /// Showing search results rather than the topic feed.
  bool _searching = false;

  /// The newest videos for the user's topics, shown when not searching.
  late final TopicFeed _feed;
  late final AppLifecycleListener _lifecycle;

  /// The topic chip picked above the feed; null for all of them.
  String? _topic;

  /// Coming back to the app after this long refreshes the feed.
  static const _staleAfter = Duration(minutes: 30);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
    // The feed saved last time shows straight away. The fresh one loads
    // after the first frame is drawn, in the background, so starting the
    // app never waits on the network.
    _feed = TopicFeed(AppSettings.instance);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _feed.load();
    });
    _lifecycle = AppLifecycleListener(onResume: _refreshIfStale);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _feed.dispose();
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _refreshIfStale() {
    final at = _feed.loadedAt;
    if (_feed.loading || at == null) return;
    if (DateTime.now().difference(at) >= _staleAfter) _feed.load();
  }

  Future<void> _editTopics() async {
    final before = AppSettings.instance.topics;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const TopicsPage()),
    );
    if (!mounted) return;
    final after = AppSettings.instance.topics;
    if (!listEquals(before, after)) {
      if (_topic != null && !after.contains(_topic)) {
        setState(() => _topic = null);
      }
      _feed.load();
    }
  }

  /// Leaves search results and goes back to the topic feed.
  void _clearSearch() {
    _query.clear();
    setState(() {
      _searching = false;
      _loading = false;
      _error = null;
      _results.clear();
      _page = null;
      _lastQuery = '';
    });
  }

  Future<void> _submit(String text) async {
    final String query;
    switch (parseSearchInput(text)) {
      case EmptyInput():
        return;
      case VideoInput(:final id):
        // A pasted link or id plays straight away instead of searching.
        _open(id);
        return;
      case QueryInput(query: final q):
        query = q;
    }
    _lastQuery = query;

    setState(() {
      _searching = true;
      _loading = true;
      _error = null;
      _results.clear();
      _page = null;
    });
    try {
      final page = await YoutubeService.instance.search(query);
      // Ignore an answer for a search the user has since cleared or replaced.
      if (!mounted || !_searching || _lastQuery != query) return;
      setState(() {
        _page = page;
        _results.addAll(page);
      });
    } catch (e) {
      if (mounted && _searching && _lastQuery == query) {
        setState(() => _error = '$e');
      }
    } finally {
      if (mounted && _lastQuery == query) setState(() => _loading = false);
    }
  }

  Future<void> _maybeLoadMore() async {
    if (_loadingMore || _page == null) return;
    if (_scroll.position.pixels < _scroll.position.maxScrollExtent - 600) return;
    _loadingMore = true;
    try {
      final next = await _page!.nextPage();
      if (!mounted) return;
      setState(() {
        _page = next;
        if (next != null) _results.addAll(next);
      });
    } catch (_) {
      // Ignore; the user can scroll again to retry.
    } finally {
      _loadingMore = false;
    }
  }

  void _open(String id) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => PlayerPage(videoId: id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Back from search results goes to the feed rather than leaving.
    return PopScope(
      canPop: !_searching,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _clearSearch();
      },
      child: _scaffold(),
    );
  }

  Widget _scaffold() {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AdFree Tube'),
        actions: [
          IconButton(
            tooltip: 'Your topics',
            icon: const Icon(Icons.interests_outlined),
            onPressed: _editTopics,
          ),
          const DownloadsButton(),
          IconButton(
            tooltip: 'History',
            icon: const Icon(Icons.history),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const HistoryPage()),
            ),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsPage()),
            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(64),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: SearchBar(
              controller: _query,
              hintText: 'Search YouTube or paste a link',
              leading: const Icon(Icons.search),
              onSubmitted: _submit,
              textInputAction: TextInputAction.search,
              trailing: [
                IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.clear),
                  onPressed: _clearSearch,
                ),
              ],
            ),
          ),
        ),
      ),
      body: _body(),
      bottomNavigationBar: const MiniPlayer(),
    );
  }

  Widget _body() {
    if (!_searching) return _feedView();
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Search didn\'t work. Check your connection and try again.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => _submit(_lastQuery),
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    }
    if (_results.isEmpty) {
      return const Center(child: Text('Nothing found. Try other words.'));
    }
    return ListView.builder(
      controller: _scroll,
      itemCount: _results.length + (_page != null ? 1 : 0),
      itemBuilder: (context, i) {
        if (i == _results.length) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final v = _results[i];
        final views = v.engagement.viewCount;
        return VideoTile(
          thumbnail: v.thumbnails.mediumResUrl,
          title: v.title,
          subtitle: [
            v.author,
            if (views > 0) '${formatCount(views)} views',
            if (v.uploadDateRaw != null) v.uploadDateRaw!,
          ].join(' • '),
          badge: v.isLive ? 'LIVE' : formatDuration(v.duration),
          onTap: () => _open(v.id.value),
        );
      },
    );
  }

  Widget _feedView() {
    return ListenableBuilder(
      listenable: Listenable.merge([_feed, AppSettings.instance]),
      builder: (context, _) {
        final topics = AppSettings.instance.topics;
        if (topics.isEmpty) return _noTopics();
        final topic = topics.contains(_topic) ? _topic : null;
        final sort = FeedSort.byName(AppSettings.instance.feedSort);
        final videos = sort.apply(_feed.videosFor(topic));
        return Column(
          children: [
            SizedBox(
              height: 52,
              child: Row(
                children: [
                  Expanded(child: _topicChips(topics, topic)),
                  _sortButton(sort),
                ],
              ),
            ),
            SizedBox(
              height: 3,
              child: _feed.loading && videos.isNotEmpty
                  ? const LinearProgressIndicator()
                  : null,
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _feed.load,
                child: _feedList(videos),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _sortButton(FeedSort sort) {
    return PopupMenuButton<FeedSort>(
      tooltip: 'Sort',
      initialValue: sort,
      onSelected: (s) => AppSettings.instance.feedSort = s.name,
      itemBuilder: (context) => [
        for (final s in FeedSort.values)
          CheckedPopupMenuItem(
            value: s,
            checked: s == sort,
            child: Text(s.label),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 12, 0),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.sort, size: 20),
            const SizedBox(width: 4),
            Text(sort.label, style: Theme.of(context).textTheme.labelLarge),
          ],
        ),
      ),
    );
  }

  Widget _topicChips(List<String> topics, String? topic) {
    return ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      children: [
        for (final t in <String?>[null, ...topics])
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(t ?? 'All'),
              selected: t == topic,
              onSelected: (_) => setState(() => _topic = t),
            ),
          ),
        ActionChip(
          avatar: const Icon(Icons.edit, size: 18),
          label: const Text('Edit'),
          onPressed: _editTopics,
        ),
      ],
    );
  }

  Widget _feedList(List<FeedVideo> videos) {
    if (videos.isEmpty) {
      final Widget message;
      if (_feed.loading) {
        message = const Center(child: CircularProgressIndicator());
      } else if (_feed.error != null) {
        message = Column(
          children: [
            const Text(
              'Couldn\'t load the latest videos. Check your connection and '
              'try again.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _feed.load,
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
          ],
        );
      } else {
        message = const Text(
          'No videos for these topics yet.',
          textAlign: TextAlign.center,
        );
      }
      // Scrollable so pull-to-refresh works on an empty feed too.
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [const SizedBox(height: 48), message],
      );
    }
    final failed = _feed.loading ? const <String>[] : _feed.failedTopics;
    return ListView.builder(
      itemCount: videos.length + (failed.isEmpty ? 0 : 1),
      itemBuilder: (context, i) {
        if (failed.isNotEmpty) {
          if (i == 0) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                'Couldn\'t refresh ${failed.join(', ')}. Pull down to try '
                'again.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            );
          }
          i--;
        }
        final v = videos[i];
        return VideoTile(
          thumbnail: v.thumbnail,
          title: v.title,
          subtitle: [
            v.author,
            if (v.views > 0) '${formatCount(v.views)} views',
            if (v.published != null) v.published!,
          ].join(' • '),
          badge: v.isLive ? 'LIVE' : formatDuration(v.duration),
          onTap: () => _open(v.id),
        );
      },
    );
  }

  Widget _noTopics() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.interests_outlined, size: 48),
            const SizedBox(height: 16),
            const Text(
              'Pick topics you like and their newest videos show up here '
              'every time you open the app.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _editTopics,
              icon: const Icon(Icons.add),
              label: const Text('Choose topics'),
            ),
          ],
        ),
      ),
    );
  }
}

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final items = settings.history;
        return Scaffold(
          appBar: AppBar(
            title: const Text('History'),
            actions: [
              if (items.isNotEmpty)
                TextButton(
                  onPressed: settings.clearHistory,
                  child: const Text('Clear'),
                ),
            ],
          ),
          bottomNavigationBar: const MiniPlayer(),
          body: items.isEmpty
              ? const Center(child: Text('Nothing watched yet.'))
              : ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, i) {
                    final e = items[i];
                    return VideoTile(
                      thumbnail: e.thumbnail,
                      title: e.title,
                      subtitle: e.author,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => PlayerPage(videoId: e.id),
                        ),
                      ),
                    );
                  },
                ),
        );
      },
    );
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => ListView(
          children: [
            const ListTile(title: Text('Default video quality')),
            RadioGroup<int>(
              groupValue: settings.preferredHeight,
              onChanged: (v) => settings.preferredHeight = v!,
              child: Column(
                children: [
                  for (final q in AppSettings.qualities)
                    RadioListTile<int>(value: q, title: Text('${q}p')),
                ],
              ),
            ),
            // Workaround (bug 7 in the README "Known bugs and workarounds"):
            // let people switch how video is drawn if it shows black.
            const Divider(),
            const ListTile(
              title: Text('Video display (Android)'),
              subtitle: Text(
                'If you hear sound but the video is black, '
                'try the other option.',
              ),
            ),
            RadioGroup<String>(
              groupValue: settings.videoDisplay,
              onChanged: (v) => settings.videoDisplay = v!,
              child: const Column(
                children: [
                  RadioListTile<String>(
                    value: 'hybrid',
                    title: Text('Hybrid composition'),
                  ),
                  RadioListTile<String>(
                    value: 'texture',
                    title: Text('Texture'),
                  ),
                ],
              ),
            ),
            SwitchListTile(
              title: const Text('Draw video through a canvas'),
              subtitle: const Text(
                'Copies each frame onto the page. Fixes '
                'black video on some phones; uses a little more battery.',
              ),
              value: settings.canvasVideo,
              onChanged: (v) => settings.canvasVideo = v,
            ),
            SwitchListTile(
              title: const Text('Keep video drawn in the page'),
              subtitle: const Text(
                'Stops Android moving the video to a '
                'separate layer. Try turning it off if the video is black.',
              ),
              value: settings.pageDrawnVideo,
              onChanged: (v) => settings.pageDrawnVideo = v,
            ),
          ],
        ),
      ),
    );
  }
}
