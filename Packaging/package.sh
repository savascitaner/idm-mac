#!/usr/bin/env bash
# Builds "MDM.app" (arm64) with yt-dlp and ffmpeg inside, signs it and makes dist/MDM.dmg and dist/MDM.pkg.
#
# Optional environment (CI sets these from repository secrets; without them the build is ad-hoc signed):
#   SIGN_ID           "Developer ID Application: Name (TEAMID)": real signature with the hardened runtime
#   INSTALLER_ID      "Developer ID Installer: Name (TEAMID)": signs MDM.pkg (without it no .pkg is published)
#   NOTARY_APPLE_ID, NOTARY_PASSWORD, NOTARY_TEAM_ID: Apple ID, app-specific password and team for notarization
#   EXTENSION_PEM     private key of the Chrome extension: packs Resources/mdm-extension.crx
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-1}"
APP="dist/MDM.app"
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
# The app compares this with the "latest" release to offer updates.
COMMIT="${GITHUB_SHA:-dev}"
fill() { sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" -e "s/__OWNER__/$OWNER/" -e "s/__TOKEN__/$TOKEN/" -e "s/__COMMIT__/$COMMIT/" "$1"; }
fill Packaging/Info.plist > "$APP/Contents/Info.plist"
cp -R Extension "$APP/Contents/Resources/ChromeExtension"
if [ -n "${EXTENSION_PEM:-}" ]; then
  echo "==> Chrome extension (signed CRX)"
  printf '%s\n' "$EXTENSION_PEM" > "$TMP/extension.pem"
  GOT_ID="$(python3 Packaging/make_crx.py Extension "$TMP/extension.pem" "$APP/Contents/Resources/mdm-extension.crx")"
  WANT_ID="$(sed -n 's/.*static let extensionID = "\([a-p]*\)".*/\1/p' Sources/IDMMac/IPCServer.swift)"
  echo "extension ID: $GOT_ID"
  if [ "$GOT_ID" != "$WANT_ID" ]; then
    echo "error: EXTENSION_PEM makes ID $GOT_ID but the app expects $WANT_ID" >&2
    exit 1
  fi
fi

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

echo "==> rqbit (BitTorrent engine, Apache-2.0)"
curl -fsSL --retry 3 -o "$TMP/rqbit" https://github.com/ikatson/rqbit/releases/latest/download/rqbit-osx-universal
lipo "$TMP/rqbit" -thin arm64 -output "$APP/Contents/Resources/bin/rqbit" 2>/dev/null || cp "$TMP/rqbit" "$APP/Contents/Resources/bin/rqbit"
chmod +x "$APP/Contents/Resources/bin/rqbit"
"$APP/Contents/Resources/bin/rqbit" --version

echo "==> deno (JavaScript runtime yt-dlp needs for YouTube)"
curl -fsSL --retry 3 -o "$TMP/deno.zip" \
  https://github.com/denoland/deno/releases/latest/download/deno-aarch64-apple-darwin.zip
unzip -oq "$TMP/deno.zip" -d "$TMP/deno"
cp "$TMP/deno/deno" "$APP/Contents/Resources/bin/deno"
chmod +x "$APP/Contents/Resources/bin/deno"

for f in "$APP"/Contents/Resources/bin/*; do
  echo "    $(basename "$f"): $(lipo -archs "$f" 2>/dev/null || echo '?')"
done

if [ -n "${SIGN_ID:-}" ]; then
  echo "==> Signing with: $SIGN_ID"
  CS=(codesign --force --sign "$SIGN_ID" --options runtime --timestamp)
else
  echo "==> Ad-hoc signing"
  CS=(codesign --force --sign -)
fi
# Inner code first, the app last; no --deep.
for f in "$APP"/Contents/Resources/bin/*; do
  case "$(basename "$f")" in
    yt-dlp|deno) "${CS[@]}" --entitlements Packaging/helper.entitlements "$f" ;;
    *) if [ -n "${SIGN_ID:-}" ]; then "${CS[@]}" "$f"; else codesign --verify "$f" 2>/dev/null || "${CS[@]}" "$f"; fi ;;
  esac
done
"${CS[@]}" "$APP/Contents/MacOS/IDMMacHost"
"${CS[@]}" --entitlements Safari/entitlements.plist "$APPEX"
"${CS[@]}" --entitlements Packaging/app.entitlements "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

if [ -n "${SIGN_ID:-}" ] && [ -n "${NOTARY_APPLE_ID:-}" ]; then
  echo "==> Notarizing the app (this waits for Apple, usually a few minutes)"
  notarize() {
    local out id status
    out="$(xcrun notarytool submit "$1" --apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" \
          --team-id "$NOTARY_TEAM_ID" --wait --timeout 40m --output-format json)" || true
    echo "$out"
    id="$(echo "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"
    status="$(echo "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' 2>/dev/null || true)"
    if [ "$status" != "Accepted" ]; then
      [ -n "$id" ] && xcrun notarytool log "$id" --apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$NOTARY_TEAM_ID" || true
      echo "error: notarization of $1 ended with status '$status'" >&2
      exit 1
    fi
  }
  # Stapling asks Apple's CloudKit for the ticket; the runner's connection to it drops now and then
  # ("network connection was lost", error 68) although notarization was accepted. Try a few times.
  staple() {
    for i in 1 2 3 4 5; do
      xcrun stapler staple "$1" && return 0
      echo "staple attempt $i of $1 failed, retrying" >&2
      sleep $((i * 10))
    done
    return 1
  }
  ditto -c -k --keepParent "$APP" "$TMP/MDM.zip"
  # stapler validate asks Apple's CloudKit too, and that connection drops now and then.
  validate() {
    for i in 1 2 3 4 5; do
      xcrun stapler validate "$1" && return 0
      echo "validate attempt $i of $1 failed, retrying" >&2
      sleep $((i * 10))
    done
    return 1
  }

  notarize "$TMP/MDM.zip"
  staple "$APP"
  validate "$APP"
fi

echo "==> DMG"
STAGE="$TMP/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp Packaging/BENIOKU.txt "$STAGE/BENİ OKU.txt"
hdiutil create -volname "MDM" -srcfolder "$STAGE" -ov -format UDZO "dist/MDM.dmg"
[ -n "${SIGN_ID:-}" ] && codesign --force --sign "$SIGN_ID" --timestamp dist/MDM.dmg
echo "==> PKG (double-click installer: puts MDM in Applications, no drag and no second \"Open Anyway\")"
PKGROOT="$TMP/pkgroot"
mkdir -p "$PKGROOT/Applications" "$TMP/pkgscripts"
cp -R "$APP" "$PKGROOT/Applications/"
cat > "$TMP/pkgscripts/postinstall" <<'EOS'
#!/bin/sh
# Files the installer writes carry no quarantine flag; make sure of it, then open MDM for the person who installed it.
/usr/bin/xattr -dr com.apple.quarantine /Applications/MDM.app 2>/dev/null
U="$(/usr/bin/stat -f%Su /dev/console)"
if [ -n "$U" ] && [ "$U" != "root" ]; then
  /bin/launchctl asuser "$(/usr/bin/id -u "$U")" /usr/bin/sudo -u "$U" /usr/bin/open /Applications/MDM.app || true
fi
exit 0
EOS
chmod +x "$TMP/pkgscripts/postinstall"
pkgbuild --analyze --root "$PKGROOT" "$TMP/components.plist" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool false "$TMP/components.plist"
# Build unsigned, then sign with productsign: pkgbuild --sign hung on the CI keychain.
# A signing prompt nobody can click would hang forever, so each step fails after a few minutes.
pkgbuild --root "$PKGROOT" --component-plist "$TMP/components.plist" --scripts "$TMP/pkgscripts" \
  --identifier com.savascitaner.idmmac.pkg --version "$VERSION" --install-location / "$TMP/MDM-unsigned.pkg"
if [ -n "${INSTALLER_ID:-}" ]; then
  echo "==> Signing the installer: $INSTALLER_ID"
  perl -e 'alarm shift; exec @ARGV' 180 productsign --sign "$INSTALLER_ID" ${KEYCHAIN:+--keychain "$KEYCHAIN"} \
    "$TMP/MDM-unsigned.pkg" dist/MDM.pkg
else
  cp "$TMP/MDM-unsigned.pkg" dist/MDM.pkg
fi
pkgutil --payload-files dist/MDM.pkg | grep -q "Applications/MDM.app/Contents/MacOS/IDMMac"
if [ -n "${SIGN_ID:-}" ] && [ -z "${INSTALLER_ID:-}" ]; then
  echo "note: no Developer ID Installer certificate, so MDM.pkg is not published (an unsigned .pkg would still show a warning)"
  rm -f dist/MDM.pkg
elif [ -n "${INSTALLER_ID:-}" ] && [ -n "${NOTARY_APPLE_ID:-}" ]; then
  echo "==> Notarizing the installer"
  notarize dist/MDM.pkg
  staple dist/MDM.pkg
fi
echo "==> dist/MDM.pkg"
echo "==> dist/MDM.dmg"
