#!/bin/zsh
# Builds "WE KeySwitcher.app", signs it and installs it into /Applications.
# Usage: tools/build_app.sh [--no-install]
# SIGN_IDENTITY overrides the certificate name (see tools/make_cert.sh);
# without that certificate the app is signed ad hoc, and macOS will ask for
# the permissions again after every rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."
IDENTITY="${SIGN_IDENTITY:-WE KeySwitcher Local Signing}"
BUNDLE_ID=sk.whiteeagles.keyswitcher
# The bundle is assembled outside the project folder: inside iCloud Drive the
# file provider keeps adding attributes that codesign rejects.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/WE KeySwitcher.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
mkdir -p build

swift build -c release --arch arm64 --product KeySwitcher
BIN="$(swift build -c release --arch arm64 --show-bin-path)/KeySwitcher"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/data"
cp "$BIN" "$APP/Contents/MacOS/KeySwitcher"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/data/*.dict Resources/data/*.ngram "$APP/Contents/Resources/data/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

xattr -cr "$APP"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" --timestamp=none "$APP"
else
  echo "warning: certificate \"$IDENTITY\" not found, signing ad hoc (run tools/make_cert.sh)"
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi
codesign --verify --strict "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated || true
ZIP="build/WE-KeySwitcher-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "packed $ZIP"

[[ "${1:-}" == "--no-install" ]] && exit 0

DEST="/Applications/WE KeySwitcher.app"
if pgrep -x KeySwitcher >/dev/null; then
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  sleep 1
  pkill -x KeySwitcher || true
fi
# Replace the files inside the existing bundle rather than the bundle itself.
mkdir -p "$DEST"
rsync -a --delete "$APP/" "$DEST/"
codesign --verify --strict "$DEST"
open "$DEST"
echo "installed $DEST"
