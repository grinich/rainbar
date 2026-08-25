#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Rainbar"
APP_DIR="$ROOT_DIR/build/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
MODULE_CACHE_DIR="$ROOT_DIR/.build/clang-module-cache"

cd "$ROOT_DIR"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"
mkdir -p "$MODULE_CACHE_DIR"

SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --find clang)"

"$CLANG" \
    -fobjc-arc \
    -Wall \
    -Wextra \
    -Wno-deprecated-declarations \
    -mmacosx-version-min=13.0 \
    -isysroot "$SDKROOT" \
    -fmodules \
    -fmodules-cache-path="$MODULE_CACHE_DIR" \
    -framework AppKit \
    -framework AVFoundation \
    "$ROOT_DIR/Sources/Rainbar/main.m" \
    -o "$MACOS_DIR/$APP_NAME"

cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
cp "$ROOT_DIR/Resources/AudioCredits.txt" "$RESOURCES_DIR/AudioCredits.txt"
mkdir -p "$RESOURCES_DIR/Audio"
cp "$ROOT_DIR"/Resources/Audio/*.mp3 "$RESOURCES_DIR/Audio/"
chmod +x "$MACOS_DIR/$APP_NAME"

echo "$APP_DIR"
