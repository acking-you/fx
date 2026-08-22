import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";

const TIMEOUT = 15_000;
const NO_GATEWAY_AUTH = {
  AI_GATEWAY_API_KEY: undefined,
  OPENAI_API_KEY: undefined,
  VERCEL_OIDC_TOKEN: undefined,
  CODEX_HOME: undefined,
  FX_CODEX_AUTH_FILE: undefined,
  FX_DISABLE_KEYCHAIN: "1",
};

async function runWithoutGatewayAuth(args: string[]) {
  const root = mkdtempSync(join(tmpdir(), "fx-web-fetch-no-auth-"));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(home);
  mkdirSync(workspace);
  try {
    return await runFx(args, {
      cwd: workspace,
      env: { ...NO_GATEWAY_AUTH, HOME: home },
    });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

function expectNoFetchProgress(stderr: string) {
  expect(stderr).not.toContain("Fetching ");
  expect(stderr).not.toContain("Converting ");
  expect(stderr).not.toContain("Extracting ");
}

describe("web_fetch permission progress", () => {
  test(
    "default ask emits no native fetch progress before authentication",
    async () => {
      const result = await runWithoutGatewayAuth([
        "ask",
        "--auto",
        "fetch https://example.com/ and summarize it",
      ]);

      expect(result.code).toBe(1);
      expect(result.stderr).toContain("Fx needs a model credential. Use fx login for Vercel, fx login codex for ChatGPT Codex, fx login grok for Grok, set OPENAI_API_KEY for a Responses API, or use fx setup or AI_GATEWAY_API_KEY for Vercel AI Gateway.");
      expectNoFetchProgress(result.stderr);
    },
    TIMEOUT,
  );

});
