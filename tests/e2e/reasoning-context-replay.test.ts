import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";
import { startFakeGateway } from "./tmux-helpers";

const TIMEOUT = 20_000;
const MODEL = "openai/gpt-5";

function sse(events: object[]) {
  return new Response(
    events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("") +
      "data: [DONE]\n\n",
    { headers: { "content-type": "text/event-stream" } },
  );
}

const roots: string[] = [];

function createRoot() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-reasoning-replay-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(home);
  mkdirSync(workspace);
  roots.push(root);
  return { home: realpathSync(home), workspace: realpathSync(workspace) };
}

function gatewayEnv(
  home: string,
  gateway: ReturnType<typeof startFakeGateway>,
): Record<string, string | undefined> {
  return {
    HOME: home,
    AI_GATEWAY_API_KEY: "fake-reasoning-replay-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_DISABLE_KEYCHAIN: "1",
    FX_SKIP_ONBOARDING: "1",
    FX_MODEL: MODEL,
    FX_PERMISSION_MODE: "auto",
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
  };
}

/** Assistant reasoning parts in the order the request serialized them. */
function reasoningParts(body: string): Array<Record<string, unknown>> {
  const request = JSON.parse(body) as {
    prompt: Array<{ role: string; content?: unknown }>;
  };
  const parts: Array<Record<string, unknown>> = [];
  for (const message of request.prompt) {
    if (message.role !== "assistant" || !Array.isArray(message.content)) continue;
    for (const part of message.content as Array<Record<string, unknown>>) {
      if (part.type === "reasoning") parts.push(part);
    }
  }
  return parts;
}

describe("reasoning context replay", () => {
  test(
    "a tool step replays the full reasoning body and signature to the provider",
    async () => {
      const { home, workspace } = createRoot();
      // Longer than any display window, so a body clipped for the transcript
      // would be visibly shorter than what the provider receives.
      const reasoningLines = Array.from(
        { length: 40 },
        (_, index) => `reasoning line ${index + 1}`,
      );
      const reasoning = reasoningLines.join("\n");
      const signature = "FX_REASONING_SIGNATURE";

      const gateway = startFakeGateway([
        () =>
          sse([
            { type: "reasoning-start", id: "r1" },
            {
              type: "reasoning-delta",
              id: "r1",
              delta: reasoning,
              providerMetadata: { anthropic: { signature } },
            },
            { type: "reasoning-end", id: "r1" },
            {
              type: "tool-call",
              toolCallId: "call_1",
              toolName: "run_command",
              input: { command: "printf hello" },
            },
            {
              type: "finish",
              finishReason: { unified: "tool-calls", raw: "tool_calls" },
              usage: { inputTokens: { total: 5 }, outputTokens: { total: 6 } },
            },
          ]),
        () =>
          sse([
            { type: "text-start", id: "a1" },
            { type: "text-delta", id: "a1", delta: "done" },
            {
              type: "finish",
              finishReason: { unified: "stop", raw: "stop" },
              usage: { inputTokens: { total: 7 }, outputTokens: { total: 2 } },
            },
          ]),
      ]);

      try {
        const result = await runFx(["ask", "--json", "run printf hello"], {
          cwd: workspace,
          env: gatewayEnv(home, gateway),
          timeoutMs: TIMEOUT,
        });

        expect(result.code).toBe(0);
        expect(gateway.requests.length).toBeGreaterThanOrEqual(2);

        // The first request precedes any reasoning, so it must carry none.
        expect(reasoningParts(gateway.requests[0]!.body)).toHaveLength(0);

        // The follow-up request replays the reasoning that produced the tool
        // call, verbatim and untruncated, with its provider signature.
        const replayed = reasoningParts(gateway.requests[1]!.body);
        expect(replayed).toHaveLength(1);
        expect(replayed[0]!.text).toBe(reasoning);
        expect(replayed[0]!.providerOptions).toEqual({
          anthropic: { signature },
        });
      } finally {
        gateway.stop();
      }
    },
    TIMEOUT,
  );

  test(
    "reasoning alongside assistant text and a tool call stays valid JSON",
    async () => {
      const { home, workspace } = createRoot();
      const reasoning = "weighing the options";
      const signature = "FX_SIG";

      // Reasoning, assistant text, and a tool call in one step. A missing
      // separator between the reasoning and text parts made the request body
      // invalid, which failed the turn with error.SyntaxError before the
      // request was sent, so the follow-up step never ran.
      const gateway = startFakeGateway([
        () =>
          sse([
            { type: "reasoning-start", id: "r1" },
            {
              type: "reasoning-delta",
              id: "r1",
              delta: reasoning,
              providerMetadata: { anthropic: { signature } },
            },
            { type: "reasoning-end", id: "r1" },
            { type: "text-start", id: "a1" },
            { type: "text-delta", id: "a1", delta: "Let me run that." },
            { type: "text-end", id: "a1" },
            {
              type: "tool-call",
              toolCallId: "call_1",
              toolName: "run_command",
              input: { command: "printf hello" },
            },
            {
              type: "finish",
              finishReason: { unified: "tool-calls", raw: "tool_calls" },
              usage: { inputTokens: { total: 5 }, outputTokens: { total: 6 } },
            },
          ]),
        () =>
          sse([
            { type: "text-start", id: "a2" },
            { type: "text-delta", id: "a2", delta: "done" },
            {
              type: "finish",
              finishReason: { unified: "stop", raw: "stop" },
              usage: { inputTokens: { total: 7 }, outputTokens: { total: 2 } },
            },
          ]),
      ]);

      try {
        const result = await runFx(["ask", "--json", "--no-save", "run printf hello"], {
          cwd: workspace,
          env: gatewayEnv(home, gateway),
          timeoutMs: TIMEOUT,
        });

        expect(result.code).toBe(0);
        expect(`${result.stdout}${result.stderr}`).not.toContain("SyntaxError");
        // A second request proves the turn survived to replay the reasoning.
        expect(gateway.requests).toHaveLength(2);

        const body = gateway.requests[1]!.body;
        // Every message must be parseable, not just the reasoning part.
        expect(() => JSON.parse(body)).not.toThrow();
        const replayed = reasoningParts(body);
        expect(replayed).toHaveLength(1);
        expect(replayed[0]!.text).toBe(reasoning);
      } finally {
        gateway.stop();
      }
    },
    TIMEOUT,
  );

  test(
    "a turn without provider reasoning sends no reasoning part",
    async () => {
      const { home, workspace } = createRoot();
      const gateway = startFakeGateway([
        () =>
          sse([
            { type: "text-start", id: "a1" },
            { type: "text-delta", id: "a1", delta: "plain answer" },
            {
              type: "finish",
              finishReason: { unified: "stop", raw: "stop" },
              usage: { inputTokens: { total: 3 }, outputTokens: { total: 2 } },
            },
          ]),
      ]);

      try {
        const result = await runFx(["ask", "--json", "hello"], {
          cwd: workspace,
          env: gatewayEnv(home, gateway),
          timeoutMs: TIMEOUT,
        });

        expect(result.code).toBe(0);
        for (const request of gateway.requests) {
          expect(reasoningParts(request.body)).toHaveLength(0);
          expect(request.body).not.toContain("\"type\":\"reasoning\"");
        }
      } finally {
        gateway.stop();
      }
    },
    TIMEOUT,
  );
});

process.on("exit", () => {
  for (const root of roots) {
    try {
      rmSync(root, { recursive: true, force: true });
    } catch {}
  }
});
