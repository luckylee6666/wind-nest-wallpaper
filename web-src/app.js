import * as THREE from "three";
import { GLTFLoader } from "three/addons/loaders/GLTFLoader.js";
import { RoomEnvironment } from "three/addons/environments/RoomEnvironment.js";
import fanAssetUrl from "../Resources/assets/wind-nest-fan.glb";

const stage = document.querySelector("#fanStage");
const loading = document.querySelector("#loading");
const statusText = document.querySelector("#statusText");
const statusDot = document.querySelector("#statusDot");
const powerButton = document.querySelector("#powerButton");
const oscillateButton = document.querySelector("#oscillateButton");
const gestureButton = document.querySelector("#gestureButton");
const gestureLabel = document.querySelector("#gestureLabel");
const cameraPreviewButton = document.querySelector("#cameraPreviewButton");
const cameraPreviewLabel = document.querySelector("#cameraPreviewLabel");
const gestureToast = document.querySelector("#gestureToast");
const gestureSettingsButton = document.querySelector("#gestureSettingsButton");
const gestureToastClose = document.querySelector("#gestureToastClose");
const dragHint = document.querySelector("#dragHint");
const controlDock = document.querySelector(".control-dock");
const quitButton = document.querySelector("#quitButton");
const cameraGestureValue = document.querySelector("#cameraGestureValue");
const gestureHoldProgress = document.querySelector("#gestureHoldProgress");
const handSkeleton = document.querySelector("#handSkeleton");
const handBounds = document.querySelector("#handBounds");
const speedButtons = [...document.querySelectorAll("[data-speed]")];

const SVG_NS = "http://www.w3.org/2000/svg";
const handSegments = [
  ["wrist", "thumbCMC"],
  ["thumbCMC", "thumbMP"],
  ["thumbMP", "thumbIP"],
  ["thumbIP", "thumbTip"],
  ["wrist", "indexMCP"],
  ["indexMCP", "indexPIP"],
  ["indexPIP", "indexDIP"],
  ["indexDIP", "indexTip"],
  ["wrist", "middleMCP"],
  ["middleMCP", "middlePIP"],
  ["middlePIP", "middleDIP"],
  ["middleDIP", "middleTip"],
  ["wrist", "ringMCP"],
  ["ringMCP", "ringPIP"],
  ["ringPIP", "ringDIP"],
  ["ringDIP", "ringTip"],
  ["wrist", "littleMCP"],
  ["littleMCP", "littlePIP"],
  ["littlePIP", "littleDIP"],
  ["littleDIP", "littleTip"],
  ["thumbCMC", "indexMCP"],
  ["indexMCP", "middleMCP"],
  ["middleMCP", "ringMCP"],
  ["ringMCP", "littleMCP"],
];
const handJointNames = [
  "wrist",
  "thumbCMC",
  "thumbMP",
  "thumbIP",
  "thumbTip",
  "indexMCP",
  "indexPIP",
  "indexDIP",
  "indexTip",
  "middleMCP",
  "middlePIP",
  "middleDIP",
  "middleTip",
  "ringMCP",
  "ringPIP",
  "ringDIP",
  "ringTip",
  "littleMCP",
  "littlePIP",
  "littleDIP",
  "littleTip",
];
const skeletonLines = handSegments.map(() => {
  const line = document.createElementNS(SVG_NS, "line");
  handSkeleton.append(line);
  return line;
});
const skeletonPoints = new Map(
  handJointNames.map((name) => {
    const circle = document.createElementNS(SVG_NS, "circle");
    circle.setAttribute("r", "5.2");
    handSkeleton.append(circle);
    return [name, circle];
  }),
);

const renderer = new THREE.WebGLRenderer({
  antialias: true,
  alpha: true,
  premultipliedAlpha: true,
  preserveDrawingBuffer: Boolean(window.__WIND_NEST_QA__),
});
const drawingBufferSize = new THREE.Vector2();
renderer.setClearColor(0x000000, 0);
renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.toneMappingExposure = 0.72;
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;
stage.append(renderer.domElement);

const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(32.4, 1, 0.1, 100);
camera.position.set(4.8, 3.35, 7.7);
camera.lookAt(0, 1.55, 0);
const cameraForward = new THREE.Vector3();
const cameraRight = new THREE.Vector3();
camera.getWorldDirection(cameraForward);
cameraRight.crossVectors(cameraForward, camera.up).normalize();

const pmrem = new THREE.PMREMGenerator(renderer);
const roomEnvironment = new RoomEnvironment();
const environmentTarget = pmrem.fromScene(roomEnvironment, 0.035);
scene.environment = environmentTarget.texture;
roomEnvironment.dispose();
pmrem.dispose();

const hemisphere = new THREE.HemisphereLight(0xa8d3d8, 0x020706, 0.48);
scene.add(hemisphere);

const moonKey = new THREE.DirectionalLight(0xa9d8f2, 1.6);
moonKey.position.set(-3.8, 5.2, 4.5);
scene.add(moonKey);

const warmRim = new THREE.DirectionalLight(0xffa573, 1.75);
warmRim.position.set(4.2, 3.8, -0.8);
scene.add(warmRim);

const softFill = new THREE.PointLight(0x9edfd3, 3.2, 12, 1.6);
softFill.position.set(0, 1.8, 3.2);
scene.add(softFill);

const state = {
  loaded: false,
  power: true,
  speed: 2,
  actualSpeed: 0,
  rotorAngle: 0,
  rotorVelocity: 0,
  oscillate: true,
  cursorFollowing: false,
  gestureEnabled: false,
  cameraPreviewVisible: true,
  gestureStatus: "off",
  gestureX: 0.5,
  gestureZone: "center",
  gesturePose: "neutral",
  gestureFingerCount: null,
  gestureCommand: "neutral",
  gestureCommandSince: 0,
  gestureCommandLatched: "neutral",
  gestureToastDismissed: false,
  pointerX: 0.5,
  pointerY: 0.5,
  lastPointerX: null,
  lastPointerY: null,
  elapsed: 0,
  yaw: 0.12,
  targetYaw: 0.12,
  tilt: 0,
  targetTilt: 0,
  dragging: false,
  dragStartX: 0,
  dragStartY: 0,
  lastX: 0,
  lastY: 0,
  dragDistance: 0,
  uiTimer: 0,
  uiInteracting: false,
};

