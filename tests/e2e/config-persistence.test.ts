import { afterEach, describe, expect, test } from "bun:test";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import {
  composerContains,
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  hasEmptyComposer,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const TIMEOUT = 20_000;
const NO_AUTH = {
  OPENAI_API_KEY: "",
  FX_MODEL: undefined,
  NO_COLOR: "1",
};

const serialTest = test.serial;
const SELECTED_COMPLETION_SGR = "\x1b[1m\x1b[38;5;255m";

function selectedModelStageRow(paneEscapes: string, label: string): string | null {
  return paneEscapes.split("\n").find((line) => {
    const visible = line.replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "").trim();
    return line.includes(SELECTED_COMPLETION_SGR) && visible === label;
  }) ?? null;
}

async function waitForSelectedModelStage(
  active: TmuxSession,
  label: string,
  timeoutMs: number,
): Promise<string> {
  const deadline = Date.now() + timeoutMs;
  let last: string | null = null;
  while (Date.now() < deadline) {
    last = selectedModelStageRow(await active.capturePaneEscapes(), label);
    if (last !== null) return last;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error(`Timed out waiting for selected model option ${label}; last=${last}`);
}

async function disablePromptHistory(
  session: TmuxSession,
  settingsPath: string,
): Promise<void> {
  await session.sendText("/settings");
  await session.waitForText("←→ Change", TIMEOUT);
  for (let index = 0; index < 10; index += 1) {
    await session.sendKeys("Down");
  }
  await session.sendKeys("Left");
  const deadline = Date.now() + TIMEOUT;
  let enabled: unknown;
  while (Date.now() < deadline) {
    if (existsSync(settingsPath)) {
      enabled = JSON.parse(readFileSync(settingsPath, "utf8")).prompt_history?.enabled;
      if (enabled === false) break;
    }
    await Bun.sleep(25);
  }
  if (enabled !== false) throw new Error("Timed out disabling prompt history");
  await session.sendKeys("Escape");
  await session.waitForPane(
    (pane) => hasEmptyComposer(pane) && !pane.includes("←→ Change"),
    TIMEOUT,
  );
}

function tree(root: string, relative = ""): string[] {
  const path = relative ? join(root, relative) : root;
  const entries = readdirSync(path, { withFileTypes: true });
  const result: string[] = [];
  for (const entry of entries) {
    const child = relative ? join(relative, entry.name) : entry.name;
    result.push(child);
    if (entry.isDirectory()) result.push(...tree(root, child));
  }
  return result.sort();
}

function migrationSnapshotPath(home: string, field: string): string {
  const backups = join(home, ".fx", "backups");
  const name = `settings.json.preference-migration.${field}.json`;
  expect(readdirSync(backups)).toContain(name);
  return join(backups, name);
}

function clearedPaneWithoutAllowlistRules(pane: string): boolean {
  return (
    hasEmptyComposer(pane) &&
    !pane.includes("● Allowlist:") &&
    !pane.includes("user *")
  );
}

describe.skipIf(!tmuxAvailable())("config persistence", () => {
  let session: TmuxSession | null = null;
  let secondSession: TmuxSession | null = null;

  afterEach(async () => {
    await session?.kill();
    await secondSession?.kill();
    session = null;
    secondSession = null;
  });

  serialTest(
    "user preferences migrate globally and load in another project",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-config-persistence-"));
      const gateway = startFakeGateway([], {
        models: [{
          id: "gpt-5.6-sol",
          object: "model",
          owned_by: "openai",
        }],
      });
      try {
        const home = join(root, "home");
        const workspaceA = join(root, "workspace-a");
        const workspaceB = join(root, "workspace-b");
        const stderrAPath = join(root, "stderr-a.log");
        const stderrBPath = join(root, "stderr-b.log");
        mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
        mkdirSync(workspaceA);
        mkdirSync(workspaceB);
        const workspaceARoot = realpathSync(workspaceA);
        const workspaceBRoot = realpathSync(workspaceB);
        const projectABytes = "{\"project_future\":{\"name\":\"a\"}}\n";
        const projectBBytes = "{\"project_future\":{\"name\":\"b\"}}\n";
        writeFileSync(join(workspaceA, ".fx.json"), projectABytes);
        writeFileSync(join(workspaceB, ".fx.json"), projectBBytes);
        writeFileSync(
          join(home, ".fx", "settings.json"),
          JSON.stringify({
            future_global: { nested: "preserve-me" },
            workspaces: {
              [workspaceARoot]: {
                model: "legacy/project-a",
                permission_mode: "ask",
                effort: "low",
                fast_mode: false,
                startup_scrollback: true,
                prompt_history: { enabled: true, future: "keep-a-history" },
                statusLine: {
                  sandbox: false,
                  context: false,
                  session: false,
                  workspace: false,
                  future: "keep-a-status",
                },
                future_workspace: { nested: "a" },
              },
              [workspaceBRoot]: {
                model: "legacy/project-b",
                permission_mode: "ask",
                effort: "high",
                fast_mode: false,
                startup_scrollback: true,
                prompt_history: { enabled: true, future: "keep-b-history" },
                statusLine: {
                  sandbox: false,
                  context: false,
                  session: false,
                  workspace: false,
                  future: "keep-b-status",
                },
                future_workspace: { nested: "b" },
              },
            },
          }) + "\n",
          { mode: 0o600 },
        );
        const catalogEnv = {
          ...NO_AUTH,
          OPENAI_API_KEY: "fake-preference-catalog-key",
          HOME: home,
          FX_RESPONSES_BASE_URL: gateway.baseUrl,
        };

        session = await TmuxSession.create({
          cwd: workspaceARoot,
          env: catalogEnv,
          stderrPath: stderrAPath,
        });
        await session.waitForText("Run /help", TIMEOUT);
        await session.sendKeys("BTab");
        await session.waitForText("auto ·", TIMEOUT);
        await session.pasteText("/model gpt-5.6-sol auto normal");
        const beforeModelCommit = JSON.parse(
          readFileSync(join(home, ".fx", "settings.json"), "utf8"),
        );
        expect(beforeModelCommit).not.toHaveProperty("model");
        await session.sendKeys("Enter");
        await session.waitForText("● Switched to gpt-5.6-sol", TIMEOUT);
        await session.sendText("/fast");
        await session.waitForText("● Fast: on", TIMEOUT);
        await session.sendText("/statusline context");
        await session.waitForText("● Statusline: context:", TIMEOUT);
        await session.sendText("/statusline session");
        await session.waitForText("● Statusline: session:", TIMEOUT);
        await session.sendText("/statusline workspace");
        await session.waitForText("● Statusline: workspace:", TIMEOUT);
        await session.sendText("/settings startup-scrollback off");
        await session.waitForText("startup_scrollback: off", TIMEOUT);
        await disablePromptHistory(session, join(home, ".fx", "settings.json"));
        await session.sendText("/quit");
        await session.waitForSessionEnd(TIMEOUT);
        session = null;

        const stored = JSON.parse(readFileSync(join(home, ".fx", "settings.json"), "utf8"));
        expect(stored.models.gateway).toBe("gpt-5.6-sol");
        expect(stored.permission_mode).toBe("auto");
        expect(stored.effort).toBe("auto");
        expect(stored.fast_mode).toBe(true);
        expect(stored.startup_scrollback).toBe(false);
        expect(stored.prompt_history).toMatchObject({ enabled: false });
        expect(stored.statusLine).toMatchObject({
          context: true,
          session: true,
          workspace: true,
        });
        expect(stored.future_global).toEqual({ nested: "preserve-me" });
        for (const [workspaceRoot, futureWorkspace, historyFuture, statusFuture] of [
          [workspaceARoot, "a", "keep-a-history", "keep-a-status"],
          [workspaceBRoot, "b", "keep-b-history", "keep-b-status"],
        ] as const) {
          const override = stored.workspaces[workspaceRoot];
          expect(override).not.toHaveProperty("model");
          expect(override).not.toHaveProperty("permission_mode");
          expect(override).not.toHaveProperty("effort");
          expect(override).not.toHaveProperty("fast_mode");
          expect(override).not.toHaveProperty("startup_scrollback");
          expect(override.prompt_history).toEqual({ future: historyFuture });
          expect(override.statusLine).toEqual({ sandbox: false, workspace: false, future: statusFuture });
          expect(override.future_workspace).toEqual({ nested: futureWorkspace });
        }
        expect(readFileSync(join(workspaceA, ".fx.json"), "utf8")).toBe(projectABytes);
        expect(readFileSync(join(workspaceB, ".fx.json"), "utf8")).toBe(projectBBytes);

        const migrationSnapshots = [
          "model",
          "permission_mode",
          "effort",
          "fast_mode",
          "startup_scrollback",
          "prompt_history_enabled",
          "statusline_context",
          "statusline_session",
        ].map((field) => migrationSnapshotPath(home, field));
        for (const snapshotPath of migrationSnapshots) {
          expect(statSync(snapshotPath).mode & 0o777).toBe(0o600);
        }

        session = await TmuxSession.create({
          cwd: workspaceBRoot,
          env: catalogEnv,
          stderrPath: stderrBPath,
        });
        const startup = await session.waitForText(
          "auto · gpt-5.6-sol · ⚡︎",
          TIMEOUT,
        );
        expect(startup).toContain("auto · gpt-5.6-sol · ⚡︎");
        expect(startup).not.toContain("adaptive");
        expect(startup).not.toContain("⚡︎ fast");
        await session.sendText("/settings");
        const pane = await session.waitForText("←→ Change", TIMEOUT);
        expect(pane).toContain("gpt-5.6-sol");
        expect(pane).toContain("Startup scrollback");
        expect(pane).toContain("Prompt history");
        await session.sendKeys("Escape");
        await session.waitForPane(
          (current) =>
            hasEmptyComposer(current) && !current.includes("←→ Change"),
          TIMEOUT,
        );
        await session.sendText("/statusline");
        const statusline = await session.waitForText("Context  ", TIMEOUT);
        expect(statusline).toContain("Status line");
        expect(statusline).not.toContain("Sandbox");
        expect(statusline).toContain("Context");
        expect(statusline).toContain("Session");
        expect(statusline).toContain("off  on");
        await session.sendKeys("Escape");
        await session.waitForComposer(TIMEOUT);
        await session.sendText("/quit");
        await session.waitForSessionEnd(TIMEOUT);
        session = null;

        session = await TmuxSession.create({
          cwd: workspaceBRoot,
          env: {
            ...catalogEnv,
            FX_MODEL: "openai/gpt-5",
          },
          stderrPath: stderrBPath,
        });
        await session.waitForText("gpt-5", TIMEOUT);
        await session.sendText("/quit");
        await session.waitForSessionEnd(TIMEOUT);
        session = null;

        const afterOverride = JSON.parse(
          readFileSync(join(home, ".fx", "settings.json"), "utf8"),
        );
        expect(afterOverride.models.gateway).toBe("gpt-5.6-sol");
        expect(readFileSync(stderrAPath, "utf8")).toBe("");
        expect(readFileSync(stderrBPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
        rmSync(root, { recursive: true, force: true });
      }
    },
    120_000,
  );

  serialTest(
    "unscoped allowlist stays local while explicit user rules cross projects",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-config-permission-scopes-"));
      try {
        const home = join(root, "home");
        const workspaceA = join(root, "workspace-a");
        const workspaceB = join(root, "workspace-b");
        const stderrAPath = join(root, "stderr-a.log");
        const stderrBPath = join(root, "stderr-b.log");
        mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
        mkdirSync(workspaceA);
        mkdirSync(workspaceB);
        const workspaceARoot = realpathSync(workspaceA);
        const workspaceBRoot = realpathSync(workspaceB);
        writeFileSync(
          join(home, ".fx", "settings.json"),
          JSON.stringify({
            permission: {
              " bash ": {
                " padded * ": "allow",
              },
            },
          }) + "\n",
          { mode: 0o600 },
        );

        session = await TmuxSession.create({
          cwd: workspaceARoot,
          env: { ...NO_AUTH, HOME: home },
          stderrPath: stderrAPath,
        });
        await session.waitForText("Run /help", TIMEOUT);
        await session.sendText('/allowlist add command "local-a *"');
        await session.waitForText("(scope=local)", TIMEOUT);
        await session.sendText('/allowlist user add command "user *"');
        await session.waitForText("(scope=user)", TIMEOUT);
        await session.sendText("/quit");
        await session.waitForSessionEnd(TIMEOUT);
        session = null;

        const afterA = JSON.parse(
          readFileSync(join(home, ".fx", "settings.json"), "utf8"),
        );
        expect(afterA.permission.bash["user *"]).toBe("allow");
        expect(afterA.workspaces[workspaceARoot].permission.bash["local-a *"]).toBe(
          "allow",
        );
        expect(afterA.workspaces).not.toHaveProperty(workspaceBRoot);

        session = await TmuxSession.create({
          cwd: workspaceBRoot,
          env: { ...NO_AUTH, HOME: home },
          stderrPath: stderrBPath,
        });
        await session.waitForText("Run /help", TIMEOUT);
        await session.sendText("/allowlist view local");
        await session.waitForText(
          "● Allowlist: local persistent allow rules: (none)",
          TIMEOUT,
        );
        await session.sendText("/allowlist view user");
        await session.waitForText("user *", TIMEOUT);
        await session.sendText('/allowlist user remove command "padded *"');
        await session.waitForText("● Allowlist: removed command", TIMEOUT);
        await session.sendText("/clear");
        await session.waitForPane(
          clearedPaneWithoutAllowlistRules,
          TIMEOUT,
        );
        await session.sendText("/allowlist view effective");
        const inherited = await session.waitForText("user *", TIMEOUT);
        expect(inherited).toContain("● Allowlist: effective persistent allow rules:");

        await session.sendText('/allowlist add command "local-b *"');
        await session.waitForText("(scope=local)", TIMEOUT);
        await session.sendText("/allowlist view user");
        const shadowed = await session.waitForText(
          "user rules are shadowed by local settings",
          TIMEOUT,
        );
        expect(shadowed).toContain("user *");
        await session.sendText("/clear");
        await session.waitForPane(
          clearedPaneWithoutAllowlistRules,
          TIMEOUT,
        );
        await session.sendText("/allowlist view effective");
        const localEffective = await session.waitForText("local-b *", TIMEOUT);
        expect(localEffective).not.toContain("user *");

        await session.sendText('/allowlist user remove command "user *"');
        await session.waitForText("● Allowlist: removed command", TIMEOUT);
        await session.sendText("/quit");
        await session.waitForSessionEnd(TIMEOUT);
        session = null;

        const afterB = JSON.parse(
          readFileSync(join(home, ".fx", "settings.json"), "utf8"),
        );
        expect(afterB.permission).toEqual({});
        expect(afterB.workspaces[workspaceARoot].permission.bash["local-a *"]).toBe(
          "allow",
        );
        expect(afterB.workspaces[workspaceBRoot].permission.bash["local-b *"]).toBe(
          "allow",
        );
        expect(readFileSync(stderrAPath, "utf8")).toBe("");
        expect(readFileSync(stderrBPath, "utf8")).toBe("");
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    90_000,
  );

  serialTest(
    "legacy output settings remain inert and output text follows prompt admission",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-config-output-shadow-"));
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        const stderrPath = join(root, "stderr.log");
        mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
        mkdirSync(workspace);
        const workspaceRoot = realpathSync(workspace);
        const projectBytes =
          "{\"output_level\":{\"legacy\":true},\"future\":{\"keep\":true}}\n";
        writeFileSync(join(workspace, ".fx.json"), projectBytes);
        const unrelatedWorkspace = join(root, "unrelated-workspace");
        const settingsBytes =
          JSON.stringify({
            output_level: { legacy: true },
            startup_scrollback: true,
            workspaces: {
              [workspaceRoot]: {
                output_level: ["quiet", 7],
                future_workspace: { keep: true },
              },
              [unrelatedWorkspace]: {
                model: 123,
                future_workspace: { preserve: true },
              },
            },
          }) + "\n";
        writeFileSync(
          join(home, ".fx", "settings.json"),
          settingsBytes,
          { mode: 0o600 },
        );

        session = await TmuxSession.create({
          cwd: workspaceRoot,
          env: { ...NO_AUTH, HOME: home },
          stderrPath,
        });
        await session.waitForText("Run /help", TIMEOUT);
        await session.sendText("/output quiet");
        await session.waitForText("Fx needs a model credential", TIMEOUT);
        expect(composerContains(await session.capturePane(), "/output quiet")).toBe(
          true,
        );
        await session.sendKeys("C-u");
        await session.waitForPane(hasEmptyComposer, TIMEOUT);
        await session.sendText("/settings startup-scrollback off");
        await session.waitForText(
          "startup_scrollback: off (applies on next launch)",
          TIMEOUT,
        );
        await session.waitForStableComposer(TIMEOUT);
        await session.sendText("/quit");
        await session.waitForSessionEnd(TIMEOUT);
        session = null;

        const stored = JSON.parse(
          readFileSync(join(home, ".fx", "settings.json"), "utf8"),
        );
        expect(stored.output_level).toEqual({ legacy: true });
        expect(stored.startup_scrollback).toBe(false);
        expect(stored.workspaces[workspaceRoot]).toEqual({
          output_level: ["quiet", 7],
          future_workspace: { keep: true },
        });
        expect(stored.workspaces[unrelatedWorkspace]).toEqual({
          model: 123,
          future_workspace: { preserve: true },
        });
        expect(readFileSync(join(workspace, ".fx.json"), "utf8")).toBe(projectBytes);
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    30_000,
  );


  serialTest(
    "Escape keeps the model picker dismissed until the model trigger restarts",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-model-picker-dismissal-"));
      const gateway = startFakeGateway([], {
        models: [{
          id: "xai/grok-build-1",
          object: "model",
          created: 1,
        }],
      });
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        const stderrPath = join(root, "stderr.log");
        mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
        mkdirSync(workspace);
        writeFileSync(
          join(home, ".fx", "settings.json"),
          JSON.stringify({ model: "openai/gpt-5" }) + "\n",
        );

        session = await TmuxSession.create({
          cwd: realpathSync(workspace),
          env: {
            ...NO_AUTH,
            OPENAI_API_KEY: "fake-picker-catalog-key",
            HOME: home,
            FX_RESPONSES_BASE_URL: gateway.baseUrl,
          },
          stderrPath,
        });
        await session.waitForText("Run /help", TIMEOUT);
        await session.sendLiteral("/model");
        await session.sendKeys("Enter");
        await session.waitForText("xai/grok-build-1", TIMEOUT);

        await session.sendKeys("Escape");
        await session.waitForPane(
          (pane) =>
            composerContains(pane, "/model") &&
            !pane.includes("xai/grok-build-1"),
          TIMEOUT,
        );
        await session.sendLiteral("x");
        await session.waitForPane(
          (pane) =>
            composerContains(pane, "/model x") &&
            !pane.includes("xai/grok-build-1"),
          TIMEOUT,
        );

        await session.sendKeys("C-u");
        await session.sendLiteral("/model");
        await session.sendKeys("Enter");
        await session.waitForText("xai/grok-build-1", TIMEOUT);

        await session.sendKeys("C-u");
        await session.sendText("/quit");
        await session.waitForSessionEnd(TIMEOUT);
        session = null;
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
        rmSync(root, { recursive: true, force: true });
      }
    },
    30_000,
  );

  test(
    "Fast command rejects a name-only Fast alias",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-fast-unsupported-"));
      const gateway = startFakeGateway([], {
        models: [{
          id: "company-fast-alias",
          object: "model",
          created: 1,
        }],
      });
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        const stderrPath = join(root, "stderr.log");
        mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
        mkdirSync(workspace);
        const settingsPath = join(home, ".fx", "settings.json");
        const initialSettings = JSON.stringify({
          model: "company-fast-alias",
          fast_mode: false,
        }) + "\n";
        writeFileSync(settingsPath, initialSettings, { mode: 0o600 });

        session = await TmuxSession.create({
          cwd: realpathSync(workspace),
          env: {
            ...NO_AUTH,
            OPENAI_API_KEY: "fake-standard-key",
            HOME: home,
            FX_RESPONSES_BASE_URL: gateway.baseUrl,
          },
          stderrPath,
        });
        await session.waitForText("Run /help", TIMEOUT);
        await session.sendText("/fast");
        const pane = await session.waitForText(
          "This model does not come with a fast mode.",
          TIMEOUT,
        );
        expect(pane).not.toContain("⚡︎");
        expect(gateway.requests).toHaveLength(0);
        expect(readFileSync(settingsPath, "utf8")).toBe(initialSettings);

        await session.sendText("/quit");
        await session.waitForSessionEnd(TIMEOUT);
        session = null;
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
        rmSync(root, { recursive: true, force: true });
      }
    },
    30_000,
  );

  test(
    "settings reasoning effort changes without mutating the selected model",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-settings-effort-"));
      const gateway = startFakeGateway([], {
        models: [{
          id: "gpt-5.6-sol",
          object: "model",
          created: 1,
          owned_by: "openai",
        }],
      });
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        const stderrPath = join(root, "stderr.log");
        const settingsPath = join(home, ".fx", "settings.json");
        mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
        mkdirSync(workspace);
        writeFileSync(
          settingsPath,
          JSON.stringify({ model: "gpt-5.6-sol", effort: "low" }) + "\n",
          { mode: 0o600 },
        );

        session = await TmuxSession.create({
          cwd: realpathSync(workspace),
          env: {
            ...NO_AUTH,
            OPENAI_API_KEY: "fake-settings-catalog-key",
            HOME: home,
            FX_RESPONSES_BASE_URL: gateway.baseUrl,
          },
          stderrPath,
        });
        await session.waitForText("Run /help", TIMEOUT);
        await session.sendText("/settings");
        await session.waitForText("←→ Change", TIMEOUT);
        await session.sendLiteral("reason");
        const effortSetting = await session.waitForText("Reasoning effort", TIMEOUT);
        expect(effortSetting).toContain("low");
        await session.sendKeys("Right");

        let stored = JSON.parse(readFileSync(settingsPath, "utf8"));
        const persistenceDeadline = Date.now() + TIMEOUT;
        while (stored.effort !== "medium" && Date.now() < persistenceDeadline) {
          await Bun.sleep(25);
          stored = JSON.parse(readFileSync(settingsPath, "utf8"));
        }
        expect(stored).toMatchObject({
          model: "gpt-5.6-sol",
          effort: "medium",
        });
        expect(session.paneStatus()).toEqual({ dead: false, status: null });
        expect(await session.capturePane()).toContain("medium");

        await session.sendKeys("Escape");
        await session.waitForComposer(TIMEOUT);
        await session.sendText("/quit");
        await session.waitForSessionEnd(TIMEOUT);
        session = null;

        expect(readFileSync(stderrPath, "utf8")).toBe("");
        expect(gateway.requests).toHaveLength(0);
      } finally {
        gateway.stop();
        rmSync(root, { recursive: true, force: true });
      }
    },
    60_000,
  );


  test(
    "GPT 5.6 Sol uses the Responses priority service tier",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-openai-capabilities-"));
      const gateway = startFakeGateway(
        [
          fakeGatewayFinalText("GPT 5.6 stale effort filtered"),
          fakeGatewayFinalText("GPT 5.6 max fast complete"),
        ],
        {
          models: [{
            id: "gpt-5.6-sol",
            object: "model",
            owned_by: "openai",
            created: 1,
          }],
        },
      );
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        const stderrPath = join(root, "stderr.log");
        mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
        mkdirSync(workspace);
        const workspaceRoot = realpathSync(workspace);
        const settingsPath = join(home, ".fx", "settings.json");
        writeFileSync(
          settingsPath,
          JSON.stringify({
            model: "gpt-5.6-sol",
            effort: "minimal",
            fast_mode: true,
          }) + "\n",
          { mode: 0o600 },
        );
        const gatewayEnv = {
          ...NO_AUTH,
          OPENAI_API_KEY: "fake-capability-key",
          HOME: home,
          FX_RESPONSES_BASE_URL: gateway.baseUrl,
        };

        const staleResult = await runFx(
          ["ask", "--auto", "--json", "--no-save", "Use stale minimal fast."],
          {
            cwd: workspaceRoot,
            env: gatewayEnv,
            timeoutMs: TIMEOUT,
          },
        );
        expect(staleResult.code).toBe(0);
        expect(gateway.requests).toHaveLength(1);
        expect(JSON.parse(gateway.requests[0]!.body)).not.toHaveProperty(
          "reasoning",
        );
        expect(JSON.parse(gateway.requests[0]!.body)).not.toHaveProperty("fast");
        expect(JSON.parse(gateway.requests[0]!.body)).toMatchObject({
          service_tier: "priority",
        });
        expect(JSON.parse(readFileSync(settingsPath, "utf8"))).toMatchObject({
          model: "gpt-5.6-sol",
          effort: "minimal",
          fast_mode: true,
        });

        session = await TmuxSession.create({
          cwd: workspaceRoot,
          env: gatewayEnv,
          stderrPath,
        });
        await session.waitForText("Run /help", TIMEOUT);
        await session.sendLiteral("/model sol");
        await session.waitForText("gpt-5.6-sol", TIMEOUT);
        await session.sendKeys("Enter");
        const efforts = await session.waitForText("default", TIMEOUT);
        expect(efforts).not.toContain("minimal");
        for (let i = 0; i < 6; i += 1) await session.sendKeys("Down");
        await session.waitForText("max", TIMEOUT);
        await session.sendKeys("Enter");
        await session.waitForText("normal", TIMEOUT);
        await session.sendLiteral("fast");
        await session.waitForText("/model gpt-5.6-sol max fast", TIMEOUT);
        await session.sendKeys("Enter");
        const selected = await session.waitForText("gpt-5.6-sol · max · ⚡︎", TIMEOUT);
        expect(selected).not.toContain("⚡︎ fast");
        await session.waitForComposer(TIMEOUT);

        const stored = JSON.parse(
          readFileSync(settingsPath, "utf8"),
        );
        expect(stored).toMatchObject({
          models: { gateway: "gpt-5.6-sol" },
          effort: "max",
          fast_mode: true,
        });

        await session.sendText("Use max fast.");
        await session.waitForText("GPT 5.6 max fast complete", TIMEOUT);
        expect(gateway.requests).toHaveLength(2);
        expect(gateway.requests[1]!.headers.get("authorization")).toBe(
          "Bearer fake-capability-key",
        );
        expect(JSON.parse(gateway.requests[1]!.body)).toMatchObject({
          model: "gpt-5.6-sol",
          reasoning: { effort: "max" },
          service_tier: "priority",
        });
        expect(JSON.parse(gateway.requests[1]!.body)).not.toHaveProperty("fast");

        await session.sendText("/quit");
        await session.waitForSessionEnd(TIMEOUT);
        session = null;
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
        rmSync(root, { recursive: true, force: true });
      }
    },
    60_000,
  );


  test(
    "model picker selection persists when a matching skill exists",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-model-picker-skill-"));
      const gateway = startFakeGateway([], {
        models: [{
          id: "xai/grok-build-1",
          object: "model",
          created: 1,
        }],
      });
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        const stderrPath = join(root, "stderr.log");
        const skillRoot = join(home, ".fx", "skills", "model-helper");
        mkdirSync(skillRoot, { recursive: true, mode: 0o700 });
        mkdirSync(workspace);
        writeFileSync(
          join(skillRoot, "SKILL.md"),
          "---\nname: model-helper\ndescription: model helper skill\n---\n\nModel helper body\n",
        );
        const workspaceRoot = realpathSync(workspace);

        session = await TmuxSession.create({
          cwd: workspaceRoot,
          env: {
            ...NO_AUTH,
            OPENAI_API_KEY: "fake-skill-catalog-key",
            HOME: home,
            FX_RESPONSES_BASE_URL: gateway.baseUrl,
          },
          stderrPath,
        });
        await session.waitForComposer(TIMEOUT);
        await session.sendLiteral("/model");
        await session.sendKeys("Enter");
        const pickerPane = await session.waitForText("xai/grok-build-1", TIMEOUT);
        expect(pickerPane).toContain("xai/grok-build-1");
        await session.sendKeys("Enter");
        await session.waitForText("● Switched to xai/grok-build-1", TIMEOUT);
        await session.waitForPane(
          (pane) =>
            hasEmptyComposer(pane) &&
            !pane.includes("model-helper"),
          TIMEOUT,
        );
        expect(await session.capturePane()).not.toContain("saved to user settings");

        const stored = JSON.parse(readFileSync(join(home, ".fx", "settings.json"), "utf8"));
        expect(stored.models.gateway).toBe("xai/grok-build-1");
        expect(stored).not.toHaveProperty("effort");
        expect(stored.fast_mode).toBe(false);

        const scrollback = await session.captureFullScrollbackEscapes();
        expect(scrollback).toContain("grok-build-1");
        expect(scrollback).toContain("● Switched to xai/grok-build-1");
        expect(gateway.requests).toHaveLength(0);

        await session.sendText("/quit");
        await session.waitForSessionEnd(TIMEOUT);
        session = null;

        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
        rmSync(root, { recursive: true, force: true });
      }
    },
    60_000,
  );

});
