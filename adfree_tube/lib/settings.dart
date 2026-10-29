import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class HistoryEntry {
  final String id;
  final String title;
  final String author;

  const HistoryEntry(this.id, this.title, this.author);

  String get thumbnail => 'https://i.ytimg.com/vi/$id/mqdefault.jpg';

  Map<String, String> toJson() => {'id': id, 'title': title, 'author': author};

  factory HistoryEntry.fromJson(Map<String, dynamic> j) =>
      HistoryEntry(j['id'] as String, j['title'] as String, j['author'] as String);
}

/// Preferred quality and watch history, persisted locally.
class AppSettings extends ChangeNotifier {
  AppSettings._(this._prefs);

  static late AppSettings instance;

  static Future<void> load() async {
    instance = AppSettings._(await SharedPreferences.getInstance());
  }

  final SharedPreferences _prefs;

  static const qualities = [2160, 1440, 1080, 720, 480, 360];

  int get preferredHeight => _prefs.getInt('preferredHeight') ?? 1080;

  set preferredHeight(int value) {
    _prefs.setInt('preferredHeight', value);
    notifyListeners();
  }

  /// How the WebView is put on screen on Android: 'hybrid' (hybrid
  /// composition) or 'texture' (texture layer). Workaround (bug 7 in the
  /// README "Known bugs and workarounds"): some phones show the video black
  /// in one mode, so it can be switched in Settings.
  String get videoDisplay => _prefs.getString('videoDisplay') ?? 'hybrid';

  set videoDisplay(String value) {
    _prefs.setString('videoDisplay', value);
    notifyListeners();
  }

  /// Workaround (bug 7): keep the WebView from moving the video to a
  /// separate hardware layer, by making it very slightly transparent and
  /// rotated by a tiny angle. See `keepVisible()` in yt_web_player.dart.
  bool get pageDrawnVideo => _prefs.getBool('pageDrawnVideo') ?? true;

  set pageDrawnVideo(bool value) {
    _prefs.setBool('pageDrawnVideo', value);
    notifyListeners();
  }

  List<HistoryEntry> get history => (_prefs.getStringList('history') ?? [])
      .map((s) => HistoryEntry.fromJson(jsonDecode(s) as Map<String, dynamic>))
      .toList();

  void addToHistory(HistoryEntry entry) {
    final list = history.where((e) => e.id != entry.id).toList()
      ..insert(0, entry);
    _prefs.setStringList(
        'history', list.take(200).map((e) => jsonEncode(e.toJson())).toList());
    notifyListeners();
  }

  void clearHistory() {
    _prefs.remove('history');
    notifyListeners();
  }
}