let model = null;
const modelHomePosition = new THREE.Vector3();
const modelLayoutTarget = new THREE.Vector3();
let bladeRotor = null;
let yawPivot = null;
let tiltPivot = null;
let powerLedMaterial = null;
let coldAirEffect = null;
let yawBase = 0;
let rotorBase = 0;
let tiltBase = 0;
const bladeMaterials = new Set();
const approvedFinish = {
  "Moon Enamel": { color: 0x203a35, metalness: 0.62, roughness: 0.3 },
  "Edge Enamel": { color: 0x57736c, metalness: 0.58, roughness: 0.25 },
  "Brushed Chrome": { color: 0x5b706b, metalness: 0.92, roughness: 0.21 },
  "Dark Chrome": { color: 0x1b322d, metalness: 0.9, roughness: 0.23 },
  "Motor Housing": { color: 0x152823, metalness: 0.7, roughness: 0.27 },
  "Celadon Blades": { color: 0x3e8176, metalness: 0.44, roughness: 0.25 },
};

const clamp = (value, min, max) => Math.max(min, Math.min(max, value));
const damp = (current, target, lambda, delta) =>
  THREE.MathUtils.lerp(current, target, 1 - Math.exp(-lambda * delta));

function overlayPoint(point) {
  if (
    !point ||
    !Number.isFinite(point.x) ||
    !Number.isFinite(point.y)
  ) {
    return null;
  }
  return {
    x: clamp(point.x, 0, 1) * 1000,
    y: clamp(point.y, 0, 1) * 750,
  };
}

window.windNestGestureOverlay = (payload) => {
  const points = payload?.points;
  if (!points || Object.keys(points).length < 2) {
    document.body.classList.remove("gesture-hand-visible");
    handBounds.removeAttribute("x");
    handBounds.removeAttribute("y");
    handBounds.removeAttribute("width");
    handBounds.removeAttribute("height");
    return;
  }

  const visiblePoints = [];
  handSegments.forEach(([startName, endName], index) => {
    const start = overlayPoint(points[startName]);
    const end = overlayPoint(points[endName]);
    const line = skeletonLines[index];
    if (!start || !end) {
      line.style.display = "none";
      return;
    }
    line.style.display = "";
    line.setAttribute("x1", start.x);
    line.setAttribute("y1", start.y);
    line.setAttribute("x2", end.x);
    line.setAttribute("y2", end.y);
  });

  skeletonPoints.forEach((circle, name) => {
    const point = overlayPoint(points[name]);
    if (!point) {
      circle.style.display = "none";
      return;
    }
    circle.style.display = "";
    circle.setAttribute("cx", point.x);
    circle.setAttribute("cy", point.y);
    visiblePoints.push(point);
  });

  if (visiblePoints.length >= 2) {
    const xs = visiblePoints.map((point) => point.x);
    const ys = visiblePoints.map((point) => point.y);
    const paddingX = 34;
    const paddingY = 26;
    const minX = Math.max(12, Math.min(...xs) - paddingX);
    const maxX = Math.min(988, Math.max(...xs) + paddingX);
    const minY = Math.max(12, Math.min(...ys) - paddingY);
    const maxY = Math.min(738, Math.max(...ys) + paddingY);
    handBounds.setAttribute("x", minX);
    handBounds.setAttribute("y", minY);
    handBounds.setAttribute("width", Math.max(1, maxX - minX));
    handBounds.setAttribute("height", Math.max(1, maxY - minY));
    handBounds.setAttribute("rx", "28");
    document.body.classList.add("gesture-hand-visible");
  } else {
    document.body.classList.remove("gesture-hand-visible");
  }
};

