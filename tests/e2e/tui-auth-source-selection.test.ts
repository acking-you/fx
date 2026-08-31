import { afterEach, expect, test } from "bun:test";
import { spawn as nodeSpawn } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, REPO_ROOT, runFx } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const HAS_TMUX = tmuxAvailable();
if (process.env.FX_REQUIRE_TMUX === "1" && !HAS_TMUX) {
  throw new Error("tmux is required for tui-auth-source-selection.test.ts");
}

const tmuxTest = test.skipIf(!HAS_TMUX);
const TIMEOUT = 30_000;
const ENV_TOKEN = "env-api-key-token";

function grokSubscriptionModel(
  id: string,
  contextWindow: number,
  efforts: string[] = [],
  supportsBackendSearch?: boolean,
) {
  const model = {
    id,
    model: id,
    api_backend: "responses",
    context_window: contextWindow,
    supports_reasoning_effort: efforts.length > 0,
    reasoning_efforts: efforts.map((value) => ({ value })),
  };
  return supportsBackendSearch === undefined
    ? model
    : { ...model, supportsBackendSearch };
}

function grokModalityModel(id: string, vision: boolean) {
  return {
    id,
    input_modalities: vision ? ["text", "image"] : ["text"],
    output_modalities: ["text"],
  };
}

let session: TmuxSession | null = null;
let home: string | null = null;
let stderrPath: string | null = null;
let gateway: ReturnType<typeof startFakeGateway> | null = null;
let chatgptOauth: ReturnType<typeof startFakeChatGptOAuth> | null = null;

afterEach(async () => {
  await session?.kill();
  session = null;
  gateway?.stop();
  gateway = null;
  chatgptOauth?.stop();
  chatgptOauth = null;
  if (home) rmSync(home, { recursive: true, force: true });
  home = null;
  stderrPath = null;
});

function writeSeededChatGptLogin(
  testHome: string,
  accessToken = chatgptAccessToken(),
  expiresAtMs = Date.now() + 60 * 60 * 1000,
): void {
  const fxDir = join(testHome, ".fx");
  mkdirSync(fxDir, { recursive: true, mode: 0o700 });
  chmodSync(fxDir, 0o700);
  const authPath = join(fxDir, "chatgpt-auth.json");
  writeFileSync(authPath, JSON.stringify({
    version: 1,
    access_token: accessToken,
    refresh_token: "chatgpt-refresh",
    expires_at_ms: expiresAtMs,
    account_id: "acct_e2e",
  }) + "\n", { mode: 0o600 });
  chmodSync(authPath, 0o600);
}

function writeSeededGrokLogin(testHome: string, accessToken: string, accountId = "acct_grok_e2e"): void {
  const fxDir = join(testHome, ".fx");
  mkdirSync(fxDir, { recursive: true, mode: 0o700 });
  chmodSync(fxDir, 0o700);
  const authPath = join(fxDir, "grok-auth.json");
  writeFileSync(authPath, JSON.stringify({
    version: 1,
    access_token: accessToken,
    refresh_token: "grok-refresh",
    expires_at_ms: Date.now() + 60 * 60 * 1000,
    account_id: accountId,
  }) + "\n", { mode: 0o600 });
  chmodSync(authPath, 0o600);
}

function readSingleUsageSnapshot(testHome: string): {
  billing: string;
  next_sequence: number;
  settled_through_sequence: number;
  input_tokens: number;
  output_tokens: number;
  request_count: number | null;
  models: Array<{ model: string; request_count: number | null }>;
  publication_backlog: unknown[];
} {
  const sessionsDir = join(testHome, ".fx", "sessions");
  const usagePaths = readdirSync(sessionsDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => join(sessionsDir, entry.name, "usage-v2.json"))
    .filter((path) => existsSync(path));
  expect(usagePaths).toHaveLength(1);
  return (JSON.parse(readFileSync(usagePaths[0]!, "utf8")) as {
    snapshot: {
      billing: string;
      next_sequence: number;
      settled_through_sequence: number;
      input_tokens: number;
      output_tokens: number;
      request_count: number | null;
      models: Array<{ model: string; request_count: number | null }>;
      publication_backlog: unknown[];
    };
  }).snapshot;
}

async function startFx(
  testHome: string,
  testStderrPath: string,
  fakeGateway: ReturnType<typeof startFakeGateway>,
  tracePath?: string,
  envOverrides: Record<string, string | undefined> = {},
  cwd?: string,
): Promise<TmuxSession> {
  return TmuxSession.create({
    cmd: FX_BIN,
    cwd,
    env: {
      HOME: testHome,
      OPENAI_API_KEY: ENV_TOKEN,
      FX_DISABLE_KEYCHAIN: "1",
      FX_SKIP_ONBOARDING: "1",
      FX_RESPONSES_BASE_URL: fakeGateway.baseUrl,
      FX_MODEL: FAKE_GATEWAY_MODEL,
      FX_NO_OPEN_BROWSER: "1",
      FX_TRACE_LOG: tracePath,
      FX_TRACE_SCOPES: tracePath ? "auth,prompt" : undefined,
      ...envOverrides,
    },
    stderrPath: testStderrPath,
    width: 100,
    height: 30,
  });
}

function chatgptAccessToken(accountId = "acct_e2e"): string {
  const payload = Buffer.from(JSON.stringify({
    exp: 4_102_444_800,
    "https://api.openai.com/auth": { chatgpt_account_id: accountId },
  })).toString("base64url");
  return `header.${payload}.signature`;
}

function writeCodexSetupSource(testHome: string, accessToken: string): string {
  const codexHome = join(testHome, "codex-source");
  mkdirSync(codexHome, { recursive: true, mode: 0o700 });
  const authPath = join(codexHome, "auth.json");
  writeFileSync(authPath, JSON.stringify({
    auth_mode: "chatgpt",
    tokens: {
      access_token: accessToken,
      refresh_token: "codex-setup-refresh",
      account_id: "acct_e2e",
    },
  }), { mode: 0o600 });
  chmodSync(authPath, 0o600);
  return codexHome;
}

function startFakeChatGptOAuth(
  options: {
    tokenDelayMs?: number;
    modelDelayMs?: number;
    responseDelayMs?: number;
    contextOverflowResponses?: number;
    unauthorizedResponses?: number;
    holdCompactionResponse?: boolean;
  } = {},
) {
  const accessToken = chatgptAccessToken();
  let responseCount = 0;
  let releaseCompactionResponse: (() => void) | null = null;
  const compactionResponseGate = options.holdCompactionResponse
    ? new Promise<void>((resolve) => {
      releaseCompactionResponse = resolve;
    })
    : null;
  let models = [
    { slug: "gpt-5.6-sol", visibility: "list", supported_in_api: true, supported_reasoning_levels: [{ effort: "max" }, { effort: "high" }], additional_speed_tiers: ["fast"], input_modalities: ["text", "image"], context_window: 272000 },
    { slug: "gpt-5.4-mini", visibility: "list", supported_in_api: true, supported_reasoning_levels: [{ effort: "low" }], additional_speed_tiers: [], input_modalities: ["text"], context_window: 128000 },
  ];
  const requests: Array<{
    method: string;
    path: string;
    authorization: string | null;
    body: string | null;
    accept: string | null;
    betaFeatures: string | null;
  }> = [];
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const url = new URL(request.url);
      const body = url.pathname === "/chatgpt/responses" || url.pathname === "/chatgpt/token"
        ? await request.text()
        : null;
      requests.push({
        method: request.method,
        path: url.pathname,
        authorization: request.headers.get("authorization"),
        body,
        accept: request.headers.get("accept"),
        betaFeatures: request.headers.get("x-codex-beta-features"),
      });
      if (url.pathname === "/oauth/authorize") {
        const redirectUri = url.searchParams.get("redirect_uri");
        const state = url.searchParams.get("state");
        if (!redirectUri || !state) return new Response("invalid authorize request", { status: 400 });
        const callback = new URL(redirectUri.replace("localhost", "127.0.0.1"));
        callback.searchParams.set("code", "chatgpt-code");
        callback.searchParams.set("state", state);
        return Response.redirect(callback.toString(), 302);
      }
      if (url.pathname === "/chatgpt/token") {
        if (options.tokenDelayMs) await Bun.sleep(options.tokenDelayMs);
        return Response.json({
          access_token: accessToken,
          refresh_token: "chatgpt-refresh",
          expires_in: 3600,
        });
      }
      if (url.pathname === "/chatgpt/models") {
        if (options.modelDelayMs) await Bun.sleep(options.modelDelayMs);
        return Response.json({ models });
      }
      if (url.pathname === "/chatgpt/responses") {
        responseCount += 1;
        if (responseCount <= (options.unauthorizedResponses ?? 0)) {
          return Response.json(
            { error: { message: "expired ChatGPT token" } },
            { status: 401 },
          );
        }
        if (options.responseDelayMs) await Bun.sleep(options.responseDelayMs);
        const parsedBody = JSON.parse(body ?? "{}") as {
          input?: Array<Record<string, unknown>>;
          stream?: boolean;
        };
        const compactInput = parsedBody.input ?? [];
        if (
          compactInput.at(-1)?.type !== "compaction_trigger" &&
          responseCount <= (options.contextOverflowResponses ?? 0)
        ) {
          return Response.json(
            { error: { code: "context_length_exceeded", message: "maximum context length reached" } },
            { status: 400 },
          );
        }
        if (compactInput.at(-1)?.type === "compaction_trigger") {
          if (parsedBody.stream !== true) {
            return Response.json(
              { detail: "Stream must be set to true" },
              { status: 400 },
            );
          }
          if (compactionResponseGate) await compactionResponseGate;
          return new Response(
            'data: {"type":"response.output_item.done","output_index":0,"item":{"id":"cmp_e2e","type":"compaction","encrypted_content":"opaque-codex-compaction-e2e"}}\n\n' +
              'data: {"type":"response.completed","response":{"id":"resp_compact_e2e","status":"completed","output":[],"usage":{"input_tokens":12,"output_tokens":3,"total_tokens":15}}}\n\n',
            { headers: { "content-type": "text/event-stream" } },
          );
        }
        return new Response(
          'data: {"type":"response.output_text.delta","delta":"CHATGPT_DIRECT_RESPONSE"}\n\n' +
            'data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":4,"output_tokens":2}}}\n\n',
          { headers: { "content-type": "text/event-stream" } },
        );
      }
      return new Response("not found", { status: 404 });
    },
  });
  const baseUrl = `http://127.0.0.1:${server.port}`;
  return {
    accessToken,
    requests,
    env: {
      FX_E2E_CHATGPT_ISSUER_URL: baseUrl,
      FX_E2E_CHATGPT_TOKEN_URL: `${baseUrl}/chatgpt/token`,
      FX_E2E_OPENAI_CODEX_MODELS_URL: `${baseUrl}/chatgpt/models`,
      FX_CODEX_BASE_URL: `${baseUrl}/chatgpt`,
    },
    baseUrl,
    setModels(next: typeof models) {
      models = next;
    },
    releaseCompaction() {
      releaseCompactionResponse?.();
      releaseCompactionResponse = null;
    },
    stop() {
      releaseCompactionResponse?.();
      releaseCompactionResponse = null;
      server.stop(true);
    },
  };
}

function startFakeOpenAIResponses() {
  const requests: Array<{
    path: string;
    authorization: string | null;
    body: string | null;
  }> = [];
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const url = new URL(request.url);
      const body = request.method === "POST" ? await request.text() : null;
      requests.push({
        path: url.pathname,
        authorization: request.headers.get("authorization"),
        body,
      });
      if (url.pathname === "/v1/models") {
        return Response.json({ data: [{ id: "gpt-5.4", object: "model" }] });
      }
      if (url.pathname === "/v1/responses") {
        return new Response(
          'data: {"type":"response.output_text.delta","delta":"OPENAI_BYOK_RESPONSE"}\n\n' +
            'data: {"type":"response.completed","response":{"id":"resp_openai_byok","status":"completed","usage":{"input_tokens":5,"output_tokens":2,"total_tokens":7}}}\n\n',
          { headers: { "content-type": "text/event-stream" } },
        );
      }
      return new Response("not found", { status: 404 });
    },
  });
  const baseUrl = `http://127.0.0.1:${server.port}/v1`;
  return {
    requests,
    baseUrl,
    stop() { server.stop(true); },
  };
}

