# Workaround (bug 14 in the README "Known bugs and workarounds"): Flutter
# shrinks release builds with R8, which renamed or removed classes that
# youtubedl-android (yt-dlp, Python, ffmpeg) and its JSON and archive
# libraries load by name, so the app closed on start. Keep them whole.
-keep class com.yausername.** { *; }
-keep class com.fasterxml.jackson.** { *; }
-keep class org.apache.commons.compress.** { *; }
-keep class org.apache.commons.io.** { *; }
-dontwarn com.fasterxml.jackson.**
-dontwarn org.apache.commons.**
-dontwarn org.brotli.**
-dontwarn org.tukaani.**
-dontwarn com.github.luben.**
-dontwarn org.objectweb.asm.**
-dontwarn javax.annotation.**