function createColdAirEffect(parent) {
  const particleCount = 580;
  const geometry = new THREE.BufferGeometry();
  const positions = new Float32Array(particleCount * 3);
  const phases = new Float32Array(particleCount);
  const radii = new Float32Array(particleCount);
  const angles = new Float32Array(particleCount);
  const characters = new Float32Array(particleCount);

  for (let index = 0; index < particleCount; index += 1) {
    phases[index] = Math.random();
    radii[index] = Math.pow(Math.random(), 1.65);
    angles[index] = Math.random() * Math.PI * 2;
    characters[index] = Math.random();
  }

  geometry.setAttribute("position", new THREE.BufferAttribute(positions, 3));
  geometry.setAttribute("aPhase", new THREE.BufferAttribute(phases, 1));
  geometry.setAttribute("aRadius", new THREE.BufferAttribute(radii, 1));
  geometry.setAttribute("aAngle", new THREE.BufferAttribute(angles, 1));
  geometry.setAttribute(
    "aCharacter",
    new THREE.BufferAttribute(characters, 1),
  );

  const material = new THREE.ShaderMaterial({
    transparent: true,
    depthWrite: false,
    depthTest: false,
    blending: THREE.NormalBlending,
    uniforms: {
      uTime: { value: 0 },
      uIntensity: { value: 0 },
      uSpeed: { value: 0 },
      uResolution: { value: new THREE.Vector2(1, 1) },
    },
    vertexShader: `
      attribute float aPhase;
      attribute float aRadius;
      attribute float aAngle;
      attribute float aCharacter;

      uniform float uTime;
      uniform float uIntensity;
      uniform float uSpeed;

      varying float vAlpha;
      varying float vCoolness;
      varying float vMist;

      void main() {
        float travel = fract(
          aPhase + uTime * (0.085 + uSpeed * 0.026)
        );
        float envelope = sin(travel * 3.14159265);
        float farFade = 1.0 - smoothstep(0.72, 1.0, travel);
        float spread = aRadius * (0.14 + travel * 1.42);
        float curl = sin(
          aAngle * 2.0 + uTime * 1.15 + travel * 8.0
        ) * 0.045 * travel;

        vec3 transformed = vec3(
          cos(aAngle) * spread + curl,
          sin(aAngle) * spread * 0.72 +
            cos(uTime * 0.8 + aPhase * 11.0) * 0.025,
          0.42 + travel * 3.28
        );

        vec4 mvPosition = modelViewMatrix * vec4(transformed, 1.0);
        float pointScale = 360.0 / max(1.0, -mvPosition.z);
        float mist = smoothstep(0.36, 1.0, aCharacter);
        gl_PointSize = clamp(
          mix(0.068, 0.36, mist) * pointScale,
          2.8,
          30.0
        );
        gl_Position = projectionMatrix * mvPosition;

        vAlpha = envelope * farFade * uIntensity *
          mix(0.82, 0.52, mist);
        vCoolness = aCharacter;
        vMist = mist;
      }
    `,
    fragmentShader: `
      varying float vAlpha;
      varying float vCoolness;
      varying float vMist;
      uniform vec2 uResolution;

      void main() {
        vec2 center = gl_PointCoord - vec2(0.5);
        float distanceToCenter = length(center) * 2.0;
        float softness = mix(
          1.0 - smoothstep(0.08, 1.0, distanceToCenter),
          exp(-distanceToCenter * distanceToCenter * 2.15),
          vMist
        );
        vec3 iceBlue = mix(
          vec3(0.04, 0.62, 0.82),
          vec3(0.68, 0.94, 0.98),
          max(vCoolness, vMist * 0.76)
        );
        float viewportEdge = min(
          min(gl_FragCoord.x, uResolution.x - gl_FragCoord.x),
          min(gl_FragCoord.y, uResolution.y - gl_FragCoord.y)
        );
        float viewportFade = smoothstep(0.0, 72.0, viewportEdge);
        gl_FragColor = vec4(
          iceBlue,
          softness * vAlpha * mix(1.2, 0.88, vMist) * viewportFade
        );
      }
    `,
  });

  const particles = new THREE.Points(geometry, material);
  particles.name = "Cold Air Mist";
  particles.frustumCulled = false;
  particles.renderOrder = 3;

  const haloMaterial = new THREE.MeshBasicMaterial({
    color: 0x8ee9f5,
    transparent: true,
    opacity: 0,
    depthWrite: false,
    depthTest: false,
    blending: THREE.NormalBlending,
    side: THREE.DoubleSide,
  });
  const halo = new THREE.Mesh(
    new THREE.RingGeometry(0.56, 0.86, 72),
    haloMaterial,
  );
  halo.name = "Cold Air Halo";
  halo.position.z = 0.38;
  halo.renderOrder = 2;

  const group = new THREE.Group();
  group.name = "Cold Air";
  const fogSheets = [];
  for (let index = 0; index < 6; index += 1) {
    const fogMaterial = new THREE.ShaderMaterial({
      transparent: true,
      depthWrite: false,
      depthTest: false,
      side: THREE.DoubleSide,
      blending: THREE.NormalBlending,
      uniforms: {
        uTime: { value: 0 },
        uIntensity: { value: 0 },
        uPhase: { value: Math.random() * 20 },
        uProgress: { value: 0 },
        uResolution: { value: new THREE.Vector2(1, 1) },
      },
      vertexShader: `
        varying vec2 vUv;

        void main() {
          vUv = uv;
          gl_Position = projectionMatrix *
            modelViewMatrix *
            vec4(position, 1.0);
        }
      `,
      fragmentShader: `
        uniform float uTime;
        uniform float uIntensity;
        uniform float uPhase;
        uniform float uProgress;
        uniform vec2 uResolution;

        varying vec2 vUv;

        float hash(vec2 point) {
          return fract(
            sin(dot(point, vec2(127.1, 311.7))) * 43758.5453
          );
        }

        float noise(vec2 point) {
          vec2 cell = floor(point);
          vec2 fraction = fract(point);
          fraction = fraction * fraction * (3.0 - 2.0 * fraction);
          return mix(
            mix(
              hash(cell),
              hash(cell + vec2(1.0, 0.0)),
              fraction.x
            ),
            mix(
              hash(cell + vec2(0.0, 1.0)),
              hash(cell + vec2(1.0, 1.0)),
              fraction.x
            ),
            fraction.y
          );
        }

        float fbm(vec2 point) {
          float value = 0.0;
          float amplitude = 0.56;
          for (int octave = 0; octave < 4; octave += 1) {
            value += amplitude * noise(point);
            point = point * 2.03 + 17.13;
            amplitude *= 0.5;
          }
          return value;
        }

        void main() {
          vec2 center = vUv - vec2(0.5);
          float radius = length(center * vec2(1.0, 1.08));
          float edge = 1.0 - smoothstep(0.14, 0.5, radius);
          vec2 drift = vec2(
            uTime * 0.08 + uPhase,
            -uTime * 0.055 + uPhase * 0.37
          );
          float vapor = fbm(center * 4.8 + drift);
          float ribbon = 0.5 + 0.5 * sin(
            center.x * 15.0 +
            center.y * 8.0 +
            uTime * 0.32 +
            uPhase
          );
          float density = smoothstep(
            0.34,
            0.76,
            vapor * 0.82 + ribbon * 0.18
          );
          float life = sin(uProgress * 3.14159265);
          vec3 color = mix(
            vec3(0.02, 0.56, 0.74),
            vec3(0.28, 0.82, 0.91),
            vapor
          );
          float viewportEdge = min(
            min(gl_FragCoord.x, uResolution.x - gl_FragCoord.x),
            min(gl_FragCoord.y, uResolution.y - gl_FragCoord.y)
          );
          float viewportFade = smoothstep(0.0, 88.0, viewportEdge);
          gl_FragColor = vec4(
            color,
            edge * density * life * uIntensity * 0.48 * viewportFade
          );
        }
      `,
    });
    const sheet = new THREE.Mesh(
      new THREE.PlaneGeometry(2, 2),
      fogMaterial,
    );
    sheet.name = `Cold Air Fog ${index + 1}`;
    sheet.renderOrder = 1;
    fogSheets.push({
      mesh: sheet,
      material: fogMaterial,
      phase: index / 6 + Math.random() * 0.08,
      driftX: (Math.random() - 0.5) * 0.22,
      driftY: (Math.random() - 0.5) * 0.18,
    });
    group.add(sheet);
  }

  const wisps = [];
  for (let index = 0; index < 7; index += 1) {
    const pointCount = 28;
    const wispGeometry = new THREE.BufferGeometry();
    wispGeometry.setAttribute(
      "position",
      new THREE.BufferAttribute(new Float32Array(pointCount * 3), 3),
    );
    const wispMaterial = new THREE.LineBasicMaterial({
      color: index % 2 === 0 ? 0x56cce3 : 0x9beaf2,
      transparent: true,
      opacity: 0,
      depthWrite: false,
      depthTest: false,
      blending: THREE.NormalBlending,
    });
    const wisp = new THREE.Line(wispGeometry, wispMaterial);
    wisp.name = `Cold Air Wisp ${index + 1}`;
    wisp.renderOrder = 2;
    wisps.push({
      line: wisp,
      material: wispMaterial,
      phase: Math.random() * Math.PI * 2,
      offsetX: (Math.random() - 0.5) * 0.64,
      offsetY: (Math.random() - 0.5) * 0.46,
      pointCount,
    });
    group.add(wisp);
  }
  group.add(halo, particles);
  parent.add(group);

  return {
    group,
    halo,
    haloMaterial,
    material,
    fogSheets,
    wisps,
    intensity: 0,
  };
}

