import { expect, test } from "bun:test";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  startFakeGateway,
} from "./tmux-helpers";

const TIMEOUT = 30_000;
const SELECTED_API_KEY = "selected-api-key";

function sessionIdsFromHome(home: string): string[] {
  return readdirSync(join(home, ".fx", "sessions"), {
    withFileTypes: true,
  })
    .filter((entry) => entry.isDirectory() && entry.name !== "latest")
    .map((entry) => entry.name)
    .sort();
}

test(
  "fx ask reports the selected API-key failure without leaking the key",
  async () => {
    const home = mkdtempSync(join(tmpdir(), "fx-auth-source-failure-e2e-"));
    const tracePath = join(home, "trace.log");
    writeFileSync(tracePath, "");
    const gateway = startFakeGateway([
      new Response(JSON.stringify({
        error: { message: `rejected ${SELECTED_API_KEY}` },
      }), {
        status: 401,
        headers: { "content-type": "application/json" },
      }),
    ]);

    try {
      const result = await runFx(
        ["ask", "--json", "--no-save", "report the selected API key"],
        {
          env: {
            HOME: home,
            OPENAI_API_KEY: SELECTED_API_KEY,
            FX_DISABLE_KEYCHAIN: "1",
            FX_SKIP_ONBOARDING: "1",
            FX_TRACE_LOG: tracePath,
                        FX_RESPONSES_BASE_URL: gateway.baseUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
          },
          timeoutMs: TIMEOUT,
        },
      );

      expect(result.code).toBe(1);
      expect(result.stderr).toContain(
        "OPENAI_API_KEY authentication failed · HTTP 401",
      );
      const output = JSON.parse(result.stdout);
      expect(output.exit_code).toBe(1);
      expect(output.output).toBe(
        "OPENAI_API_KEY authentication failed · HTTP 401\n",
      );
      expect(output.auth_failure).toEqual({
        source: "OPENAI_API_KEY",
        reason: "http_unauthorized",
        http_status: 401,
      });
      expect(gateway.requests).toHaveLength(1);
      expect(gateway.requests[0].headers.get("authorization")).toBe(
        `Bearer ${SELECTED_API_KEY}`,
      );
      expect(result.stdout).not.toContain(SELECTED_API_KEY);
      expect(result.stderr).not.toContain(SELECTED_API_KEY);
      expect(readFileSync(tracePath, "utf8")).not.toContain(SELECTED_API_KEY);
    } finally {
      gateway.stop();
      rmSync(home, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);

test(
  "saved API-key 401 discards only the new empty session and preserves resume last",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-auth-empty-session-e2e-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    mkdirSync(home);
    mkdirSync(workspace);
    const gateway = startFakeGateway([
      fakeGatewayFinalText("SEED_SESSION_RESPONSE"),
      new Response(JSON.stringify({ error: { message: "rejected" } }), {
        status: 401,
        headers: { "content-type": "application/json" },
      }),
      fakeGatewayFinalText("RESUMED_SESSION_RESPONSE"),
    ]);
    const env = {
      HOME: home,
      OPENAI_API_KEY: SELECTED_API_KEY,
      FX_DISABLE_KEYCHAIN: "1",
      FX_SKIP_ONBOARDING: "1",
            FX_RESPONSES_BASE_URL: gateway.baseUrl,
      FX_MODEL: FAKE_GATEWAY_MODEL,
    };

    try {
      const seed = await runFx(
        ["ask", "--json", "--auto", "Persist the seed session."],
        { cwd: workspace, env, timeoutMs: TIMEOUT },
      );
      expect(seed.code, `stdout: ${seed.stdout}\nstderr: ${seed.stderr}`).toBe(0);
      expect(seed.stderr).toBe("");
      const seedJson = JSON.parse(seed.stdout);
      expect(seedJson.output).toContain("SEED_SESSION_RESPONSE");
      const seedSessionId = seedJson.session_id as string;
      expect(seedSessionId.length).toBeGreaterThan(0);
      expect(sessionIdsFromHome(home)).toEqual([seedSessionId]);

      const rejected = await runFx(
        ["ask", "--json", "--auto", "Reject this new saved session."],
        { cwd: workspace, env, timeoutMs: TIMEOUT },
      );
      expect(rejected.code).toBe(1);
      expect(rejected.stderr).toBe(
        "fx ask: OPENAI_API_KEY authentication failed · HTTP 401\n",
      );
      const rejectedJson = JSON.parse(rejected.stdout);
      expect(rejectedJson).toMatchObject({
        exit_code: 1,
        session_id: "",
        steps: 0,
        tool_calls: [],
      });
      expect(rejectedJson.error).toBeUndefined();
      expect(sessionIdsFromHome(home)).toEqual([seedSessionId]);

      const sessionsResult = await runFx(
        ["sessions", "--json"],
        { cwd: workspace, env, timeoutMs: TIMEOUT },
      );
      expect(sessionsResult.code).toBe(0);
      const sessions = JSON.parse(sessionsResult.stdout);
      expect(sessions.count).toBe(1);
      expect(sessions.sessions[0].id).toBe(seedSessionId);
      expect(sessions.sessions[0].history_len).toBe(1);

      const resumed = await runFx(
        ["ask", "--json", "--auto", "--resume", "last", "Resume the seed session."],
        { cwd: workspace, env, timeoutMs: TIMEOUT },
      );
      expect(resumed.code, `stdout: ${resumed.stdout}\nstderr: ${resumed.stderr}`).toBe(0);
      expect(resumed.stderr).toBe("");
      const resumedJson = JSON.parse(resumed.stdout);
      expect(resumedJson.session_id).toBe(seedSessionId);
      expect(resumedJson.output).toContain("RESUMED_SESSION_RESPONSE");
      expect(sessionIdsFromHome(home)).toEqual([seedSessionId]);

      const detail = await runFx(
        ["session", "--id", seedSessionId, "--json"],
        { cwd: workspace, env, timeoutMs: TIMEOUT },
      );
      expect(detail.code).toBe(0);
      expect(JSON.parse(detail.stdout).history_len).toBe(2);

      expect(gateway.requests).toHaveLength(3);
      expect(gateway.requests[0].body).toContain("Persist the seed session.");
      expect(gateway.requests[1].body).toContain("Reject this new saved session.");
      expect(gateway.requests[1].body).not.toContain("SEED_SESSION_RESPONSE");
      expect(gateway.requests[2].body).toContain("SEED_SESSION_RESPONSE");
      expect(gateway.requests[2].body).toContain("Resume the seed session.");
      expect(gateway.requests[2].body).not.toContain("Reject this new saved session.");
    } finally {
      gateway.stop();
      rmSync(root, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);
