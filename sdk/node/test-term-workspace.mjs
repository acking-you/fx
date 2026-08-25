#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import xtermHeadless from "@xterm/headless";
import { createFxTerminal, supportsJspi, xtermAdapter } from "../node.js";

const { Terminal } = xtermHeadless;
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const wasmPath = resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/bin/fx-term.wasm"));
if (!supportsJspi()) process.exit(2);

const terminal = new Terminal({ cols: 100, rows: 34, allowProposedApi: true, scrollback: 3000 });
const config = new Map([["model", "test/workspace-model"], ["mode", "code"]]);
const encoder = new TextEncoder();
const requestDecoder = new TextDecoder();
const stderrDecoder = new TextDecoder();
const catalog = {
  object: "list",
  data: [{ id: "test/workspace-model", object: "model", created: 1 }],
};
const execCalls = [];
let abortStarted = false;
let abortObserved = false;
let checkedToolProjection = false;
const truncatedOutput = `start\n${"🙂".repeat(17_000)}\nend\n`;
const truncatedBytes = encoder.encode(truncatedOutput).length;

const workspace = {
  info: {
    version: 1,
    root: "/workspace",
    cwd: "/workspace",
    home: "/home/visitor",
    gitAvailable: false,
    ephemeral: true,
  },
  permission: "allow-sandboxed",
  exec({ command, cwd, signal, timeoutMs, outputLimitBytes }) {
    execCalls.push(command);
    if (cwd !== "/workspace" || timeoutMs !== 30_000 || outputLimitBytes !== 65_536) {
      throw new Error(`unexpected workspace exec contract: cwd=${cwd} timeout=${timeoutMs} outputLimit=${outputLimitBytes}`);
    }
    if (command === "printf adapter-success") {
      return { stdout: "adapter-success\n", stderr: "", exitCode: 0 };
    }
    if (command === "generate-truncated-output") {
      return { stdout: truncatedOutput, stderr: "warning\n", exitCode: 0 };
    }
    if (command === "timeout-command") {
      throw new DOMException("deadline", "TimeoutError");
    }
    if (command === "hold-command") {
      abortStarted = true;
      return new Promise((resolve) => {
        signal.addEventListener("abort", () => {
          abortObserved = true;
          resolve({ stdout: "", stderr: "", exitCode: 124 });
        }, { once: true });
      });
    }
    throw new Error(`unexpected workspace command: ${command}`);
  },
};

function sse(events) {
  return new Response(
    `${events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("")}data: [DONE]\n\n`,
    { headers: { "content-type": "text/event-stream" } },
  );
}

function toolCall(id, command) {
  return sse([
    { type: "response.output_item.added", output_index: 0, item: { type: "function_call", id: `${id}_item`, call_id: id, name: "terminal" } },
    { type: "response.function_call_arguments.done", item_id: `${id}_item`, call_id: id, output_index: 0, arguments: JSON.stringify({ action: "exec", command }) },
    { type: "response.completed", response: { status: "completed", usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 } } },
  ]);
}

function terminalToolCalls(calls) {
  const events = calls.flatMap(({ id, input }, output_index) => {
    const serialized = JSON.stringify(input);
    const deltas = [];
    for (let offset = 0; offset < serialized.length; offset += 4096) {
      deltas.push({ type: "response.function_call_arguments.delta", item_id: `${id}_item`, call_id: id, output_index, delta: serialized.slice(offset, offset + 4096) });
    }
    return [
      { type: "response.output_item.added", output_index, item: { type: "function_call", id: `${id}_item`, call_id: id, name: "terminal" } },
      ...deltas,
      { type: "response.function_call_arguments.done", item_id: `${id}_item`, call_id: id, output_index, arguments: serialized },
    ];
  });
  const responseEvents = [
    ...events,
    { type: "response.completed", response: { status: "completed", usage: { input_tokens: 1, output_tokens: calls.length, total_tokens: calls.length + 1 } } },
  ];
  return new Response(new ReadableStream({
    start(controller) {
      for (const event of responseEvents) {
        controller.enqueue(encoder.encode(`data: ${JSON.stringify(event)}\n\n`));
      }
      controller.enqueue(encoder.encode("data: [DONE]\n\n"));
      controller.close();
    },
  }), { headers: { "content-type": "text/event-stream" } });
}

