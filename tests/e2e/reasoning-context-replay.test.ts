import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";
import {
  responseCompleted,
  responseFunctionCall,
  responseTextDelta,
  startFakeGateway,
} from "./tmux-helpers";

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
    OPENAI_API_KEY: "fake-reasoning-replay-key",
    FX_DISABLE_KEYCHAIN: "1",
    FX_MODEL: MODEL,
    FX_PERMISSION_MODE: "auto",
    FX_RESPONSES_BASE_URL: gateway.baseUrl,
  };
}

/** Responses reasoning items in the order the request serialized them. */
function reasoningItems(body: string): Array<Record<string, unknown>> {
  const request = JSON.parse(body) as {
    input?: Array<Record<string, unknown>>;
  };
  return (request.input ?? []).filter((item) => item.type === "reasoning");
}

function reasoningToolResponse(
  reasoning: string,
  encryptedContent: string,
  assistantText?: string,
) {
  return sse([
    {
      type: "response.reasoning_summary_text.delta",
      item_id: "rs_1",
      output_index: 0,
      summary_index: 0,
      delta: reasoning,
    },
    {
      type: "response.output_item.done",
      output_index: 0,
      item: {
        type: "reasoning",
        id: "rs_1",
        summary: [{ type: "summary_text", text: reasoning }],
        encrypted_content: encryptedContent,
      },
    },
    ...(assistantText ? [responseTextDelta(assistantText, "answer_1", 1)] : []),
    ...responseFunctionCall(
      "call_1",
      "terminal",
      { action: "exec", command: "printf hello" },
      assistantText ? 2 : 1,
    ),
    responseCompleted(5, 6),
  ]);
}

describe("reasoning context replay", () => {
  test(
    "a tool step replays the full reasoning item to the provider",
    async () => {
      const { home, workspace } = createRoot();
      // Longer than any display window, so a body clipped for the transcript
      // would be visibly shorter than what the provider receives.
      const reasoningLines = Array.from(
        { length: 40 },
        (_, index) => `reasoning line ${index + 1}`,
      );
      const reasoning = reasoningLines.join("\n");
      const encryptedContent = "FX_ENCRYPTED_REASONING_STATE";

      const gateway = startFakeGateway([
        () => reasoningToolResponse(reasoning, encryptedContent),
        () => sse([responseTextDelta("done"), responseCompleted(7, 2)]),
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
        expect(reasoningItems(gateway.requests[0]!.body)).toHaveLength(0);

        // The follow-up request replays the reasoning that produced the tool
        // call, verbatim and untruncated, with its opaque provider state.
        const replayed = reasoningItems(gateway.requests[1]!.body);
        expect(replayed).toHaveLength(1);
        expect(replayed[0]!.id).toBe("rs_1");
        expect(replayed[0]!.summary).toEqual([
          { type: "summary_text", text: reasoning },
        ]);
        expect(replayed[0]!.encrypted_content).toBe(encryptedContent);
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
      const encryptedContent = "FX_ENCRYPTED_STATE";

      // Reasoning, assistant text, and a tool call in one step. A missing
      // separator between the reasoning and text parts made the request body
      // invalid, which failed the turn with error.SyntaxError before the
      // request was sent, so the follow-up step never ran.
      const gateway = startFakeGateway([
        () => reasoningToolResponse(reasoning, encryptedContent, "Let me run that."),
        () => sse([responseTextDelta("done"), responseCompleted(7, 2)]),
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
        const replayed = reasoningItems(body);
        expect(replayed).toHaveLength(1);
        expect(replayed[0]!.encrypted_content).toBe(encryptedContent);
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
        () => sse([responseTextDelta("plain answer"), responseCompleted(3, 2)]),
      ]);

      try {
        const result = await runFx(["ask", "--json", "hello"], {
          cwd: workspace,
          env: gatewayEnv(home, gateway),
          timeoutMs: TIMEOUT,
        });

        expect(result.code).toBe(0);
        for (const request of gateway.requests) {
          expect(reasoningItems(request.body)).toHaveLength(0);
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