function startFakeGrokOAuth(options: {
  unauthorizedResponses?: number;
  revokeStatus?: number;
  userinfoSub?: string;
} = {}) {
  const initialAccessToken = "grok-initial-access-token";
  const refreshedAccessToken = "grok-refreshed-access-token";
  const requests: Array<{
    method: string;
    path: string;
    authorization: string | null;
    body: string | null;
    conversationId: string | null;
    tokenAuth: string | null;
    authenticateResponse: string | null;
    clientIdentifier: string | null;
    clientVersion: string | null;
    modelOverride: string | null;
    grokUserId: string | null;
    userId: string | null;
    query: string;
  }> = [];
  let tokenCalls = 0;
  let responseCalls = 0;
  let models = [
    { id: "grok-4.20", object: "model", input_modalities: ["text", "image"], output_modalities: ["text"] },
    { id: "grok-4.6", object: "model", input_modalities: ["text", "image"], output_modalities: ["text"] },
    { id: "grok-image-only", object: "model", input_modalities: ["text"], output_modalities: ["image"] },
  ];
  const allSubscriptionModels = [
    grokSubscriptionModel("grok-4.20", 1_000_000),
    grokSubscriptionModel("grok-4.6", 500_000, ["xhigh", "high", "medium", "low"]),
  ];
  let subscriptionModels = allSubscriptionModels;
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const url = new URL(request.url);
      const body = request.method === "POST" ? await request.text() : null;
      requests.push({
        method: request.method,
        path: url.pathname,
        authorization: request.headers.get("authorization"),
        body,
        conversationId: request.headers.get("x-grok-conv-id"),
        tokenAuth: request.headers.get("x-xai-token-auth"),
        authenticateResponse: request.headers.get("x-authenticateresponse"),
        clientIdentifier: request.headers.get("x-grok-client-identifier"),
        clientVersion: request.headers.get("x-grok-client-version"),
        modelOverride: request.headers.get("x-grok-model-override"),
        grokUserId: request.headers.get("x-grok-user-id"),
        userId: request.headers.get("x-userid"),
        query: url.search,
      });
      if (url.pathname === "/oauth2/authorize") {
        const redirectUri = url.searchParams.get("redirect_uri");
        const state = url.searchParams.get("state");
        if (!redirectUri || !state || url.searchParams.get("nonce")) {
          return new Response("invalid authorize request", { status: 400 });
        }
        if (url.searchParams.get("referrer") !== "fx") {
          return new Response("missing fx referrer", { status: 400 });
        }
        const callback = new URL(redirectUri);
        callback.searchParams.set("code", "grok-code");
        callback.searchParams.set("state", state);
        return Response.redirect(callback.toString(), 302);
      }
      if (url.pathname === "/oauth2/token") {
        tokenCalls += 1;
        const form = new URLSearchParams(body ?? "");
        const refresh = form.get("grant_type") === "refresh_token";
        return Response.json({
          access_token: refresh ? refreshedAccessToken : initialAccessToken,
          refresh_token: refresh ? "grok-refresh-next" : "grok-refresh",
          expires_in: 3600,
        });
      }
      if (url.pathname === "/oauth2/userinfo") {
        if (!request.headers.get("authorization")?.startsWith("Bearer grok-")) {
          return Response.json({ error: "unauthorized" }, { status: 401 });
        }
        return Response.json({ sub: options.userinfoSub ?? "acct_grok_e2e" });
      }
      if (url.pathname === "/oauth2/revoke") {
        const form = new URLSearchParams(body ?? "");
        const valid = form.get("client_id") === "b1a00492-073a-47ea-816f-4c329264a828" &&
          (form.get("token") === "grok-refresh-next" || form.get("token") === "grok-refresh");
        if (valid && options.revokeStatus && options.revokeStatus !== 200) {
          return Response.json({ error: "revocation unavailable" }, { status: options.revokeStatus });
        }
        return Response.json(valid ? { revoked: true } : { error: "invalid" }, {
          status: valid ? 200 : 400,
        });
      }
      if (url.pathname === "/v1/language-models") {
        return Response.json({ models });
      }
      if (url.pathname === "/v1/models") {
        return Response.json({ data: subscriptionModels });
      }
      if (url.pathname === "/v1/responses") {
        responseCalls += 1;
        if (responseCalls <= (options.unauthorizedResponses ?? 0)) {
          return Response.json({ error: { message: "expired" } }, { status: 401 });
        }
        return new Response(
          'data: {"type":"response.output_text.delta","delta":"GROK_DIRECT_RESPONSE"}\n\n' +
            'data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":4,"output_tokens":2}}}\n\n',
          { headers: { "content-type": "text/event-stream" } },
        );
      }
      return new Response("not found", { status: 404 });
    },
  });
  const baseUrl = `http://127.0.0.1:${server.port}`;
  return {
    initialAccessToken,
    refreshedAccessToken,
    requests,
    tokenCalls: () => tokenCalls,
    baseUrl,
    env: {
      FX_E2E_GROK_ISSUER_URL: baseUrl,
      FX_E2E_GROK_TOKEN_URL: `${baseUrl}/oauth2/token`,
      FX_E2E_GROK_USERINFO_URL: `${baseUrl}/oauth2/userinfo`,
      FX_E2E_GROK_REVOKE_URL: `${baseUrl}/oauth2/revoke`,
      FX_E2E_XAI_GROK_MODELS_URL: `${baseUrl}/v1/models`,
      FX_E2E_XAI_GROK_MODALITIES_URL: `${baseUrl}/v1/language-models`,
      FX_E2E_XAI_GROK_RESPONSES_URL: `${baseUrl}/v1/responses`,
    },
    setModels(next: typeof models) {
      models = next;
      const visibleIds = new Set(next.map((model) => model.id));
      subscriptionModels = allSubscriptionModels.filter((model) => visibleIds.has(model.id));
    },
    stop() { server.stop(true); },
  };
}

async function runGrokLoginWithBrowser(env: Record<string, string | undefined>) {
  const childEnv: NodeJS.ProcessEnv = { ...process.env };
  for (const [key, value] of Object.entries(env)) {
    if (value === undefined) delete childEnv[key];
    else childEnv[key] = value;
  }
  const proc = nodeSpawn(FX_BIN, ["login", "grok"], {
    cwd: REPO_ROOT,
    env: childEnv,
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  proc.stdout!.on("data", (chunk: Buffer) => { stdout += chunk.toString(); });
  proc.stderr!.on("data", (chunk: Buffer) => { stderr += chunk.toString(); });
  const deadline = Date.now() + TIMEOUT;
  let authorizationUrl: string | undefined;
  while (Date.now() < deadline) {
    authorizationUrl = stdout.match(/http:\/\/127\.0\.0\.1:\d+\/oauth2\/authorize\?\S+/)?.[0];
    if (authorizationUrl) break;
    await Bun.sleep(20);
  }
  if (!authorizationUrl) {
    proc.kill("SIGTERM");
    throw new Error(`Grok login did not print an authorization URL: ${stdout}\n${stderr}`);
  }
  const response = await fetch(authorizationUrl, { redirect: "follow" });
  expect(response.status).toBe(200);
  const code = await new Promise<number>((resolve, reject) => {
    proc.once("error", reject);
    proc.once("close", (value) => resolve(value ?? 1));
  });
  return { code, stdout, stderr };
}

async function completeDisplayedGrokLogin(
  activeSession: TmuxSession,
  fixture: ReturnType<typeof startFakeGrokOAuth>,
) {
  await activeSession.waitForText("Authorize with Grok", TIMEOUT);
  const escapes = await activeSession.capturePaneEscapes();
  const urlStart = escapes.indexOf(`${fixture.baseUrl}/oauth2/authorize?`);
  const linkStart = escapes.lastIndexOf("\x1b]8;", urlStart);
  const urlEnd = escapes.indexOf("\x1b\\", urlStart);
  if (urlStart < 0 || linkStart < 0 || urlEnd < 0) {
    throw new Error("Grok authorization hyperlink was not rendered");
  }
  const authorizationUrl = escapes.slice(urlStart, urlEnd);
  const response = await fetch(authorizationUrl, { redirect: "follow" });
  expect(response.status).toBe(200);
}

async function completeDisplayedCodexLogin(
  activeSession: TmuxSession,
  fixture: ReturnType<typeof startFakeChatGptOAuth>,
) {
  await activeSession.waitForText("Authorize with Codex", TIMEOUT);
  const escapes = await activeSession.capturePaneEscapes();
  const urlStart = escapes.indexOf(`${fixture.baseUrl}/oauth/authorize?`);
  const linkStart = escapes.lastIndexOf("\x1b]8;", urlStart);
  const urlEnd = escapes.indexOf("\x1b\\", urlStart);
  if (urlStart < 0 || linkStart < 0 || urlEnd < 0) {
    throw new Error("Codex authorization hyperlink was not rendered");
  }
  const authorizationUrl = escapes.slice(urlStart, urlEnd);
  const response = await fetch(authorizationUrl, { redirect: "follow" });
  expect(response.status).toBe(200);
}

async function runCodexLoginWithBrowser(
  env: Record<string, string | undefined>,
) {
  const childEnv: NodeJS.ProcessEnv = { ...process.env };
  for (const [key, value] of Object.entries(env)) {
    if (value === undefined) delete childEnv[key];
    else childEnv[key] = value;
  }
  const proc = nodeSpawn(FX_BIN, ["login", "codex"], {
    cwd: REPO_ROOT,
    env: childEnv,
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  proc.stdout!.on("data", (chunk: Buffer) => { stdout += chunk.toString(); });
  proc.stderr!.on("data", (chunk: Buffer) => { stderr += chunk.toString(); });
  const deadline = Date.now() + TIMEOUT;
  let authorizationUrl: string | undefined;
  while (Date.now() < deadline) {
    authorizationUrl = stdout.match(/http:\/\/127\.0\.0\.1:\d+\/oauth\/authorize\?\S+/)?.[0];
    if (authorizationUrl) break;
    await Bun.sleep(20);
  }
  if (!authorizationUrl) {
    proc.kill("SIGTERM");
    throw new Error(`Codex login did not print an authorization URL: ${stdout}\n${stderr}`);
  }
  const response = await fetch(authorizationUrl, { redirect: "follow" });
  expect(response.status).toBe(200);
  const code = await new Promise<number>((resolve, reject) => {
    proc.once("error", reject);
    proc.once("close", (value) => resolve(value ?? 1));
  });
  return { code, stdout, stderr };
}

function startFakeCodexToolLoop(options: {
  toolName?: string;
  toolArguments?: object;
  finalText?: string;
} = {}) {
  const bodies: string[] = [];
  const accessToken = chatgptAccessToken("acct_tool_loop");
  const toolName = options.toolName ?? "read_file";
  const toolArguments = options.toolArguments ?? { path: "README.md" };
  const finalText = options.finalText ?? "CODEX_TOOL_LOOP_OK";
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      if (new URL(request.url).pathname === "/models") {
        return Response.json({ models: [
          { slug: "gpt-5.6-sol", visibility: "list", supported_in_api: true, supported_reasoning_levels: [{ effort: "high" }], additional_speed_tiers: [], input_modalities: ["text"], context_window: 272000 },
          { slug: "gpt-5.4-mini", visibility: "list", supported_in_api: true, supported_reasoning_levels: [{ effort: "low" }], additional_speed_tiers: [], input_modalities: ["text"], context_window: 128000 },
        ] });
      }
      bodies.push(await request.text());
      if (bodies.length === 1) {
        return new Response(
          'data: {"type":"response.output_item.added","output_index":0,"item":{"type":"reasoning"}}\n\n' +
            'data: {"type":"response.output_item.done","output_index":0,"item":{"id":"rs_tool","type":"reasoning","summary":[],"encrypted_content":"opaque-tool-loop"}}\n\n' +
            `data: ${JSON.stringify({ type: "response.output_item.added", output_index: 1, item: { type: "function_call", call_id: "call_tool", name: toolName } })}\n\n` +
            `data: ${JSON.stringify({ type: "response.function_call_arguments.done", output_index: 1, arguments: JSON.stringify(toolArguments) })}\n\n` +
            'data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":5,"output_tokens":2}}}\n\n',
          { headers: { "content-type": "text/event-stream" } },
        );
      }
      return new Response(
        `data: ${JSON.stringify({ type: "response.output_text.delta", delta: finalText })}\n\n` +
          'data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":7,"output_tokens":3}}}\n\n',
        { headers: { "content-type": "text/event-stream" } },
      );
    },
  });
  return {
    accessToken,
    bodies,
    responsesUrl: `http://127.0.0.1:${server.port}/responses`,
    modelsUrl: `http://127.0.0.1:${server.port}/models`,
    stop() { server.stop(true); },
  };
}

function startFakeCodexCapacityLoop() {
  const bodies: string[] = [];
  const accessToken = chatgptAccessToken("acct_capacity_loop");
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      if (new URL(request.url).pathname === "/models") {
        return Response.json({ models: [
          { slug: "gpt-5.6-sol", visibility: "list", supported_in_api: true, supported_reasoning_levels: [{ effort: "high" }], additional_speed_tiers: [], input_modalities: ["text"], context_window: 272000 },
        ] });
      }
      bodies.push(await request.text());
      const call = bodies.length;
      if (call <= 64) {
        return new Response(
          `data: ${JSON.stringify({ type: "response.output_item.added", output_index: 0, item: { type: "function_call", call_id: `call_capacity_${call}`, name: "read_file" } })}\n\n` +
            `data: ${JSON.stringify({ type: "response.function_call_arguments.done", output_index: 0, arguments: JSON.stringify({ path: "README.md", start_line: call, line_count: 1 }) })}\n\n` +
            `data: ${JSON.stringify({ type: "response.completed", response: { id: `resp_capacity_${call}`, status: "completed", usage: { input_tokens: 5, output_tokens: 2 } } })}\n\n`,
          { headers: { "content-type": "text/event-stream" } },
        );
      }
      const text = call === 65 ? "CODEX_CAPACITY_65_OK" : "CODEX_CAPACITY_NEXT_OK";
      return new Response(
        `data: ${JSON.stringify({ type: "response.output_text.delta", delta: text })}\n\n` +
          `data: ${JSON.stringify({ type: "response.completed", response: { id: `resp_capacity_${call}`, status: "completed", usage: { input_tokens: 7, output_tokens: 3 } } })}\n\n`,
        { headers: { "content-type": "text/event-stream" } },
      );
    },
  });
  return {
    accessToken,
    bodies,
    responsesUrl: `http://127.0.0.1:${server.port}/responses`,
    modelsUrl: `http://127.0.0.1:${server.port}/models`,
    stop() { server.stop(true); },
  };
}

