#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { createRequire } from "node:module";
import { readdirSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const addonPath = resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/lib/libfx.node"));
const addon = require(addonPath);

function fdCount() {
  try { return readdirSync("/dev/fd").length; } catch { return null; }
}

const beforeFds = fdCount();
for (let index = 0; index < 1000; index += 1) {
  assert.throws(() => addon.createCore({
    apiKey: "k".repeat(4096),
    model: 42,
    home: process.cwd(),
    workspaceRoot: process.cwd(),
  }));
}
const afterFds = fdCount();
if (beforeFds !== null && afterFds !== null) assert.ok(afterFds - beforeFds < 4, `fd leak: ${beforeFds} -> ${afterFds}`);

const runtimeLimitProbe = Array.from({ length: 64 }, () => addon.createCore({
  apiKey: "runtime-limit-key",
  home: process.cwd(),
  workspaceRoot: process.cwd(),
}));
assert.throws(
  () => addon.createCore({ apiKey: "runtime-limit-key", home: process.cwd(), workspaceRoot: process.cwd() }),
  (error) => error.code === "LIBFX_NATIVE_LIMIT",
);
for (const handle of runtimeLimitProbe) addon.closeCore(handle);
for (const handle of runtimeLimitProbe) addon.destroyCore(handle);

console.log("native core security passed: malformed creation is stable and runtime limits are enforced");