function updateColdAir(delta) {
  if (!coldAirEffect) return;

  const targetIntensity = state.power
    ? clamp(0.18 + (state.actualSpeed / 3) * 0.9, 0, 1)
    : 0;
  coldAirEffect.intensity = damp(
    coldAirEffect.intensity,
    targetIntensity,
    state.power ? 2.7 : 4.6,
    delta,
  );

  const intensity = coldAirEffect.intensity;
  coldAirEffect.group.visible = intensity > 0.004;
  coldAirEffect.material.uniforms.uTime.value = state.elapsed;
  coldAirEffect.material.uniforms.uIntensity.value = intensity;
  coldAirEffect.material.uniforms.uSpeed.value = state.actualSpeed;
  coldAirEffect.haloMaterial.opacity =
    intensity * (0.045 + Math.sin(state.elapsed * 2.2) * 0.008);
  const haloPulse = 1 + Math.sin(state.elapsed * 1.8) * 0.018 * intensity;
  coldAirEffect.halo.scale.setScalar(haloPulse);

  coldAirEffect.fogSheets.forEach((fog, fogIndex) => {
    const progress = (
      fog.phase +
      state.elapsed * (0.052 + state.actualSpeed * 0.016)
    ) % 1;
    const spread = 0.58 + progress * 1.5;
    fog.mesh.position.set(
      fog.driftX * (0.35 + progress),
      fog.driftY * (0.35 + progress) +
        Math.sin(state.elapsed * 0.24 + fogIndex) * 0.025,
      0.46 + progress * 3.32,
    );
    fog.mesh.scale.setScalar(spread);
    fog.mesh.rotation.z =
      fogIndex * 0.74 +
      Math.sin(state.elapsed * 0.12 + fogIndex) * 0.16;
    fog.material.uniforms.uTime.value = state.elapsed;
    fog.material.uniforms.uIntensity.value = intensity;
    fog.material.uniforms.uProgress.value = progress;
  });

  coldAirEffect.wisps.forEach((wisp, wispIndex) => {
    const position = wisp.line.geometry.attributes.position;
    for (let pointIndex = 0; pointIndex < wisp.pointCount; pointIndex += 1) {
      const progress = pointIndex / (wisp.pointCount - 1);
      const spread = 0.22 + progress * 0.92;
      const current = pointIndex * 3;
      position.array[current] =
        wisp.offsetX * spread +
        Math.sin(
          progress * 7.2 +
          state.elapsed * (0.5 + state.actualSpeed * 0.08) +
          wisp.phase
        ) * 0.055 * progress;
      position.array[current + 1] =
        wisp.offsetY * spread +
        Math.cos(
          progress * 5.4 -
          state.elapsed * 0.42 +
          wisp.phase * 1.3
        ) * 0.042 * progress;
      position.array[current + 2] = 0.42 + progress * 3.15;
    }
    position.needsUpdate = true;
    wisp.material.opacity =
      intensity *
      (0.135 + (wispIndex % 3) * 0.026) *
      (0.86 + Math.sin(state.elapsed * 0.7 + wisp.phase) * 0.14);
  });
}

function markActivity() {
  document.body.classList.add("ui-visible");
  window.clearTimeout(state.uiTimer);
  state.uiTimer = window.setTimeout(() => {
    if (!state.dragging && !state.uiInteracting) {
      document.body.classList.remove("ui-visible");
    }
  }, 6000);
}