function startFakeGrokToolLoop(options: {
  toolName?: string;
  toolArguments?: object;
  finalText?: string;
} = {}) {
  const bodies: string[] = [];
  const accessToken = "grok-tool-loop-token";
  const toolName = options.toolName ?? "read_file";
  const toolArguments = options.toolArguments ?? { path: "README.md" };
  const finalText = options.finalText ?? "GROK_TOOL_LOOP_OK";
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const path = new URL(request.url).pathname;
      if (path === "/models") {
        return Response.json({ data: [grokSubscriptionModel("grok-4.20", 1_000_000)] });
      }
      if (path === "/modalities") {
        return Response.json({ models: [grokModalityModel("grok-4.20", true)] });
      }
      bodies.push(await request.text());
      if (bodies.length === 1) {
        return new Response(
          'data: {"type":"response.output_item.added","output_index":0,"item":{"type":"reasoning"}}\n\n' +
            'data: {"type":"response.output_item.done","output_index":0,"item":{"id":"rs_tool","type":"reasoning","summary":[],"encrypted_content":"opaque-grok-tool-loop"}}\n\n' +
            `data: ${JSON.stringify({ type: "response.output_item.added", output_index: 1, item: { type: "function_call", call_id: "call_tool", name: toolName } })}\n\n` +
            `data: ${JSON.stringify({ type: "response.function_call_arguments.done", output_index: 1, arguments: JSON.stringify(toolArguments) })}\n\n` +
            'data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":5,"output_tokens":2}}}\n\n',
          { headers: { "content-type": "text/event-stream" } },
        );
      }
      return new Response(
        `data: ${JSON.stringify({ type: "response.output_text.delta", delta: finalText })}\n\n` +
          'data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":7,"output_tokens":3}}}\n\n',
        { headers: { "content-type": "text/event-stream" } },
      );
    },
  });
  return {
    accessToken,
    bodies,
    responsesUrl: `http://127.0.0.1:${server.port}/responses`,
    modelsUrl: `http://127.0.0.1:${server.port}/models`,
    modalitiesUrl: `http://127.0.0.1:${server.port}/modalities`,
    stop() { server.stop(true); },
  };
}

function startFakeGrokWebSearch() {
  const bodies: string[] = [];
  const accessToken = "grok-web-search-token";
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const path = new URL(request.url).pathname;
      if (path === "/models") {
        return Response.json({
          data: [grokSubscriptionModel("grok-4.20", 1_000_000, [], true)],
        });
      }
      if (path === "/modalities") {
        return Response.json({
          models: [grokModalityModel("grok-4.20", true)],
        });
      }
      bodies.push(await request.text());
      if (bodies.length === 1) {
        return new Response(
          'data: {"type":"response.output_item.added","output_index":0,"item":{"type":"web_search_call","id":"ws_grok_e2e","status":"in_progress"}}\n\n' +
            'data: {"type":"response.output_item.done","output_index":0,"item":{"type":"web_search_call","id":"ws_grok_e2e","status":"completed","action":{"type":"search","query":"Zig 0.16","sources":[]}}}\n\n' +
            'data: {"type":"response.output_text.delta","delta":"GROK_WEB_SEARCH_DONE"}\n\n' +
            'data: {"type":"response.output_item.done","output_index":1,"item":{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"GROK_WEB_SEARCH_DONE","annotations":[]}]}}\n\n' +
            'data: {"type":"response.completed","response":{"id":"resp_grok_search","status":"completed","usage":{"input_tokens":6,"output_tokens":3}}}\n\n',
          { headers: { "content-type": "text/event-stream" } },
        );
      }
      return new Response(
        'data: {"type":"response.output_text.delta","delta":"GROK_WEB_SEARCH_REPLAY_DONE"}\n\n' +
          'data: {"type":"response.completed","response":{"id":"resp_grok_replay","status":"completed","usage":{"input_tokens":8,"output_tokens":3}}}\n\n',
        { headers: { "content-type": "text/event-stream" } },
      );
    },
  });
  return {
    accessToken,
    bodies,
    responsesUrl: `http://127.0.0.1:${server.port}/responses`,
    modelsUrl: `http://127.0.0.1:${server.port}/models`,
    modalitiesUrl: `http://127.0.0.1:${server.port}/modalities`,
    stop() { server.stop(true); },
  };
}

function startFakeGrokConfiguredSearchFallback() {
  const grokBodies: string[] = [];
  const fallbackBodies: string[] = [];
  const fallbackAuthorizations: Array<string | null> = [];
  const accessToken = "grok-configured-search-fallback-token";
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const path = new URL(request.url).pathname;
      if (path === "/models") {
        return Response.json({
          data: [grokSubscriptionModel("grok-no-backend-search", 1_000_000, [], false)],
        });
      }
      if (path === "/modalities") {
        return Response.json({
          models: [grokModalityModel("grok-no-backend-search", false)],
        });
      }
      if (path === "/fallback/responses") {
        fallbackAuthorizations.push(request.headers.get("authorization"));
        fallbackBodies.push(await request.text());
        return Response.json({
          output: [{
            type: "message",
            role: "assistant",
            content: [{
              type: "output_text",
              text: "Configured search found the current Zig release.",
              annotations: [{
                type: "url_citation",
                url: "https://ziglang.org/download/",
                title: "Zig downloads",
              }],
            }],
          }],
        });
      }
      grokBodies.push(await request.text());
      if (grokBodies.length === 1) {
        return new Response(
          'data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_search_fallback","name":"web_search"}}\n\n' +
            'data: {"type":"response.function_call_arguments.done","output_index":0,"arguments":"{\\"query\\":\\"current Zig release\\"}"}\n\n' +
            'data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":5,"output_tokens":2}}}\n\n',
          { headers: { "content-type": "text/event-stream" } },
        );
      }
      return new Response(
        'data: {"type":"response.output_text.delta","delta":"GROK_CONFIGURED_SEARCH_FALLBACK_DONE"}\n\n' +
          'data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":8,"output_tokens":3}}}\n\n',
        { headers: { "content-type": "text/event-stream" } },
      );
    },
  });
  return {
    accessToken,
    grokBodies,
    fallbackBodies,
    fallbackAuthorizations,
    responsesUrl: `http://127.0.0.1:${server.port}/grok-responses`,
    modelsUrl: `http://127.0.0.1:${server.port}/models`,
    modalitiesUrl: `http://127.0.0.1:${server.port}/modalities`,
    fallbackBaseUrl: `http://127.0.0.1:${server.port}/fallback`,
    stop() { server.stop(true); },
  };
}

function startFakeCodexAutoReview() {
  const bodies: string[] = [];
  const accessToken = chatgptAccessToken("acct_auto_review");
  let mainRequests = 0;
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const path = new URL(request.url).pathname;
      if (path === "/models") {
        return Response.json({ models: [
          { slug: "gpt-5.6-sol", visibility: "list", supported_in_api: true, supported_reasoning_levels: [{ effort: "high" }], additional_speed_tiers: [], input_modalities: ["text"], context_window: 272000 },
          { slug: "gpt-5.4-mini", visibility: "list", supported_in_api: true, supported_reasoning_levels: [{ effort: "low" }], additional_speed_tiers: [], input_modalities: ["text"], context_window: 128000 },
        ] });
      }
      const body = await request.text();
      bodies.push(body);
      const model = (JSON.parse(body) as { model?: string }).model;
      if (model === "gpt-5.4-mini") {
        return new Response(
          'data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_permission","name":"permission_decision"}}\n\n' +
            'data: {"type":"response.function_call_arguments.done","output_index":0,"arguments":"{\\"risk\\":\\"low\\",\\"decision\\":\\"clear\\",\\"rationale\\":\\"The user requested this harmless command.\\"}"}\n\n' +
            'data: {"type":"response.completed","response":{"id":"gen_review","status":"completed","usage":{"input_tokens":8,"output_tokens":3}}}\n\n',
          { headers: { "content-type": "text/event-stream" } },
        );
      }
      mainRequests += 1;
      if (mainRequests === 1) {
        return new Response(
          'data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_terminal","name":"exec_command"}}\n\n' +
            'data: {"type":"response.function_call_arguments.done","output_index":0,"arguments":"{\\"cmd\\":\\"rm auto-review-fixture\\"}"}\n\n' +
            'data: {"type":"response.completed","response":{"id":"gen_main_1","status":"completed","usage":{"input_tokens":5,"output_tokens":2}}}\n\n',
          { headers: { "content-type": "text/event-stream" } },
        );
      }
      return new Response(
        'data: {"type":"response.output_text.delta","delta":"CODEX_AUTO_REVIEW_OK"}\n\n' +
          'data: {"type":"response.completed","response":{"id":"gen_main_2","status":"completed","usage":{"input_tokens":7,"output_tokens":3}}}\n\n',
        { headers: { "content-type": "text/event-stream" } },
      );
    },
  });
  return {
    accessToken,
    bodies,
    responsesUrl: `http://127.0.0.1:${server.port}/responses`,
    modelsUrl: `http://127.0.0.1:${server.port}/models`,
    stop() { server.stop(true); },
  };
}

function startFakeGrokAutoReview() {
  const bodies: string[] = [];
  const headers: Array<{
    tokenAuth: string | null;
    authenticateResponse: string | null;
    clientIdentifier: string | null;
    clientVersion: string | null;
    modelOverride: string | null;
    grokUserId: string | null;
  }> = [];
  const accessToken = "grok-auto-review-token";
  let mainRequests = 0;
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const path = new URL(request.url).pathname;
      if (path === "/models") {
        return Response.json({ data: [grokSubscriptionModel("grok-4.20", 500_000)] });
      }
      if (path === "/modalities") {
        return Response.json({ models: [grokModalityModel("grok-4.20", false)] });
      }
      headers.push({
        tokenAuth: request.headers.get("x-xai-token-auth"),
        authenticateResponse: request.headers.get("x-authenticateresponse"),
        clientIdentifier: request.headers.get("x-grok-client-identifier"),
        clientVersion: request.headers.get("x-grok-client-version"),
        modelOverride: request.headers.get("x-grok-model-override"),
        grokUserId: request.headers.get("x-grok-user-id"),
      });
      const body = await request.text();
      bodies.push(body);
      if (body.includes('"name":"permission_decision"')) {
        return new Response(
          'data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_permission","name":"permission_decision"}}\n\n' +
            'data: {"type":"response.function_call_arguments.done","output_index":0,"arguments":"{\\"risk\\":\\"low\\",\\"decision\\":\\"clear\\",\\"rationale\\":\\"The user requested this harmless command.\\"}"}\n\n' +
            'data: {"type":"response.completed","response":{"id":"gen_review","status":"completed","usage":{"input_tokens":8,"output_tokens":3}}}\n\n',
          { headers: { "content-type": "text/event-stream" } },
        );
      }
      mainRequests += 1;
      if (mainRequests === 1) {
        return new Response(
          'data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_terminal","name":"exec_command"}}\n\n' +
            'data: {"type":"response.function_call_arguments.done","output_index":0,"arguments":"{\\"cmd\\":\\"rm auto-review-fixture\\"}"}\n\n' +
            'data: {"type":"response.completed","response":{"id":"gen_main_1","status":"completed","usage":{"input_tokens":5,"output_tokens":2}}}\n\n',
          { headers: { "content-type": "text/event-stream" } },
        );
      }
      return new Response(
        'data: {"type":"response.output_text.delta","delta":"GROK_AUTO_REVIEW_OK"}\n\n' +
          'data: {"type":"response.completed","response":{"id":"gen_main_2","status":"completed","usage":{"input_tokens":7,"output_tokens":3}}}\n\n',
        { headers: { "content-type": "text/event-stream" } },
      );
    },
  });
  return {
    accessToken,
    bodies,
    headers,
    responsesUrl: `http://127.0.0.1:${server.port}/responses`,
    modelsUrl: `http://127.0.0.1:${server.port}/models`,
    modalitiesUrl: `http://127.0.0.1:${server.port}/modalities`,
    stop() { server.stop(true); },
  };
}

function startFakeGrokResourceRecovery() {
  const accessToken = "grok-resource-limit-token";
  const bodies: string[] = [];
  let responseCalls = 0;
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const path = new URL(request.url).pathname;
      if (path === "/models") {
        return Response.json({ data: [grokSubscriptionModel("grok-4.20", 500_000)] });
      }
      if (path === "/modalities") {
        return Response.json({ models: [grokModalityModel("grok-4.20", false)] });
      }
      bodies.push(await request.text());
      responseCalls += 1;
      if (responseCalls === 1) {
        return new Response(
          'data: {"type":"response.output_text.delta","delta":"' +
            "x".repeat(1024 * 1024) +
            '"}\n\n',
          { headers: { "content-type": "text/event-stream" } },
        );
      }
      const text = responseCalls === 2 ? "GROK_LIMIT_RECOVERED" : "GROK_AFTER_LIMIT_OK";
      return new Response(
        `data: ${JSON.stringify({ type: "response.output_text.delta", delta: text })}\n\n` +
          'data: {"type":"response.completed","response":{"status":"completed"}}\n\n',
        { headers: { "content-type": "text/event-stream" } },
      );
    },
  });
  return {
    accessToken,
    bodies,
    responsesUrl: `http://127.0.0.1:${server.port}/responses`,
    modelsUrl: `http://127.0.0.1:${server.port}/models`,
    modalitiesUrl: `http://127.0.0.1:${server.port}/modalities`,
    stop() { server.stop(true); },
  };
}

