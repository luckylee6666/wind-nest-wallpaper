#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$PROJECT_DIR/dist/风巢.app"
ARCHIVE_NAME="${WIND_NEST_ARCHIVE_NAME:-Wind-Nest-macOS-universal.zip}"
ARCHIVE_PATH="$PROJECT_DIR/dist/$ARCHIVE_NAME"
CHECKSUM_PATH="$ARCHIVE_PATH.sha256"

if [[ ! -d "$APP_DIR" ]]; then
  echo "未找到 $APP_DIR，请先运行 scripts/build.sh" >&2
  exit 1
fi

rm -f "$ARCHIVE_PATH" "$CHECKSUM_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ARCHIVE_PATH"

(
  cd "$PROJECT_DIR/dist"
  shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256"
)

echo "$ARCHIVE_PATH"
echo "$CHECKSUM_PATH"
