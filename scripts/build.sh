#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$PROJECT_DIR/dist/风巢.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
CACHE_DIR="$PROJECT_DIR/.build-cache"
BIN_DIR="$CACHE_DIR/bin"
APP_VERSION="${WIND_NEST_VERSION:-$(node -p "require('$PROJECT_DIR/package.json').version")}"
BUILD_NUMBER="${WIND_NEST_BUILD_NUMBER:-1}"
TARGET_ARCHS="${WIND_NEST_ARCHS:-arm64 x86_64}"

if [[ ! "$APP_VERSION" =~ '^[0-9]+(\.[0-9]+){0,2}$' ]]; then
  echo "WIND_NEST_VERSION 必须是数字版本号，例如 2.0.0" >&2
  exit 1
fi

if [[ ! "$BUILD_NUMBER" =~ '^[0-9]+(\.[0-9]+){0,2}$' ]]; then
  echo "WIND_NEST_BUILD_NUMBER 必须是数字构建号，例如 42" >&2
  exit 1
fi

npm --prefix "$PROJECT_DIR" run build:web

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$CACHE_DIR" "$BIN_DIR"

typeset -a ARCHS BUILT_BINARIES
ARCHS=(${=TARGET_ARCHS})
BUILT_BINARIES=()

for ARCH in "${ARCHS[@]}"; do
  case "$ARCH" in
    arm64|x86_64) ;;
    *)
      echo "不支持的架构：$ARCH" >&2
      exit 1
      ;;
  esac

  ARCH_BINARY="$BIN_DIR/WindNest-$ARCH"
  xcrun swiftc \
    "$PROJECT_DIR/Sources/main.swift" \
    -o "$ARCH_BINARY" \
    -target "$ARCH-apple-macosx13.0" \
    -module-cache-path "$CACHE_DIR/$ARCH" \
    -framework Cocoa \
    -framework AVFoundation \
    -framework CoreGraphics \
    -framework Vision \
    -framework WebKit \
    -O
  BUILT_BINARIES+=("$ARCH_BINARY")
done

if (( ${#BUILT_BINARIES[@]} == 1 )); then
  cp "${BUILT_BINARIES[1]}" "$MACOS_DIR/WindNest"
else
  xcrun lipo -create "${BUILT_BINARIES[@]}" -output "$MACOS_DIR/WindNest"
fi

cp "$PROJECT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleShortVersionString $APP_VERSION" \
  "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleVersion $BUILD_NUMBER" \
  "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/Resources/index.html" "$RESOURCES_DIR/index.html"
cp "$PROJECT_DIR/Resources/style.css" "$RESOURCES_DIR/style.css"
cp "$PROJECT_DIR/Resources/app.js" "$RESOURCES_DIR/app.js"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
cp "$PROJECT_DIR/LICENSE" "$RESOURCES_DIR/LICENSE.txt"
cp \
  "$PROJECT_DIR/THIRD_PARTY_NOTICES.txt" \
  "$RESOURCES_DIR/THIRD_PARTY_NOTICES.txt"

codesign \
  --force \
  --deep \
  --options runtime \
  --entitlements "$PROJECT_DIR/Entitlements.plist" \
  --sign - \
  "$APP_DIR"

file "$MACOS_DIR/WindNest"
echo "$APP_DIR"