async function startFxWithoutAuth(
  testHome: string,
  testStderrPath: string,
  fakeGateway: ReturnType<typeof startFakeGateway>,
  cwd?: string,
): Promise<TmuxSession> {
  return TmuxSession.create({
    cmd: FX_BIN,
    cwd,
    env: {
      HOME: testHome,
      OPENAI_API_KEY: undefined,
      FX_DISABLE_KEYCHAIN: "1",
      FX_SKIP_ONBOARDING: "1",
      FX_RESPONSES_BASE_URL: fakeGateway.baseUrl,
      FX_MODEL: FAKE_GATEWAY_MODEL,
    },
    stderrPath: testStderrPath,
    width: 100,
    height: 30,
  });
}

async function waitForModelRequestCount(
  fakeGateway: ReturnType<typeof startFakeGateway>,
  count: number,
): Promise<void> {
  const started = Date.now();
  while (fakeGateway.modelRequests.length < count) {
    if (Date.now() - started >= TIMEOUT) {
      throw new Error(
        `Timed out waiting for ${count} model requests; saw ${fakeGateway.modelRequests.length}`,
      );
    }
    await Bun.sleep(25);
  }
}

async function openProviderPicker(pickerSession: TmuxSession): Promise<void> {
  await pickerSession.sendText("/provider");
  await pickerSession.waitForText("Model provider", TIMEOUT);
}

tmuxTest(
  "login hub exposes only supported provider and credential actions",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-login-hub-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    session = await startFx(home, stderrPath, gateway);
    await session.waitForComposer(TIMEOUT);

    await session.sendText("/login");
    const root = await session.waitForPane(
      (pane) =>
        pane.includes("Accounts") &&
        pane.includes("Sign in with Codex") &&
        pane.includes("Sign in with Grok") &&
        pane.includes("Switch credential"),
      TIMEOUT,
    );
    expect(root).not.toContain("Change team");

    await session.sendKeys("Down");
    await session.sendKeys("Down");
    await session.sendKeys("Enter");
    const credentials = await session.waitForText("Credential source", TIMEOUT);
    expect(credentials).toContain("OPENAI_API_KEY");
    expect(credentials).not.toContain("fx login");
    await session.sendKeys("Escape");
    await session.waitForText("Accounts", TIMEOUT);
    await session.sendKeys("Escape");
    await session.waitForPane(
      (pane) => !pane.includes("Accounts") && !pane.includes("Credential source"),
      TIMEOUT,
    );

    await session.sendText("/provider");
    await session.waitForText("Model provider", TIMEOUT);
    await session.sendKeys("Escape");
    await session.waitForComposer(TIMEOUT);

    expect(session.isAlive()).toBe(true);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "provider setup imports without switching and provider command activates Codex",
  async () => {
    home = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-provider-setup-")));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    chatgptOauth = startFakeChatGptOAuth();
    const codexHome = writeCodexSetupSource(home, chatgptOauth.accessToken);
    const sourcePath = join(codexHome, "auth.json");
    const sourceBefore = readFileSync(sourcePath, "utf8");
    const providerEnv = {
      ...chatgptOauth.env,
      HOME: home,
      CODEX_HOME: codexHome,
      GROK_HOME: join(home, "missing-grok-home"),
      FX_DISABLE_KEYCHAIN: "1",
    };
    session = await startFx(home, stderrPath, gateway, undefined, providerEnv);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/setup");
    await session.waitForText("Codex: imported from Codex CLI.", TIMEOUT);
    await session.sendText("/provider codex");
    await session.waitForText("Switched to Codex subscription with gpt-5.6-sol.", TIMEOUT);
    await session.sendText("Use the imported Codex CLI login.");
    await session.waitForText("CHATGPT_DIRECT_RESPONSE", TIMEOUT);

    expect(readFileSync(sourcePath, "utf8")).toBe(sourceBefore);
    expect(existsSync(join(home, ".fx", "chatgpt-auth.json"))).toBe(true);
    expect(session.isAlive()).toBe(true);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "Codex browser sign-in cancels cleanly",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-chatgpt-cancel-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    chatgptOauth = startFakeChatGptOAuth();

    session = await startFx(
      home,
      stderrPath,
      gateway,
      undefined,
      chatgptOauth.env,
    );
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/login");
    await session.waitForText("Sign in with Codex", TIMEOUT);
    await session.sendKeys("Enter");
    const signInScreen = await session.waitForPane(
      (pane) =>
        pane.includes("Sign in with Codex") &&
        pane.includes("Authorize with Codex") &&
        pane.includes("Waiting for authorization") &&
        pane.includes("Enter reopens browser · Esc cancels"),
      TIMEOUT,
    );
    expect(signInScreen).not.toContain(`${chatgptOauth.baseUrl}/oauth/authorize?`);
    const signInEscapes = await session.capturePaneEscapes();
    expect(signInEscapes).toContain(`\x1b]8;;${chatgptOauth.baseUrl}/oauth/authorize?`);
    expect(signInEscapes).toContain("\x1b]8;;\x1b\\");
    await session.sendKeys("C-c");
    await session.waitForComposer(TIMEOUT);

    expect(session.isAlive()).toBe(true);
    expect(existsSync(join(home, ".fx", "chatgpt-auth.json"))).toBe(false);
    expect(await session.captureFullScrollback()).not.toContain("Signed in with Codex.");
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "provider catalog loading keeps the TUI event loop responsive",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-provider-responsive-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    chatgptOauth = startFakeChatGptOAuth({ modelDelayMs: 2_000 });
    writeSeededChatGptLogin(home, chatgptOauth.accessToken);
    session = await startFx(home, stderrPath, gateway, undefined, chatgptOauth.env);
    await session.waitForComposer(TIMEOUT);

    await session.sendText("/provider codex");
    await session.waitForText("Switching to Codex subscription...", TIMEOUT);
    const statusStarted = Date.now();
    await session.sendText("/status");
    await session.waitForText("auth=OPENAI_API_KEY", TIMEOUT);
    expect(Date.now() - statusStarted).toBeLessThan(1_500);
    await session.waitForText("Switched to Codex subscription", TIMEOUT);

    expect(session.isAlive()).toBe(true);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "logout waits for a provider refresh without blocking the TUI thread",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-provider-logout-responsive-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    chatgptOauth = startFakeChatGptOAuth({ tokenDelayMs: 3_000 });
    writeSeededChatGptLogin(home, chatgptOauth.accessToken, Date.now() - 1_000);
    session = await startFx(home, stderrPath, gateway, undefined, chatgptOauth.env);
    await session.waitForComposer(TIMEOUT);

    await session.sendText("/provider codex");
    await session.waitForText("Switching to Codex subscription...", TIMEOUT);
    while (!chatgptOauth.requests.some((request) => request.path === "/chatgpt/token")) {
      await Bun.sleep(10);
    }
    const logoutStarted = Date.now();
    await session.sendText("/logout codex");
    await session.waitForText("Signing out of Codex...", TIMEOUT);
    await session.sendText("/status");
    await session.waitForText("auth=OPENAI_API_KEY", TIMEOUT);
    expect(Date.now() - logoutStarted).toBeLessThan(1_500);
    await session.waitForText("Signed out of Codex.", TIMEOUT);
    expect(existsSync(join(home, ".fx", "chatgpt-auth.json"))).toBe(false);

    expect(await session.captureFullScrollback()).not.toContain(
      "Switched to Codex subscription with",
    );
    expect(session.isAlive()).toBe(true);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "provider switch reauthenticates current Codex and replaces an unavailable model",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-chatgpt-success-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([], {
      models() {
        return [{ id: "openai/gpt-5.6-sol", object: "model" }];
      },
    });
    chatgptOauth = startFakeChatGptOAuth();

    session = await startFx(
      home,
      stderrPath,
      gateway,
      undefined,
      {
        ...chatgptOauth.env,
        FX_MODEL: undefined,
      },
    );
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/model openai/gpt-5.6-sol");
    await session.waitForText("Switched to openai/gpt-5.6-sol", TIMEOUT);
    await openProviderPicker(session);
    await session.sendKeys("Down");
    await session.sendKeys("Enter");
    await session.waitForText("Sign in with Codex", TIMEOUT);
    await completeDisplayedCodexLogin(session, chatgptOauth);
    await session.waitForText("Switched to Codex subscription with gpt-5.6-sol.", TIMEOUT);

    const authPath = join(home, ".fx", "chatgpt-auth.json");
    expect(existsSync(authPath)).toBe(true);
    expect(statSync(authPath).mode & 0o077).toBe(0);

    await session.sendText("/status");
    await session.waitForText(
      "model_source=Codex subscription",
      TIMEOUT,
    );
    await session.sendText("/model");
    const picker = await session.waitForPane(
      (pane) =>
        pane.includes("gpt-5.6-sol") &&
        pane.includes("gpt-5.4-mini"),
      TIMEOUT,
    );
    const pickerRows = picker.split("\n").filter((line) => /^\s+gpt-/.test(line));
    expect(pickerRows.join("\n")).not.toContain("openai/gpt-5.6-sol");
    await session.sendKeys("Escape");
    await session.sendKeys("C-c");
    await session.waitForComposer(TIMEOUT);
    await session.sendLiteralText("/model gpt-5.6-sol");
    await session.sendKeys("Space");
    await session.sendLiteralText("max");
    await session.sendKeys("Space");
    await session.sendLiteralText("fast");
    await session.sendKeys("Enter");
    await session.waitForText("Switched to gpt-5.6-sol", TIMEOUT);
    await session.sendText("/fast");
    await session.waitForText("Fast: off", TIMEOUT);
    await session.sendText("/fast");
    await session.waitForText("Fast: on", TIMEOUT);
    await session.sendText("Use the Codex subscription directly.");
    await session.waitForText("CHATGPT_DIRECT_RESPONSE", TIMEOUT);
    const directRequest = chatgptOauth.requests.find(
      (request) => request.path === "/chatgpt/responses",
    );
    expect(directRequest?.authorization).toBe(`Bearer ${chatgptOauth.accessToken}`);
    const directBody = JSON.parse(directRequest?.body ?? "{}") as {
      model?: string;
      service_tier?: string;
      max_output_tokens?: number;
      reasoning?: { effort?: string };
    };
    expect(directBody.model).toBe("gpt-5.6-sol");
    expect(directBody.service_tier).toBe("priority");
    expect(directBody.max_output_tokens).toBeUndefined();
    expect(directBody.reasoning?.effort).toBe("max");
    for (const request of [...gateway.requests, ...gateway.modelRequests]) {
      expect(request.headers.get("authorization")).not.toBe(
        `Bearer ${chatgptOauth.accessToken}`,
      );
    }
    await session.sendText("/models");
    await session.waitForPane(
      (pane) =>
        pane.includes("Models") &&
        pane.includes("gpt-5.6-sol") &&
        pane.includes("gpt-5.4-mini") &&
        !pane.includes("openai/gpt-5.6-sol"),
      TIMEOUT,
    );
    await session.sendKeys("Escape");
    await session.waitForPane((pane) => !pane.includes("Esc Close"), TIMEOUT);
    await session.waitForComposer(TIMEOUT);
    const authorizeRequestsBeforeRoundTrip = chatgptOauth.requests.filter(
      (request) => request.path === "/oauth/authorize",
    ).length;
    const settingsPath = join(home, ".fx", "settings.json");
    const gatewayModelBefore = JSON.parse(readFileSync(settingsPath, "utf8")).models.gateway;
    expect(typeof gatewayModelBefore).toBe("string");
    const savedCodex = JSON.parse(readFileSync(settingsPath, "utf8"));
    expect(savedCodex.models.gateway).toBe(gatewayModelBefore);
    expect(savedCodex.models.codex).toBe("gpt-5.6-sol");
    await session.sendText("/quit");
    await session.waitForSessionEnd(TIMEOUT);
    session = null;

    session = await startFx(
      home,
      stderrPath,
      gateway,
      undefined,
      {
        ...chatgptOauth.env,
        FX_MODEL: undefined,
      },
    );
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/status");
    await session.waitForText("model=gpt-5.6-sol", TIMEOUT);
    await openProviderPicker(session);
    await session.sendKeys("Up");
    await session.sendKeys("Enter");
    await session.waitForText("Switched to BYOK Responses API", TIMEOUT);
    const savedGateway = JSON.parse(readFileSync(settingsPath, "utf8"));
    expect(savedGateway.provider).toBe("gateway");
    expect(savedGateway.models.gateway).toBe(gatewayModelBefore);
    expect(savedGateway.models.codex).toBe("gpt-5.6-sol");
    await openProviderPicker(session);
    await session.sendKeys("Down");
    await session.sendKeys("Enter");
    await session.waitForText("Switched to Codex subscription", TIMEOUT);
    const restoredCodex = JSON.parse(readFileSync(settingsPath, "utf8"));
    expect(restoredCodex.provider).toBe("codex");
    expect(restoredCodex.models.gateway).toBe(gatewayModelBefore);
    expect(restoredCodex.models.codex).toBe("gpt-5.6-sol");
    expect(chatgptOauth.requests.filter((request) => request.path === "/oauth/authorize"))
      .toHaveLength(authorizeRequestsBeforeRoundTrip);
    await session.sendText("/logout codex");
    await session.waitForText("Signed out of Codex.", TIMEOUT);
    expect(existsSync(authPath)).toBe(false);
    await session.sendText("/status");
    await session.waitForText("model_source=Codex subscription", TIMEOUT);
    chatgptOauth.setModels([
      { slug: "gpt-5.4-mini", visibility: "list", supported_in_api: true, supported_reasoning_levels: [{ effort: "low" }], additional_speed_tiers: [], input_modalities: ["text"], context_window: 128000 },
    ]);
    await openProviderPicker(session);
    await session.sendKeys("Enter");
    await session.waitForText("Sign in with Codex", TIMEOUT);
    await completeDisplayedCodexLogin(session, chatgptOauth);
    await session.waitForText("Switched to Codex subscription with gpt-5.4-mini.", TIMEOUT);
    const reauthenticated = JSON.parse(readFileSync(settingsPath, "utf8"));
    expect(reauthenticated.provider).toBe("codex");
    expect(reauthenticated.models.codex).toBe("gpt-5.4-mini");
    expect(chatgptOauth.requests.filter((request) => request.path === "/oauth/authorize"))
      .toHaveLength(authorizeRequestsBeforeRoundTrip + 1);
    await session.sendKeys("C-c");

    expect(session.isAlive()).toBe(true);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "interactive Codex login activates a Codex catalog model",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-chatgpt-login-activation-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    chatgptOauth = startFakeChatGptOAuth();

    session = await startFx(
      home,
      stderrPath,
      gateway,
      undefined,
      { ...chatgptOauth.env, FX_MODEL: undefined },
    );
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/login");
    await session.waitForText("Sign in with Codex", TIMEOUT);
    await session.sendKeys("Enter");
    await completeDisplayedCodexLogin(session, chatgptOauth);
    await session.waitForText("Switched to Codex subscription with gpt-5.6-sol.", TIMEOUT);

    const selected = JSON.parse(readFileSync(join(home, ".fx", "settings.json"), "utf8"));
    expect(selected.provider).toBe("codex");
    expect(selected.models.codex).toBe("gpt-5.6-sol");
    await session.sendText("/status");
    await session.waitForText("model_source=Codex subscription", TIMEOUT);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "ChatGPT response transport cancels blocked HTTP without stopping the shell",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-chatgpt-response-cancel-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    chatgptOauth = startFakeChatGptOAuth({ responseDelayMs: 10_000 });
    writeSeededChatGptLogin(home, chatgptOauth.accessToken);
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({ provider: "codex", codex_model: "gpt-5.6-sol" }) + "\n",
      { mode: 0o600 },
    );

    session = await startFx(
      home,
      stderrPath,
      gateway,
      undefined,
      {
        ...chatgptOauth.env,
        FX_MODEL: undefined,
      },
    );
    await session.waitForComposer(TIMEOUT);
    await session.sendText("Cancel the blocked Codex response.");
    await Bun.sleep(300);
    const cancelStarted = Date.now();
    await session.sendKeys("C-c");
    await session.waitForText("System: cancelled", TIMEOUT);
    await session.waitForComposer(TIMEOUT);
    expect(Date.now() - cancelStarted).toBeLessThan(3_000);
    expect(session.isAlive()).toBe(true);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

test(
  "OpenAI API key uses the direct Responses wire protocol",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-openai-byok-"));
    const openai = startFakeOpenAIResponses();
    try {
      const result = await runFx(["ask", "--json", "--auto", "--no-save", "Answer directly."], {
        env: {
          HOME: home,
          OPENAI_API_KEY: "sk-openai-byok",
          FX_DISABLE_KEYCHAIN: "1",
          FX_SKIP_ONBOARDING: "1",
          FX_MODEL: "openai/gpt-5.4",
          FX_RESPONSES_BASE_URL: openai.baseUrl,
        },
        timeoutMs: TIMEOUT,
      });

      expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
      expect(result.stdout).toContain("OPENAI_BYOK_RESPONSE");
      expect(result.stderr).toBe("");
      const responses = openai.requests.filter((request) => request.path === "/v1/responses");
      expect(responses).toHaveLength(1);
      expect(responses[0]!.authorization).toBe("Bearer sk-openai-byok");
      const body = JSON.parse(responses[0]!.body ?? "{}") as Record<string, unknown>;
      expect(body.model).toBe("gpt-5.4");
      expect(Array.isArray(body.input)).toBe(true);
      expect(body.prompt).toBeUndefined();
    } finally {
      openai.stop();
    }
  },
  60_000,
);

