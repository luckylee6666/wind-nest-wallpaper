#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$PROJECT_DIR/dist/风巢.app"

REQUIRED_VARIABLES=(
  APPLE_CERTIFICATE_P12
  APPLE_CERTIFICATE_PASSWORD
  APPLE_ID
  APPLE_TEAM_ID
  APPLE_APP_SPECIFIC_PASSWORD
)

for VARIABLE_NAME in "${REQUIRED_VARIABLES[@]}"; do
  if [[ -z "${(P)VARIABLE_NAME:-}" ]]; then
    echo "缺少签名或公证变量：$VARIABLE_NAME" >&2
    exit 1
  fi
done

if [[ ! -d "$APP_DIR" ]]; then
  echo "未找到 $APP_DIR，请先运行 scripts/build.sh" >&2
  exit 1
fi

TEMP_DIR="$(mktemp -d)"
KEYCHAIN_PATH="$TEMP_DIR/WindNest.keychain-db"
KEYCHAIN_PASSWORD="$(uuidgen)"
CERTIFICATE_PATH="$TEMP_DIR/developer-id.p12"
NOTARY_ARCHIVE="$TEMP_DIR/Wind-Nest-notary.zip"

cleanup() {
  security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT INT TERM

print -rn -- "$APPLE_CERTIFICATE_P12" | base64 -D > "$CERTIFICATE_PATH"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$CERTIFICATE_PATH" \
  -k "$KEYCHAIN_PATH" \
  -P "$APPLE_CERTIFICATE_PASSWORD" \
  -T /usr/bin/codesign
security set-key-partition-list \
  -S apple-tool:,apple: \
  -s \
  -k "$KEYCHAIN_PASSWORD" \
  "$KEYCHAIN_PATH"

SIGNING_IDENTITY="${APPLE_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(
    security find-identity -v -p codesigning "$KEYCHAIN_PATH" |
      awk -F'"' '/Developer ID Application:/{print $2; exit}'
  )"
fi

if [[ -z "$SIGNING_IDENTITY" ]]; then
  echo "证书中没有找到 Developer ID Application 签名身份" >&2
  exit 1
fi

codesign \
  --force \
  --options runtime \
  --timestamp \
  --entitlements "$PROJECT_DIR/Entitlements.plist" \
  --keychain "$KEYCHAIN_PATH" \
  --sign "$SIGNING_IDENTITY" \
  "$APP_DIR"

codesign --verify --deep --strict --verbose=2 "$APP_DIR"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$NOTARY_ARCHIVE"

xcrun notarytool submit "$NOTARY_ARCHIVE" \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_APP_SPECIFIC_PASSWORD" \
  --wait

xcrun stapler staple "$APP_DIR"
xcrun stapler validate "$APP_DIR"
spctl --assess --type execute --verbose=2 "$APP_DIR"
