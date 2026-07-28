import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const projectRoot = new URL("../", import.meta.url);
const sourceModel = await readFile(
  new URL("Resources/assets/wind-nest-fan.glb", projectRoot),
);
const bundlePath =
  process.argv[2] ??
  fileURLToPath(
    new URL(
      "dist/风巢.app/Contents/Resources/app.js",
      projectRoot,
    ),
  );
const webBundle = await readFile(
  bundlePath,
  "utf8",
);
const match = webBundle.match(
  /data:(?:model\/gltf-binary|application\/octet-stream);base64,([A-Za-z0-9+/=]+)/,
);

if (!match) {
  throw new Error(`${bundlePath} 中没有找到内嵌 GLB 模型`);
}

const embeddedModel = Buffer.from(match[1], "base64");
if (!embeddedModel.equals(sourceModel)) {
  throw new Error(`${bundlePath} 中的 GLB 与源模型不一致`);
}

console.log(`内嵌 GLB 模型校验通过（${sourceModel.length} 字节）`);