test(
  "Codex CLI browser login fetches raw models and replays one isolated 401",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-codex-cli-login-"));
    gateway = startFakeGateway([]);
    chatgptOauth = startFakeChatGptOAuth({ unauthorizedResponses: 1 });
    const env = {
      HOME: home,
      OPENAI_API_KEY: ENV_TOKEN,
      FX_DISABLE_KEYCHAIN: "1",
      FX_SKIP_ONBOARDING: "1",
      FX_NO_OPEN_BROWSER: "1",
      FX_RESPONSES_BASE_URL: gateway.baseUrl,
      ...chatgptOauth.env,
    };

    const login = await runCodexLoginWithBrowser(env);
    expect(login.code, `stdout: ${login.stdout}\nstderr: ${login.stderr}`).toBe(0);
    expect(login.stdout).toContain("Signed in with Codex.");
    expect(login.stdout).not.toContain("Code:");
    expect(login.stderr).toBe("");

    const authPath = join(home, ".fx", "chatgpt-auth.json");
    expect(existsSync(authPath)).toBe(true);
    expect(statSync(authPath).mode & 0o077).toBe(0);
    const settingsPath = join(home, ".fx", "settings.json");
    const selected = JSON.parse(readFileSync(settingsPath, "utf8"));
    expect(selected.provider).toBe("codex");
    expect(selected.models.codex).toBe("gpt-5.6-sol");

    const models = await runFx(["models", "--json"], { env, timeoutMs: TIMEOUT });
    const modelIds = (JSON.parse(models.stdout) as { models: Array<{ id: string }> }).models
      .map((model) => model.id);
    expect(modelIds).toContain("gpt-5.6-sol");
    expect(modelIds).toContain("gpt-5.4-mini");
    expect(modelIds.some((id) => id.includes("openai-codex/"))).toBe(false);

    const ask = await runFx(["ask", "--json", "--auto", "--no-save", "Answer directly."], {
      env,
      timeoutMs: TIMEOUT,
    });
    expect(ask.code, `stdout: ${ask.stdout}\nstderr: ${ask.stderr}`).toBe(0);
    expect(ask.stdout).toContain("CHATGPT_DIRECT_RESPONSE");
    const responses = chatgptOauth.requests.filter((request) => request.path === "/chatgpt/responses");
    expect(responses).toHaveLength(2);
    expect(responses[0]!.body).toBe(responses[1]!.body);
    expect(responses[0]!.authorization).toBe(`Bearer ${chatgptOauth.accessToken}`);
    for (const request of [...gateway.requests, ...gateway.modelRequests]) {
      expect(request.headers.get("authorization")).not.toBe(`Bearer ${chatgptOauth.accessToken}`);
    }

    const gatewayRequestsBeforeImage = gateway.requests.length;
    const gatewayModelRequestsBeforeImage = gateway.modelRequests.length;
    const imageAsk = await runFx([
      "ask",
      "--json",
      "--auto",
      "--no-save",
      "--image",
      join(REPO_ROOT, "tests/e2e/fixtures/favicon.png"),
      "Read the attached image directly.",
    ], {
      env,
      timeoutMs: TIMEOUT,
    });
    expect(imageAsk.code, `stdout: ${imageAsk.stdout}\nstderr: ${imageAsk.stderr}`).toBe(0);
    expect(imageAsk.stdout).toContain("CHATGPT_DIRECT_RESPONSE");
    const imageResponses = chatgptOauth.requests.filter(
      (request) => request.path === "/chatgpt/responses",
    );
    expect(imageResponses).toHaveLength(3);
    const imageBody = imageResponses[2]!.body ?? "";
    expect(imageBody.match(/"type":"input_image"/g)).toHaveLength(1);
    expect(imageBody).toContain("data:image/png;base64,");
    expect(imageBody).not.toContain('"name":"vision"');
    expect(gateway.requests).toHaveLength(gatewayRequestsBeforeImage);
    expect(gateway.modelRequests).toHaveLength(gatewayModelRequestsBeforeImage);

    const tokenRequestsBeforeRoundTrip = chatgptOauth.requests.filter(
      (request) => request.path === "/chatgpt/token",
    ).length;
    expect((await runFx(["provider", "gateway"], { env, timeoutMs: TIMEOUT })).code).toBe(0);
    expect((await runFx(["provider", "codex"], { env, timeoutMs: TIMEOUT })).code).toBe(0);
    expect(chatgptOauth.requests.filter((request) => request.path === "/chatgpt/token"))
      .toHaveLength(tokenRequestsBeforeRoundTrip);

    const logout = await runFx(["logout", "codex"], { env, timeoutMs: TIMEOUT });
    expect(logout.code).toBe(0);
    expect(logout.stdout).toContain("Signed out of Codex.");
    expect(existsSync(authPath)).toBe(false);
  },
  60_000,
);

tmuxTest(
  "Codex V2 remote compaction persists opaque history and resumes through Responses",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-codex-remote-compact-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    writeSeededChatGptLogin(home);
    writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({
      provider: "codex",
      codex_model: "gpt-5.6-sol",
    }) + "\n");
    chatgptOauth = startFakeChatGptOAuth({ holdCompactionResponse: true });
    const env = {
      HOME: home,
      OPENAI_API_KEY: undefined,
      FX_DISABLE_KEYCHAIN: "1",
      FX_SKIP_ONBOARDING: "1",
      ...chatgptOauth.env,
      FX_CODEX_BASE_URL: `${chatgptOauth.baseUrl}/chatgpt`,
    };

    session = await TmuxSession.create({
      cmd: FX_BIN,
      cwd: REPO_ROOT,
      env,
      stderrPath,
      width: 100,
      height: 30,
    });
    await session.waitForComposer(TIMEOUT);
    await session.sendText("first compaction turn");
    await session.waitForPane(
      (pane) => (pane.match(/CHATGPT_DIRECT_RESPONSE/g) ?? []).length === 1 &&
        (pane.match(/0s \(↑6 ↓2\)/g) ?? []).length === 1,
      TIMEOUT,
    );
    await session.waitForComposer(TIMEOUT);
    await session.sendText("second compaction turn");
    await session.waitForPane(
      (pane) => pane.includes("second compaction turn") &&
        (pane.match(/CHATGPT_DIRECT_RESPONSE/g) ?? []).length === 2 &&
        (pane.match(/0s \(↑6 ↓2\)/g) ?? []).length === 2,
      TIMEOUT,
    );
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/compact");
    await session.waitForText("Context compaction started.", TIMEOUT);
    await session.waitForText("Compacting context", TIMEOUT);
    await session.sendText("BLOCKED_DURING_COMPACTION");
    const duringCompaction = await session.capturePane();
    expect(duringCompaction).toContain("BLOCKED_DURING_COMPACTION");
    expect(
      chatgptOauth.requests.filter((request) => request.path === "/chatgpt/responses"),
    ).toHaveLength(3);
    expect(duringCompaction.match(/CHATGPT_DIRECT_RESPONSE/g)?.length ?? 0).toBe(2);
    chatgptOauth.releaseCompaction();
    await session.waitForText("Context compacted with the active Responses provider.", TIMEOUT);
    await session.waitForPane(
      (pane) => (pane.match(/CHATGPT_DIRECT_RESPONSE/g) ?? []).length === 3,
      TIMEOUT,
    );
    await session.waitForComposer(TIMEOUT);
    expect(
      chatgptOauth.requests.filter((request) => request.path === "/chatgpt/responses"),
    ).toHaveLength(4);
    await session.sendText("/quit");
    await session.waitForSessionEnd(TIMEOUT);
    session = null;

    const compactRequest = chatgptOauth.requests.find((request) => {
      if (request.path !== "/chatgpt/responses" || !request.body) return false;
      const input = (JSON.parse(request.body) as { input?: Array<Record<string, unknown>> }).input;
      return input?.at(-1)?.type === "compaction_trigger";
    });
    expect(compactRequest).toBeDefined();
    const compactBody = JSON.parse(compactRequest!.body!) as {
      input: Array<Record<string, unknown>>;
      include: string[];
      parallel_tool_calls: boolean;
      stream: boolean;
      tool_choice: string;
    };
    expect(compactBody.input.length).toBeGreaterThan(1);
    expect(compactBody.input.at(-1)?.type).toBe("compaction_trigger");
    expect(compactBody.stream).toBe(true);
    expect(compactBody.include).toContain("reasoning.encrypted_content");
    expect(compactBody.parallel_tool_calls).toBe(true);
    expect(compactBody.tool_choice).toBe("auto");
    expect(compactRequest!.accept).toBe("text/event-stream");
    expect(compactRequest!.betaFeatures?.split(",")).toContain("remote_compaction_v2");

    const resumed = await runFx(
      ["ask", "--json", "--auto", "--resume", "last", "resume after remote compaction"],
      { cwd: REPO_ROOT, env, timeoutMs: TIMEOUT },
    );
    expect(resumed.code, `stdout: ${resumed.stdout}\nstderr: ${resumed.stderr}`).toBe(0);
    expect(resumed.stderr).toBe("");
    expect(resumed.stdout).toContain("CHATGPT_DIRECT_RESPONSE");

    const responseBodies = chatgptOauth.requests
      .filter((request) => request.path === "/chatgpt/responses" && request.body)
      .map((request) => JSON.parse(request.body!) as { input?: Array<Record<string, unknown>> });
    const replayInput = responseBodies.at(-1)?.input ?? [];
    const replayTypes = replayInput.map((item) => item.type);
    expect(replayTypes).toContain("compaction");
    expect(replayTypes).not.toContain("compaction_trigger");
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "automatic Codex overflow compaction is visible through settlement",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-codex-auto-compact-visible-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    writeSeededChatGptLogin(home);
    writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({
      provider: "codex",
      codex_model: "gpt-5.6-sol",
    }) + "\n");
    chatgptOauth = startFakeChatGptOAuth({
      holdCompactionResponse: true,
      contextOverflowResponses: 1,
    });
    const env = {
      HOME: home,
      OPENAI_API_KEY: undefined,
      FX_DISABLE_KEYCHAIN: "1",
      FX_SKIP_ONBOARDING: "1",
      ...chatgptOauth.env,
      FX_CODEX_BASE_URL: `${chatgptOauth.baseUrl}/chatgpt`,
    };

    session = await TmuxSession.create({
      cmd: FX_BIN,
      cwd: REPO_ROOT,
      env,
      stderrPath,
      width: 100,
      height: 30,
    });
    await session.waitForComposer(TIMEOUT);
    await session.sendText("trigger visible automatic compaction");
    await session.waitForText(
      "Context limit reached; compacting before the next model step.",
      TIMEOUT,
    );
    expect(await session.capturePane()).not.toContain("CHATGPT_DIRECT_RESPONSE");

    chatgptOauth.releaseCompaction();
    await session.waitForText(
      "Context compacted with the active Responses provider.",
      TIMEOUT,
    );
    await session.waitForText("CHATGPT_DIRECT_RESPONSE", TIMEOUT);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/quit");
    await session.waitForSessionEnd(TIMEOUT);
    session = null;

    const compactRequest = chatgptOauth.requests.find((request) => {
      if (request.path !== "/chatgpt/responses" || !request.body) return false;
      const input = (JSON.parse(request.body) as { input?: Array<Record<string, unknown>> }).input;
      return input?.at(-1)?.type === "compaction_trigger";
    });
    expect(compactRequest).toBeDefined();
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