function textResponse(value) {
  return sse([
    { type: "response.output_text.delta", item_id: "answer_1", output_index: 0, content_index: 0, delta: value },
    { type: "response.completed", response: { status: "completed", usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 } } },
  ]);
}

function toolResult(body, id) {
  return (body.input || []).find((item) =>
    item.type === "function_call_output" && item.call_id === id
  );
}

function latestToolResult(body) {
  const item = (body.input || []).at(-1);
  return item?.type === "function_call_output" ? item : null;
}

function latestUserText(body) {
  for (let index = (body.input || []).length - 1; index >= 0; index -= 1) {
    const message = body.input[index];
    if (message.role === "user") return JSON.stringify(message.content);
  }
  return "";
}

function requireResult(body, id, expected) {
  const result = toolResult(body, id);
  if (!result) throw new Error(`missing tool result ${id}`);
  const serialized = JSON.stringify(result);
  for (const value of expected) {
    if (!serialized.includes(value)) throw new Error(`tool result ${id} omitted ${value}`);
  }
  return serialized;
}

const fetch = async (_url, init = {}) => {
  if ((init.method || "GET") === "GET") {
    return new Response(JSON.stringify(catalog), { status: 200, headers: { "content-type": "application/json" } });
  }
  const body = JSON.parse(requestDecoder.decode(init.body));
  if (!checkedToolProjection) {
    if (body.tools?.length !== 1 || body.tools[0]?.name !== "terminal") {
      throw new Error(`workspace advertised unexpected tools: ${JSON.stringify(body.tools)}`);
    }
    const schema = body.tools[0]?.parameters;
    if (JSON.stringify(schema?.required) !== JSON.stringify(["action", "command"]) ||
        schema?.properties?.action?.enum?.[0] !== "exec" ||
        schema?.properties?.command?.maxLength !== 65_536 ||
        Object.keys(schema?.properties || {}).join(",") !== "action,command" ||
        schema?.additionalProperties !== false) {
      throw new Error(`workspace advertised unexpected terminal schema: ${JSON.stringify(schema)}`);
    }
    checkedToolProjection = true;
  }
  const latestResult = latestToolResult(body);
  if (latestResult?.call_id === "workspace-success") {
    requireResult(body, "workspace-success", ["adapter-success", "exit_code=0"]);
    return textResponse("success record checked");
  }
  if (latestResult?.call_id === "workspace-truncated") {
    const serialized = requireResult(body, "workspace-truncated", ["start", "exit_code=0"]);
    if (serialized.includes("\\nend\\n")) throw new Error("workspace output was not truncated");
    if (serialized.includes("�")) throw new Error("truncated workspace output split a UTF-8 sequence");
    if (truncatedBytes <= 65_536) throw new Error("truncation fixture did not exceed the ABI output cap");
    return textResponse("truncation record checked");
  }
  if (latestResult?.call_id === "workspace-timeout") {
    requireResult(body, "workspace-timeout", ["timeout_ms=30000"]);
    return textResponse("timeout mapping checked");
  }
  if (latestResult?.call_id === "workspace-abort") {
    requireResult(body, "workspace-abort", ["cancelled"]);
    return textResponse("abort mapping checked");
  }
  if ([
    "workspace-oversized",
    "workspace-profile",
    "workspace-durable",
    "workspace-unknown",
  ].includes(latestResult?.call_id)) {
    requireResult(body, "workspace-oversized", ["exceeds 65536 bytes"]);
    requireResult(body, "workspace-profile", ["accepts only the", "action", "command", "fields"]);
    requireResult(body, "workspace-durable", ["action must be", "exec"]);
    requireResult(body, "workspace-unknown", ["accepts only the", "action", "command", "fields"]);
    return textResponse("invalid boundaries checked");
  }
  const prompt = latestUserText(body);
  if (prompt.includes("workspace success")) return toolCall("workspace-success", "printf adapter-success");
  if (prompt.includes("workspace truncation")) return toolCall("workspace-truncated", "generate-truncated-output");
  if (prompt.includes("workspace timeout")) return toolCall("workspace-timeout", "timeout-command");
  if (prompt.includes("workspace abort")) return toolCall("workspace-abort", "hold-command");
  if (prompt.includes("workspace invalid boundaries")) {
    return terminalToolCalls([
      { id: "workspace-oversized", input: { action: "exec", command: "x".repeat(65_537) } },
      { id: "workspace-profile", input: { action: "exec", command: "must-not-run", profile: "clean" } },
      { id: "workspace-durable", input: { action: "start", command: "must-not-run" } },
      { id: "workspace-unknown", input: { action: "exec", command: "must-not-run", unexpected: true } },
    ]);
  }
  if (prompt.includes("workspace recovery")) return textResponse("session stayed alive");
  throw new Error(`unexpected gateway request: ${JSON.stringify(body)}`);
};

