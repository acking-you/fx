#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent } from "../node.js";

const marker = "LIBFX_EXPLICIT_WORKSPACE_CONTEXT";
const originalCwd = process.cwd();
const originalHome = process.env.HOME;
const processHome = await mkdtemp(join(tmpdir(), "libfx-process-home-"));
const processWorkspace = await mkdtemp(join(tmpdir(), "libfx-process-workspace-"));
const runtimeHome = await mkdtemp(join(tmpdir(), "libfx-runtime-home-"));
const runtimeWorkspace = await mkdtemp(join(tmpdir(), "libfx-runtime-workspace-"));
await writeFile(join(processWorkspace, ".fx.json"), `${JSON.stringify({ context: false })}\n`);
await writeFile(join(runtimeWorkspace, ".fx.json"), `${JSON.stringify({ context: true })}\n`);
await writeFile(join(runtimeWorkspace, "AGENTS.md"), `# Context\n\n${marker}\n`);

let requestBody = "";
const requests = [];
const server = createServer((request, response) => {
  requests.push({ path: request.url, authorization: request.headers.authorization });
  request.setEncoding("utf8");
  request.on("data", (chunk) => { requestBody += chunk; });
  request.on("end", () => {
    if (request.method === "GET") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({ data: [{ id: "native/test-model", object: "model" }] }));
      return;
    }
    response.writeHead(200, { "content-type": "text/event-stream" });
    response.write('data: {"type":"response.output_text.delta","item_id":"answer_1","output_index":0,"content_index":0,"delta":"isolated"}\n\n');
    response.write('data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}}\n\n');
    response.end("data: [DONE]\n\n");
  });
});
await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
const { port } = server.address();
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const addon = resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/lib/libfx.node"));

try {
  for (const [home, route] of [[processHome, "process-profile"], [runtimeHome, "runtime-profile"]]) {
    await mkdir(join(home, ".fx"), { mode: 0o700 });
    await writeFile(join(home, ".fx", "gateway-auth.json"), JSON.stringify({
      version: 1,
      base_url: `http://127.0.0.1:${port}/${route}/v1`,
      api_key: `${route}-key`,
    }), { mode: 0o600 });
  }
  process.env.HOME = processHome;
  process.chdir(processWorkspace);
  const agent = await createFxAgent({
    nativeAddon: addon,
    backend: "native",
    home: runtimeHome,
    workspaceRoot: runtimeWorkspace,
    env: {
      OPENAI_API_KEY: "native-core-config-key",
      FX_RESPONSES_BASE_URL: `http://127.0.0.1:${port}/v1`,
      FX_MODEL: "native/test-model",
    },
  });
  const session = await agent.createSession();
  const turn = session.prompt("read the explicit workspace context");
  await turn.result;
  assert.equal(requests.length, 2, "one catalog and one model request");
  assert.deepEqual(requests.map((request) => request.path), ["/v1/models", "/v1/responses"]);
  assert.ok(requests.every((request) => request.authorization === "Bearer native-core-config-key"), "explicit SDK credentials must survive profile discovery");
  assert.match(requestBody, new RegExp(marker), "native startup must load context policy from workspaceRoot, not process.cwd()" );
  await session.close();
  assert.equal(await agent.close(), 0);

  const defaultRequests = [];
  const defaultAgent = await createFxAgent({
    nativeAddon: addon,
    backend: "native",
    home: runtimeHome,
    workspaceRoot: runtimeWorkspace,
    env: { OPENAI_API_KEY: "explicit-default-key", FX_MODEL: "native/test-model" },
    fetch(input, init) {
      defaultRequests.push({ url: String(input), key: new Headers(init.headers).get("authorization") });
      if (init.method === "GET") return Promise.resolve(Response.json({ data: [{ id: "native/test-model", object: "model" }] }));
      return Promise.resolve(new Response(
        'data: {"type":"response.output_text.delta","item_id":"answer","output_index":0,"content_index":0,"delta":"default route"}\n\n' +
        'data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":1,"output_tokens":1}}}\n\n' +
        'data: [DONE]\n\n',
        { headers: { "content-type": "text/event-stream" } },
      ));
    },
  });
  let defaultClosed = false;
  try {
    const defaultSession = await defaultAgent.createSession();
    await defaultSession.prompt("Use the SDK default route.").result;
    assert.deepEqual(defaultRequests, [
      { url: "https://api.openai.com/v1/models", key: "Bearer explicit-default-key" },
      { url: "https://api.openai.com/v1/responses", key: "Bearer explicit-default-key" },
    ], "omitting the SDK URL must not opt into an unrelated process binding");
    await defaultSession.close();
    assert.equal(await defaultAgent.close(), 0);
    defaultClosed = true;
  } finally {
    if (!defaultClosed) defaultAgent.abort();
  }
  console.log("native config isolation passed: explicit home and workspace own startup state");
} finally {
  if (originalHome === undefined) delete process.env.HOME;
  else process.env.HOME = originalHome;
  process.chdir(originalCwd);
  server.closeAllConnections();
  server.close();
  await Promise.all([
    rm(processWorkspace, { recursive: true, force: true }),
    rm(processHome, { recursive: true, force: true }),
    rm(runtimeHome, { recursive: true, force: true }),
    rm(runtimeWorkspace, { recursive: true, force: true }),
  ]);
}