test(
  "Grok CLI browser login fetches subscription models and replays one account-stable 401",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-grok-cli-login-"));
    gateway = startFakeGateway([]);
    const grok = startFakeGrokOAuth({ unauthorizedResponses: 1 });
    try {
      const env = {
        HOME: home,
        OPENAI_API_KEY: ENV_TOKEN,
        FX_DISABLE_KEYCHAIN: "1",
        FX_SKIP_ONBOARDING: "1",
        FX_NO_OPEN_BROWSER: "1",
        FX_RESPONSES_BASE_URL: gateway.baseUrl,
        ...grok.env,
      };

      const login = await runGrokLoginWithBrowser(env);
      expect(login.code, `stdout: ${login.stdout}\nstderr: ${login.stderr}`).toBe(0);
      expect(login.stdout).toContain("Signed in with Grok.");
      expect(login.stderr).toBe("");

      const authPath = join(home, ".fx", "grok-auth.json");
      expect(existsSync(authPath)).toBe(true);
      expect(statSync(authPath).mode & 0o077).toBe(0);
      const settings = JSON.parse(readFileSync(join(home, ".fx", "settings.json"), "utf8"));
      expect(settings.provider).toBe("grok");
      expect(settings.models.grok).toBe("grok-4.20");

      const models = await runFx(["models", "--json"], { env, timeoutMs: TIMEOUT });
      const modelIds = (JSON.parse(models.stdout) as { models: Array<{ id: string }> }).models
        .map((model) => model.id);
      expect(modelIds).toEqual(["grok-4.20", "grok-4.6"]);
      const subscriptionCatalogRequests = grok.requests.filter((request) => request.path === "/v1/models");
      expect(subscriptionCatalogRequests.length).toBeGreaterThan(0);
      for (const request of subscriptionCatalogRequests) {
        expect(request.tokenAuth).toBe("xai-grok-cli");
        expect(request.userId).toBe("acct_grok_e2e");
      }
      const modalityRequests = grok.requests.filter((request) => request.path === "/v1/language-models");
      expect(modalityRequests.length).toBeGreaterThan(0);
      for (const request of modalityRequests) {
        expect(request.tokenAuth).toBeNull();
        expect(request.userId).toBeNull();
      }

      const ask = await runFx(["ask", "--json", "--auto", "Answer directly."], {
        env,
        timeoutMs: TIMEOUT,
      });
      expect(ask.code, `stdout: ${ask.stdout}\nstderr: ${ask.stderr}`).toBe(0);
      expect(ask.stdout).toContain("GROK_DIRECT_RESPONSE");
      const responses = grok.requests.filter((request) => request.path === "/v1/responses");
      expect(responses).toHaveLength(2);
      expect(responses[0]!.body).toBe(responses[1]!.body);
      expect(responses[0]!.conversationId).toBeTruthy();
      expect(responses[0]!.conversationId).toBe(responses[1]!.conversationId);
      expect(responses[0]!.authorization).toBe(`Bearer ${grok.initialAccessToken}`);
      expect(responses[1]!.authorization).toBe(`Bearer ${grok.refreshedAccessToken}`);
      for (const request of responses) {
        expect(request.tokenAuth).toBe("xai-grok-cli");
        expect(request.authenticateResponse).toBe("authenticate-response");
        expect(request.clientIdentifier).toBe("fx");
        expect(request.clientVersion).toBe("1.0.6");
        expect(request.modelOverride).toBe("grok-4.20");
        expect(request.grokUserId).toBe("acct_grok_e2e");
        expect(request.userId).toBeNull();
      }
      expect(grok.tokenCalls()).toBe(2);
      const userinfo = grok.requests.filter((request) => request.path === "/oauth2/userinfo");
      expect(userinfo).toHaveLength(2);
      for (const request of [...gateway.requests, ...gateway.modelRequests]) {
        expect(request.headers.get("authorization")).not.toContain("grok-");
      }

      expect((await runFx(["provider", "gateway"], { env, timeoutMs: TIMEOUT })).code).toBe(0);
      expect((await runFx(["provider", "grok"], { env, timeoutMs: TIMEOUT })).code).toBe(0);
      expect(grok.tokenCalls()).toBe(2);

      const logout = await runFx(["logout", "grok"], { env, timeoutMs: TIMEOUT });
      expect(logout.code, `stdout: ${logout.stdout}\nstderr: ${logout.stderr}`).toBe(0);
      expect(logout.stdout).toContain("Signed out of Grok.");
      expect(grok.requests.some((request) => request.path === "/oauth2/revoke")).toBe(true);
      expect(existsSync(authPath)).toBe(false);
    } finally {
      grok.stop();
    }
  },
  60_000,
);

test("Grok logout removes local credentials when remote revocation fails", async () => {
  home = mkdtempSync(join(tmpdir(), "fx-grok-logout-revoke-failure-"));
  const grok = startFakeGrokOAuth({ revokeStatus: 503 });
  try {
    writeSeededGrokLogin(home, grok.initialAccessToken);
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({ provider: "grok", grok_model: "grok-4.20" }) + "\n",
      { mode: 0o600 },
    );
    const authPath = join(home, ".fx", "grok-auth.json");
    const result = await runFx(["logout", "grok"], {
      env: {
        HOME: home,
        FX_DISABLE_KEYCHAIN: "1",
        FX_E2E_GROK_REVOKE_URL: grok.env.FX_E2E_GROK_REVOKE_URL,
      },
      timeoutMs: TIMEOUT,
    });
    expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
    expect(result.stdout).toContain("Signed out of Grok.");
    expect(result.stderr).toContain("remote revocation could not be confirmed");
    expect(existsSync(authPath)).toBe(false);
    expect(JSON.parse(readFileSync(join(home, ".fx", "settings.json"), "utf8")).provider)
      .toBe("grok");
    const ask = await runFx(["ask", "--json", "--no-save", "Still Grok?"], {
      env: { HOME: home, FX_DISABLE_KEYCHAIN: "1" },
      timeoutMs: TIMEOUT,
    });
    expect(ask.code).toBe(1);
    expect(ask.stderr).toContain("fx login grok");
  } finally {
    grok.stop();
  }
});

test("Grok 401 replay refuses a different account before the second provider send", async () => {
  home = mkdtempSync(join(tmpdir(), "fx-grok-account-mismatch-"));
  gateway = startFakeGateway([]);
  const grok = startFakeGrokOAuth({ unauthorizedResponses: 1, userinfoSub: "acct_other" });
  try {
    writeSeededGrokLogin(home, grok.initialAccessToken);
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({ provider: "grok", grok_model: "grok-4.20" }) + "\n",
      { mode: 0o600 },
    );
    const env = {
      HOME: home,
      OPENAI_API_KEY: ENV_TOKEN,
      FX_DISABLE_KEYCHAIN: "1",
      FX_RESPONSES_BASE_URL: gateway.baseUrl,
      ...grok.env,
    };
    const ask = await runFx(["ask", "--json", "--auto", "--no-save", "Answer."], {
      env,
      timeoutMs: TIMEOUT,
    });
    expect(ask.code).toBe(1);
    expect(grok.requests.filter((request) => request.path === "/v1/responses")).toHaveLength(1);
    const saved = JSON.parse(readFileSync(join(home, ".fx", "grok-auth.json"), "utf8")) as {
      access_token: string;
      account_id: string;
    };
    expect(saved.access_token).toBe(grok.initialAccessToken);
    expect(saved.account_id).toBe("acct_grok_e2e");
    for (const request of [...gateway.requests, ...gateway.modelRequests]) {
      expect(request.headers.get("authorization")).not.toContain("grok-");
    }
  } finally {
    grok.stop();
  }
});

test("Grok CLI sends verified images directly without advertising the vision fallback", async () => {
  home = mkdtempSync(join(tmpdir(), "fx-grok-native-image-"));
  gateway = startFakeGateway([]);
  const grok = startFakeGrokOAuth();
  try {
    writeSeededGrokLogin(home, grok.initialAccessToken);
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({ provider: "grok", grok_model: "grok-4.20" }) + "\n",
      { mode: 0o600 },
    );
    const imagePath = join(home, "attachment.png");
    writeFileSync(imagePath, Buffer.from("89504e470d0a1a0a72657374", "hex"));
    const ask = await runFx([
      "ask",
      "--json",
      "--auto",
      "--no-save",
      "--image",
      imagePath,
      "Describe the image.",
    ], {
      env: {
        HOME: home,
        OPENAI_API_KEY: ENV_TOKEN,
        FX_DISABLE_KEYCHAIN: "1",
        FX_RESPONSES_BASE_URL: gateway.baseUrl,
        ...grok.env,
      },
      timeoutMs: TIMEOUT,
    });
    expect(ask.code, `stdout: ${ask.stdout}\nstderr: ${ask.stderr}`).toBe(0);
    const responses = grok.requests.filter((request) => request.path === "/v1/responses");
    expect(responses).toHaveLength(1);
    expect(responses[0]!.body).toContain('"type":"input_image"');
    expect(responses[0]!.body).not.toContain('"name":"vision"');
    expect(gateway.requests).toHaveLength(0);
  } finally {
    grok.stop();
  }
});

tmuxTest(
  "interactive Grok login activates Grok and provider switching avoids reauthentication",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-grok-tui-switch-"));
    stderrPath = join(home, "stderr.log");
    gateway = startFakeGateway([fakeGatewayFinalText("GATEWAY_AFTER_GROK")]);
    const grok = startFakeGrokOAuth();
    try {
      session = await startFx(home, stderrPath, gateway, undefined, {
        FX_MODEL: undefined,
        ...grok.env,
      });
      await session.waitForText("auto ·", TIMEOUT);

      await session.sendText("/login");
      await session.waitForText("Sign in with Grok", TIMEOUT);
      await session.sendKeys("Down");
      await session.sendKeys("Enter");
      await completeDisplayedGrokLogin(session, grok);
      await session.waitForText("Switched to Grok subscription with grok-4.20.", TIMEOUT);
      await session.sendText("Answer from Grok.");
      await session.waitForText("GROK_DIRECT_RESPONSE", TIMEOUT);

      const tokenCallsAfterLogin = grok.tokenCalls();
      await openProviderPicker(session);
      await session.sendKeys("Up");
      await session.sendKeys("Up");
      await session.sendKeys("Enter");
      await session.waitForText("Switched to BYOK Responses API", TIMEOUT);
      await openProviderPicker(session);
      await session.sendKeys("Down");
      await session.sendKeys("Down");
      await session.sendKeys("Enter");
      await session.waitForText("Switched to Grok subscription with grok-4.20.", TIMEOUT);
      const settingsPath = join(home, ".fx", "settings.json");
      const persistenceDeadline = Date.now() + TIMEOUT;
      let saved: { provider: string; models: { grok: string } } | undefined;
      while (Date.now() < persistenceDeadline) {
        saved = JSON.parse(readFileSync(settingsPath, "utf8")) as {
          provider: string;
          models: { grok: string };
        };
        if (saved.provider === "grok") break;
        await Bun.sleep(25);
      }
      expect(saved).toBeDefined();
      expect(grok.tokenCalls()).toBe(tokenCallsAfterLogin);
      expect(saved!.provider).toBe("grok");
      expect(saved!.models.grok).toBe("grok-4.20");
      const responses = grok.requests.filter((request) => request.path === "/v1/responses");
      expect(responses).toHaveLength(1);
      expect(responses[0]!.conversationId).toBeTruthy();
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    } finally {
      grok.stop();
    }
  },
  60_000,
);