function updateUI() {
  document.body.classList.toggle("power-off", !state.power);
  document.body.classList.toggle("cursor-following", state.cursorFollowing);
  document.body.classList.toggle("gesture-preview-on", state.gestureEnabled);
  document.body.classList.toggle(
    "camera-preview-visible",
    state.cameraPreviewVisible,
  );
  document.body.classList.toggle(
    "gesture-camera-live",
    ["searching", "tracking"].includes(state.gestureStatus),
  );
  statusText.textContent = state.power ? "运行中" : "已关闭";
  statusDot.classList.toggle("off", !state.power);
  powerButton.classList.toggle("active", state.power);
  powerButton.setAttribute("aria-pressed", String(state.power));
  oscillateButton.classList.toggle("active", state.oscillate);
  oscillateButton.setAttribute("aria-pressed", String(state.oscillate));
  gestureButton.dataset.status = state.gestureStatus;
  gestureButton.classList.toggle("active", state.gestureEnabled);
  gestureButton.setAttribute(
    "aria-pressed",
    String(state.gestureEnabled),
  );
  cameraPreviewButton.classList.toggle(
    "active",
    state.cameraPreviewVisible,
  );
  cameraPreviewButton.setAttribute(
    "aria-pressed",
    String(state.cameraPreviewVisible),
  );
  cameraPreviewLabel.textContent = state.cameraPreviewVisible
    ? "画面"
    : "已隐藏";
  const gestureLabels = {
    off: "手势",
    requesting: "等待权限",
    checking: "检查权限",
    prompting: "等待授权",
    starting: "启动相机",
    searching: "寻找手掌",
    tracking: "手势跟随",
    denied: "手势",
    unavailable: "不可用",
  };
  gestureLabel.textContent =
    gestureLabels[state.gestureStatus] ?? gestureLabels.off;
  gestureButton.disabled = state.gestureStatus === "unavailable";

  if (state.gestureStatus === "tracking") {
    if (state.gestureFingerCount !== null) {
      const speedLabels = ["", "一档", "二档", "三档"];
      cameraGestureValue.textContent =
        `${state.gestureFingerCount} 根手指 · ` +
        speedLabels[state.gestureFingerCount];
    } else if (state.gesturePose === "fist") {
      cameraGestureValue.textContent = "握拳 · 关闭";
    } else if (state.gesturePose === "open") {
      cameraGestureValue.textContent = "张开手掌 · 启动";
    } else {
      cameraGestureValue.textContent = "手掌跟随";
    }
  } else if (state.gestureStatus === "searching") {
    cameraGestureValue.textContent = "等待手势";
  } else if (state.gestureEnabled) {
    cameraGestureValue.textContent = "正在启动摄像头";
  } else {
    cameraGestureValue.textContent = "摄像头待机";
  }

  if (state.gestureStatus === "tracking") {
    const zoneLabels = {
      left: "已识别 · 手掌在左侧",
      center: "已识别 · 手掌在中间",
      right: "已识别 · 手掌在右侧",
    };
    if (state.gestureFingerCount !== null) {
      const speedLabels = ["", "一档", "二档", "三档"];
      dragHint.textContent =
        `已识别 · ${state.gestureFingerCount} 根手指 · ` +
        speedLabels[state.gestureFingerCount];
    } else if (state.gesturePose === "fist") {
      dragHint.textContent = state.power
        ? "已识别 · 握拳保持 · 关闭风扇"
        : "已识别 · 握拳 · 风扇已关闭";
    } else if (state.gesturePose === "open" && !state.power) {
      dragHint.textContent = "已识别 · 张开手掌保持 · 启动风扇";
    } else {
      dragHint.textContent =
        `${zoneLabels[state.gestureZone]} · 风扇同步转向`;
    }
  } else if (state.gestureStatus === "searching") {
    dragHint.textContent = "举手 · 1/2/3 指调档 · 握拳关闭";
  } else if (state.gestureStatus === "requesting") {
    dragHint.textContent = "正在等待摄像头权限";
  } else if (state.gestureStatus === "checking") {
    dragHint.textContent = "正在检查摄像头权限";
  } else if (state.gestureStatus === "prompting") {
    dragHint.textContent = "请在系统提示中允许使用摄像头";
  } else if (state.gestureStatus === "starting") {
    dragHint.textContent = "正在启动摄像头";
  } else {
    dragHint.textContent = "移动鼠标 · 风扇跟随";
  }
  gestureToast.hidden =
    state.gestureStatus !== "denied" || state.gestureToastDismissed;

  speedButtons.forEach((button) => {
    const active = Number(button.dataset.speed) === state.speed;
    button.classList.toggle("active", active);
    button.setAttribute("aria-pressed", String(active));
  });
}

function setPointerTarget(pointerX, pointerY) {
  const nextX = clamp(pointerX, 0, 1);
  const nextY = clamp(pointerY, 0, 1);
  const moved =
    state.lastPointerX === null ||
    Math.hypot(
      nextX - state.lastPointerX,
      nextY - state.lastPointerY,
    ) > 0.00045;

  state.pointerX = nextX;
  state.pointerY = nextY;
  state.lastPointerX = nextX;
  state.lastPointerY = nextY;

  if (state.gestureEnabled) return;
  if (!moved) return;

  const needsUIUpdate = state.oscillate || !state.cursorFollowing;
  state.cursorFollowing = true;
  state.oscillate = false;
  if (needsUIUpdate) updateUI();
}

function postWallpaperMessage(message) {
  if (!window.webkit?.messageHandlers?.wallpaper) return false;
  window.webkit.messageHandlers.wallpaper.postMessage(message);
  return true;
}

function setCameraPreviewMode(visible, notifyNative = true) {
  state.cameraPreviewVisible = Boolean(visible);
  if (notifyNative) {
    postWallpaperMessage({
      action: "camera-preview-toggle",
      visible: state.cameraPreviewVisible,
    });
  }
  updateUI();
  markActivity();
}

