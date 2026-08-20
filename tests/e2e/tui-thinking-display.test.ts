import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startFakeGateway, TmuxSession, tmuxAvailable } from "./tmux-helpers";

const TIMEOUT = 30_000;
const MODEL = "openai/gpt-5";

// Distinctive lines so the assertions cannot match incidental transcript text.
const EARLY_THOUGHT = "FXEARLYTHOUGHT";
const LATE_THOUGHT = "FXLATETHOUGHT";
const ANSWER = "FXFINALANSWER";

let root: string | null = null;
let session: TmuxSession | null = null;
let gateway: ReturnType<typeof startFakeGateway> | null = null;

function reasoningStream(reasoning: string, answer: string) {
  const encoder = new TextEncoder();
  const send = (event: object) => `data: ${JSON.stringify(event)}\n\n`;
  return new Response(
    new ReadableStream<Uint8Array>({
      async start(controller) {
        controller.enqueue(encoder.encode(send({ type: "reasoning-start", id: "r1" })));
        // Stream one line per chunk, as a provider does, so each chunk drains
        // through the worker-event queue separately.
        for (const line of reasoning.split("\n")) {
          controller.enqueue(
            encoder.encode(
              send({ type: "reasoning-delta", id: "r1", delta: `${line}\n` }),
            ),
          );
          await Bun.sleep(10);
        }
        controller.enqueue(encoder.encode(send({ type: "reasoning-end", id: "r1" })));
        controller.enqueue(encoder.encode(send({ type: "text-start", id: "a1" })));
        controller.enqueue(
          encoder.encode(send({ type: "text-delta", id: "a1", delta: answer })),
        );
        controller.enqueue(
          encoder.encode(
            send({
              type: "finish",
              finishReason: { unified: "stop", raw: "stop" },
              usage: { inputTokens: { total: 4 }, outputTokens: { total: 8 } },
            }),
          ),
        );
        controller.enqueue(encoder.encode("data: [DONE]\n\n"));
        controller.close();
      },
    }),
    { headers: { "content-type": "text/event-stream" } },
  );
}

afterEach(async () => {
  if (session) {
    await session.kill();
    session = null;
  }
  gateway?.stop();
  gateway = null;
  if (root) {
    try {
      rmSync(root, { recursive: true, force: true });
    } catch {}
    root = null;
  }
});

describe.skipIf(!tmuxAvailable())("TUI thinking display", () => {
  test(
    "streams reasoning by default and truncates it to a trailing window",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-thinking-")));
      const home = join(root, "home");
      const workspacePath = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspacePath, { recursive: true });
      // No show_thinking key: reasoning display must not need opting in.
      writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ model: MODEL }));
      const workspace = realpathSync(workspacePath);

      // Far more lines than the display window keeps, so truncation is visible.
      const reasoning = [
        EARLY_THOUGHT,
        ...Array.from({ length: 30 }, (_, i) => `middle thought ${i + 1}`),
        LATE_THOUGHT,
      ].join("\n");

      gateway = startFakeGateway([() => reasoningStream(reasoning, ANSWER)], {
        models: [{ id: MODEL, type: "language", tags: ["reasoning", "tool-use"] }],
      });

      session = await TmuxSession.create({
        cwd: workspace,
        width: 72,
        height: 24,
        minimumHistoryLines: 400,
        stderrPath,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-tui-thinking-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_PERMISSION_MODE: "auto",
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
          FX_MODEL: MODEL,
        },
      });
      await session.waitForComposer(TIMEOUT);

      await session.sendText("think it through");
      await session.waitForText(ANSWER, TIMEOUT);
      await session.waitForComposer(TIMEOUT);

      const scrollback = await session.captureFullScrollback();

      // Reasoning reached the transcript with no flag, setting, or env var.
      expect(scrollback).toContain(LATE_THOUGHT);
      // The window keeps the tail, so the oldest line is dropped from view.
      expect(scrollback).not.toContain(EARLY_THOUGHT);
      expect(scrollback).toContain(ANSWER);

      // This path aborted twice before on cross-thread transcript mutation, so
      // a clean stderr and a live process are part of the contract.
      expect(session.isAlive()).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT * 2,
  );
});