tmuxTest(
  "Grok model selection uses provider-advertised context and effort metadata",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-grok-effort-selection-"));
    stderrPath = join(home, "stderr.log");
    gateway = startFakeGateway([]);
    const grok = startFakeGrokOAuth();
    try {
      writeSeededGrokLogin(home, grok.initialAccessToken);
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({ provider: "grok", grok_model: "grok-4.20", statusLine: { context: true } }) + "\n",
        { mode: 0o600 },
      );
      session = await startFx(home, stderrPath, gateway, undefined, {
        FX_MODEL: undefined,
        ...grok.env,
      });
      await session.waitForComposer(TIMEOUT);
      const catalogDeadline = Date.now() + TIMEOUT;
      while (!grok.requests.some((request) => request.path === "/v1/language-models")) {
        if (Date.now() >= catalogDeadline) throw new Error("Grok catalog did not load");
        await Bun.sleep(25);
      }
      await session.sendText("/model grok-4.6 xhigh");
      await session.waitForText("Switched to grok-4.6", TIMEOUT);
      await session.sendText("Use the selected effort.");
      await session.waitForText("GROK_DIRECT_RESPONSE", TIMEOUT);

      const response = grok.requests.find((request) => request.path === "/v1/responses");
      expect(response).toBeDefined();
      const body = JSON.parse(response!.body ?? "{}") as {
        model?: string;
        reasoning?: { effort?: string };
      };
      expect(body.model).toBe("grok-4.6");
      expect(body.reasoning?.effort).toBe("xhigh");
      expect(await session.capturePane()).toContain("/500k");
      expect(readFileSync(join(home, ".fx", "settings.json"), "utf8")).toContain('"effort":"xhigh"');
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    } finally {
      grok.stop();
    }
  },
  60_000,
);

tmuxTest(
  "Grok resource exhaustion stays on-provider and leaves later input usable",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-grok-resource-recovery-"));
    stderrPath = join(home, "stderr.log");
    gateway = startFakeGateway([]);
    const grok = startFakeGrokResourceRecovery();
    try {
      writeSeededGrokLogin(home, grok.accessToken, "acct_resource_limit");
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({ provider: "grok", grok_model: "grok-4.20" }) + "\n",
        { mode: 0o600 },
      );
      session = await startFx(home, stderrPath, gateway, undefined, {
        FX_MODEL: undefined,
        FX_E2E_XAI_GROK_RESPONSES_URL: grok.responsesUrl,
        FX_E2E_XAI_GROK_MODELS_URL: grok.modelsUrl,
        FX_E2E_XAI_GROK_MODALITIES_URL: grok.modalitiesUrl,
      });
      await session.waitForComposer(TIMEOUT);
      const failureVisible = session.waitForText("request failed: XaiGrokSseEventTooLarge", TIMEOUT);
      await session.sendText("Recover from a bounded Grok response.");
      await failureVisible;
      await session.sendText("Accept another prompt after recovery.");
      await session.waitForText("GROK_LIMIT_RECOVERED", TIMEOUT);
      await session.sendText("Accept one more prompt after recovery.");
      await session.waitForText("GROK_AFTER_LIMIT_OK", TIMEOUT);

      const scrollback = await session.captureFullScrollback();
      expect(scrollback).toContain("XaiGrokSseEventTooLarge");
      expect(grok.bodies).toHaveLength(3);
      expect(gateway.requests).toHaveLength(0);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    } finally {
      grok.stop();
    }
  },
  60_000,
);

test(
  "ChatGPT tool loops round-trip encrypted reasoning without cross-provider leakage",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-chatgpt-tool-loop-"));
    gateway = startFakeGateway([]);
    const codex = startFakeCodexToolLoop();
    try {
      writeSeededChatGptLogin(home, codex.accessToken);
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({ provider: "codex", codex_model: "gpt-5.6-sol" }) + "\n",
        { mode: 0o600 },
      );
      const result = await runFx(
        ["ask", "--json", "--auto", "--no-save", "Read the README, then finish."],
        {
          env: {
            HOME: home,
            OPENAI_API_KEY: "gateway-tool-loop-sentinel",
            FX_DISABLE_KEYCHAIN: "1",
            FX_RESPONSES_BASE_URL: gateway.baseUrl,
            FX_CODEX_BASE_URL: codex.responsesUrl.replace(/\/responses$/, ""),
            FX_E2E_OPENAI_CODEX_MODELS_URL: codex.modelsUrl,
          },
          timeoutMs: TIMEOUT,
        },
      );
      expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
      expect(result.stdout).toContain("CODEX_TOOL_LOOP_OK");
      expect(codex.bodies).toHaveLength(2);
      expect(codex.bodies[1]).toContain('"encrypted_content":"opaque-tool-loop"');
      expect(codex.bodies[1]).toContain('"type":"function_call_output"');
      for (const request of [...gateway.requests, ...gateway.modelRequests]) {
        expect(request.headers.get("authorization")).not.toBe(`Bearer ${codex.accessToken}`);
      }
    } finally {
      codex.stop();
    }
  },
  60_000,
);

tmuxTest(
  "Codex remains usable beyond the durable invocation capacity in one process",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-codex-capacity-loop-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    const codex = startFakeCodexCapacityLoop();
    try {
      writeSeededChatGptLogin(home, codex.accessToken);
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({ provider: "codex", codex_model: "gpt-5.6-sol" }) + "\n",
        { mode: 0o600 },
      );
      session = await startFx(home, stderrPath, gateway, undefined, {
        FX_MODEL: undefined,
        FX_E2E_OPENAI_CODEX_RESPONSES_URL: codex.responsesUrl,
        FX_E2E_OPENAI_CODEX_MODELS_URL: codex.modelsUrl,
      });
      await session.waitForComposer(TIMEOUT);
      await session.sendText("Read enough lines to complete the capacity loop.");
      await session.waitForText("CODEX_CAPACITY_65_OK", 120_000);
      expect(codex.bodies).toHaveLength(65);

      await session.sendText("Confirm the same process remains usable.");
      await session.waitForText("CODEX_CAPACITY_NEXT_OK", TIMEOUT);
      expect(codex.bodies).toHaveLength(66);
      expect(await session.captureFullScrollback()).not.toContain("UsageCapacityExceeded");
      expect(gateway.requests).toHaveLength(0);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    } finally {
      codex.stop();
    }
  },
  150_000,
);

test(
  "Grok tool loops round-trip encrypted reasoning without cross-provider leakage",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-grok-tool-loop-"));
    gateway = startFakeGateway([]);
    const grok = startFakeGrokToolLoop();
    try {
      writeSeededGrokLogin(home, grok.accessToken, "acct_tool_loop");
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({ provider: "grok", grok_model: "grok-4.20" }) + "\n",
        { mode: 0o600 },
      );
      const result = await runFx(
        ["ask", "--json", "--auto", "--no-save", "Read the README, then finish."],
        {
          env: {
            HOME: home,
            OPENAI_API_KEY: "gateway-grok-tool-loop-sentinel",
            FX_DISABLE_KEYCHAIN: "1",
            FX_RESPONSES_BASE_URL: gateway.baseUrl,
            FX_E2E_XAI_GROK_RESPONSES_URL: grok.responsesUrl,
            FX_E2E_XAI_GROK_MODELS_URL: grok.modelsUrl,
            FX_E2E_XAI_GROK_MODALITIES_URL: grok.modalitiesUrl,
          },
          timeoutMs: TIMEOUT,
        },
      );
      expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
      expect(result.stdout).toContain("GROK_TOOL_LOOP_OK");
      expect(grok.bodies).toHaveLength(2);
      expect(grok.bodies[1]).toContain('"encrypted_content":"opaque-grok-tool-loop"');
      expect(grok.bodies[1]).toContain('"type":"function_call_output"');
      for (const request of [...gateway.requests, ...gateway.modelRequests]) {
        expect(request.headers.get("authorization")).not.toContain("grok-tool-loop-token");
      }
    } finally {
      grok.stop();
    }
  },
  60_000,
);

tmuxTest(
  "Grok hosted web search uses the unified TUI lifecycle and replays provider state",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-grok-web-search-"));
    stderrPath = join(home, "stderr.log");
    gateway = startFakeGateway([]);
    const grok = startFakeGrokWebSearch();
    try {
      writeSeededGrokLogin(home, grok.accessToken, "acct_web_search");
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({ provider: "grok", grok_model: "grok-4.20" }) + "\n",
        { mode: 0o600 },
      );
      session = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: REPO_ROOT,
        stderrPath,
        width: 110,
        height: 36,
        env: {
          HOME: home,
          OPENAI_API_KEY: "gateway-grok-search-sentinel",
          FX_DISABLE_KEYCHAIN: "1",
          FX_SKIP_ONBOARDING: "1",
          FX_RESPONSES_BASE_URL: gateway.baseUrl,
          FX_E2E_XAI_GROK_RESPONSES_URL: grok.responsesUrl,
          FX_E2E_XAI_GROK_MODELS_URL: grok.modelsUrl,
          FX_E2E_XAI_GROK_MODALITIES_URL: grok.modalitiesUrl,
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("Search for the current Zig 0.16 status.");
      await session.waitForText("Searched web Zig 0.16", TIMEOUT);
      await session.waitForText("GROK_WEB_SEARCH_DONE", TIMEOUT);
      expect(grok.bodies).toHaveLength(1);
      const first = JSON.parse(grok.bodies[0]!) as {
        tools?: Array<{ type?: string; name?: string }>;
      };
      expect(first.tools?.some((tool) => tool.type === "web_search")).toBe(true);
      expect(first.tools?.some((tool) => tool.name === "web_search")).toBe(false);

      await session.sendText("Use the prior search evidence and finish.");
      await session.waitForText("GROK_WEB_SEARCH_REPLAY_DONE", TIMEOUT);
      expect(grok.bodies).toHaveLength(2);
      const second = JSON.parse(grok.bodies[1]!) as { input?: unknown[] };
      expect(JSON.stringify(second.input)).toContain('"type":"web_search_call"');
      expect(JSON.stringify(second.input)).toContain('"id":"ws_grok_e2e"');
      expect(gateway.requests).toHaveLength(0);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(session.paneStatus()).toEqual({ dead: false, status: null });
    } finally {
      grok.stop();
    }
  },
  60_000,
);

tmuxTest(
  "Grok without backend search uses the separately configured Responses fallback",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-grok-configured-search-fallback-"));
    stderrPath = join(home, "stderr.log");
    gateway = startFakeGateway([]);
    const fixture = startFakeGrokConfiguredSearchFallback();
    try {
      writeSeededGrokLogin(home, fixture.accessToken, "acct_search_fallback");
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({ provider: "grok", grok_model: "grok-no-backend-search" }) + "\n",
        { mode: 0o600 },
      );
      session = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: REPO_ROOT,
        stderrPath,
        width: 110,
        height: 36,
        env: {
          HOME: home,
          OPENAI_API_KEY: "gateway-search-fallback-sentinel",
          FX_DISABLE_KEYCHAIN: "1",
          FX_SKIP_ONBOARDING: "1",
          FX_RESPONSES_BASE_URL: gateway.baseUrl,
          FX_E2E_XAI_GROK_RESPONSES_URL: fixture.responsesUrl,
          FX_E2E_XAI_GROK_MODELS_URL: fixture.modelsUrl,
          FX_E2E_XAI_GROK_MODALITIES_URL: fixture.modalitiesUrl,
          FX_WEB_SEARCH_API_KEY: "configured-search-key",
          FX_WEB_SEARCH_MODEL: "configured-search-model",
          FX_WEB_SEARCH_BASE_URL: fixture.fallbackBaseUrl,
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("Find the current Zig release using web search.");
      await session.waitForText("Searched web current Zig release", TIMEOUT);
      await session.waitForText("GROK_CONFIGURED_SEARCH_FALLBACK_DONE", TIMEOUT);

      expect(fixture.grokBodies).toHaveLength(2);
      const first = JSON.parse(fixture.grokBodies[0]!) as {
        tools?: Array<{ type?: string; name?: string }>;
      };
      expect(first.tools?.some((tool) => tool.type === "web_search")).toBe(false);
      expect(first.tools?.some((tool) => tool.name === "web_search")).toBe(true);
      expect(fixture.fallbackBodies).toHaveLength(1);
      expect(fixture.fallbackAuthorizations).toEqual([
        "Bearer configured-search-key",
      ]);
      const fallback = JSON.parse(fixture.fallbackBodies[0]!) as {
        model?: string;
        tools?: Array<{ type?: string }>;
      };
      expect(fallback.model).toBe("configured-search-model");
      expect(fallback.tools).toEqual([{ type: "web_search" }]);
      expect(fixture.grokBodies[1]).toContain("https://ziglang.org/download/");
      expect(gateway.requests).toHaveLength(0);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(session.paneStatus()).toEqual({ dead: false, status: null });
    } finally {
      fixture.stop();
    }
  },
  60_000,
);

