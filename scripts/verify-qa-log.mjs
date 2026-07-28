import { readFile } from "node:fs/promises";

const logPath = process.argv[2];
if (!logPath) {
  throw new Error("用法：node scripts/verify-qa-log.mjs <QA 日志>");
}

const log = await readFile(logPath, "utf8");
const lines = log.split(/\r?\n/);

function result(name) {
  const prefix = `WIND_NEST_QA_${name} `;
  const line = lines.find((candidate) => candidate.startsWith(prefix));
  if (!line) {
    throw new Error(`缺少 QA 结果：${name}`);
  }
  try {
    return JSON.parse(line.slice(prefix.length));
  } catch (error) {
    throw new Error(`QA 结果 ${name} 不是有效 JSON：${error.message}`);
  }
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function assertNear(actual, expected, tolerance, label) {
  assert(
    Number.isFinite(actual) && Math.abs(actual - expected) <= tolerance,
    `${label} 应接近 ${expected}，实际为 ${actual}`,
  );
}

const initial = result("STATE");
assert(initial.title === "风巢｜透明桌面风扇", "页面标题不正确");
assert(initial.canvasCount === 1, "WebGL 画布数量不正确");

const overlay = result("OVERLAY");
assert(overlay.visible === true, "手部骨架没有显示");
assert(overlay.lines === 24, `手部骨架连线应为 24，实际为 ${overlay.lines}`);
assert(overlay.points === 21, `手部骨架点位应为 21，实际为 ${overlay.points}`);

const motion = result("MOTION");
assert(Number.isFinite(motion.rotor), "叶片动画节点未载入");
assert(motion.rotorVelocity > 0, "叶片没有旋转");

for (const speed of [1, 2, 3]) {
  const frame = result(`SPEED_${speed}`);
  assert(frame.speed === speed, `${speed} 档没有切换成功`);
  assert(frame.power === true, `${speed} 档切换后风扇没有启动`);
  assertNear(frame.actualSpeed, speed, 0.5, `${speed} 档实际速度`);
}

const left = result("GESTURE_LEFT");
assert(left.gestureStatus === "tracking", "左侧手势没有进入跟随状态");
assertNear(left.gestureX, 0.12, 0.03, "左侧手势横坐标");
assert(left.yaw < -0.3, `左侧手势转向错误：${left.yaw}`);

const right = result("GESTURE_RIGHT");
assert(right.gestureStatus === "tracking", "右侧手势没有进入跟随状态");
assertNear(right.gestureX, 0.88, 0.03, "右侧手势横坐标");
assert(right.yaw > 0.3, `右侧手势转向错误：${right.yaw}`);

for (const fingerCount of [1, 2, 3]) {
  const frame = result(`FINGERS_${fingerCount}`);
  assert(
    frame.gestureFingerCount === fingerCount,
    `${fingerCount} 指识别结果不正确`,
  );
  assert(frame.speed === fingerCount, `${fingerCount} 指没有切换对应档位`);
  assert(
    frame.gestureCommand === `speed-${fingerCount}`,
    `${fingerCount} 指手势命令不正确`,
  );
  assert(frame.power === true, `${fingerCount} 指切档后风扇没有启动`);
}

const fist = result("FIST");
assert(fist.gesturePose === "fist", "握拳姿态没有识别");
assert(fist.gestureCommand === "fist", "握拳命令没有锁定");
assert(fist.power === false, "握拳没有关闭风扇");

const open = result("OPEN");
assert(open.gesturePose === "open", "张开手掌姿态没有识别");
assert(open.gestureCommand === "open", "张开手掌命令没有锁定");
assert(open.power === true, "张开手掌没有启动风扇");

const finalState = result("FINAL");
assert(finalState.loading === "loading done", "三维模型没有完成载入");
assert(Number.isFinite(finalState.frame?.rotor), "最终叶片状态无效");
assert(Number.isFinite(finalState.frame?.coldAir), "冷风动画状态无效");

console.log("QA 状态语义校验通过");