let stderr = "";
const runtime = await createFxTerminal({
  backend: "wasm",
  wasm: await readFile(wasmPath),
  terminal: xtermAdapter(terminal),
  env: { OPENAI_API_KEY: "workspace-key" },
  fetch,
  configStore: { get(id) { return config.get(id) ?? null; }, set(id, value) { config.set(id, value); } },
  stderr(chunk) { stderr += stderrDecoder.decode(chunk, { stream: true }); },
  workspace,
});
const flush = () => new Promise((resolve) => terminal.write("", resolve));
const grid = () => {
  const lines = [];
  for (let row = 0; row < terminal.buffer.active.length; row += 1) {
    lines.push(terminal.buffer.active.getLine(row)?.translateToString(true) ?? "");
  }
  return lines.join("\n");
};
async function waitFor(predicate, label) {
  const deadline = performance.now() + 5000;
  while (!predicate()) {
    await flush();
    if (performance.now() >= deadline) throw new Error(`timed out waiting for ${label}:\n${stderr}\n${grid()}`);
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}
async function prompt(value, expected) {
  runtime.write(`${value}\r`);
  await waitFor(() => grid().includes(expected), expected);
}

await waitFor(() => grid().includes("𝒇x"), "startup");
await prompt("workspace success", "success record checked");
await prompt("workspace truncation", "truncation record checked");
await prompt("workspace timeout", "timeout mapping checked");
runtime.write("workspace abort\r");
await waitFor(() => abortStarted, "workspace exec start");
runtime.write("\x03");
await waitFor(() => abortObserved, "workspace exec abort signal");
await waitFor(() => grid().includes("abort mapping checked"), "workspace abort mapping");
await prompt("workspace invalid boundaries", "invalid boundaries checked");
await prompt("workspace recovery", "session stayed alive");

runtime.write("/exit\r");
const exitCode = await Promise.race([
  runtime.exited,
  new Promise((_, reject) => setTimeout(() => reject(new Error("workspace runtime exit timeout")), 5000)),
]);
if (exitCode !== 0) throw new Error(`fx-term exited with ${exitCode}`);
if (!checkedToolProjection) throw new Error("workspace tool projection was not checked");
if (execCalls.join(",") !== "printf adapter-success,generate-truncated-output,timeout-command,hold-command") {
  throw new Error(`unexpected workspace exec calls: ${execCalls.join(",")}`);
}
console.log("headless workspace passed: success, truncation, timeout, Ctrl-C abort, and strict invalid boundaries mapped through the host adapter");
