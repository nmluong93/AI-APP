import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../../../youtube_explode_dart.dart';
import '../../extensions/helpers_extension.dart';
import '../../retry.dart';
import '../pages/watch_page.dart';

@internal
class CommentsClient {
  final JsonMap root;

  late final List<JsonMap>? _commentRenderers = _getCommentRenderers();

  // AdFree Tube patch (bug 20 in its README): YouTube now sends each
  // comment as a commentViewModel that only holds keys, with the author,
  // text and counts in frameworkUpdates/entityBatchUpdate/mutations. Read
  // both that and the old commentRenderer, and skip a comment that can't
  // be read rather than failing the whole page.
  late final Map<String, JsonMap> _entities = _getEntities();

  late final List<_Comment>? comments = _commentRenderers
      ?.map((e) => _Comment.tryParse(e, _entities))
      .whereType<_Comment>()
      .toList(growable: false);

  late final String? _continuationToken = _getContinuationToken();

  /// AdFree Tube patch (bug 20): whether [nextPage] has anything to fetch.
  bool get hasNextPage => _continuationToken != null;

  CommentsClient(this.root);

  ///
  static Future<CommentsClient?> get(
    YoutubeHttpClient httpClient,
    Video video,
  ) async {
    final watchPage = video.watchPage ??
        await retry<WatchPage>(
          httpClient,
          () async => WatchPage.get(httpClient, video.id.value),
        );

    final continuation = watchPage.initialData.commentsContinuation;
    if (continuation == null) {
      return null;
    }

    final data = await httpClient.sendContinuation('next', continuation);
    return CommentsClient(data);
  }

  ///
  static Future<CommentsClient?> getReplies(
    YoutubeHttpClient httpClient,
    String token,
  ) async {
    final data = await httpClient.sendContinuation('next', token);
    return CommentsClient(data);
  }

  /*
onResponseReceivedEndpoints[1].reloadContinuationItemsCommand.continuationItems[2].commentThreadRenderer.comment.commentRenderer.contentText.runs[0].text   */
  List<JsonMap>? _getCommentRenderers() {
    final endpoints =
        root.getJson<List<dynamic>>('onResponseReceivedEndpoints');
    final endpoint = endpoints?.last as JsonMap?;
    if (endpoint == null) {
      return null;
    }

    // This was used in old youtube versions.
    final continuationItems = endpoint.getJson<List<dynamic>>(
      'appendContinuationItemsAction/continuationItems',
    );
    final comments = continuationItems
        ?.where(
            (e) => e['commentRenderer'] != null || e['commentViewModel'] != null)
        .toList(growable: false);

    if (comments?.isNotEmpty ?? false) {
      return comments?.cast<JsonMap>();
    }

    // This can probably be simplified.
    final cmd = endpoint.getJson<JsonMap>('reloadContinuationItemsCommand') ??
        endpoint.getJson<JsonMap>('appendContinuationItemsAction');
    final items = cmd?.getJson<List<dynamic>>('continuationItems') ??
        cmd?.getJson<List<dynamic>>('appendContinuationItemsAction');
    return items
            ?.where((e) => e['commentThreadRenderer'] != null)
            .map((e) =>
                (e as JsonMap).getJson<JsonMap>('commentThreadRenderer')!)
            .toList(growable: false) ??
        const [];
  }

  Map<String, JsonMap> _getEntities() {
    final mutations = root.getJson<List<dynamic>>(
      'frameworkUpdates/entityBatchUpdate/mutations',
    );
    final entities = <String, JsonMap>{};
    for (final m in mutations ?? const []) {
      if (m is! JsonMap) continue;
      final payload = m.getJson<JsonMap>('payload');
      final value = payload?.values.firstOrNull;
      final key = m['entityKey'];
      if (key is String && value is JsonMap) entities[key] = value;
    }
    return entities;
  }

  String? _getContinuationToken() {
    final endpoints =
        root.getJson<List<dynamic>>('onResponseReceivedEndpoints');
    final last = endpoints?.lastOrNull as JsonMap?;
    if (last == null) return null;
    final items = last.getJson<List<dynamic>>(
      'appendContinuationItemsAction/continuationItems',
    );
    final item =
        items?.firstWhereOrNull((e) => e['continuationItemRenderer'] != null)
            as JsonMap?;
    final token = item?.getJson<String>(
      'continuationItemRenderer/button/buttonRenderer/command/continuationCommand/token',
    ); /* Used for the replies */
    if (token != null) return token;

    final cmd = last.getJson<JsonMap>('reloadContinuationItemsCommand') ??
        last.getJson<JsonMap>('appendContinuationItemsAction');
    final continuationItems =
        cmd?.getJson<List<dynamic>>('continuationItems') ??
            cmd?.getJson<List<dynamic>>('appendContinuationItemsAction');
    final continuationItem = continuationItems?.firstWhereOrNull(
        (e) => e['continuationItemRenderer'] != null) as JsonMap?;
    return continuationItem?.getJson<String>(
      'continuationItemRenderer/continuationEndpoint/continuationCommand/token',
    );
  }

  // onResponseReceivedEndpoints[0].reloadContinuationItemsCommand.continuationItems[0].commentsHeaderRenderer
  int getCommentsCount() {
    final endpoints =
        root.getJson<List<dynamic>>('onResponseReceivedEndpoints');
    final header = (endpoints?.firstOrNull as JsonMap?)?.getJson<JsonMap>(
      'reloadContinuationItemsCommand/continuationItems/0/commentsHeaderRenderer',
    );
    final text = header?.getJson<String>('countText/runs/0/text') ??
        header?.getJson<String>('commentsCount/runs/0/text') ??
        header?.getJson<String>('commentsCount/simpleText');
    return parseCommentCount(text);
  }