function setGestureMode(enabled, notifyNative = true) {
  state.gestureEnabled = enabled;
  state.gestureStatus = enabled ? "requesting" : "off";
  state.gesturePose = "neutral";
  state.gestureFingerCount = null;
  state.gestureCommand = "neutral";
  state.gestureCommandSince = performance.now();
  state.gestureCommandLatched = "neutral";
  state.gestureToastDismissed = false;

  if (enabled) {
    state.power = true;
    state.oscillate = false;
    state.cursorFollowing = false;
  } else {
    window.windNestGestureOverlay(null);
  }

  if (notifyNative) {
    const delivered = postWallpaperMessage({
      action: "gesture-toggle",
      enabled,
    });
    if (enabled && !delivered) {
      window.setTimeout(() => {
        window.windNestGestureStatus("unavailable");
      }, 260);
    }
  }

  updateUI();
  markActivity();
}

window.windNestGestureStatus = (status) => {
  const supportedStatuses = new Set([
    "off",
    "requesting",
    "checking",
    "prompting",
    "starting",
    "searching",
    "tracking",
    "denied",
    "unavailable",
  ]);
  const nextStatus = supportedStatuses.has(status) ? status : "unavailable";
  state.gestureStatus = nextStatus;
  state.gestureEnabled = [
    "requesting",
    "checking",
    "prompting",
    "starting",
    "searching",
    "tracking",
  ].includes(nextStatus);

  if (state.gestureEnabled) {
    state.oscillate = false;
    state.cursorFollowing = false;
  }
  if (nextStatus === "denied") state.gestureToastDismissed = false;

  updateUI();
  markActivity();
};

function applyGestureCommand(pose, fingerCount = null) {
  const nextPose = ["open", "fist"].includes(pose) ? pose : "neutral";
  const nextFingerCount =
    Number.isInteger(fingerCount) && fingerCount >= 1 && fingerCount <= 3
      ? fingerCount
      : null;
  const nextCommand =
    nextFingerCount === null ? nextPose : `speed-${nextFingerCount}`;
  const now = performance.now();

  state.gesturePose = nextPose;
  state.gestureFingerCount = nextFingerCount;

  if (state.gestureCommand !== nextCommand) {
    state.gestureCommand = nextCommand;
    state.gestureCommandSince = now;
    state.gestureCommandLatched = "neutral";
    gestureHoldProgress.classList.remove("holding");
    if (nextCommand !== "neutral") {
      void gestureHoldProgress.offsetWidth;
      gestureHoldProgress.classList.add("holding");
    }
    updateUI();
    return;
  }

  if (
    nextCommand === "neutral" ||
    state.gestureCommandLatched === nextCommand ||
    now - state.gestureCommandSince < 460
  ) {
    return;
  }

  state.gestureCommandLatched = nextCommand;
  gestureHoldProgress.classList.remove("holding");
  if (nextFingerCount !== null) {
    state.speed = nextFingerCount;
    state.power = true;
    updateUI();
    markActivity();
  } else if (nextPose === "fist" && state.power) {
    state.power = false;
    updateUI();
    markActivity();
  } else if (nextPose === "open" && !state.power) {
    state.power = true;
    updateUI();
    markActivity();
  }
}

window.windNestGestureFrame = (
  gestureX,
  hasHand = true,
  gesturePose = "neutral",
  fingerCount = null,
) => {
  if (!state.gestureEnabled) return;
  if (!hasHand || !Number.isFinite(gestureX)) {
    applyGestureCommand("neutral");
    if (state.gestureStatus !== "searching") {
      window.windNestGestureStatus("searching");
    }
    return;
  }

  applyGestureCommand(gesturePose, fingerCount);
  state.gestureX = clamp(gestureX, 0, 1);
  const nextGestureZone =
    state.gestureX < 0.38
      ? "left"
      : state.gestureX > 0.62
        ? "right"
        : "center";
  const gestureZoneChanged = state.gestureZone !== nextGestureZone;
  state.gestureZone = nextGestureZone;
  if (state.gestureStatus !== "tracking") {
    window.windNestGestureStatus("tracking");
  } else if (gestureZoneChanged) {
    updateUI();
  }
};

function setSpeed(speed) {
  state.speed = clamp(Math.round(speed), 1, 3);
  state.power = true;
  updateUI();
  markActivity();
}

function togglePower() {
  state.power = !state.power;
  updateUI();
  markActivity();
  if (window.__WIND_NEST_QA__ && window.webkit?.messageHandlers?.wallpaper) {
    window.webkit.messageHandlers.wallpaper.postMessage({
      action: "qa-power",
      power: state.power,
    });
  }
}

const loader = new GLTFLoader();
loader.load(
  fanAssetUrl,
  (gltf) => {
    model = gltf.scene;
    model.name = "ApprovedFan";
    modelHomePosition.copy(model.position);
    model.position.addScaledVector(cameraRight, 1.42);
    scene.add(model);

    model.traverse((object) => {
      if (!object.isMesh) return;
      object.castShadow = true;
      object.receiveShadow = true;
      const materials = Array.isArray(object.material)
        ? object.material
        : [object.material];
      materials.forEach((material) => {
        material.envMapIntensity = 0.68;
        const finish = approvedFinish[material.name];
        if (finish && material.color) {
          material.color.setHex(finish.color);
          material.metalness = finish.metalness;
          material.roughness = finish.roughness;
        }
        material.needsUpdate = true;
        if (object.name.startsWith("Blade ")) bladeMaterials.add(material);
        if (object.name === "Power LED") powerLedMaterial = material;
      });
    });

    bladeRotor = model.getObjectByName("BladeRotor");
    yawPivot = model.getObjectByName("YawPivot");
    tiltPivot = model.getObjectByName("TiltPivot");

    if (!bladeRotor || !yawPivot || !tiltPivot) {
      throw new Error("Blender 风扇的动画节点不完整。");
    }

    // Blender Z-up exports to glTF Y-up:
    // blade spin stays on the fan-local Z axis, while vertical yaw becomes Y.
    rotorBase = bladeRotor.rotation.z;
    state.rotorAngle = rotorBase;
    yawBase = yawPivot.rotation.y;
    tiltBase = tiltPivot.rotation.x;
    coldAirEffect = createColdAirEffect(tiltPivot);
    state.actualSpeed = state.speed;
    state.loaded = true;
    loading.classList.add("done");
    resize();
    update(0);
    renderer.render(scene, camera);
  },
  (event) => {
    if (!event.total) return;
    const progress = Math.round((event.loaded / event.total) * 100);
    loading.querySelector("span").textContent = `载入风扇 ${progress}%`;
  },
  (error) => {
    console.error(error);
    loading.querySelector("span").textContent = "风扇模型载入失败";
    loading.classList.add("error");
  },
);

