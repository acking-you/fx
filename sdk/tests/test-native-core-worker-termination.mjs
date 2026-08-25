#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { createServer } from "node:http";
import { resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { Worker } from "node:worker_threads";

const server = createServer((request, response) => {
  if (request.method === "GET" && request.url?.endsWith("/models")) {
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({
      object: "list",
      data: [{
        id: "native/test-model",
        object: "model",
        created: 1,
        owned_by: "test",
      }],
    }));
    return;
  }
  request.resume();
});
await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
const { port } = server.address();
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const addonPath = resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/lib/libfx.node"));
const nodeModuleUrl = pathToFileURL(resolve(scriptDir, "../node.js")).href;

try {
  const worker = new Worker(`
    const { parentPort, workerData } = require("node:worker_threads");
    (async () => {
      const { createFxAgent } = await import(workerData.nodeModuleUrl);
      const agent = await createFxAgent({
        nativeAddon: workerData.addonPath,
        backend: "native",
        env: {
          OPENAI_API_KEY: "worker-termination-key",
          FX_RESPONSES_BASE_URL: workerData.gatewayUrl,
          FX_MODEL: "native/test-model",
        },
      });
      const session = await agent.createSession();
      session.prompt("stall during worker termination");
      parentPort.postMessage("started");
    })().catch((error) => { throw error; });
  `, {
    eval: true,
    workerData: {
      addonPath,
      nodeModuleUrl,
      gatewayUrl: `http://127.0.0.1:${port}/v1`,
    },
  });
  await new Promise((resolveStarted, reject) => {
    worker.once("message", resolveStarted);
    worker.once("error", reject);
  });
  await new Promise((resolveWait) => setTimeout(resolveWait, 50));
  const exitCode = await Promise.race([
    worker.terminate(),
    new Promise((_, reject) => setTimeout(() => reject(new Error("worker termination hung in native finalizer")), 5000)),
  ]);
  assert.equal(typeof exitCode, "number");
  console.log("native worker termination passed: active stalled runtime finalized within 5s");
} finally {
  server.closeAllConnections();
  server.close();
}
