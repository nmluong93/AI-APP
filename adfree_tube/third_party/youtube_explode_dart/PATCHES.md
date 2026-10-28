# Local patches

This is youtube_explode_dart 3.1.0 from pub.dev (BSD-3-Clause, see LICENSE),
vendored so AdFree Tube can carry fixes before they are released upstream.
It is used through `dependency_overrides` in `../../pubspec.yaml`.

1. `lib/src/videos/streams/stream_client.dart`, `_parseStreamInfo`: skip
   streams whose URL is empty. YouTube's WEB client returns adaptive formats
   with no URL (SABR-only), which made the whole manifest fail with
   "Invalid argument(s): No host specified in URI" before the HLS manifest
   (which does work) was read.

When upgrading: replace this folder with the new release, re-apply the
patches above if still needed, or delete the folder and the override if the
upstream release fixes them.