function resize() {
  const width = Math.max(1, stage.clientWidth);
  const height = Math.max(1, stage.clientHeight);
  renderer.setSize(width, height, false);
  renderer.getDrawingBufferSize(drawingBufferSize);
  camera.aspect = width / height;

  // Preserve the approved square product-photo framing across compact windows.
  if (camera.aspect < 0.9) {
    camera.fov = 35;
  } else if (camera.aspect > 1.18) {
    camera.fov = 30.4;
  } else {
    camera.fov = 32.4;
  }
  camera.updateProjectionMatrix();

  if (coldAirEffect) {
    coldAirEffect.material.uniforms.uResolution.value.copy(
      drawingBufferSize,
    );
    coldAirEffect.fogSheets.forEach((fog) => {
      fog.material.uniforms.uResolution.value.copy(drawingBufferSize);
    });
  }
}

function update(delta) {
  state.elapsed += delta;
  const desiredSpeed = state.power ? state.speed : 0;
  state.actualSpeed = damp(
    state.actualSpeed,
    desiredSpeed,
    state.power ? 2.8 : 1.18,
    delta,
  );

  if (
    state.power &&
    state.gestureEnabled &&
    state.gestureStatus === "tracking" &&
    !state.dragging
  ) {
    state.targetYaw = clamp((state.gestureX - 0.5) * 1.9, -0.72, 0.72);
    state.targetTilt = damp(state.targetTilt, 0, 3.2, delta);
  } else if (
    state.power &&
    state.cursorFollowing &&
    !state.dragging &&
    !state.gestureEnabled
  ) {
    state.targetYaw = clamp((state.pointerX - 0.5) * 1.18, -0.62, 0.62);
    state.targetTilt = clamp((state.pointerY - 0.5) * 0.19, -0.1, 0.1);
  } else if (state.power && state.oscillate && !state.dragging) {
    state.targetYaw = Math.sin(state.elapsed * 0.23) * 0.55;
    state.targetTilt = Math.sin(state.elapsed * 0.31 + 0.7) * 0.035;
  }
  const yawDamping =
    state.gestureEnabled && state.gestureStatus === "tracking" ? 5.4 : 3.5;
  state.yaw = damp(state.yaw, state.targetYaw, yawDamping, delta);
  state.tilt = damp(state.tilt, state.targetTilt, 4.2, delta);

  if (!state.loaded) return;

  modelLayoutTarget.copy(modelHomePosition);
  if (state.cameraPreviewVisible && window.innerWidth >= 980) {
    modelLayoutTarget.addScaledVector(cameraRight, 1.42);
  }
  model.position.lerp(
    modelLayoutTarget,
    1 - Math.exp(-5.2 * delta),
  );

  const rotorSpeeds = [0, 2.4, 6.4, 11.8];
  const lowerSpeed = Math.floor(state.actualSpeed);
  const upperSpeed = Math.min(3, Math.ceil(state.actualSpeed));
  const speedBlend = state.actualSpeed - lowerSpeed;
  state.rotorVelocity = THREE.MathUtils.lerp(
    rotorSpeeds[lowerSpeed],
    rotorSpeeds[upperSpeed],
    speedBlend,
  );
  state.rotorAngle -= state.rotorVelocity * delta;
  bladeRotor.rotation.z = state.rotorAngle;
  yawPivot.rotation.y = yawBase + state.yaw;
  tiltPivot.rotation.x = tiltBase + state.tilt;

  bladeMaterials.forEach((material) => {
    const bladeOpacities = [1, 0.94, 0.78, 0.6];
    const movingOpacity = THREE.MathUtils.lerp(
      bladeOpacities[lowerSpeed],
      bladeOpacities[upperSpeed],
      speedBlend,
    );
    material.transparent = movingOpacity < 1;
    material.opacity = damp(
      material.opacity ?? 0.96,
      movingOpacity,
      5,
      delta,
    );
  });

  if (powerLedMaterial?.emissiveIntensity !== undefined) {
    powerLedMaterial.emissiveIntensity = damp(
      powerLedMaterial.emissiveIntensity,
      state.power ? 3.2 : 0.05,
      5,
      delta,
    );
  }

  updateColdAir(delta);
}

let previousTime = performance.now();
let lastPresentedTime = previousTime;
const drawFrame = (now) => {
  const delta = Math.min(0.05, (now - previousTime) / 1000);
  previousTime = now;
  lastPresentedTime = now;
  update(delta);
  renderer.render(scene, camera);
  if (window.__WIND_NEST_QA__) {
    window.__WIND_NEST_QA_FRAME__ = {
      time: Number(state.elapsed.toFixed(3)),
      yaw: Number(state.yaw.toFixed(4)),
      rotor: bladeRotor ? Number(bladeRotor.rotation.z.toFixed(4)) : null,
      rotorVelocity: Number(state.rotorVelocity.toFixed(4)),
      speed: state.speed,
      actualSpeed: Number(state.actualSpeed.toFixed(4)),
      power: state.power,
      cursorFollowing: state.cursorFollowing,
      gestureEnabled: state.gestureEnabled,
      cameraPreviewVisible: state.cameraPreviewVisible,
      gestureStatus: state.gestureStatus,
      gestureX: Number(state.gestureX.toFixed(4)),
      gesturePose: state.gesturePose,
      gestureFingerCount: state.gestureFingerCount,
      gestureCommand: state.gestureCommand,
      pointerX: Number(state.pointerX.toFixed(4)),
      pointerY: Number(state.pointerY.toFixed(4)),
      coldAir: coldAirEffect
        ? Number(coldAirEffect.intensity.toFixed(4))
        : null,
    };
  }
};
window.windNestNativeTick = drawFrame;
window.windNestNativeFrame = (now, pointerX, pointerY) => {
  setPointerTarget(pointerX, pointerY);
  drawFrame(now);
};

