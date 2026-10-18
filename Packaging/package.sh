#!/usr/bin/env bash
# Builds "IDM Mac.app" (arm64) with yt-dlp and ffmpeg inside, ad-hoc signs it and makes dist/IDM-Mac.dmg.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-1}"
APP="dist/IDM Mac.app"
TMP="$(mktemp -d)"

echo "==> Swift build"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)"

echo "==> App bundle"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp "$BIN/IDMMac" "$BIN/IDMMacHost" "$APP/Contents/MacOS/"
OWNER="${OWNER:-Enes Savaşçı}"
# Shared secret between the app and its Safari extension (see SafariBridge.swift).
TOKEN="$(uuidgen | tr -d '-')"
fill() { sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" -e "s/__OWNER__/$OWNER/" -e "s/__TOKEN__/$TOKEN/" "$1"; }
fill Packaging/Info.plist > "$APP/Contents/Info.plist"
cp -R Extension "$APP/Contents/Resources/ChromeExtension"

echo "==> Safari extension"
APPEX="$APP/Contents/PlugIns/IDMMacSafari.appex"
mkdir -p "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources"
swiftc -O -parse-as-library -application-extension -target arm64-apple-macos13.0 -module-name IDMMacSafari \
  -Xlinker -e -Xlinker _NSExtensionMain -framework SafariServices -framework AppKit \
  Safari/Handler.swift -o "$APPEX/Contents/MacOS/IDMMacSafari"
fill Safari/Info.plist > "$APPEX/Contents/Info.plist"
cp Safari/Web/* "$APPEX/Contents/Resources/"
cp -R Extension/content.js Extension/popup.html Extension/popup.js Extension/icons "$APPEX/Contents/Resources/"
plutil -lint "$APP/Contents/Info.plist" "$APPEX/Contents/Info.plist"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$APPEX/Contents/Resources/manifest.json"
cp THIRD_PARTY.md "$APP/Contents/Resources/THIRD_PARTY.md"

echo "==> Icon"
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Packaging/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Packaging/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> yt-dlp"
curl -fsSL --retry 3 -o "$APP/Contents/Resources/bin/yt-dlp" \
  https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos
chmod +x "$APP/Contents/Resources/bin/yt-dlp"

echo "==> ffmpeg / ffprobe (arm64)"
for tool in ffmpeg ffprobe; do
  if curl -fsSL --retry 3 -o "$TMP/$tool.zip" \
      "https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/$tool.zip"; then
    unzip -oq "$TMP/$tool.zip" -d "$TMP/$tool"
    cp "$(find "$TMP/$tool" -type f -name "$tool" | head -1)" "$APP/Contents/Resources/bin/$tool"
    chmod +x "$APP/Contents/Resources/bin/$tool"
  else
    echo "warning: $tool could not be downloaded; the app will fall back to Homebrew's copy" >&2
  fi
done

echo "==> deno (JavaScript runtime yt-dlp needs for YouTube)"
curl -fsSL --retry 3 -o "$TMP/deno.zip" \
  https://github.com/denoland/deno/releases/latest/download/deno-aarch64-apple-darwin.zip
unzip -oq "$TMP/deno.zip" -d "$TMP/deno"
cp "$TMP/deno/deno" "$APP/Contents/Resources/bin/deno"
chmod +x "$APP/Contents/Resources/bin/deno"

for f in "$APP"/Contents/Resources/bin/*; do
  echo "    $(basename "$f"): $(lipo -archs "$f" 2>/dev/null || echo '?')"
done

echo "==> Ad-hoc signing"
for f in "$APP"/Contents/Resources/bin/*; do
  codesign --verify "$f" 2>/dev/null || codesign --force --sign - "$f"
done
codesign --force --sign - "$APP/Contents/MacOS/IDMMacHost"
codesign --force --sign - --entitlements Safari/entitlements.plist "$APPEX"
codesign --force --sign - "$APP"
codesign --verify --verbose "$APP"

echo "==> DMG"
STAGE="$TMP/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp Packaging/BENIOKU.txt "$STAGE/BENİ OKU.txt"
hdiutil create -volname "IDM Mac" -srcfolder "$STAGE" -ov -format UDZO "dist/IDM-Mac.dmg"
echo "==> dist/IDM-Mac.dmg"
