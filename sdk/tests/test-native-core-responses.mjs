#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { createRequire } from "node:module";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent } from "../node.js";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const addonPath = resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/lib/libfx.node"));
const openaiKey = "native-openai-responses-key";
const model = "gpt-5.4";
const modelsBody = JSON.stringify({ object: "list", data: [{ id: model, object: "model", created: 1 }] });
const responsesBody = (text) => [
  `data: ${JSON.stringify({ type: "response.output_text.delta", item_id: "msg_1", output_index: 0, content_index: 0, delta: text })}\n\n`,
  `data: ${JSON.stringify({ type: "response.completed", response: { status: "completed", usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 } } })}\n\n`,
  "data: [DONE]\n\n",
].join("");

function headerMap(serialized) {
  return new Map(JSON.parse(serialized).map(({ name, value }) => [name.toLowerCase(), value]));
}

function assertDirectRequest(request, expectedBase, expectedMethod) {
  assert.equal(request.method, expectedMethod);
  assert.equal(request.url, `${expectedBase}/${expectedMethod === "GET" ? "models" : "responses"}`);
  assert.doesNotMatch(request.url, /ai-gateway\.vercel\.sh|api\.openai\.com/);
  const headers = headerMap(request.headers);
  assert.equal(headers.get("authorization"), `Bearer ${openaiKey}`);
  assert.equal(headers.has("ai-gateway-protocol-version"), false);
  assert.equal(headers.has("x-vercel-ai-gateway-team"), false);
}

const highLevelBase = "http://127.0.0.1:43101/v1";
const ignoredLowerPriorityBase = "http://127.0.0.1:43102/v1";
const highLevelRequests = [];
let agent;
try {
  agent = await createFxAgent({
    nativeAddon: addonPath,
    backend: "native",
    fetch(input, init) {
      const request = {
        method: init.method,
        url: String(input),
        headers: JSON.stringify([...new Headers(init.headers).entries()].map(([name, value]) => ({ name, value }))),
        body: init.body,
      };
      highLevelRequests.push(request);
      if (request.method === "GET") {
        return Promise.resolve(new Response(modelsBody, {
          status: 200,
          headers: { "content-type": "application/json" },
        }));
      }
      return Promise.resolve(new Response(responsesBody("native responses"), {
        status: 200,
        headers: { "content-type": "text/event-stream" },
      }));
    },
    env: {
      OPENAI_API_KEY: openaiKey,
      FX_RESPONSES_BASE_URL: highLevelBase,
      OPENAI_BASE_URL: ignoredLowerPriorityBase,
      FX_MODEL: model,
    },
  });
  const session = await agent.createSession();
  const turn = session.prompt("route this through Responses");
  let text = "";
  for await (const update of turn) {
    if (update.sessionUpdate === "agent_message_chunk" && !update.content.text.startsWith("[context]")) {
      text += update.content.text;
    }
  }
  assert.equal(text.trimEnd(), "native responses");
  assert.equal((await turn.result).stopReason, "end_turn");
  assert.equal(highLevelRequests.length, 2, "one model lookup and one Responses request are expected");
  assertDirectRequest(highLevelRequests[0], highLevelBase, "GET");
  assertDirectRequest(highLevelRequests[1], highLevelBase, "POST");
  assert.doesNotMatch(highLevelRequests[0].url + highLevelRequests[1].url, /43102/);
  const highLevelPayload = JSON.parse(Buffer.from(highLevelRequests[1].body).toString("utf8"));
  assert.equal(highLevelPayload.model, model);
  assert.equal(highLevelPayload.stream, true);
  await session.close();
  assert.equal(await agent.close(), 0);
  agent = null;
} finally {
  agent?.abort();
}

const require = createRequire(import.meta.url);
const addon = require(addonPath);
const lowLevelBase = "http://127.0.0.1:43103/custom";
const core = addon.createCore({
  apiKey: openaiKey,
  credentialSource: "openai_api_key",
  responsesBaseUrl: lowLevelBase,
  gatewayChatUrl: "http://127.0.0.1:43104/vercel-trap",
  model,
  home: "/tmp",
  workspaceRoot: "/tmp",
});
let nextId = 1;
let buffered = "";
const timeout = (label, ms = 5000) => new Promise((_, reject) => {
  const timer = setTimeout(() => reject(new Error(`timed out waiting for ${label}`)), ms);
  timer.unref();
});
const send = (method, params = {}) => {
  const id = nextId++;
  addon.writeCore(core, Buffer.from(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`));
  return id;
};
const waitForResponse = async (id) => {
  for (;;) {
    buffered += addon.drainCore(core).toString("utf8");
    const lines = buffered.split("\n");
    buffered = lines.pop();
    for (const line of lines) {
      if (!line) continue;
      const message = JSON.parse(line);
      if (message.id === id) return message;
    }
    await new Promise((resolveWait) => setTimeout(resolveWait, 2));
  }
};
const takeFetch = async () => {
  for (;;) {
    const bytes = addon.takeCoreFetch(core);
    if (bytes) return JSON.parse(bytes.toString("utf8"));
    await new Promise((resolveWait) => setTimeout(resolveWait, 2));
  }
};
const finishFetch = (request, body) => {
  assert.equal(addon.startCoreFetchResponse(core, request.handle, 200), 1);
  assert.equal(addon.pushCoreFetchResponse(core, request.handle, Buffer.from(body)), 1);
  assert.equal(addon.finishCoreFetch(core, request.handle), 1);
};

try {
  const initializeId = send("initialize", { protocolVersion: 1, clientCapabilities: {} });
  const catalogRequest = await Promise.race([takeFetch(), timeout("low-level model catalog fetch")]);
  assertDirectRequest(catalogRequest, lowLevelBase, "GET");
  finishFetch(catalogRequest, modelsBody);
  assert.ok((await Promise.race([waitForResponse(initializeId), timeout("initialize")])).result);

  const created = await Promise.race([waitForResponse(send("session/new")), timeout("session/new")]);
  const promptId = send("session/prompt", {
    sessionId: created.result.sessionId,
    prompt: [{ type: "text", text: "low-level Responses route" }],
  });
  const responseRequest = await Promise.race([takeFetch(), timeout("low-level Responses fetch")]);
  assertDirectRequest(responseRequest, lowLevelBase, "POST");
  const lowLevelPayload = JSON.parse(Buffer.from(responseRequest.body, "base64").toString("utf8"));
  assert.equal(lowLevelPayload.model, model);
  assert.equal(lowLevelPayload.stream, true);
  finishFetch(responseRequest, responsesBody("low-level responses"));
  const prompt = await Promise.race([waitForResponse(promptId), timeout("session/prompt")]);
  assert.equal(prompt.result.stopReason, "end_turn");
} finally {
  addon.closeCore(core);
  addon.destroyCore(core);
}

console.log("native Responses routing passed: typed credentials and per-runtime model and stream endpoints stay on the selected origin");
