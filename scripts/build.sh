#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$PROJECT_DIR/dist/风巢.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
CACHE_DIR="$PROJECT_DIR/.build-cache"

npm --prefix "$PROJECT_DIR" run build:web

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$CACHE_DIR"

xcrun swiftc \
  "$PROJECT_DIR/Sources/main.swift" \
  -o "$MACOS_DIR/WindNest" \
  -module-cache-path "$CACHE_DIR" \
  -framework Cocoa \
  -framework AVFoundation \
  -framework CoreGraphics \
  -framework Vision \
  -framework WebKit \
  -O

cp "$PROJECT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/Resources/index.html" "$RESOURCES_DIR/index.html"
cp "$PROJECT_DIR/Resources/style.css" "$RESOURCES_DIR/style.css"
cp "$PROJECT_DIR/Resources/app.js" "$RESOURCES_DIR/app.js"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
mkdir -p "$RESOURCES_DIR/assets"
cp \
  "$PROJECT_DIR/Resources/assets/wind-nest-fan.glb" \
  "$RESOURCES_DIR/assets/wind-nest-fan.glb"

codesign \
  --force \
  --deep \
  --options runtime \
  --entitlements "$PROJECT_DIR/Entitlements.plist" \
  --sign - \
  "$APP_DIR"

echo "$APP_DIR"
