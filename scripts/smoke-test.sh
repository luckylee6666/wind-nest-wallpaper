#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EXECUTABLE="$PROJECT_DIR/dist/风巢.app/Contents/MacOS/WindNest"
LOG_FILE="$(mktemp)"
APP_PID=""

cleanup() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" >/dev/null 2>&1; then
    kill "$APP_PID" >/dev/null 2>&1 || true
  fi
  rm -f "$LOG_FILE"
}
trap cleanup EXIT INT TERM

if [[ ! -x "$EXECUTABLE" ]]; then
  echo "未找到可执行应用，请先运行 scripts/build.sh" >&2
  exit 1
fi

WIND_NEST_QA=1 "$EXECUTABLE" >"$LOG_FILE" 2>&1 &
APP_PID=$!

for _ in {1..25}; do
  if ! kill -0 "$APP_PID" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if kill -0 "$APP_PID" >/dev/null 2>&1; then
  echo "QA 冒烟测试超时" >&2
  sed -n '1,240p' "$LOG_FILE" >&2
  exit 1
fi

EXIT_STATUS=0
wait "$APP_PID" || EXIT_STATUS=$?
APP_PID=""
if (( EXIT_STATUS != 0 )); then
  echo "风巢以状态 $EXIT_STATUS 异常退出" >&2
  sed -n '1,240p' "$LOG_FILE" >&2
  exit 1
fi

if grep -Eq 'WIND_NEST_QA_.*ERROR' "$LOG_FILE"; then
  echo "QA 冒烟测试报告错误" >&2
  sed -n '1,240p' "$LOG_FILE" >&2
  exit 1
fi

if ! node "$PROJECT_DIR/scripts/verify-qa-log.mjs" "$LOG_FILE"; then
  echo "QA 冒烟测试结果断言失败" >&2
  sed -n '1,240p' "$LOG_FILE" >&2
  exit 1
fi

REQUIRED_MARKERS=(
  WIND_NEST_QA_STATE
  WIND_NEST_QA_OVERLAY
  WIND_NEST_QA_MOTION
  WIND_NEST_QA_SPEED_1
  WIND_NEST_QA_SPEED_2
  WIND_NEST_QA_SPEED_3
  WIND_NEST_QA_GESTURE_LEFT
  WIND_NEST_QA_GESTURE_RIGHT
  WIND_NEST_QA_FINGERS_1
  WIND_NEST_QA_FINGERS_2
  WIND_NEST_QA_FINGERS_3
  WIND_NEST_QA_FIST
  WIND_NEST_QA_OPEN
  WIND_NEST_QA_FINAL
  WIND_NEST_QA_CANVAS
  WIND_NEST_QA_SNAPSHOT
  WIND_NEST_QA_COMPLETE
)

for MARKER in "${REQUIRED_MARKERS[@]}"; do
  if ! grep -Fq "$MARKER" "$LOG_FILE"; then
    echo "QA 冒烟测试缺少结果：$MARKER" >&2
    sed -n '1,240p' "$LOG_FILE" >&2
    exit 1
  fi
done

echo "风巢 QA 冒烟测试通过"
