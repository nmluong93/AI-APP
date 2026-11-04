import 'package:flutter/material.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

import 'widgets.dart';
import 'youtube_service.dart';

/// The comments of one video, fetched page by page in the background.
///
/// Nothing here is awaited by the player: [load] and [loadMore] start the
/// network request and return, and listeners are told when a page arrives,
/// so playback and the rest of the screen never wait for comments.
class VideoComments extends ChangeNotifier {
  VideoComments(this.video, {YoutubeService? service})
    : _service = service ?? YoutubeService.instance;

  final yt.Video video;
  final YoutubeService _service;

  final List<yt.Comment> items = [];

  /// The total YouTube reports, which can be more than it lets us page.
  int total = 0;
  bool loading = false;

  /// True once YouTube said the video has no comments, or they're off.
  bool none = false;
  String? error;

  yt.CommentsList? _page;
  bool _started = false;
  bool _disposed = false;

  bool get hasMore => _page != null && !none;

  /// Loads the first page, once.
  Future<void> load() async {
    if (_started) return;
    _started = true;
    await _fetch(() => _service.comments(video));
  }

  /// Loads the next page, if there is one and nothing is loading.
  Future<void> loadMore() async {
    final page = _page;
    if (loading) return;
    if (page == null) {
      // The first page failed: Try again.
      if (error != null) await _fetch(() => _service.comments(video));
      return;
    }
    await _fetch(page.nextPage, more: true);
  }

  Future<void> _fetch(
    Future<yt.CommentsList?> Function() get, {
    bool more = false,
  }) async {
    loading = true;
    error = null;
    _notify();
    try {
      final page = await get();
      if (_disposed) return;
      if (page == null || (page.isEmpty && !more)) {
        if (more) {
          _page = null;
        } else {
          none = true;
        }
      } else {
        // The last page has no next token; YouTube may also just stop.
        _page = page.isEmpty || !page.hasNextPage ? null : page;
        items.addAll(page);
        if (page.totalLength > 0) total = page.totalLength;
      }
    } catch (e) {
      if (_disposed) return;
      debugPrint('Could not load comments: $e');
      error = "Comments didn't load.";
    }
    loading = false;
    _notify();
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

/// "Comments · 1.2K" with the comments below it and a button for more.
///
/// With [preview] it shows only the first comment, and tapping it opens all
/// of them in a sheet (used on phones, where Up next comes after it).
class CommentsSection extends StatelessWidget {
  const CommentsSection({
    super.key,
    required this.comments,
    this.preview = false,
  });

  final VideoComments comments;
  final bool preview;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: comments,
      builder: (context, _) =>
          preview ? _preview(context) : _CommentsList(comments: comments),
    );
  }

  Widget _preview(BuildContext context) {
    final theme = Theme.of(context);
    final c = comments;
    if (c.none && c.items.isEmpty) return const SizedBox.shrink();
    final first = c.items.isEmpty ? null : c.items.first;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => showCommentsSheet(context, c),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Header(comments: c),
            const SizedBox(height: 6),
            if (first != null)
              Text(first.text, maxLines: 2, overflow: TextOverflow.ellipsis)
            else if (c.loading)
              const LinearProgressIndicator()
            else if (c.error != null)
              Text(c.error!, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

/// Opens every comment of [comments] in a sheet that scrolls and pages.
Future<void> showCommentsSheet(BuildContext context, VideoComments comments) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, controller) => ListenableBuilder(
        listenable: comments,
        builder: (context, _) =>
            _CommentsList(comments: comments, controller: controller),
      ),
    ),
  );
}

class _Header extends StatelessWidget {
  const _Header({required this.comments});

  final VideoComments comments;

  @override
  Widget build(BuildContext context) {
    final count = comments.total > 0 ? comments.total : comments.items.length;
    return Text(
      count > 0 ? 'Comments · ${formatCount(count)}' : 'Comments',
      style: Theme.of(context).textTheme.titleMedium,
    );
  }
}

class _CommentsList extends StatelessWidget {
  const _CommentsList({required this.comments, this.controller});

  final VideoComments comments;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final c = comments;
    if (c.none && c.items.isEmpty) {
      if (controller == null) return const SizedBox.shrink();
      return const Center(child: Text('No comments'));
    }
    final children = [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: _Header(comments: c),
      ),
      for (final comment in c.items) CommentTile(comment: comment),
      if (c.loading)
        const Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator()),
        )
      else if (c.error != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Expanded(child: Text(c.error!)),
              TextButton(onPressed: c.loadMore, child: const Text('Try again')),
            ],
          ),
        )
      else if (c.hasMore)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: c.loadMore,
            child: const Text('Show more comments'),
          ),
        ),
    ];
    if (controller == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      );
    }
    // In the sheet: load the next page on reaching the end.
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.extentAfter < 400 && c.hasMore && !c.loading) {
          c.loadMore();
        }
        return false;
      },
      child: ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: children,
      ),
    );
  }
}

class CommentTile extends StatelessWidget {
  const CommentTile({super.key, required this.comment});

  final yt.Comment comment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              comment.author,
              comment.publishedTime,
            ].where((s) => s.isNotEmpty).join(' • '),
            style: small?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          SelectableText(comment.text),
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(Icons.thumb_up_outlined, size: 14, color: small?.color),
              const SizedBox(width: 4),
              Text(
                comment.likeCount > 0 ? formatCount(comment.likeCount) : '',
                style: small,
              ),
              if (comment.replyCount > 0) ...[
                const SizedBox(width: 16),
                Text(
                  '${formatCount(comment.replyCount)} '
                  '${comment.replyCount == 1 ? 'reply' : 'replies'}',
                  style: small,
                ),
              ],
              if (comment.isHearted) ...[
                const SizedBox(width: 16),
                Icon(Icons.favorite, size: 14, color: theme.colorScheme.error),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