test(
  "Codex CLI login preserves durable auth but does not claim success when activation fails",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-codex-cli-activation-failure-"));
    gateway = startFakeGateway([]);
    chatgptOauth = startFakeChatGptOAuth();
    chatgptOauth.setModels([]);
    const env = {
      HOME: home,
      OPENAI_API_KEY: ENV_TOKEN,
      FX_DISABLE_KEYCHAIN: "1",
      FX_SKIP_ONBOARDING: "1",
      FX_NO_OPEN_BROWSER: "1",
      FX_RESPONSES_BASE_URL: gateway.baseUrl,
      ...chatgptOauth.env,
    };

    const login = await runCodexLoginWithBrowser(env);
    expect(login.code).toBe(1);
    expect(login.stdout).not.toContain("Signed in with Codex.");
    expect(login.stderr).toContain("fx login: could not load the target model catalog (malformed_response)");
    expect(existsSync(join(home, ".fx", "chatgpt-auth.json"))).toBe(true);
    const settingsPath = join(home, ".fx", "settings.json");
    expect(existsSync(settingsPath)).toBe(false);
  },
  60_000,
);

test(
  "Grok CLI login preserves durable auth but does not claim success when activation fails",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-grok-cli-activation-failure-"));
    gateway = startFakeGateway([]);
    const grok = startFakeGrokOAuth();
    grok.setModels([]);
    try {
      const env = {
        HOME: home,
        OPENAI_API_KEY: ENV_TOKEN,
        FX_DISABLE_KEYCHAIN: "1",
        FX_SKIP_ONBOARDING: "1",
        FX_NO_OPEN_BROWSER: "1",
        FX_RESPONSES_BASE_URL: gateway.baseUrl,
        ...grok.env,
      };

      const login = await runGrokLoginWithBrowser(env);
      expect(login.code).toBe(1);
      expect(login.stdout).not.toContain("Signed in with Grok.");
      expect(login.stderr).toContain("fx login: target model catalog is empty");
      expect(existsSync(join(home, ".fx", "grok-auth.json"))).toBe(true);
      expect(existsSync(join(home, ".fx", "settings.json"))).toBe(false);
    } finally {
      grok.stop();
    }
  },
  60_000,
);

test(
  "Codex rejects the vision fallback without another provider request",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-codex-vision-disabled-"));
    gateway = startFakeGateway([]);
    const codex = startFakeCodexToolLoop({
      toolName: "vision",
      toolArguments: { image_ids: [1], focus: "Inspect the image." },
      finalText: "CODEX_VISION_DISABLED_OK",
    });
    try {
      writeSeededChatGptLogin(home, codex.accessToken);
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({ provider: "codex", codex_model: "gpt-5.6-sol" }) + "\n",
        { mode: 0o600 },
      );
      const result = await runFx(
        ["ask", "--json", "--auto", "--no-save", "Answer without using a vision fallback."],
        {
          env: {
            HOME: home,
            OPENAI_API_KEY: "gateway-vision-sentinel",
            FX_DISABLE_KEYCHAIN: "1",
            FX_RESPONSES_BASE_URL: gateway.baseUrl,
            FX_CODEX_BASE_URL: codex.responsesUrl.replace(/\/responses$/, ""),
            FX_E2E_OPENAI_CODEX_MODELS_URL: codex.modelsUrl,
          },
          timeoutMs: TIMEOUT,
        },
      );
      expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
      expect(result.stdout).toContain("CODEX_VISION_DISABLED_OK");
      expect(codex.bodies).toHaveLength(2);
      expect(codex.bodies[0]).not.toContain('"name":"vision"');
      const continuation = JSON.parse(codex.bodies[1]) as {
        input: Array<{ type?: string; output?: string }>;
      };
      const toolResult = continuation.input.find(
        (item) => item.type === "function_call_output",
      );
      expect(toolResult?.output).toContain("Vision is unavailable for this request.");
      expect(toolResult?.output).toContain("native image input");
      for (const request of [...gateway.requests, ...gateway.modelRequests]) {
        expect(request.headers.get("authorization")).not.toBe(`Bearer ${codex.accessToken}`);
      }
    } finally {
      codex.stop();
    }
  },
  60_000,
);

test(
  "Grok rejects the vision fallback because native image input owns OCR",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-grok-vision-disabled-"));
    gateway = startFakeGateway([]);
    const grok = startFakeGrokToolLoop({
      toolName: "vision",
      toolArguments: { image_ids: [1], focus: "Inspect the image." },
      finalText: "GROK_VISION_DISABLED_OK",
    });
    try {
      writeSeededGrokLogin(home, grok.accessToken, "acct_vision");
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({ provider: "grok", grok_model: "grok-4.20" }) + "\n",
        { mode: 0o600 },
      );
      const result = await runFx(
        ["ask", "--json", "--auto", "--no-save", "Answer without a vision fallback."],
        {
          env: {
            HOME: home,
            OPENAI_API_KEY: "gateway-grok-vision-sentinel",
            FX_DISABLE_KEYCHAIN: "1",
            FX_RESPONSES_BASE_URL: gateway.baseUrl,
            FX_E2E_XAI_GROK_RESPONSES_URL: grok.responsesUrl,
            FX_E2E_XAI_GROK_MODELS_URL: grok.modelsUrl,
            FX_E2E_XAI_GROK_MODALITIES_URL: grok.modalitiesUrl,
          },
          timeoutMs: TIMEOUT,
        },
      );
      expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
      expect(result.stdout).toContain("GROK_VISION_DISABLED_OK");
      expect(grok.bodies).toHaveLength(2);
      expect(grok.bodies[0]).not.toContain('"name":"vision"');
      const continuation = JSON.parse(grok.bodies[1]) as {
        input: Array<{ type?: string; output?: string }>;
      };
      const toolResult = continuation.input.find((item) => item.type === "function_call_output");
      expect(toolResult?.output).toContain("Vision is unavailable for this request.");
      expect(gateway.requests).toHaveLength(0);
    } finally {
      grok.stop();
    }
  },
  60_000,
);

test(
  "Codex automatic review uses gpt-5.4-mini without reaching BYOK Responses",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-codex-auto-review-"));
    gateway = startFakeGateway([]);
    const codex = startFakeCodexAutoReview();
    const tracePath = join(home, "permission-trace.log");
    try {
      writeFileSync(join(home, "auto-review-fixture"), "temporary\n");
      writeSeededChatGptLogin(home, codex.accessToken);
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({ provider: "codex", codex_model: "gpt-5.6-sol" }) + "\n",
        { mode: 0o600 },
      );
      const result = await runFx(
        ["ask", "--json", "--auto", "Run the auto-review fixture, then finish."],
        {
          env: {
            HOME: home,
            OPENAI_API_KEY: "gateway-auto-review-sentinel",
            FX_DISABLE_KEYCHAIN: "1",
            FX_RESPONSES_BASE_URL: gateway.baseUrl,
            FX_CODEX_BASE_URL: codex.responsesUrl.replace(/\/responses$/, ""),
            FX_E2E_OPENAI_CODEX_MODELS_URL: codex.modelsUrl,
            FX_TRACE_LOG: tracePath,
            FX_TRACE_SCOPES: "permission",
          },
          cwd: home,
          timeoutMs: TIMEOUT,
        },
      );
      expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
      expect(result.stdout).toContain("CODEX_AUTO_REVIEW_OK");
      expect(readFileSync(tracePath, "utf8")).toContain("event=auto_review_start");
      expect(gateway.classifierRequests).toHaveLength(0);
      expect(codex.bodies.map((body) => (JSON.parse(body) as { model: string }).model))
        .toEqual(["gpt-5.6-sol", "gpt-5.4-mini", "gpt-5.6-sol"]);
      expect(codex.bodies[1]).toContain('"name":"permission_decision"');
      expect(codex.bodies[2]).toContain('"type":"function_call_output"');
      expect(codex.bodies[2]).toContain('\\"exit_code\\":0');
      for (const request of gateway.requests) {
        expect(request.body).not.toContain("permission_decision");
      }
      expect(readSingleUsageSnapshot(home)).toMatchObject({
        billing: "complete",
        api_duration_complete: true,
        next_sequence: 4,
        settled_through_sequence: 3,
        input_tokens: 20,
        output_tokens: 8,
        request_count: 3,
        models: [
          { model: "codex/gpt-5.6-sol", request_count: 2 },
          { model: "codex/gpt-5.4-mini", request_count: 1 },
        ],
        publication_backlog: [],
      });
    } finally {
      codex.stop();
    }
  },
  60_000,
);

test(
  "Grok automatic review reuses the admitted Grok model without reaching BYOK Responses",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-grok-auto-review-"));
    gateway = startFakeGateway([]);
    const grok = startFakeGrokAutoReview();
    const tracePath = join(home, "permission-trace.log");
    try {
      writeFileSync(join(home, "auto-review-fixture"), "temporary\n");
      writeSeededGrokLogin(home, grok.accessToken, "acct_auto_review");
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({ provider: "grok", grok_model: "grok-4.20" }) + "\n",
        { mode: 0o600 },
      );
      const result = await runFx(
        ["ask", "--json", "--auto", "Run the auto-review fixture, then finish."],
        {
          env: {
            HOME: home,
            OPENAI_API_KEY: "gateway-grok-auto-review-sentinel",
            FX_DISABLE_KEYCHAIN: "1",
            FX_RESPONSES_BASE_URL: gateway.baseUrl,
            FX_E2E_XAI_GROK_RESPONSES_URL: grok.responsesUrl,
            FX_E2E_XAI_GROK_MODELS_URL: grok.modelsUrl,
            FX_E2E_XAI_GROK_MODALITIES_URL: grok.modalitiesUrl,
            FX_TRACE_LOG: tracePath,
            FX_TRACE_SCOPES: "permission",
          },
          cwd: home,
          timeoutMs: TIMEOUT,
        },
      );
      expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
      expect(result.stdout).toContain("GROK_AUTO_REVIEW_OK");
      expect(readFileSync(tracePath, "utf8")).toContain("event=auto_review_start");
      expect(gateway.classifierRequests).toHaveLength(0);
      expect(grok.bodies.map((body) => (JSON.parse(body) as { model: string }).model))
        .toEqual(["grok-4.20", "grok-4.20", "grok-4.20"]);
      expect(grok.bodies[1]).toContain('"name":"permission_decision"');
      expect(grok.bodies[2]).toContain('"type":"function_call_output"');
      expect(grok.bodies[2]).toContain('\\"exit_code\\":0');
      expect(grok.headers).toHaveLength(3);
      for (const headers of grok.headers) {
        expect(headers.tokenAuth).toBe("xai-grok-cli");
        expect(headers.authenticateResponse).toBe("authenticate-response");
        expect(headers.clientIdentifier).toBe("fx");
        expect(headers.clientVersion).toBe("1.0.6");
        expect(headers.modelOverride).toBe("grok-4.20");
        expect(headers.grokUserId).toBe("acct_auto_review");
      }
      for (const request of gateway.requests) {
        expect(request.body).not.toContain("permission_decision");
      }
      expect(readSingleUsageSnapshot(home)).toMatchObject({
        billing: "complete",
        api_duration_complete: true,
        next_sequence: 4,
        settled_through_sequence: 3,
        input_tokens: 20,
        output_tokens: 8,
        request_count: 3,
        models: [{ model: "grok/grok-4.20", request_count: 3 }],
        publication_backlog: [],
      });
    } finally {
      grok.stop();
    }
  },
  60_000,
);

tmuxTest(
  "missing auth after deferred onboarding preserves the complete prompt",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-preflight-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    const imagePath = join(home, "attachment.png");
    writeFileSync(imagePath, Buffer.from("89504e470d0a1a0a72657374", "hex"));
    gateway = startFakeGateway([], {
      models: [{
        id: "gpt-5",
        object: "model",
        owned_by: "openai",
      }],
    });

    session = await startFxWithoutAuth(home, stderrPath, gateway);
    const initial = await session.waitForComposer(TIMEOUT);
    expect(initial).not.toContain("Switch credential");

    await session.sendText(`/image ${imagePath}`);
    await session.waitForText("attached image: attachment.png", TIMEOUT);
    await session.sendText(" preserve this exact prompt");
    const blocked = await session.waitForPane(
      (pane) =>
        pane.includes("Fx needs a model credential") &&
        pane.includes("preserve this exact prompt") &&
        pane.includes("Image 1"),
      TIMEOUT,
    );
    expect(blocked).not.toContain("Welcome to fx");
    expect(blocked).not.toContain("Switch credential");
    expect(gateway.requests).toHaveLength(0);
    expect(session.isAlive()).toBe(true);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "HTTP auth failure names the selected source and suppresses provider detail",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-http-failure-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    const providerDetail = `rejected ${ENV_TOKEN} in provider response`;
    gateway = startFakeGateway([
      new Response(JSON.stringify({ error: { message: providerDetail } }), {
        status: 401,
        headers: { "content-type": "application/json" },
      }),
    ]);

    session = await startFx(home, stderrPath, gateway);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("exercise interactive auth failure");
    const failed = await session.waitForPane(
      (pane) =>
        pane.includes("OPENAI_API_KEY authentication failed · HTTP 401") &&
        pane.includes("Run /login to choose another source."),
      TIMEOUT,
    );

    expect(failed).not.toContain(ENV_TOKEN);
    expect(failed).not.toContain(providerDetail);
    expect(gateway.requests).toHaveLength(1);
    expect(gateway.requests[0].headers.get("authorization")).toBe(`Bearer ${ENV_TOKEN}`);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);