if (!window.__WIND_NEST_NATIVE__) {
  renderer.setAnimationLoop(drawFrame);

  window.setInterval(() => {
    const now = performance.now();
    if (now - lastPresentedTime > 80) drawFrame(now);
  }, 50);
}

renderer.domElement.addEventListener("pointerdown", (event) => {
  state.dragging = true;
  state.dragStartX = event.clientX;
  state.dragStartY = event.clientY;
  state.lastX = event.clientX;
  state.lastY = event.clientY;
  state.dragDistance = 0;
  renderer.domElement.setPointerCapture(event.pointerId);
  markActivity();
});

renderer.domElement.addEventListener("pointermove", (event) => {
  markActivity();
  if (!state.dragging) {
    setPointerTarget(
      event.clientX / Math.max(1, window.innerWidth),
      1 - event.clientY / Math.max(1, window.innerHeight),
    );
    return;
  }

  const dx = event.clientX - state.lastX;
  const dy = event.clientY - state.lastY;
  state.dragDistance += Math.hypot(dx, dy);
  state.targetYaw = clamp(
    state.targetYaw + (dx / Math.max(400, window.innerWidth)) * 2.7,
    -0.72,
    0.72,
  );
  state.targetTilt = clamp(
    state.targetTilt - (dy / Math.max(400, window.innerHeight)) * 0.8,
    -0.13,
    0.13,
  );
  state.oscillate = false;
  state.cursorFollowing = false;
  state.lastX = event.clientX;
  state.lastY = event.clientY;
  updateUI();
});

function endDrag(event) {
  if (!state.dragging) return;
  if (renderer.domElement.hasPointerCapture(event.pointerId)) {
    renderer.domElement.releasePointerCapture(event.pointerId);
  }
  const wasClick = state.dragDistance < 12;
  state.dragging = false;
  if (wasClick) togglePower();
  markActivity();
}

renderer.domElement.addEventListener("pointerup", endDrag);
renderer.domElement.addEventListener("pointercancel", endDrag);
renderer.domElement.addEventListener(
  "wheel",
  (event) => {
    event.preventDefault();
    setSpeed(state.speed + (event.deltaY < 0 ? 1 : -1));
  },
  { passive: false },
);

speedButtons.forEach((button) => {
  button.addEventListener("pointerdown", (event) => event.stopPropagation());
  button.addEventListener("click", () => setSpeed(Number(button.dataset.speed)));
});
powerButton.addEventListener("pointerdown", (event) => event.stopPropagation());
powerButton.addEventListener("click", togglePower);
oscillateButton.addEventListener("pointerdown", (event) =>
  event.stopPropagation(),
);
oscillateButton.addEventListener("click", () => {
  if (state.gestureEnabled) setGestureMode(false);
  state.oscillate = !state.oscillate;
  state.cursorFollowing = false;
  updateUI();
  markActivity();
});
gestureButton.addEventListener("pointerdown", (event) =>
  event.stopPropagation(),
);
gestureButton.addEventListener("click", () => {
  setGestureMode(!state.gestureEnabled);
});
cameraPreviewButton.addEventListener("pointerdown", (event) =>
  event.stopPropagation(),
);
cameraPreviewButton.addEventListener("click", () => {
  setCameraPreviewMode(!state.cameraPreviewVisible);
});
gestureSettingsButton.addEventListener("pointerdown", (event) =>
  event.stopPropagation(),
);
gestureSettingsButton.addEventListener("click", () => {
  postWallpaperMessage({ action: "gesture-settings" });
});
gestureToastClose.addEventListener("pointerdown", (event) =>
  event.stopPropagation(),
);
gestureToastClose.addEventListener("click", () => {
  state.gestureToastDismissed = true;
  updateUI();
});
for (const uiSurface of [controlDock, gestureToast, quitButton]) {
  uiSurface.addEventListener("pointerenter", () => {
    state.uiInteracting = true;
    markActivity();
  });
  uiSurface.addEventListener("pointerleave", () => {
    state.uiInteracting = false;
    markActivity();
  });
  uiSurface.addEventListener("focusin", () => {
    state.uiInteracting = true;
    markActivity();
  });
  uiSurface.addEventListener("focusout", () => {
    state.uiInteracting = false;
    markActivity();
  });
}
quitButton.addEventListener("pointerdown", (event) => event.stopPropagation());
quitButton.addEventListener("click", () => {
  if (window.webkit?.messageHandlers?.wallpaper) {
    window.webkit.messageHandlers.wallpaper.postMessage({ action: "quit" });
  } else {
    window.close();
  }
});

window.addEventListener("keydown", (event) => {
  markActivity();
  if (event.code === "Space") {
    event.preventDefault();
    togglePower();
  }
  if (event.key >= "1" && event.key <= "3") {
    setSpeed(Number(event.key));
  }
  if (event.key.toLowerCase() === "o") {
    if (state.gestureEnabled) setGestureMode(false);
    state.oscillate = !state.oscillate;
    state.cursorFollowing = false;
    updateUI();
  }
  if (event.key.toLowerCase() === "v") {
    setCameraPreviewMode(!state.cameraPreviewVisible);
  }
  if (event.key.toLowerCase() === "h") {
    document.body.classList.toggle("ui-visible");
  }
});

window.wallpaperEscape = () => {
  document.body.classList.toggle("ui-visible");
};

window.addEventListener("resize", resize);
window.addEventListener("contextmenu", (event) => event.preventDefault());

resize();
updateUI();