  Future<CommentsClient?> nextPage(YoutubeHttpClient httpClient) async {
    if (_continuationToken == null) {
      return null;
    }

    final data = await httpClient.sendContinuation('next', _continuationToken!);
    return CommentsClient(data);
  }
}

/// Reads a count as YouTube writes it on comments: "1,234", "1.2K",
/// "3M", "12 Comments", or blank for none.
int parseCommentCount(String? text) {
  final match =
      RegExp(r'(\d[\d,]*(?:\.\d+)?)\s*([KMB])?', caseSensitive: false)
          .firstMatch(text ?? '');
  if (match == null) return 0;
  final number = double.tryParse(match.group(1)!.replaceAll(',', '')) ?? 0;
  final multiplier = switch (match.group(2)?.toUpperCase()) {
    'K' => 1000,
    'M' => 1000000,
    'B' => 1000000000,
    _ => 1,
  };
  return (number * multiplier).round();
}

class _Comment {
  final String author;
  final String channelId;
  final String text;
  final String publishTime;
  final int? likeCount;
  final int? repliesCount;
  final bool isHearted;

  /// Used to get replies
  final String? continuation;

  _Comment._({
    required this.author,
    required this.channelId,
    required this.text,
    required this.publishTime,
    required this.likeCount,
    required this.repliesCount,
    required this.isHearted,
    required this.continuation,
  });

  /// [root] is a commentThreadRenderer, or a reply (commentRenderer or
  /// commentViewModel). Null if it can't be read.
  static _Comment? tryParse(JsonMap root, Map<String, JsonMap> entities) {
    try {
      final comment = _parse(root, entities);
      // The public Comment needs a valid ChannelId.
      if (comment == null || !ChannelId.validateChannelId(comment.channelId)) {
        return null;
      }
      return comment;
    } catch (_) {
      return null;
    }
  }

  static _Comment? _parse(JsonMap root, Map<String, JsonMap> entities) {
    {
      final continuation = root.getJson<String>(
        'replies/commentRepliesRenderer/contents/0/continuationItemRenderer/continuationEndpoint/continuationCommand/token',
      );
      final viewModel = root.getJson<JsonMap>('commentViewModel/commentViewModel') ??
          root.getJson<JsonMap>('commentViewModel');
      if (viewModel != null && viewModel['commentKey'] != null) {
        return _fromEntities(viewModel, entities, continuation);
      }
      final renderer = root.getJson<JsonMap>('commentRenderer') ??
          root.getJson<JsonMap>('comment/commentRenderer');
      if (renderer == null) return null;
      return _fromRenderer(renderer, continuation);
    }
  }

  static _Comment? _fromEntities(
    JsonMap viewModel,
    Map<String, JsonMap> entities,
    String? continuation,
  ) {
    final entity = entities[viewModel['commentKey']];
    if (entity == null) return null;
    final toolbarState = entities[viewModel['toolbarStateKey']] ??
        entities[entity.getJson<String>('properties/toolbarStateKey')];
    return _Comment._(
      author: entity.getJson<String>('author/displayName') ?? '',
      channelId: entity.getJson<String>('author/channelId') ?? '',
      text: entity.getJson<String>('properties/content/content') ?? '',
      publishTime: entity.getJson<String>('properties/publishedTime') ?? '',
      likeCount: parseCommentCount(
        entity.getJson<String>('toolbar/likeCountNotliked'),
      ),
      repliesCount:
          parseCommentCount(entity.getJson<String>('toolbar/replyCount')),
      isHearted:
          toolbarState?['heartState'] == 'TOOLBAR_HEART_STATE_HEARTED',
      continuation: continuation,
    );
  }

  static _Comment _fromRenderer(JsonMap renderer, String? continuation) =>
      _Comment._(
        author: renderer.getJson<String>('authorText/simpleText') ?? '',
        channelId: renderer
                .getJson<String>('authorEndpoint/browseEndpoint/browseId') ??
            '',
        text: renderer
                .getJson<List<dynamic>>('contentText/runs')
                ?.cast<Map<dynamic, dynamic>>()
                .parseRuns() ??
            '',
        publishTime:
            renderer.getJson<String>('publishedTimeText/runs/0/text') ?? '',
        likeCount:
            parseCommentCount(renderer.getJson<String>('voteCount/simpleText')),
        repliesCount: renderer.getT<int>('replyCount'),
        isHearted: renderer.getJson<JsonMap>(
              'actionButtons/commentActionButtonsRenderer/creatorHeart',
            ) !=
            null,
        continuation: continuation,
      );

  @override
  String toString() => '$author: $text';
}

extension _CommentsDataExtension on WatchPageInitialData {
  JsonMap? getContinuationContext() {
    if (root['contents'] != null) {
      final contents = root.getJson<List<dynamic>>(
        'contents/twoColumnWatchNextResults/results/results/contents',
      );
      final section =
          contents?.lastWhereOrNull((e) => e['itemSectionRenderer'] != null)
              as JsonMap?;
      final sectionContents =
          section?.getJson<List<dynamic>>('itemSectionRenderer/contents');
      final first = sectionContents?.firstOrNull as JsonMap?;
      return first?.getJson<JsonMap>(
        'continuationItemRenderer/continuationEndpoint/continuationCommand',
      );
    }
    return null;
  }

  String? get commentsContinuation =>
      getContinuationContext()?.getT<String>('token');
}
