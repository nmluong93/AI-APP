import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the pieces of the injected page script that the Dart side and
/// the black-video workarounds depend on. The script's behaviour is tested
/// in a real browser by tool/page_script_test/test.mjs.
void main() {
  final source = File('lib/yt_web_player.dart').readAsStringSync();

  test('page script exposes every command the app calls', () {
    for (final api in [
      'api.play',
      'api.pause',
      'api.seek',
      'api.setVolume',
      'api.setQuality',
      'api.debug',
      'api.testSquare',
    ]) {
      expect(source, contains('$api ='), reason: api);
    }
  });

  test('black-video workarounds are still wired in', () {
    expect(source, contains('function drawFrame()'));
    expect(source, contains('opts.canvasVideo === false'));
    expect(source, contains('function keepVisible(el)'));
    expect(source, contains('function unmute(p, el)'));
    expect(source, contains("'canvasVideo': canvasVideo"));
  });

  test('state is posted to the AdFreeBridge channel', () {
    expect(source, contains("addJavaScriptChannel(\n      'AdFreeBridge'"));
    expect(source, contains('AdFreeBridge.postMessage(json)'));
  });

  test('Android keeps Impeller off', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();
    expect(
      manifest,
      matches(
        RegExp(
          r'io\.flutter\.embedding\.android\.EnableImpeller"\s*android:value="false"',
        ),
      ),
    );
  });
}
