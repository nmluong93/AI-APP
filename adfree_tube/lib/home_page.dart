import 'package:flutter/material.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'mini_player.dart';
import 'player_page.dart';
import 'settings.dart';
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

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _submit(String text) async {
    text = text.trim();
    if (text.isEmpty) return;

    // A pasted link or id plays straight away instead of searching.
    final id = YoutubeService.parseVideoId(text);
    if (id != null && (text.contains('/') || text.length == 11 && !text.contains(' '))) {
      _open(id);
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      _results.clear();
      _page = null;
    });
    try {
      final page = await YoutubeService.instance.search(text);
      if (!mounted) return;
      setState(() {
        _page = page;
        _results.addAll(page);
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Search failed: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('AdFree Tube'),
        actions: [
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
                  icon: const Icon(Icons.clear),
                  onPressed: _query.clear,
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
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, textAlign: TextAlign.center),
        ),
      );
    }
    if (_results.isEmpty) {
      return const Center(child: Text('Search for something to watch.'));
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
                        MaterialPageRoute(builder: (_) => PlayerPage(videoId: e.id)),
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
              subtitle: Text('If you hear sound but the video is black, '
                  'try the other option.'),
            ),
            RadioGroup<String>(
              groupValue: settings.videoDisplay,
              onChanged: (v) => settings.videoDisplay = v!,
              child: const Column(
                children: [
                  RadioListTile<String>(
                      value: 'hybrid', title: Text('Hybrid composition')),
                  RadioListTile<String>(
                      value: 'texture', title: Text('Texture')),
                ],
              ),
            ),
            SwitchListTile(
              title: const Text('Keep video drawn in the page'),
              subtitle: const Text('Stops Android moving the video to a '
                  'separate layer. Try turning it off if the video is black.'),
              value: settings.pageDrawnVideo,
              onChanged: (v) => settings.pageDrawnVideo = v,
            ),
          ],
        ),
      ),
    );
  }
}
