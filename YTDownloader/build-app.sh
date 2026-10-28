#!/bin/bash
# Builds "YT Downloader.app" into ./build.
# Usage: ./build-app.sh [--universal] [--spm]
#   --universal  one app for both Apple Silicon and Intel Macs
#   --spm        build with Swift Package Manager instead of calling swiftc directly
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="YT Downloader"
BUNDLE_ID="local.ytdownloader"
MIN_MACOS="13.0"
UNIVERSAL=0
USE_SPM=0
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    --spm) USE_SPM=1 ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

if [[ $UNIVERSAL == 1 ]]; then
  ARCHS=(arm64 x86_64)
else
  ARCHS=("$(uname -m)")
fi

mkdir -p build/obj
BINARIES=()
for ARCH in "${ARCHS[@]}"; do
  echo "==> Compiling (release, $ARCH)…"
  if [[ $USE_SPM == 1 ]]; then
    BUILD_PATH=".build/$ARCH"
    swift build -c release --triple "$ARCH-apple-macosx$MIN_MACOS" --build-path "$BUILD_PATH"
    BINARIES+=("$(swift build -c release --triple "$ARCH-apple-macosx$MIN_MACOS" --build-path "$BUILD_PATH" --show-bin-path)/YTDownloader")
  else
    # Calling swiftc directly avoids SwiftPM, so a mismatched Command Line Tools install
    # (e.g. "Invalid manifest … PackageDescription") doesn't block the build.
    SDK="$(xcrun --sdk macosx --show-sdk-path)"
    OUT="build/obj/YTDownloader-$ARCH"
    xcrun swiftc -O -parse-as-library -module-name YTDownloader \
      -target "$ARCH-apple-macos$MIN_MACOS" -sdk "$SDK" \
      Sources/YTDownloader/*.swift -o "$OUT"
    BINARIES+=("$OUT")
  fi
done

if [[ ${#BINARIES[@]} -gt 1 ]]; then
  BINARY="build/obj/YTDownloader-universal"
  lipo -create "${BINARIES[@]}" -output "$BINARY"
  lipo -info "$BINARY"
else
  BINARY="${BINARIES[0]}"
fi

APP="build/${APP_NAME}.app"
echo "==> Creating ${APP}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/YTDownloader"

# Optional: drop standalone yt-dlp / ffmpeg / deno binaries into ./bin to ship them inside the app.
if [[ -d bin ]]; then
  mkdir -p "$APP/Contents/Resources/bin"
  cp bin/* "$APP/Contents/Resources/bin/"
  chmod +x "$APP/Contents/Resources/bin/"*
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>YTDownloader</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$APP"

echo "Done: $(pwd)/$APP"
echo "Run it with: open \"$APP\"   (or drag it into /Applications)"
