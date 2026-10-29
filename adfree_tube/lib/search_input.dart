/// What the search bar's text means: a video to open, words to search for,
/// or nothing.
sealed class SearchInput {
  const SearchInput();
}

class EmptyInput extends SearchInput {
  const EmptyInput();
}

/// A pasted YouTube link or video id.
class VideoInput extends SearchInput {
  final String id;
  const VideoInput(this.id);

  @override
  bool operator ==(Object other) => other is VideoInput && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'VideoInput($id)';
}

/// Words to search YouTube for, with spaces tidied up.
class QueryInput extends SearchInput {
  final String query;
  const QueryInput(this.query);

  @override
  bool operator ==(Object other) => other is QueryInput && other.query == query;

  @override
  int get hashCode => query.hashCode;

  @override
  String toString() => 'QueryInput($query)';
}

final _idPattern = RegExp(r'^[A-Za-z0-9_-]{11}$');
final _spaces = RegExp(r'\s+');

const _youtubeHosts = {
  'youtube.com',
  'www.youtube.com',
  'm.youtube.com',
  'music.youtube.com',
  'youtube-nocookie.com',
  'www.youtube-nocookie.com',
};

/// Reads the search bar's [text].
///
/// A link to a YouTube video (watch, youtu.be, shorts, live, embed, on any
/// YouTube site) opens that video. A bare 11-character video id opens it
/// too, but only if it looks like one: an English word such as
/// "programming" or a name like "TaylorSwift" is also 11 letters, so it
/// must have a digit, `-` or `_` (as about 9 in 10 ids do; paste the link
/// for the rest). Anything else is searched for.
SearchInput parseSearchInput(String text) {
  // Non-breaking and other unusual spaces (e.g. from a pasted title) count
  // as spaces.
  final query = text.replaceAll(_spaces, ' ').trim();
  if (query.isEmpty) return const EmptyInput();

  if (!query.contains(' ')) {
    final id = videoIdFromLink(query);
    if (id != null) return VideoInput(id);
    if (_looksLikeId(query)) return VideoInput(query);
  }
  return QueryInput(query);
}

bool _looksLikeId(String s) {
  if (!_idPattern.hasMatch(s)) return false;
  return RegExp(r'[0-9_-]').hasMatch(s);
}

/// The video id in a YouTube link, or null if [link] isn't one.
String? videoIdFromLink(String link) {
  var text = link.trim();
  if (!text.contains('/') && !text.contains('?')) return null;
  if (!text.contains('://')) text = 'https://$text';
  final Uri uri;
  try {
    uri = Uri.parse(text);
  } on FormatException {
    return null;
  }
  final host = uri.host.toLowerCase();
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  String? candidate;
  if (host == 'youtu.be' || host == 'www.youtu.be') {
    candidate = segments.firstOrNull;
  } else if (_youtubeHosts.contains(host)) {
    if (segments.isNotEmpty &&
        const {'shorts', 'live', 'embed', 'v', 'e'}.contains(segments.first)) {
      candidate = segments.elementAtOrNull(1);
    } else if (segments.firstOrNull == 'watch' || segments.isEmpty) {
      candidate = uri.queryParameters['v'];
    }
  }
  if (candidate == null || !_idPattern.hasMatch(candidate)) return null;
  return candidate;
}
