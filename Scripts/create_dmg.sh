#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Rainbar"
VOLUME_NAME="Rainbar"
APP_PATH="${1:-$ROOT_DIR/build/$APP_NAME.app}"
OUTPUT_DMG="${2:-$ROOT_DIR/build/$APP_NAME.dmg}"
BACKGROUND_PATH="$ROOT_DIR/Resources/DMG/background.tiff"
STAGING_DIR="$ROOT_DIR/build/dmg-staging"
RW_DMG="$ROOT_DIR/build/$APP_NAME-rw.dmg"
MOUNT_DIR="$ROOT_DIR/build/dmg-mount"
MOUNTED=0

cleanup() {
    if [[ "$MOUNTED" == "1" ]]; then
        hdiutil detach "$MOUNT_DIR" -quiet || true
    fi
    rm -rf "$STAGING_DIR" "$RW_DMG" "$MOUNT_DIR"
}
trap cleanup EXIT

if [[ ! -d "$APP_PATH" ]]; then
    echo "Missing app bundle: $APP_PATH" >&2
    exit 1
fi

if [[ ! -f "$BACKGROUND_PATH" ]]; then
    echo "Missing DMG background: $BACKGROUND_PATH" >&2
    exit 1
fi

rm -rf "$STAGING_DIR" "$RW_DMG" "$OUTPUT_DMG" "$MOUNT_DIR"
mkdir -p "$STAGING_DIR/.background" "$MOUNT_DIR"

ditto "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"
cp "$BACKGROUND_PATH" "$STAGING_DIR/.background/background.tiff"

hdiutil create \
    -quiet \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -format UDRW \
    -fs HFS+ \
    "$RW_DMG"

hdiutil attach \
    -quiet \
    -readwrite \
    -noverify \
    -noautoopen \
    -mountpoint "$MOUNT_DIR" \
    "$RW_DMG"
MOUNTED=1

chflags hidden "$MOUNT_DIR/.background" || true
SetFile -a V "$MOUNT_DIR/.background" 2>/dev/null || true

osascript - "$MOUNT_DIR" <<'APPLESCRIPT'
on run argv
    set mountPath to item 1 of argv
    set mountedFolder to POSIX file mountPath as alias
    set backgroundFile to POSIX file (mountPath & "/.background/background.tiff") as alias

    tell application "Finder"
        open mountedFolder
        set dmgWindow to container window of mountedFolder
        set current view of dmgWindow to icon view
        set toolbar visible of dmgWindow to false
        set statusbar visible of dmgWindow to false
        set bounds of dmgWindow to {100, 100, 760, 500}

        set viewOptions to icon view options of dmgWindow
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set background picture of viewOptions to backgroundFile

        set position of item "Rainbar.app" of mountedFolder to {180, 200}
        set position of item "Applications" of mountedFolder to {480, 200}

        close dmgWindow
        open mountedFolder
        update mountedFolder without registering applications
        delay 1
    end tell
end run
APPLESCRIPT

sync
sleep 1
hdiutil detach "$MOUNT_DIR" -quiet
MOUNTED=0

hdiutil convert \
    "$RW_DMG" \
    -quiet \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$OUTPUT_DMG"

echo "$OUTPUT_DMG"
