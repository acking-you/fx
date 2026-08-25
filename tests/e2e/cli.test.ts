import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { createServer } from "node:net";
import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  realpathSync,
  renameSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { platform, tmpdir } from "node:os";
import { join, sep } from "node:path";
import {
  cleanupIsolatedTestHome,
  createIsolatedTestHome,
  FX_BIN,
  REPO_ROOT,
  runFx,
} from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  startFakeGateway,
} from "./tmux-helpers";

const TIMEOUT = 15_000;
const NO_GATEWAY_AUTH = {
  OPENAI_API_KEY: undefined,
  CODEX_HOME: undefined,
  FX_CODEX_AUTH_FILE: undefined,
};
const MISSING_AUTH_MESSAGE =
  "Fx needs a model credential. Set OPENAI_API_KEY for a Responses API, use fx login codex for ChatGPT Codex, or use fx login grok for Grok.";

function maxLineWidth(text: string): number {
  return Math.max(...text.split(/\r?\n/).map((line) => Bun.stringWidth(line)));
}

function sourceVersion(): string {
  const source = readFileSync(join(REPO_ROOT, "src/main.zig"), "utf8");
  const match = source.match(/pub const version = "([^"]+)";/);
  if (!match) throw new Error("src/main.zig version declaration not found");
  return match[1];
}

function doctorSessionDiagnosticsLimit(): number {
  const source = readFileSync(
    join(REPO_ROOT, "src/core/cli/doctor_runtime.zig"),
    "utf8",
  );
  const match = source.match(/const default_session_diagnostics_limit: usize = (\d+);/);
  if (!match) throw new Error("doctor session diagnostics limit not found");
  return Number(match[1]);
}

const SEEDED_GATEWAY_TOKEN = "seeded-access-token";

function snapshotTree(root: string): string[] {
  const entries: string[] = [];
  const visit = (path: string, relative: string): void => {
    const info = lstatSync(path);
    entries.push(
      `${relative}|${info.isDirectory() ? "dir" : "file"}|${info.mode & 0o777}|${info.size}`,
    );
    if (!info.isDirectory()) return;
    for (const name of readdirSync(path).sort()) {
      visit(join(path, name), relative ? join(relative, name) : name);
    }
  };
  visit(root, "");
  return entries;
}

function writeLegacySession(
  home: string,
  workspaceRoot: string,
  sessionId: string,
  opts: {
    createdAtMs?: number;
    updatedAtMs?: number;
    historyLen?: number;
  } = {},
): void {
  const sessionDir = join(home, ".fx", "sessions", sessionId);
  mkdirSync(sessionDir, { recursive: true, mode: 0o700 });
  chmodSync(join(home, ".fx"), 0o700);
  chmodSync(join(home, ".fx", "sessions"), 0o700);
  chmodSync(sessionDir, 0o700);
  const historyLen = opts.historyLen ?? 0;
  writeFileSync(
    join(sessionDir, "session.json"),
    JSON.stringify({
      schema_version: 2,
      id: sessionId,
      created_at_ms: opts.createdAtMs ?? 1,
      updated_at_ms: opts.updatedAtMs ?? 2,
      workspace_root: workspaceRoot,
      conversation_language: "en",
      history_len: historyLen,
      history: historyLen > 0 ? [{ role: "user", content: "saved" }] : [],
      total_input_tokens: 0,
      total_output_tokens: 0,
    }) + "\n",
    { mode: 0o600 },
  );
}

describe("cli: help", () => {
  test(
    "fx help exits 0 and renders the complete navigation page",
    async () => {
      const r = await runFx(["help"]);
      expect(r.code).toBe(0);
      expect(r.stderr).toBe("");
      expect(r.stdout).not.toContain("\x1b[");
      expect(r.stdout).not.toContain("\x1b]2;");
      expect(r.stdout).toStartWith(
        `𝒇x v${sourceVersion()}\nFast, native coding agent for the terminal.\n`,
      );
      expect(r.stdout).toContain("Commands:\n");
      expect(r.stdout).toContain("Run one noninteractive request");
      expect(r.stdout).toContain("Flags:\n");
      expect(r.stdout).toContain("--context-limit <spec>");
      expect(r.stdout).toContain("Set name=bytes|off; repeatable");
      expect(r.stdout).toContain("--add-dir <path>");
      expect(r.stdout).toContain("-c, --continue");
      expect(r.stdout).toContain("-r");
      expect(r.stdout).toContain("Open the saved-session picker");
      expect(r.stdout).not.toContain("-c, -r, --continue");
      expect(r.stdout).toContain("--resume [last|<id>]");
      expect(r.stdout).toContain("--resume-last");
      expect(r.stdout).toContain("session resume [last|id]");
      expect(r.stdout).toContain("-v, --version");
      expect(r.stdout).not.toContain("Must appear before the command");
      expect(r.stdout).toContain("Examples:\n");
      expect(r.stdout).toContain("https://github.com/acking-you/fx");
      expect(r.stdout).not.toContain("  Work      ");
      expect(r.stdout).not.toContain("\n\n\nRun `fx <command> --help`");
    },
    TIMEOUT,
  );

  test(
    "fx --help exits 0",
    async () => {
      const r = await runFx(["--help"]);
      expect(r.code).toBe(0);
      expect(r.stdout).toContain("ask");
    },
    TIMEOUT,
  );

  test(
    "fx -h exits 0",
    async () => {
      const r = await runFx(["-h"]);
      expect(r.code).toBe(0);
      expect(r.stdout).toContain("ask");
    },
    TIMEOUT,
  );

  test(
    "fx ask help renders documented options through both aliases",
    async () => {
      const env = {
        ...NO_GATEWAY_AUTH,
        FX_DISABLE_KEYCHAIN: "1",
      };
      const expected = `fx ask

Run one noninteractive request

Usage:
  fx ask [--auto|--yolo] [--image PATH] [--json] [--quiet] [--prompt-permissions] [--no-save] [--no-color] [--resume <last|id>|--resume-id <id>] [--continue-recovery] [--] <prompt>

Options:
  --auto                Automatically review unresolved permission requests
  --yolo                Disable fx permission checks
  --image PATH          Attach an image file; repeat for multiple images
  --json                Emit machine-readable JSON instead of text
  --quiet               Suppress assistant output
  --prompt-permissions  Prompt for Y/N permission approval when stdin is a TTY
  --no-save             Do not save the session; incompatible with --resume and --resume-id
  --no-color            Render TTY output without colors or hyperlinks
  --resume <last|id>    Continue the last session or a session by id
  --resume-id <id>      Continue a session by exact id
  --continue-recovery   Resume the paused model response in the selected session
  --                    Treat every following argument as prompt text

The prompt may be passed as arguments or piped on stdin when no prompt args are given.
TTY stdout uses the Minimal transcript presentation; redirected stdout emits raw assistant Markdown.
Operational progress and diagnostics are written to stderr. JSON output keeps raw Markdown in \`output\`.
With --prompt-permissions, JSON and quiet requests may prompt on stderr only when stdin is a TTY.
`;

      for (const alias of ["--help", "-h"]) {
        const result = await runFx(["ask", alias], { env });
        expect(result.code).toBe(0);
        expect(result.stderr).toBe("");
        expect(result.stdout).toBe(expected);
      }
    },
    TIMEOUT,
  );

  test(
    "fx session help documents inspect resume migrate and recover",
    async () => {
      for (const args of [
        ["session", "--help"],
        ["session", "resume", "--help"],
      ]) {
        const r = await runFx(args);
        expect(r.code).toBe(0);
        expect(r.stderr).toBe("");
        expect(r.stdout).toContain("Inspect, resume, migrate, or recover saved sessions");
        expect(r.stdout).toContain("session <last|id>|--id <id>");
        expect(r.stdout).toContain("session resume [last|<id>]");
        expect(r.stdout).toContain("session migrate <id>|--id <id>");
        expect(r.stdout).toContain("session recover <id>|--id <id>");
      }
    },
    TIMEOUT,
  );

  test(
    "fx acp help documents accepted options",
    async () => {
      for (const alias of ["--help", "-h"]) {
        const r = await runFx(["acp", alias]);
        expect(r.code).toBe(0);
        expect(r.stderr).toBe("");
        expect(r.stdout).toContain(
          "Usage:\n  fx acp [--model <id>] [--log-file <path>]",
        );
        expect(r.stdout).toContain("--model <id>");
        expect(r.stdout).toContain("--log-file <path>");
      }
    },
    TIMEOUT,
  );

  test(
    "fx replay help describes golden output",
    async () => {
      const r = await runFx(["replay", "--help"]);
      expect(r.code).toBe(0);
      expect(r.stderr).toBe("");
      expect(r.stdout).toContain("--golden <path>");
      expect(r.stdout).toContain("Write the final rendered grid to a file");
      expect(r.stdout).not.toContain("Compare output against a golden file");
    },
    TIMEOUT,
  );

  test(
    "fx acp rejects unknown options and missing option values",
    async () => {
      for (const args of [["--bogus"], ["--model"], ["--log-file"]]) {
        const result = await runFx(["acp", ...args]);
        expect(result.code).toBe(1);
        expect(result.stdout).toBe("");
        expect(result.stderr).toBe(
          "usage: fx acp [--model <id>] [--log-file <path>]\n",
        );
      }
    },
    TIMEOUT,
  );

  for (const alias of ["help", "--help", "-h"]) {
    test(
      `fx ${alias} respects COLUMNS=60`,
      async () => {
        const r = await runFx([alias], { env: { COLUMNS: "60" } });
        expect(r.code).toBe(0);
        expect(r.stderr).toBe("");
        expect(r.stdout).toContain("Commands:");
        expect(r.stdout).toContain("ask");
        expect(r.stdout).toContain("status");
        expect(r.stdout).toContain("doctor");
        expect(maxLineWidth(r.stdout)).toBeLessThanOrEqual(60);
      },
      TIMEOUT,
    );
  }

  for (const alias of ["help", "--help", "-h"]) {
    test(
      `fx ${alias} --record rejects the interactive-only modifier`,
      async () => {
        const r = await runFx([alias, "--record"]);
        expect(r.code).not.toBe(0);
        expect(r.stderr).toContain(
          "usage: fx --record is only supported for interactive startup",
        );
      },
      TIMEOUT,
    );
  }
});

describe("cli: version", () => {
  for (const alias of ["--version", "-v"]) {
    test(
      `fx ${alias} prints the source version`,
      async () => {
        const r = await runFx([alias]);
        expect(r.code).toBe(0);
        expect(r.stdout).toBe(`${sourceVersion()}\n`);
        expect(r.stderr).toBe("");
      },
      TIMEOUT,
    );
  }
});

describe("cli: status", () => {
  test(
    "status and doctor expose the MCP profile error that blocks ask startup",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-mcp-config-diagnostic-"));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const fxDir = join(home, ".fx");
      mkdirSync(fxDir, { recursive: true, mode: 0o700 });
      mkdirSync(workspace);
      writeFileSync(join(fxDir, "mcp.json"), "{invalid json", { mode: 0o600 });
      const gateway = startFakeGateway([]);

      try {
        const env = {
          HOME: realpathSync(home),
          OPENAI_API_KEY: "mcp-config-diagnostic-key",
          FX_DISABLE_KEYCHAIN: "1",
          FX_MODEL: FAKE_GATEWAY_MODEL,
          FX_RESPONSES_BASE_URL: gateway.baseUrl,
        };
        const cwd = realpathSync(workspace);
        const before = snapshotTree(home);

        const statusText = await runFx(["status"], { cwd, env });
        const statusJsonResult = await runFx(["status", "--json"], { cwd, env });
        const doctorText = await runFx(["doctor"], { cwd, env });
        const doctorJsonResult = await runFx(["doctor", "--json"], { cwd, env });
        const ask = await runFx(
          ["ask", "--json", "--no-save", "Do nothing."],
          { cwd, env },
        );

        for (const result of [statusText, statusJsonResult, doctorText, doctorJsonResult]) {
          expect(result.code).toBe(0);
          expect(result.stderr).toBe("");
        }
        expect(statusText.stdout).toContain(
          "[status] mcp_config_error=McpConfigInvalidJson\n",
        );
        expect(JSON.parse(statusJsonResult.stdout)).toMatchObject({
          kind: "status",
          mcp_config_error: "McpConfigInvalidJson",
        });
        expect(doctorText.stdout).toContain(
          "[fail] mcp_config: failed to load ~/.fx/mcp.json: McpConfigInvalidJson\n",
        );
        const doctorJson = JSON.parse(doctorJsonResult.stdout);
        expect(doctorJson.fail_count).toBe(1);
        expect(
          doctorJson.checks.filter(
            (check: { name: string }) => check.name === "mcp_config",
          ),
        ).toEqual([
          {
            name: "mcp_config",
            status: "fail",
            detail: "failed to load ~/.fx/mcp.json: McpConfigInvalidJson",
          },
        ]);
        expect(ask.code).toBe(1);
        expect(ask.stderr).toBe("");
        expect(JSON.parse(ask.stdout)).toMatchObject({
          exit_code: 1,
          error: "McpConfigInvalidJson",
        });
        expect(gateway.requestCount()).toBe(0);
        expect(snapshotTree(home)).toEqual(before);

        writeFileSync(join(fxDir, "mcp.json"), '{"mcp":{}}\n', { mode: 0o600 });
        const validBefore = snapshotTree(home);
        const validStatus = await runFx(["status", "--json"], { cwd, env });
        const validDoctor = await runFx(["doctor", "--json"], { cwd, env });
        expect(validStatus.code).toBe(0);
        expect(validDoctor.code).toBe(0);
        expect(JSON.parse(validStatus.stdout)).not.toHaveProperty("mcp_config_error");
        expect(
          JSON.parse(validDoctor.stdout).checks.some(
            (check: { name: string }) => check.name === "mcp_config",
          ),
        ).toBe(false);
        expect(gateway.requestCount()).toBe(0);
        expect(snapshotTree(home)).toEqual(validBefore);
      } finally {
        gateway.stop();
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "status and doctor share the missing auth snapshot",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-status-noauth-"));
      try {
        const env = {
          ...NO_GATEWAY_AUTH,
          HOME: realpathSync(root),
          FX_DISABLE_KEYCHAIN: "1",
        };
        const status = await runFx(["status", "--json"], { env });
        const doctor = await runFx(["doctor", "--json"], { env });

        expect(status.code).toBe(0);
        expect(doctor.code).toBe(0);
        const statusJson = JSON.parse(status.stdout.trim());
        const doctorJson = JSON.parse(doctor.stdout.trim());
        expect(statusJson).toMatchObject({
          auth: "missing",
          auth_refreshable: false,
          auth_help: MISSING_AUTH_MESSAGE,
        });
        expect(statusJson).not.toHaveProperty("sandbox");
        expect(doctorJson).toMatchObject({
          auth: "missing",
          auth_refreshable: false,
        });
        expect(doctorJson.checks).toContainEqual({
          name: "auth",
          status: "fail",
          detail: MISSING_AUTH_MESSAGE,
        });
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "a new status process keeps normal credential precedence",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-status-precedence-"));
      try {
        const envToken = "preferred-environment-token";
        const env = {
          HOME: realpathSync(root),
          OPENAI_API_KEY: envToken,
          FX_DISABLE_KEYCHAIN: "1",
        };

        const status = await runFx(["status", "--json"], { env });
        const doctor = await runFx(["doctor", "--json"], { env });

        const expectedAuth = {
          auth: "OPENAI_API_KEY",
          auth_refreshable: false,
        };
        expect(JSON.parse(status.stdout.trim())).toMatchObject(expectedAuth);
        expect(JSON.parse(doctor.stdout.trim())).toMatchObject(expectedAuth);
        expect(status.stdout).not.toContain(envToken);
        expect(doctor.stdout).not.toContain(envToken);
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "fx status --json returns valid status JSON",
    async () => {
      const r = await runFx(["status", "--json"]);
      expect(r.code).toBe(0);
      const json = JSON.parse(r.stdout.trim());
      expect(json.kind).toBe("status");
      expect(json).toHaveProperty("model");
      expect(json).toHaveProperty("workspace");
      expect(json).toHaveProperty("permission_mode");
      expect(json).toHaveProperty("history_turns");
      expect(json).toHaveProperty("agent_step_limit");
    },
    TIMEOUT,
  );

  test(
    "fx status --json defaults permission mode to auto",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-permission-default-"));
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        mkdirSync(home);
        mkdirSync(workspace);

        const r = await runFx(["status", "--json"], {
          cwd: realpathSync(workspace),
          env: {
            ...NO_GATEWAY_AUTH,
            HOME: realpathSync(home),
            FX_PERMISSION_MODE: undefined,
          },
        });
        expect(r.code).toBe(0);
        const json = JSON.parse(r.stdout.trim());
        expect(json.permission_mode).toBe("auto");
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "status and doctor apply an exact FX_MAX_AGENT_STEPS override",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-agent-step-limit-"));
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        mkdirSync(home);
        mkdirSync(workspace);
        const env = {
          ...NO_GATEWAY_AUTH,
          HOME: realpathSync(home),
          FX_MAX_AGENT_STEPS: "3",
        };

        const status = await runFx(["status", "--json"], {
          cwd: realpathSync(workspace),
          env,
          timeoutMs: TIMEOUT,
        });
        expect(status.code).toBe(0);
        expect(JSON.parse(status.stdout.trim()).agent_step_limit).toBe(3);

        const doctor = await runFx(["doctor", "--json"], {
          cwd: realpathSync(workspace),
          env,
          timeoutMs: TIMEOUT,
        });
        expect(doctor.code).toBe(0);
        const startup = JSON.parse(doctor.stdout.trim()).checks.find(
          (check: { name: string }) => check.name === "startup",
        );
        expect(startup.detail).toContain("agent_step_limit=3");
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "project profile-only settings are ignored before parsing and profile overrides win",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-profile-config-"));
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        mkdirSync(join(home, ".fx"), { recursive: true });
        mkdirSync(workspace);
        const homeRoot = realpathSync(home);
        const workspaceRoot = realpathSync(workspace);
        const env = {
          ...NO_GATEWAY_AUTH,
          HOME: homeRoot,
          FX_MODEL: undefined,
          FX_PERMISSION_MODE: undefined,
          FX_MAX_AGENT_STEPS: undefined,
        };

        writeFileSync(
          join(home, ".fx", "settings.json"),
          JSON.stringify({
            model: "anthropic/claude-sonnet-4.6",
            permission_mode: "auto",
          }) + "\n",
        );
        writeFileSync(
          join(workspace, ".fx.json"),
          JSON.stringify({
            model: 123,
            permission_mode: "danger",
            permission: { bash: true },
            statusLine: 7,
            max_agent_steps: 7,
          }) + "\n",
        );

        const status = await runFx(["status", "--json"], {
          cwd: workspaceRoot,
          env,
          timeoutMs: TIMEOUT,
        });
        expect(status.code).toBe(0);
        const first = JSON.parse(status.stdout.trim());
        expect(first.model).toBe("anthropic/claude-sonnet-4.6");
        expect(first.permission_mode).toBe("auto");
        expect(first.agent_step_limit).toBe(7);
        expect(status.stderr).toContain(
          "fx: config project: ignored_project_user_only_setting; key=model",
        );
        expect(status.stderr).toContain(
          "fx: config project: ignored_project_user_only_setting; key=permission_mode",
        );
        expect(status.stderr).toContain(
          "fx: config project: ignored_project_user_only_setting; key=permission",
        );
        expect(status.stderr).toContain(
          "fx: config project: ignored_project_user_only_setting; key=statusLine",
        );
        expect(status.stderr).not.toContain("danger");

        writeFileSync(
          join(home, ".fx", "settings.json"),
          JSON.stringify({
            model: "anthropic/claude-sonnet-4.6",
            permission_mode: "auto",
            workspaces: {
              [workspaceRoot]: {
                max_agent_steps: 4,
              },
            },
          }) + "\n",
        );

        const overridden = await runFx(["status", "--json"], {
          cwd: workspaceRoot,
          env,
          timeoutMs: TIMEOUT,
        });
        expect(overridden.code).toBe(0);
        const second = JSON.parse(overridden.stdout.trim());
        expect(second.model).toBe("anthropic/claude-sonnet-4.6");
        expect(second.permission_mode).toBe("auto");
        expect(second.agent_step_limit).toBe(4);
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "special settings files fail closed without blocking CLI startup",
    async () => {
      if (platform() === "win32") return;
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-config-special-"));
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        const fxDir = join(home, ".fx");
        mkdirSync(fxDir, { recursive: true, mode: 0o700 });
        mkdirSync(workspace);
        chmodSync(fxDir, 0o700);

        const env = {
          ...NO_GATEWAY_AUTH,
          HOME: home,
          FX_DISABLE_KEYCHAIN: "1",
          FX_SKIP_ONBOARDING: "1",
          FX_SOUND: "0",
        };

        expect(spawnSync("mkfifo", [join(fxDir, "settings.json")]).status).toBe(0);
        const userStartedAt = Date.now();
        const user = await runFx(["status", "--json"], {
          cwd: workspace,
          env,
          timeoutMs: 3_000,
        });
        expect(Date.now() - userStartedAt).toBeLessThan(3_000);
        expect(user.code).toBe(0);
        expect(JSON.parse(user.stdout)).toMatchObject({ kind: "status" });
        expect(user.stderr).toContain("fx: config user: durable_path_unsafe");

        rmSync(join(fxDir, "settings.json"));
        expect(spawnSync("mkfifo", [join(workspace, ".fx.json")]).status).toBe(0);
        const projectStartedAt = Date.now();
        const project = await runFx(["status", "--json"], {
          cwd: workspace,
          env,
          timeoutMs: 3_000,
        });
        expect(Date.now() - projectStartedAt).toBeLessThan(3_000);
        expect(project.code).toBe(0);
        expect(JSON.parse(project.stdout)).toMatchObject({ kind: "status" });
        expect(project.stderr).toContain("fx: config project: durable_path_unsafe");
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );
});

describe("cli: usage", () => {
  test(
    "fx usage reads rolling local facts without credentials or profile mutation",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-usage-"));
      try {
        const home = join(root, "home");
        const fxDir = join(home, ".fx");
        mkdirSync(fxDir, { recursive: true, mode: 0o700 });
        chmodSync(fxDir, 0o700);
        const now = Date.now();
        const records = [
          {
            schema_version: 1,
            kind: "coverage",
            started_at_ms: now - 40 * 24 * 60 * 60 * 1000,
          },
          {
            schema_version: 1,
            kind: "generation",
            fact: {
              id: "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
              created_at_ms: now - 60 * 60 * 1000,
              model: "provider/a",
              input_tokens: 15,
              output_tokens: 3,
              cache_read_tokens: 5,
              cache_write_tokens: 1,
              reasoning_tokens: 2,
              total_cost: 0.25,
            },
          },
          {
            schema_version: 1,
            kind: "generation",
            fact: {
              id: "gen_01ARZ3NDEKTSV4RRFFQ69G5FAW",
              created_at_ms: now - 2 * 24 * 60 * 60 * 1000,
              model: "provider/b",
              input_tokens: 10,
              output_tokens: 2,
              cache_read_tokens: 0,
              cache_write_tokens: 0,
              reasoning_tokens: null,
              total_cost: 0.1,
            },
          },
        ];
        const usagePath = join(fxDir, "usage.jsonl");
        writeFileSync(
          usagePath,
          records.map((record) => JSON.stringify(record)).join("\n") + "\n",
          { mode: 0o600 },
        );
        chmodSync(usagePath, 0o600);
        const before = readFileSync(usagePath, "utf8");
        const entriesBefore = readdirSync(fxDir).sort();
        const env = {
          ...NO_GATEWAY_AUTH,
          HOME: realpathSync(home),
          FX_DISABLE_KEYCHAIN: "1",
        };

        const text = await runFx(["usage"], { env });
        expect(text.code).toBe(0);
        expect(text.stderr).toBe("");
        expect(text.stdout).toContain("Usage (30 days)");
        expect(text.stdout).toContain("Total tokens  30");
        expect(text.stdout.indexOf("provider/a")).toBeLessThan(
          text.stdout.indexOf("provider/b"),
        );

        const json = await runFx(
          ["usage", "--json", "--period", "24h"],
          { env },
        );
        expect(json.code).toBe(0);
        expect(json.stderr).toBe("");
        const report = JSON.parse(json.stdout);
        expect(report).toMatchObject({
          kind: "usage",
          schema_version: 1,
          period: "24h",
          completeness: "complete",
          totals: {
            total_tokens: 18,
            input_tokens: 15,
            output_tokens: 3,
            request_count: 1,
          },
        });
        expect(report.models.map((model: { model: string }) => model.model))
          .toEqual(["provider/a"]);
        expect(readFileSync(usagePath, "utf8")).toBe(before);
        expect(readdirSync(fxDir).sort()).toEqual(entriesBefore);
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "fx usage preserves known totals when the ledger is incomplete",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-usage-incomplete-"));
      try {
        const home = join(root, "home");
        const fxDir = join(home, ".fx");
        mkdirSync(fxDir, { recursive: true, mode: 0o700 });
        const now = Date.now();
        const records = [
          {
            schema_version: 1,
            kind: "coverage",
            started_at_ms: now - 40 * 24 * 60 * 60 * 1000,
          },
          {
            schema_version: 1,
            kind: "generation",
            fact: {
              id: "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
              created_at_ms: now - 2,
              model: "provider/model",
              input_tokens: 4,
              output_tokens: 2,
              cache_read_tokens: 0,
              cache_write_tokens: 0,
              reasoning_tokens: 1,
              total_cost: 0.01,
            },
          },
          {
            schema_version: 1,
            kind: "incident",
            occurred_at_ms: now - 1,
            completeness: "incomplete",
          },
        ];
        writeFileSync(
          join(fxDir, "usage.jsonl"),
          records.map((record) => JSON.stringify(record)).join("\n") + "\n",
          { mode: 0o600 },
        );
        writeFileSync(join(fxDir, "usage.lock"), "", { mode: 0o600 });
        const env = {
          ...NO_GATEWAY_AUTH,
          HOME: realpathSync(home),
          FX_DISABLE_KEYCHAIN: "1",
        };

        const text = await runFx(["usage"], { env });
        expect(text.code).toBe(0);
        expect(text.stdout).toContain("Known totals may be incomplete.");
        expect(text.stdout).toContain("Total tokens  6");

        const json = await runFx(["usage", "--json"], { env });
        expect(json.code).toBe(0);
        expect(JSON.parse(json.stdout)).toMatchObject({
          completeness: "incomplete",
          totals: { total_tokens: 6, spend: 0.01 },
        });
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "fx usage distinguishes empty, invalid, corrupt, and unsafe local state",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-usage-states-"));
      try {
        const home = realpathSync(root);
        const env = { ...NO_GATEWAY_AUTH, HOME: home, FX_DISABLE_KEYCHAIN: "1" };
        const empty = await runFx(["usage", "--json"], { env });
        expect(empty.code).toBe(0);
        expect(JSON.parse(empty.stdout)).toMatchObject({
          coverage: { status: "not_started" },
          totals: null,
        });
        expect(existsSync(join(home, ".fx"))).toBe(false);

        const invalid = await runFx(
          ["usage", "--period", "session", "--json"],
          { env },
        );
        expect(invalid.code).toBe(1);
        expect(JSON.parse(invalid.stdout)).toMatchObject({
          kind: "usage",
          code: "InvalidUsageArgs",
        });

        const fxDir = join(home, ".fx");
        mkdirSync(fxDir, { mode: 0o700 });
        chmodSync(fxDir, 0o700);
        writeFileSync(
          join(fxDir, "usage.jsonl"),
          `${JSON.stringify({
            schema_version: 1,
            kind: "coverage",
            started_at_ms: Date.now() - 1,
          })}\n`,
          { mode: 0o600 },
        );
        if (platform() !== "win32") {
          chmodSync(fxDir, 0o755);
          const entries = readdirSync(fxDir);
          const unsafeDirectory = await runFx(["usage", "--json"], { env });
          expect(unsafeDirectory.code).toBe(1);
          expect(JSON.parse(unsafeDirectory.stdout)).toMatchObject({
            kind: "usage",
            code: "PrivateStatePermissionsUnsupported",
          });
          expect(lstatSync(fxDir).mode & 0o777).toBe(0o755);
          expect(readdirSync(fxDir)).toEqual(entries);
          chmodSync(fxDir, 0o700);
        }
        writeFileSync(join(fxDir, "usage.jsonl"), "{\"broken\":true}\n", {
          mode: 0o600,
        });
        writeFileSync(join(fxDir, "usage.lock"), "", { mode: 0o600 });
        const corrupt = await runFx(["usage", "--json"], { env });
        expect(corrupt.code).toBe(1);
        expect(JSON.parse(corrupt.stdout)).toMatchObject({
          kind: "usage",
          code: "InvalidUsageStore",
        });

        if (platform() !== "win32") {
          rmSync(join(fxDir, "usage.jsonl"));
          const fifo = spawnSync("mkfifo", [join(fxDir, "usage.jsonl")]);
          expect(fifo.status).toBe(0);
          const special = await runFx(["usage", "--json"], { env });
          expect(special.code).toBe(1);
          expect(JSON.parse(special.stdout)).toMatchObject({
            kind: "usage",
            code: "DurablePathUnsafe",
          });

          rmSync(join(fxDir, "usage.jsonl"));
          const socketPath = join(fxDir, "usage.jsonl");
          const server = createServer();
          await new Promise<void>((resolve, reject) => {
            server.once("error", reject);
            server.listen(socketPath, () => {
              server.off("error", reject);
              resolve();
            });
          });
          try {
            const socket = await runFx(["usage", "--json"], { env });
            expect(socket.code).toBe(1);
            expect(JSON.parse(socket.stdout)).toMatchObject({
              kind: "usage",
              code: "DurablePathUnsafe",
            });
          } finally {
            await new Promise<void>((resolve) => server.close(() => resolve()));
          }
        }
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "fx usage preserves known totals but fails closed when recovery storage is unsafe",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-usage-recovery-"));
      try {
        const home = join(root, "home");
        const fxDir = join(home, ".fx");
        mkdirSync(fxDir, { recursive: true, mode: 0o700 });
        chmodSync(fxDir, 0o700);
        writeFileSync(
          join(fxDir, "usage.jsonl"),
          [
            {
              schema_version: 1,
              kind: "coverage",
              started_at_ms: Date.now() - 40 * 24 * 60 * 60 * 1000,
            },
            {
              schema_version: 1,
              kind: "generation",
              fact: {
                id: "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
                created_at_ms: Date.now() - 1,
                model: "provider/model",
                input_tokens: 4,
                output_tokens: 2,
                cache_read_tokens: 0,
                cache_write_tokens: 0,
                reasoning_tokens: 1,
                total_cost: 0.01,
              },
            },
          ].map((record) => JSON.stringify(record)).join("\n") + "\n",
          { mode: 0o600 },
        );
        writeFileSync(join(fxDir, "usage.lock"), "", { mode: 0o600 });
        const outside = join(root, "outside");
        writeFileSync(outside, "not a session directory");
        symlinkSync(outside, join(fxDir, "sessions"));

        const result = await runFx(["usage", "--json"], {
          env: {
            ...NO_GATEWAY_AUTH,
            HOME: realpathSync(home),
            FX_DISABLE_KEYCHAIN: "1",
          },
        });
        expect(result.code).toBe(0);
        expect(result.stderr).toBe("");
        expect(JSON.parse(result.stdout)).toMatchObject({
          kind: "usage",
          coverage: { status: "full" },
          completeness: "incomplete",
          totals: { total_tokens: 6, spend: 0.01 },
        });
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );
});

describe("cli: permissions", () => {
  test(
    "fx permissions --json returns valid permissions JSON",
    async () => {
      const r = await runFx(["permissions", "--json"]);
      expect(r.code).toBe(0);
      const json = JSON.parse(r.stdout.trim());
      expect(json.kind).toBe("permissions");
      expect(json).toHaveProperty("mode");
      expect(json).toHaveProperty("grant_count");
      expect(json.grant_scope).toBe("session");
      expect(json.runtime_grants_available).toBe(false);
      expect(json.rules_scope).toBe("persistent_config");
      expect(Array.isArray(json.rules)).toBe(true);
      expect(Array.isArray(json.grants)).toBe(true);
    },
    TIMEOUT,
  );
});

describe("cli: doctor", () => {
  test(
    "fx doctor --json returns valid doctor JSON",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-doctor-json-"));
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        mkdirSync(home);
        mkdirSync(workspace);

        const r = await runFx(["doctor", "--json"], {
          cwd: realpathSync(workspace),
          env: {
            ...NO_GATEWAY_AUTH,
            HOME: realpathSync(home),
          },
          timeoutMs: TIMEOUT,
        });
        expect(r.code).toBe(0);
        const json = JSON.parse(r.stdout.trim());
        expect(json.kind).toBe("doctor");
        expect(Array.isArray(json.checks)).toBe(true);
        expect(json).toHaveProperty("ok_count");
        expect(json).toHaveProperty("warn_count");
        expect(json).toHaveProperty("fail_count");
        expect(json.checks).toContainEqual({
          name: "auth",
          status: "fail",
          detail: MISSING_AUTH_MESSAGE,
        });
        for (const check of json.checks) {
          expect(check).toHaveProperty("name");
          expect(check).toHaveProperty("status");
          expect(check).toHaveProperty("detail");
          expect(["ok", "warn", "fail"]).toContain(check.status);
        }
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "fx doctor --json leaves an empty home unchanged",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-doctor-no-create-"));
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        mkdirSync(home);
        mkdirSync(workspace);

        const r = await runFx(["doctor", "--json"], {
          cwd: realpathSync(workspace),
          env: {
            ...NO_GATEWAY_AUTH,
            HOME: realpathSync(home),
          },
          timeoutMs: TIMEOUT,
        });

        expect(r.code).toBe(0);
        expect(JSON.parse(r.stdout.trim()).kind).toBe("doctor");
        expect(existsSync(join(home, ".fx"))).toBe(false);
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "fx doctor --json bounds session diagnostics without summary cache",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-doctor-bounded-"));
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        mkdirSync(home);
        mkdirSync(workspace);
        const workspaceRoot = realpathSync(workspace);
        const limit = doctorSessionDiagnosticsLimit();
        const sessionCount = limit + 32;
        for (let i = 0; i < sessionCount; i += 1) {
          writeLegacySession(
            home,
            workspaceRoot,
            `doctor-bounded-${String(i).padStart(3, "0")}`,
            { updatedAtMs: i + 1 },
          );
        }

        expect(existsSync(join(home, ".fx", "sessions", "summary.json"))).toBe(false);

        const r = await runFx(["doctor", "--json"], {
          cwd: workspaceRoot,
          env: {
            ...NO_GATEWAY_AUTH,
            HOME: home,
          },
          timeoutMs: TIMEOUT,
        });

        expect(r.code).toBe(0);
        expect(r.stderr).toBe("");
        expect(r.stdout.length).toBeLessThan(64 * 1024);
        const json = JSON.parse(r.stdout.trim());
        expect(json.kind).toBe("doctor");
        expect(json.checks.length).toBeLessThan(sessionCount);
        expect(json.checks).toEqual(
          expect.arrayContaining([
            expect.objectContaining({
              name: "session",
              status: "warn",
              detail: expect.stringContaining(
                `truncated after ${limit} session director`,
              ),
            }),
            expect.objectContaining({
              name: "sessions",
              status: "warn",
              detail: expect.stringContaining(
                "unavailable without a full session scan",
              ),
            }),
          ]),
        );
        expect(
          json.checks.some((check: { detail: string }) =>
            check.detail.includes(`${sessionCount} saved session(s)`),
          ),
        ).toBe(false);
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );
});

describe("cli: read-only no-create matrix", () => {
  const probes = [
    { args: ["status", "--json"], code: 0, kind: "status" },
    { args: ["sessions", "--json"], code: 0, kind: "sessions", count: 0 },
    { args: ["session", "last", "--json"], code: 1, error: "no saved sessions" },
    { args: ["session", "--id", "missing.valid-id", "--json"], code: 1, error: "record not found" },
    { args: ["background", "--json"], code: 0, kind: "background", count: 0 },
    { args: ["background", "999999", "--json"], code: 1, error: "no persisted records" },
    { args: ["doctor", "--json"], code: 0, kind: "doctor" },
  ] as const;

  for (const probe of probes) {
    test(
      `${probe.args.join(" ")} leaves an empty home unchanged`,
      async () => {
        const root = mkdtempSync(join(tmpdir(), "fx-e2e-no-create-"));
        try {
          const home = join(root, "home");
          const workspace = join(root, "workspace");
          mkdirSync(home);
          mkdirSync(workspace);
          const before = snapshotTree(home);

          const result = await runFx([...probe.args], {
            cwd: realpathSync(workspace),
            env: {
              ...NO_GATEWAY_AUTH,
              HOME: realpathSync(home),
              FX_E2E_FAIL_ON_DURABLE_MUTATION: "1",
            },
            timeoutMs: TIMEOUT,
          });

          expect(result.code).toBe(probe.code);
          if ("kind" in probe) {
            const output = JSON.parse(result.stdout);
            expect(output.kind).toBe(probe.kind);
            if ("count" in probe) expect(output.count).toBe(probe.count);
          } else {
            const output = JSON.parse(result.stdout);
            expect(output.error).toContain(probe.error);
            expect(result.stderr).toBe("");
          }
          expect(snapshotTree(home)).toEqual(before);
          expect(existsSync(join(home, ".fx"))).toBe(false);
        } finally {
          rmSync(root, { recursive: true, force: true });
        }
      },
      TIMEOUT,
    );
  }
});

describe("cli: missing durable home", () => {
  test(
    "read-only commands tolerate a nonexistent HOME and saved ask bootstraps it",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-missing-home-path-"));
      const home = join(root, "missing-home");
      const workspace = join(root, "workspace");
      const gateway = startFakeGateway([
        fakeGatewayFinalText("missing home persisted"),
      ]);
      try {
        mkdirSync(workspace);
        const cwd = realpathSync(workspace);
        const baseEnv = {
          HOME: home,
          FX_DISABLE_KEYCHAIN: "1",
        };

        const status = await runFx(["status", "--json"], {
          cwd,
          env: { ...baseEnv, OPENAI_API_KEY: undefined },
          timeoutMs: TIMEOUT,
        });
        expect(status.code).toBe(0);
        expect(status.stderr).toBe("");
        expect(JSON.parse(status.stdout).kind).toBe("status");
        expect(existsSync(home)).toBe(false);

        const listed = await runFx(["sessions", "--json"], {
          cwd,
          env: { ...baseEnv, OPENAI_API_KEY: undefined },
          timeoutMs: TIMEOUT,
        });
        expect(listed.code).toBe(0);
        expect(JSON.parse(listed.stdout)).toEqual({
          kind: "sessions",
          count: 0,
          sessions: [],
        });
        expect(existsSync(home)).toBe(false);

        const asked = await runFx(
          ["ask", "--json", "--auto", "Persist under the new home."],
          {
            cwd,
            env: {
              ...baseEnv,
              OPENAI_API_KEY: "missing-home-key",
                            FX_RESPONSES_BASE_URL: gateway.baseUrl,
              FX_MODEL: FAKE_GATEWAY_MODEL,
            },
            timeoutMs: TIMEOUT,
          },
        );
        expect(asked.code).toBe(0);
        expect(JSON.parse(asked.stdout).output.trim()).toBe(
          "missing home persisted",
        );
        expect(existsSync(join(home, ".fx", "sessions"))).toBe(true);
        expect(gateway.requests).toHaveLength(1);
      } finally {
        gateway.stop();
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "session commands fail precisely while doctor remains available without HOME",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-no-home-"));
      try {
        const workspace = join(root, "workspace");
        mkdirSync(workspace);
        const cwd = realpathSync(workspace);
        const env = {
          ...NO_GATEWAY_AUTH,
          HOME: undefined,
        };

        for (const args of [
          ["sessions", "--json"],
          ["session", "last", "--json"],
          ["session", "--id", "missing.valid-id", "--json"],
          ["session", "migrate", "--id", "missing.valid-id", "--json"],
        ]) {
          const result = await runFx(args, { cwd, env, timeoutMs: TIMEOUT });
          expect(result.code).toBe(1);
          expect(result.stderr).toBe("");
          expect(JSON.parse(result.stdout)).toEqual(
            expect.objectContaining({
              code: "HomeNotSet",
            }),
          );
        }

        const doctor = await runFx(["doctor", "--json"], {
          cwd,
          env,
          timeoutMs: TIMEOUT,
        });
        expect(doctor.code).toBe(0);
        expect(JSON.parse(doctor.stdout).checks).toEqual(
          expect.arrayContaining([
            expect.objectContaining({
              name: "state",
              detail: expect.stringContaining("HomeNotSet"),
            }),
          ]),
        );
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );
});

describe("cli: sessions", () => {
  test(
    "fx sessions --json returns valid sessions JSON",
    async () => {
      const home = mkdtempSync(join(tmpdir(), "fx-e2e-sessions-empty-"));
      try {
        const r = await runFx(["sessions", "--json"], { env: { HOME: home } });
        expect(r.code).toBe(0);
        const json = JSON.parse(r.stdout.trim());
        expect(json.kind).toBe("sessions");
        expect(json).toHaveProperty("count");
        expect(Array.isArray(json.sessions)).toBe(true);
      } finally {
        rmSync(home, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "fx sessions text shows named, unnamed, and renamed sessions",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-session-names-"));
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        const sessionsDir = join(home, ".fx", "sessions");
        mkdirSync(sessionsDir, { recursive: true, mode: 0o700 });
        mkdirSync(workspace);
        chmodSync(join(home, ".fx"), 0o700);
        chmodSync(sessionsDir, 0o700);
        const workspaceRoot = realpathSync(workspace);
        const named = {
          id: "named-session",
          workspace_root: workspaceRoot,
          origin_workspace_root: workspaceRoot,
          title: "Investigate cache misses",
          preview: null,
          display_metadata_present: true,
          created_at_ms: 1,
          updated_at_ms: 3,
          conversation_language: "en",
          history_len: 2,
        };
        const unnamed = {
          ...named,
          id: "unnamed-session",
          title: null,
          display_metadata_present: false,
          updated_at_ms: 2,
          history_len: 0,
        };
        const scriptOnly = {
          ...named,
          id: "script-only-session",
          title: "Review landing page",
          updated_at_ms: 1_700_000_000_123,
          conversation_language: "und-Latn",
          history_len: 1,
        };
        const indexPath = join(sessionsDir, "index.json");
        writeFileSync(
          indexPath,
          JSON.stringify({
            schema_version: 3,
            sessions: [scriptOnly, named, unnamed],
          }),
          { mode: 0o600 },
        );

        const first = await runFx(["sessions"], {
          cwd: workspaceRoot,
          env: { HOME: home, ...NO_GATEWAY_AUTH },
          timeoutMs: TIMEOUT,
        });
        expect(first.code).toBe(0);
        expect(first.stderr).toBe("");
        expect(first.stdout).toContain(
          " - Investigate cache misses\n   id=named-session | 2 turns | English | updated 1970-01-01 00:00:00.003 UTC",
        );
        expect(first.stdout).toContain(
          " - Untitled session\n   id=unnamed-session | 0 turns | English | updated 1970-01-01 00:00:00.002 UTC",
        );
        expect(first.stdout).toContain(
          " - Review landing page\n   id=script-only-session | 1 turn | Latin script | updated 2023-11-14 22:13:20.123 UTC",
        );
        expect(first.stdout).not.toContain("updated_at_ms");
        expect(first.stdout).not.toContain("language=");

        const structured = await runFx(["sessions", "--json"], {
          cwd: workspaceRoot,
          env: { HOME: home, ...NO_GATEWAY_AUTH },
          timeoutMs: TIMEOUT,
        });
        expect(structured.code).toBe(0);
        expect(structured.stderr).toBe("");
        expect(JSON.parse(structured.stdout).sessions[0]).toMatchObject({
          id: "script-only-session",
          updated_at_ms: 1_700_000_000_123,
          conversation_language: "und-Latn",
        });

        writeFileSync(
          indexPath,
          JSON.stringify({
            schema_version: 3,
            sessions: [
              scriptOnly,
              { ...named, title: "Investigate cache hits" },
              unnamed,
            ],
          }),
          { mode: 0o600 },
        );
        const renamed = await runFx(["sessions"], {
          cwd: workspaceRoot,
          env: { HOME: home, ...NO_GATEWAY_AUTH },
          timeoutMs: TIMEOUT,
        });
        expect(renamed.code).toBe(0);
        expect(renamed.stderr).toBe("");
        expect(renamed.stdout).toContain(
          " - Investigate cache hits\n   id=named-session | 2 turns | English",
        );
        expect(renamed.stdout).not.toContain("Investigate cache misses");
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "session listing pages a 9001-entry index without scanning session directories",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-session-pages-"));
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        const sessionsDir = join(home, ".fx", "sessions");
        mkdirSync(sessionsDir, { recursive: true, mode: 0o700 });
        mkdirSync(workspace);
        chmodSync(join(home, ".fx"), 0o700);
        chmodSync(sessionsDir, 0o700);
        const workspaceRoot = realpathSync(workspace);
        const sessions = Array.from({ length: 9_001 }, (_, index) => {
          const id = `indexed-session-${index.toString().padStart(5, "0")}`;
          return {
            id,
            workspace_root: workspaceRoot,
            origin_workspace_root: workspaceRoot,
            title: id,
            preview: `${id} preview`,
            display_metadata_present: true,
            created_at_ms: 20_000 - index,
            updated_at_ms: 20_000 - index,
            conversation_language: "en",
            history_len: 0,
          };
        });
        writeFileSync(
          join(sessionsDir, "index.json"),
          JSON.stringify({ schema_version: 3, sessions }),
          { mode: 0o600 },
        );

        const first = await runFx(["sessions", "--json"], {
          cwd: workspaceRoot,
          env: { HOME: home, ...NO_GATEWAY_AUTH },
          timeoutMs: TIMEOUT,
        });
        expect(first.code).toBe(0);
        expect(Buffer.byteLength(first.stdout)).toBeLessThan(100_000);
        const firstJson = JSON.parse(first.stdout) as {
          count: number;
          has_more: boolean;
          next_cursor: string;
          sessions: Array<{ id: string; history_len: number }>;
        };
        expect(firstJson.count).toBe(100);
        expect(firstJson.has_more).toBe(true);
        expect(firstJson.sessions).toHaveLength(100);
        expect(firstJson.sessions[0]).toMatchObject({
          id: "indexed-session-00000",
          history_len: 0,
        });
        expect(firstJson.sessions[99].id).toBe("indexed-session-00099");

        const second = await runFx(
          ["sessions", "--json", "--cursor", firstJson.next_cursor],
          {
            cwd: workspaceRoot,
            env: { HOME: home, ...NO_GATEWAY_AUTH },
            timeoutMs: TIMEOUT,
          },
        );
        expect(second.code).toBe(0);
        const secondJson = JSON.parse(second.stdout) as {
          count: number;
          has_more: boolean;
          sessions: Array<{ id: string }>;
        };
        expect(secondJson.count).toBe(100);
        expect(secondJson.has_more).toBe(true);
        expect(secondJson.sessions[0].id).toBe("indexed-session-00100");
        expect(secondJson.sessions[99].id).toBe("indexed-session-00199");

        const one = await runFx(["sessions", "--json", "--limit", "1"], {
          cwd: workspaceRoot,
          env: { HOME: home, ...NO_GATEWAY_AUTH },
          timeoutMs: TIMEOUT,
        });
        expect(one.code).toBe(0);
        expect(JSON.parse(one.stdout)).toMatchObject({
          count: 1,
          has_more: true,
          sessions: [{ id: "indexed-session-00000" }],
        });

        const invalid = await runFx(["sessions", "--limit", "0"], {
          cwd: workspaceRoot,
          env: { HOME: home, ...NO_GATEWAY_AUTH },
          timeoutMs: TIMEOUT,
        });
        expect(invalid.code).not.toBe(0);
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "session lists use projections without opening unreadable event logs",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-session-projections-"));
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        mkdirSync(home);
        mkdirSync(workspace);
        const workspaceRoot = realpathSync(workspace);
        const fixture = spawnSync(
          "python3",
          [
            join(REPO_ROOT, "benchmarks", "session_list_fixture.py"),
            "--home",
            home,
            "--workspace",
            workspaceRoot,
            "--sessions",
            "2",
            "--log-size",
            "4096",
            "--deny-event-read",
          ],
          { encoding: "utf8" },
        );
        expect(fixture.status).toBe(0);

        const before = snapshotTree(join(home, ".fx"));
        const listed = await runFx(["sessions", "--json"], {
          cwd: workspaceRoot,
          env: { HOME: home },
          timeoutMs: TIMEOUT,
        });
        expect(listed.code).toBe(0);
        expect(JSON.parse(listed.stdout)).toEqual({
          kind: "sessions",
          count: 2,
          sessions: [
            {
              id: "benchmark-session-01",
              title: "Benchmark session 01",
              preview: "Benchmark session 01 preview",
              workspace_root: workspaceRoot,
              origin_workspace_root: workspaceRoot,
              created_at_ms: 1001,
              updated_at_ms: 2001,
              history_len: 1,
              conversation_language: "en",
            },
            {
              id: "benchmark-session-00",
              title: "Benchmark session 00",
              preview: "Benchmark session 00 preview",
              workspace_root: workspaceRoot,
              origin_workspace_root: workspaceRoot,
              created_at_ms: 1000,
              updated_at_ms: 2000,
              history_len: 0,
              conversation_language: "en",
            },
          ],
        });
        expect(snapshotTree(join(home, ".fx"))).toEqual(before);

        const latest = await runFx(["session", "last", "--json"], {
          cwd: workspaceRoot,
          env: { HOME: home },
          timeoutMs: TIMEOUT,
        });
        expect(latest.code).toBe(0);
        expect(JSON.parse(latest.stdout)).toEqual({
          kind: "session_summary",
          id: "benchmark-session-01",
          title: "Benchmark session 01",
          preview: "Benchmark session 01 preview",
          workspace_root: workspaceRoot,
          origin_workspace_root: workspaceRoot,
          created_at_ms: 1001,
          updated_at_ms: 2001,
          history_len: 1,
          conversation_language: "en",
        });
        expect(snapshotTree(join(home, ".fx"))).toEqual(before);

        const detail = await runFx(
          ["session", "--id", "benchmark-session-00", "--json"],
          {
            cwd: workspaceRoot,
            env: { HOME: home },
            timeoutMs: TIMEOUT,
          },
        );
        expect(detail.code).not.toBe(0);
        expect(detail.stderr).toContain("AccessDenied");
        expect(snapshotTree(join(home, ".fx"))).toEqual(before);
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "workspace-scoped session discovery filters list and last by cwd",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-workspace-sessions-"));
      try {
        const home = join(root, "home");
        const workspaceA = join(root, "workspace-a");
        const workspaceB = join(root, "workspace-b");
        mkdirSync(home);
        mkdirSync(workspaceA);
        mkdirSync(workspaceB);
        const workspaceARoot = realpathSync(workspaceA);
        const workspaceBRoot = realpathSync(workspaceB);

        writeLegacySession(home, workspaceARoot, "workspace-a-older", {
          updatedAtMs: 20,
        });
        writeLegacySession(home, workspaceARoot, "workspace-a-latest", {
          updatedAtMs: 40,
        });
        writeLegacySession(home, workspaceBRoot, "workspace-b-newest", {
          updatedAtMs: 80,
        });

        const listA = await runFx(["sessions", "--json"], {
          cwd: workspaceARoot,
          env: { HOME: home, ...NO_GATEWAY_AUTH },
          timeoutMs: TIMEOUT,
        });
        expect(listA.code).toBe(0);
        const jsonA = JSON.parse(listA.stdout);
        expect(jsonA.kind).toBe("sessions");
        expect(jsonA.count).toBe(2);
        expect(jsonA.sessions.map((session: { id: string }) => session.id))
          .toEqual(["workspace-a-latest", "workspace-a-older"]);

        const lastA = await runFx(["session", "last", "--json"], {
          cwd: workspaceARoot,
          env: { HOME: home, ...NO_GATEWAY_AUTH },
          timeoutMs: TIMEOUT,
        });
        expect(lastA.code).toBe(0);
        expect(JSON.parse(lastA.stdout).id).toBe("workspace-a-latest");

        const listB = await runFx(["sessions", "--json"], {
          cwd: workspaceBRoot,
          env: { HOME: home, ...NO_GATEWAY_AUTH },
          timeoutMs: TIMEOUT,
        });
        expect(listB.code).toBe(0);
        const jsonB = JSON.parse(listB.stdout);
        expect(jsonB.count).toBe(1);
        expect(jsonB.sessions.map((session: { id: string }) => session.id))
          .toEqual(["workspace-b-newest"]);

        const exactForeign = await runFx(
          ["session", "--id", "workspace-b-newest", "--json"],
          {
            cwd: workspaceARoot,
            env: { HOME: home, ...NO_GATEWAY_AUTH },
            timeoutMs: TIMEOUT,
          },
        );
        expect(exactForeign.code).toBe(0);
        expect(JSON.parse(exactForeign.stdout).id).toBe("workspace-b-newest");
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "session discovery reports corrupt records and distinguishes an unreadable latest session",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-corrupt-sessions-"));
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        mkdirSync(home);
        mkdirSync(workspace);
        const workspaceRoot = realpathSync(workspace);
        writeLegacySession(home, workspaceRoot, "readable-session", {
          updatedAtMs: 30,
        });
        for (const [id, contents] of [
          ["invalid-json", "{"],
          ["truncated", '{"schema_version":2,"id":"truncated"}'],
        ] as const) {
          const directory = join(home, ".fx", "sessions", id);
          mkdirSync(directory, { recursive: true, mode: 0o700 });
          writeFileSync(join(directory, "session.json"), contents, {
            mode: 0o600,
          });
        }

        const listed = await runFx(["sessions", "--json"], {
          cwd: workspaceRoot,
          env: { HOME: home, ...NO_GATEWAY_AUTH },
          timeoutMs: TIMEOUT,
        });
        expect(listed.code).toBe(0);
        expect(JSON.parse(listed.stdout)).toMatchObject({
          kind: "sessions",
          count: 1,
          skipped_invalid: 2,
          sessions: [{ id: "readable-session" }],
        });

        rmSync(join(home, ".fx", "sessions", "readable-session"), {
          recursive: true,
          force: true,
        });
        const latest = await runFx(["session", "last", "--json"], {
          cwd: workspaceRoot,
          env: { HOME: home, ...NO_GATEWAY_AUTH },
          timeoutMs: TIMEOUT,
        });
        expect(latest.code).toBe(1);
        expect(latest.stderr).toBe("");
        expect(JSON.parse(latest.stdout)).toMatchObject({
          error: expect.stringContaining("saved sessions are unreadable"),
        });
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "profile-wide session discovery recovers sessions after a workspace rename",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-renamed-workspace-"));
      try {
        const home = join(root, "home");
        const original = join(root, "workspace-before");
        const renamed = join(root, "workspace-after");
        mkdirSync(home);
        mkdirSync(original);
        const originalRoot = realpathSync(original);
        writeLegacySession(home, originalRoot, "renamed-workspace-session", {
          updatedAtMs: 40,
        });
        renameSync(original, renamed);
        const renamedRoot = realpathSync(renamed);

        const scoped = await runFx(["sessions", "--json"], {
          cwd: renamedRoot,
          env: { HOME: home, ...NO_GATEWAY_AUTH },
          timeoutMs: TIMEOUT,
        });
        expect(JSON.parse(scoped.stdout)).toMatchObject({ count: 0, sessions: [] });

        const recovered = await runFx(["sessions", "--all", "--json"], {
          cwd: renamedRoot,
          env: { HOME: home, ...NO_GATEWAY_AUTH },
          timeoutMs: TIMEOUT,
        });
        expect(recovered.code).toBe(0);
        expect(JSON.parse(recovered.stdout)).toMatchObject({
          count: 1,
          sessions: [
            {
              id: "renamed-workspace-session",
              workspace_root: originalRoot,
            },
          ],
        });
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "fx sessions --json ignores malformed and oversized list caches",
    async () => {
      for (const cached of ["{", "x".repeat(4 * 1024 * 1024 + 1)]) {
        const root = mkdtempSync(join(tmpdir(), "fx-e2e-sessions-cache-"));
        try {
          const home = join(root, "home");
          const workspace = join(root, "workspace");
          mkdirSync(join(home, ".fx", "sessions"), { recursive: true });
          mkdirSync(workspace, { recursive: true });
          writeFileSync(join(home, ".fx", "sessions", "list.json"), cached);

          const r = await runFx(["sessions", "--json"], {
            cwd: realpathSync(workspace),
            env: { HOME: home },
            timeoutMs: TIMEOUT,
          });
          expect(r.code).toBe(0);
          expect(JSON.parse(r.stdout.trim())).toEqual({
            kind: "sessions",
            count: 0,
            sessions: [],
          });
        } finally {
          rmSync(root, { recursive: true, force: true });
        }
      }
    },
    TIMEOUT,
  );

  test(
    "exact session flags address special-token and 255-byte IDs literally",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-session-exact-ids-"));
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        mkdirSync(home);
        mkdirSync(workspace);
        const workspaceRoot = realpathSync(workspace);
        const ids = [
          "last",
          "migrate",
          "--json",
          "--allow-large",
          "x".repeat(255),
        ];
        for (const id of ids) writeLegacySession(home, workspaceRoot, id);

        for (const id of ids) {
          const result = await runFx(
            ["session", "--id", id, "--json"],
            {
              cwd: workspaceRoot,
              env: { HOME: home },
              timeoutMs: TIMEOUT,
            },
          );
          expect(result.code).toBe(0);
          expect(JSON.parse(result.stdout).id).toBe(id);
        }
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "expected json failures emit machine-readable stdout",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-json-errors-"));
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        mkdirSync(home);
        mkdirSync(workspace);
        const workspaceRoot = realpathSync(workspace);
        const cases: Array<{
          args: string[];
          kind: string;
          expectedError?: string;
        }> = [
          { args: ["session", "last", "--json"], kind: "session" },
          {
            args: ["ask", "--json"],
            kind: "ask",
            expectedError: "MissingPrompt",
          },
          {
            args: ["ask", "--json", "--no-save", "--resume", "last", "hello"],
            kind: "ask",
            expectedError: "InvalidAskArgs",
          },
        ];

        for (const item of cases) {
          const result = await runFx(item.args, {
            cwd: workspaceRoot,
            env: { HOME: home, ...NO_GATEWAY_AUTH },
            timeoutMs: TIMEOUT,
          });
          expect(result.code).toBe(1);
          expect(result.stdout.trim().length).toBeGreaterThan(0);
          const parsed = JSON.parse(result.stdout.trim());
          expect(parsed.kind ?? item.kind).toBe(item.kind);
          expect(typeof parsed.error).toBe("string");
          if (item.expectedError) expect(parsed.error).toBe(item.expectedError);
        }
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );
});

describe("cli: removed delegated-task commands", () => {
  test(
    "fx task and fx tasks are unknown commands",
    async () => {
      for (const command of ["task", "tasks"]) {
        const result = await runFx([command], { env: NO_GATEWAY_AUTH });
        expect(result.code).toBe(1);
        expect(`${result.stdout}\n${result.stderr}`).toContain("unknown subcommand");
      }
    },
    TIMEOUT,
  );

  test(
    "legacy tasks files are ignored by ordinary session loading",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-legacy-tasks-ignored-"));
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        mkdirSync(home, { recursive: true });
        mkdirSync(workspace, { recursive: true });
        const workspaceRoot = realpathSync(workspace);
        writeLegacySession(home, workspaceRoot, "legacy-tasks-session");
        const tasksDir = join(home, ".fx", "sessions", "legacy-tasks-session", "tasks");
        mkdirSync(tasksDir, { recursive: true });
        writeFileSync(join(tasksDir, "unreadable-legacy-shape.json"), "not json\n");

        const result = await runFx(
          ["session", "--id", "legacy-tasks-session", "--json"],
          {
            cwd: workspaceRoot,
            env: { HOME: home, ...NO_GATEWAY_AUTH },
            timeoutMs: TIMEOUT,
          },
        );
        expect(result.code).toBe(0);
        expect(JSON.parse(result.stdout).id).toBe("legacy-tasks-session");
        expect(existsSync(join(tasksDir, "unreadable-legacy-shape.json"))).toBe(true);
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );
});

describe("cli: background", () => {
  test(
    "fx background --json returns valid background JSON",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-background-empty-"));
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        mkdirSync(home, { recursive: true });
        mkdirSync(workspace, { recursive: true });

        const r = await runFx(["background", "--json"], {
          cwd: workspace,
          env: { HOME: home },
        });
        expect(r.code).toBe(0);
        const json = JSON.parse(r.stdout.trim());
        expect(json.kind).toBe("background");
        expect(json).toHaveProperty("count");
        expect(Array.isArray(json.records)).toBe(true);
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "fx background --json revalidates saved workspace background records",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-background-"));
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        const logs = join(root, "logs");
        mkdirSync(home, { recursive: true });
        mkdirSync(workspace, { recursive: true });
        mkdirSync(logs, { recursive: true });

        const workspaceRoot = realpathSync(workspace);
        const liveLog = join(logs, "live.log");
        const staleLog = join(logs, "stale.log");
        writeFileSync(liveLog, "ready on http://localhost:48976\n");
        writeFileSync(staleLog, "started once\n");

        writeBackgroundSession({
          home,
          sessionId: "session-live",
          workspaceRoot,
          updatedAt: 20,
          record: {
            id: 1,
            pid: String(process.pid),
            command: "npm run dev",
            cwd: workspaceRoot,
            logPath: realpathSync(liveLog),
            expectUrl: true,
            state: "running",
          },
        });
        writeBackgroundSession({
          home,
          sessionId: "session-stale",
          workspaceRoot,
          updatedAt: 10,
          record: {
            id: 2,
            pid: "not-a-pid",
            command: "npm run dev",
            cwd: workspaceRoot,
            logPath: realpathSync(staleLog),
            expectUrl: true,
            state: "running",
          },
        });

        const r = await runFx(["background", "--json"], {
          cwd: workspaceRoot,
          env: { HOME: home },
          timeoutMs: TIMEOUT,
        });
        expect(r.code).toBe(0);
        const json = JSON.parse(r.stdout.trim());
        expect(json.kind).toBe("background");
        expect(json.count).toBe(2);

        const records = json.records as BackgroundRecordJson[];
        const live = records.find((record) => record.log_path === realpathSync(liveLog));
        expect(live).toBeTruthy();
        expect(live?.command).toBe("npm run dev");
        expect(live?.state).toBe("stale");
        expect(live?.server_url).toBeNull();
        expect(live?.diagnostic).toContain("no process identity token");

        const stale = records.find((record) => record.log_path === realpathSync(staleLog));
        expect(stale).toBeTruthy();
        expect(stale?.state).toBe("stale");
        expect(stale?.diagnostic).toContain("pid is missing or invalid");
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "fx background exact json reports corrupt records instead of hiding them as missing",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-background-corrupt-"));
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        const logs = join(root, "logs");
        mkdirSync(home, { recursive: true });
        mkdirSync(workspace, { recursive: true });
        mkdirSync(logs, { recursive: true });

        const workspaceRoot = realpathSync(workspace);
        const logPath = join(logs, "corrupt.log");
        writeFileSync(logPath, "started\n");
        writeBackgroundSession({
          home,
          sessionId: "background-corrupt",
          workspaceRoot,
          updatedAt: 20,
          record: {
            id: 1,
            pid: "not-a-pid",
            command: "npm run dev",
            cwd: workspaceRoot,
            logPath: realpathSync(logPath),
            expectUrl: false,
            state: "running",
          },
        });
        const recordPath = join(
          home,
          ".fx",
          "sessions",
          "background-corrupt",
          "background",
          "1.json",
        );
        writeFileSync(recordPath, "{broken", { mode: 0o600 });

        const result = await runFx(["background", "1", "--json"], {
          cwd: workspaceRoot,
          env: { HOME: home, ...NO_GATEWAY_AUTH },
          timeoutMs: TIMEOUT,
        });
        expect(result.code).toBe(1);
        expect(result.stderr).toBe("");
        const json = JSON.parse(result.stdout.trim());
        expect(json.kind).toBe("background");
        expect(json.code).toBe("InvalidBackgroundRecord");
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );
});

type BackgroundRecordJson = {
  log_path: string;
  command: string;
  state: string;
  server_url?: string | null;
  diagnostic?: string | null;
};

function writeBackgroundSession(args: {
  home: string;
  sessionId: string;
  workspaceRoot: string;
  updatedAt: number;
  record: {
    id: number;
    pid: string;
    command: string;
    cwd: string;
    logPath: string;
    expectUrl: boolean;
    state: string;
  };
}): void {
  const sessionDir = join(args.home, ".fx", "sessions", args.sessionId);
  const backgroundDir = join(sessionDir, "background");
  mkdirSync(backgroundDir, { recursive: true, mode: 0o700 });
  chmodSync(sessionDir, 0o700);
  chmodSync(backgroundDir, 0o700);
  writeFileSync(
    join(sessionDir, "session.json"),
    JSON.stringify({
      schema_version: 1,
      id: args.sessionId,
      created_at_ms: 1,
      updated_at_ms: args.updatedAt,
      workspace_root: args.workspaceRoot,
      conversation_language: "en",
      history_len: 0,
      history: [],
    }),
    { mode: 0o600 },
  );
  writeFileSync(
    join(backgroundDir, `${args.record.id}.json`),
    JSON.stringify({
      schema_version: 1,
      id: args.record.id,
      started_at_ms: 1,
      updated_at_ms: args.updatedAt,
      pid: args.record.pid,
      command: args.record.command,
      cwd: args.record.cwd,
      log_path: args.record.logPath,
      expect_url: args.record.expectUrl,
      server_url: null,
      exit_code: null,
      state: args.record.state,
      diagnostic: null,
    }),
    { mode: 0o600 },
  );
}

function modelsGatewayEnv(home: string, baseUrl: string) {
  return {
    OPENAI_API_KEY: SEEDED_GATEWAY_TOKEN,
    HOME: home,
    FX_DISABLE_KEYCHAIN: "1",
    FX_RESPONSES_BASE_URL: baseUrl,
  };
}

describe("cli: models", () => {
  test(
    "fx models uses the authenticated Responses catalog exactly once",
    async () => {
      const home = createIsolatedTestHome();
      const gateway = startFakeGateway([], {
        models: [
          { id: "gpt-5.6-sol", object: "model" },
          { id: "company-model", object: "model" },
        ],
      });

      try {
        const result = await runFx(["models", "--json"], {
          env: modelsGatewayEnv(home, gateway.baseUrl),
        });

        expect(result.code).toBe(0);
        expect(result.stderr).toBe("");
        const json = JSON.parse(result.stdout.trim());
        expect(json).toMatchObject({ kind: "models", count: 2 });
        expect(json.ids).toEqual(expect.arrayContaining(["gpt-5.6-sol", "company-model"]));
        expect(gateway.modelRequests).toHaveLength(1);
        expect(gateway.modelRequests[0]!.headers.get("authorization")).toBe(
          `Bearer ${SEEDED_GATEWAY_TOKEN}`,
        );
        expect(new URL(gateway.modelRequests[0]!.url).pathname).toBe("/v1/models");
      } finally {
        gateway.stop();
        cleanupIsolatedTestHome(home);
      }
    },
    TIMEOUT,
  );

  for (const scenario of [
    {
      name: "rate limiting",
      response: () => Response.json({ error: "slow down" }, { status: 429 }),
      code: "RateLimited",
    },
    {
      name: "malformed JSON",
      response: () => new Response("{not-json", {
        headers: { "content-type": "application/json" },
      }),
      code: "MalformedResponse",
    },
  ]) {
    test(
      `fx models preserves ${scenario.name} without retry`,
      async () => {
        const home = createIsolatedTestHome();
        const gateway = startFakeGateway([], { models: scenario.response });
        try {
          const result = await runFx(["models", "--json"], {
            env: modelsGatewayEnv(home, gateway.baseUrl),
          });

          expect(result.code).not.toBe(0);
          expect(result.stderr).toBe("");
          expect(JSON.parse(result.stdout.trim()).code).toBe(scenario.code);
          expect(gateway.modelRequests).toHaveLength(1);
        } finally {
          gateway.stop();
          cleanupIsolatedTestHome(home);
        }
      },
      TIMEOUT,
    );
  }

  test(
    "fx models rejects redirects without forwarding its credential",
    async () => {
      const home = createIsolatedTestHome();
      const captureRequests: string[] = [];
      const captureServer = Bun.serve({
        hostname: "127.0.0.1",
        port: 0,
        fetch(request) {
          captureRequests.push(
            `${request.method} ${new URL(request.url).pathname} authorization=${request.headers.get("authorization") ?? ""}`,
          );
          return Response.json({ data: [] });
        },
      });
      const redirectServer = Bun.serve({
        hostname: "127.0.0.1",
        port: 0,
        fetch() {
          return Response.redirect(`http://127.0.0.1:${captureServer.port}/capture`, 302);
        },
      });

      try {
        const result = await runFx(["models", "--json"], {
          env: modelsGatewayEnv(home, `http://127.0.0.1:${redirectServer.port}/v1`),
        });

        expect(captureRequests).toEqual([]);
        expect(result.code).not.toBe(0);
        expect(result.stderr).toBe("");
        expect(JSON.parse(result.stdout.trim())).toMatchObject({
          kind: "models",
          error: expect.stringContaining("could not list models:"),
          code: expect.any(String),
        });
      } finally {
        redirectServer.stop(true);
        captureServer.stop(true);
        cleanupIsolatedTestHome(home);
      }
    },
    TIMEOUT,
  );
});

describe("cli: replay failures", () => {
  test(
    "fx replay --json preserves structured failures for missing and malformed tapes",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-replay-json-errors-"));
      try {
        const missing = await runFx(["replay", join(root, "missing.fxtape"), "--json"]);
        expect(missing.code).toBe(1);
        expect(missing.stderr).toBe("");
        expect(JSON.parse(missing.stdout.trim())).toMatchObject({
          kind: "replay",
          code: "FileNotFound",
        });

        const malformedPath = join(root, "malformed.fxtape");
        writeFileSync(malformedPath, "not a tape");
        const malformed = await runFx(["replay", malformedPath, "--json"]);
        expect(malformed.code).toBe(1);
        expect(malformed.stderr).toBe("");
        expect(JSON.parse(malformed.stdout.trim())).toMatchObject({
          kind: "replay",
        });
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );
});

describe("cli: ask input validation", () => {
  test(
    "fx ask rejects invalid UTF-8 stdin before Gateway or session effects",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-ask-invalid-utf8-"));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      mkdirSync(home);
      mkdirSync(workspace);
      const requests: string[] = [];
      const server = Bun.serve({
        hostname: "127.0.0.1",
        port: 0,
        fetch(request) {
          requests.push(new URL(request.url).pathname);
          return Response.json({ error: "request should not arrive" }, { status: 400 });
        },
      });

      try {
        const result = await runFx(["ask", "--json", "--no-save"], {
          cwd: realpathSync(workspace),
          env: {
            ...NO_GATEWAY_AUTH,
            HOME: realpathSync(home),
            OPENAI_API_KEY: "invalid-utf8-proof-key",
            FX_DISABLE_KEYCHAIN: "1",
            FX_RESPONSES_BASE_URL: `http://127.0.0.1:${server.port}/ai/v1/chat/completions`,
          },
          stdin: Uint8Array.from([0xff, 0xfe, 0x80, 0x68, 0x69]),
          timeoutMs: TIMEOUT,
        });

        expect(result.code).toBe(1);
        expect(result.stderr).toBe("");
        expect(JSON.parse(result.stdout.trim())).toMatchObject({
          exit_code: 1,
          error: "InvalidPromptText",
        });
        expect(requests).toEqual([]);
        expect(existsSync(join(home, ".fx"))).toBe(false);
      } finally {
        server.stop(true);
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );
});

describe("cli: session", () => {
  test(
    "fx session with no id exits non-zero or shows usage",
    async () => {
      const r = await runFx(["session"]);
      expect(r.code).not.toBe(0);
    },
    TIMEOUT,
  );
});

describe("cli: interactive startup", () => {
  test(
    "interactive startup without TTY exits one",
    async () => {
      const cases = [
        [],
        ["resume", "last"],
        ["--resume"],
        ["session", "resume", "last"],
        ["session", "resume", "--id", "session.v3"],
      ];

      for (const args of cases) {
        const home = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-no-tty-")));
        try {
          const r = await runFx(args, { env: { HOME: home } });
          expect(r.code).toBe(1);
          expect(r.stdout).toBe("");
          expect(r.stderr).toBe("fx requires an interactive terminal (TTY).\n");
          expect(readdirSync(home)).toEqual([]);
        } finally {
          rmSync(home, { recursive: true, force: true });
        }
      }
    },
    TIMEOUT,
  );
});

describe("cli: pr", () => {
  test(
    "fx pr without gateway auth exits non-zero",
    async () => {
      const home = mkdtempSync(join(tmpdir(), "fx-e2e-noauth-"));
      try {
        const r = await runFx(["pr"], {
          env: { ...NO_GATEWAY_AUTH, HOME: home, FX_DISABLE_KEYCHAIN: "1" },
        });
        expect(r.code).not.toBe(0);
        expect(r.stderr).toContain(MISSING_AUTH_MESSAGE);
      } finally {
        rmSync(home, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );
});

describe("cli: issue", () => {
  test(
    "fx issue without gateway auth exits non-zero",
    async () => {
      const home = mkdtempSync(join(tmpdir(), "fx-e2e-noauth-"));
      try {
        const r = await runFx(["issue"], {
          env: { ...NO_GATEWAY_AUTH, HOME: home, FX_DISABLE_KEYCHAIN: "1" },
        });
        expect(r.code).not.toBe(0);
        expect(r.stderr).toContain(MISSING_AUTH_MESSAGE);
      } finally {
        rmSync(home, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );
});

describe("cli: ask success", () => {
  test(
    "fx ask binds an explicitly invoked skill into the prompt",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-ask-explicit-skill-"));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const skillDirectory = join(home, ".fx", "skills", "cli-explicit");
      const skillBody = "CLI_EXPLICIT_SKILL_BODY";
      const gateway = startFakeGateway([
        fakeGatewayFinalText("explicit skill ask complete"),
      ]);
      try {
        mkdirSync(skillDirectory, { recursive: true });
        mkdirSync(workspace);
        writeFileSync(
          join(skillDirectory, "SKILL.md"),
          `---\nname: cli-explicit\ndescription: explicit CLI fixture\n---\n\n${skillBody}\n`,
        );

        const result = await runFx(
          [
            "ask",
            "--json",
            "--auto",
            "--no-save",
            "$cli-explicit apply the selected skill.",
          ],
          {
            cwd: realpathSync(workspace),
            env: {
              HOME: realpathSync(home),
              OPENAI_API_KEY: "fake-explicit-skill-key",
                            FX_RESPONSES_BASE_URL: gateway.baseUrl,
              FX_MODEL: FAKE_GATEWAY_MODEL,
            },
            timeoutMs: TIMEOUT,
          },
        );

        expect(result.code).toBe(0);
        expect(result.stderr).toBe("");
        expect(JSON.parse(result.stdout).output.trim()).toBe(
          "explicit skill ask complete",
        );
        expect(gateway.requests).toHaveLength(1);
        expect(gateway.modelRequests).toHaveLength(0);
        expect(gateway.requests[0]!.body).toContain(
          "Explicitly invoked skill content for this query:",
        );
        expect(gateway.requests[0]!.body).toContain(
          '<skill_content name=\\"cli-explicit\\" resource=\\"SKILL.md\\"',
        );
        expect(gateway.requests[0]!.body).toContain(skillBody);
      } finally {
        gateway.stop();
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "fx ask stdin prompts above the old 1 MiB limit reach Gateway byte-for-byte",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-ask-large-stdin-"));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const sizes = [1024 * 1024 - 1, 1024 * 1024, 1024 * 1024 + 1, 3 * 1024 * 1024];
      const gateway = startFakeGateway(
        sizes.map((_, index) => fakeGatewayFinalText(`large stdin ${index}`)),
      );
      try {
        mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
        mkdirSync(workspace);
        writeFileSync(join(home, ".fx", "settings.json"), "{}\n");

        for (const [index, size] of sizes.entries()) {
          const prompt = `B${"x".repeat(size - 2)}E`;
          const result = await runFx(
            ["ask", "--json", "--auto", "--no-save"],
            {
              cwd: realpathSync(workspace),
              env: {
                HOME: home,
                OPENAI_API_KEY: "fake-large-stdin-key",
                                FX_RESPONSES_BASE_URL: gateway.baseUrl,
                FX_MODEL: FAKE_GATEWAY_MODEL,
              },
              stdin: prompt,
              timeoutMs: 60_000,
            },
          );

          expect(result.code).toBe(0);
          expect(JSON.parse(result.stdout).output.trim()).toBe(`large stdin ${index}`);
          const request = JSON.parse(gateway.requests[index]!.body) as {
            input: Array<{ role: string; content: Array<{ type: string; text?: string }> }>;
          };
          const user = request.input.findLast((message) => message.role === "user");
          expect(user?.content.find((part) => part.type === "input_text")?.text).toBe(prompt);
        }

        expect(gateway.requests).toHaveLength(sizes.length);
        expect(gateway.modelRequests).toHaveLength(0);
      } finally {
        gateway.stop();
        rmSync(root, { recursive: true, force: true });
      }
    },
    120_000,
  );

  test(
    "fx ask stdin resource overflow has distinct text and JSON errors",
    async () => {
      const oversized = Buffer.alloc(8 * 1024 * 1024 + 1, 0x78);

      const textResult = await runFx(["ask", "--auto", "--no-save"], {
        env: { ...NO_GATEWAY_AUTH, FX_DISABLE_KEYCHAIN: "1" },
        stdin: oversized,
        timeoutMs: 60_000,
      });
      expect(textResult.code).toBe(1);
      expect(textResult.stdout).toBe("");
      expect(textResult.stderr).toBe(
        "fx ask: prompt exceeds the local input safety limit\n",
      );

      const jsonResult = await runFx(["ask", "--json", "--auto", "--no-save"], {
        env: { ...NO_GATEWAY_AUTH, FX_DISABLE_KEYCHAIN: "1" },
        stdin: oversized,
        timeoutMs: 60_000,
      });
      expect(jsonResult.code).toBe(1);
      expect(jsonResult.stderr).toBe("");
      expect(jsonResult.stdout).toBe(
        '{"output":"","exit_code":1,"model":"","session_id":"","steps":0,"tool_calls":[],"error":"PromptResourceLimitExceeded"}\n',
      );
    },
    120_000,
  );

  test(
    "saved ask resumes the exact session while no-save creates no durable state",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-ask-persistence-"));
      const gateway = startFakeGateway([
        fakeGatewayFinalText("orange triangle"),
        fakeGatewayFinalText("blue circle"),
        fakeGatewayFinalText("green square"),
      ]);
      try {
        const savedHome = join(root, "saved-home");
        const noSaveHome = join(root, "no-save-home");
        const workspace = join(root, "workspace");
        mkdirSync(savedHome);
        mkdirSync(noSaveHome);
        mkdirSync(workspace);
        const workspaceRoot = realpathSync(workspace);

        const first = await runFx(
          ["ask", "--json", "--auto", "Reply with exactly: orange triangle"],
          {
            cwd: workspaceRoot,
            env: {
              HOME: realpathSync(savedHome),
              OPENAI_API_KEY: "fake-ask-persistence-key",
              FX_RESPONSES_BASE_URL: gateway.baseUrl,
              FX_MODEL: FAKE_GATEWAY_MODEL,
            },
            timeoutMs: 60_000,
          },
        );
        expect(first.code).toBe(0);
        expect(first.stderr).toBe("");
        const firstJson = JSON.parse(first.stdout.trim());
        expect(typeof firstJson.session_id).toBe("string");
        expect(firstJson.session_id.length).toBeGreaterThan(0);
        expect(
          existsSync(
            join(savedHome, ".fx", "sessions", firstJson.session_id),
          ),
        ).toBe(true);

        const resumed = await runFx(
          [
            "ask",
            "--json",
            "--auto",
            "--resume",
            "last",
            "Reply with exactly: blue circle",
          ],
          {
            cwd: workspaceRoot,
            env: {
              HOME: realpathSync(savedHome),
              OPENAI_API_KEY: "fake-ask-persistence-key",
              FX_RESPONSES_BASE_URL: gateway.baseUrl,
              FX_MODEL: FAKE_GATEWAY_MODEL,
            },
            timeoutMs: 60_000,
          },
        );
        expect(resumed.code).toBe(0);
        expect(resumed.stderr).toBe("");
        expect(JSON.parse(resumed.stdout.trim()).session_id).toBe(
          firstJson.session_id,
        );
        const detail = await runFx(
          ["session", "--id", firstJson.session_id, "--json"],
          {
            cwd: workspaceRoot,
            env: { HOME: realpathSync(savedHome) },
            timeoutMs: 60_000,
          },
        );
        expect(detail.code).toBe(0);
        expect(JSON.parse(detail.stdout).history_len).toBe(2);

        const noSave = await runFx(
          ["ask", "--json", "--auto", "--no-save", "Reply with exactly: green square"],
          {
            cwd: workspaceRoot,
            env: {
              HOME: realpathSync(noSaveHome),
              OPENAI_API_KEY: "fake-ask-persistence-key",
              FX_RESPONSES_BASE_URL: gateway.baseUrl,
              FX_MODEL: FAKE_GATEWAY_MODEL,
            },
            timeoutMs: 60_000,
          },
        );
        expect(noSave.code).toBe(0);
        expect(noSave.stderr).toBe("");
        expect(JSON.parse(noSave.stdout.trim()).session_id).toBe("");
        expect(existsSync(join(noSaveHome, ".fx"))).toBe(false);
        expect(gateway.requests).toHaveLength(3);
      } finally {
        gateway.stop();
        rmSync(root, { recursive: true, force: true });
      }
    },
    180_000,
  );

  test(
    "saved ask survives session cache contention and repairs after release",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-session-cache-contention-"));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const lockReady = join(root, "latest-lock-ready");
      const unrelatedReply = `unrelated saved turn ${"x".repeat(64 * 1024)}`;
      const gateway = startFakeGateway([
        fakeGatewayFinalText(unrelatedReply),
        fakeGatewayFinalText("first saved turn"),
        fakeGatewayFinalText("contended exact turn"),
        fakeGatewayFinalText("contended latest turn"),
        fakeGatewayFinalText("repairing turn"),
      ]);
      let lockHolder: ReturnType<typeof Bun.spawn> | null = null;
      try {
        mkdirSync(home);
        mkdirSync(workspace);
        const workspaceRoot = realpathSync(workspace);
        const env = {
          HOME: realpathSync(home),
          OPENAI_API_KEY: "fake-session-cache-contention-key",
          FX_RESPONSES_BASE_URL: gateway.baseUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
        };

        const unrelated = await runFx(
          ["ask", "--json", "--auto", "Save an unrelated long turn."],
          { cwd: workspaceRoot, env, timeoutMs: 60_000 },
        );
        expect(unrelated.code).toBe(0);
        expect(unrelated.stderr).toBe("");
        const unrelatedJson = JSON.parse(unrelated.stdout);
        const unrelatedSessionId = unrelatedJson.session_id as string;
        expect(unrelatedJson.output).toBe(unrelatedReply);

        const first = await runFx(
          ["ask", "--json", "--auto", "Reply with the first saved turn."],
          { cwd: workspaceRoot, env, timeoutMs: 60_000 },
        );
        expect(first.code).toBe(0);
        expect(first.stderr).toBe("");
        const sessionId = JSON.parse(first.stdout).session_id as string;
        const lockPath = join(home, ".fx", "sessions", "latest.lock");
        lockHolder = Bun.spawn(
          [
            "python3",
            "-c",
            [
              "import fcntl, os, sys, time",
              "fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)",
              "fcntl.flock(fd, fcntl.LOCK_EX)",
              "open(sys.argv[2], 'w').close()",
              "time.sleep(300)",
            ].join("\n"),
            lockPath,
            lockReady,
          ],
          { stdout: "ignore", stderr: "pipe" },
        );
        for (let attempt = 0; attempt < 250 && !existsSync(lockReady); attempt += 1) {
          await Bun.sleep(20);
        }
        expect(existsSync(lockReady)).toBe(true);

        const exact = await runFx(
          [
            "ask",
            "--json",
            "--auto",
            "--resume-id",
            sessionId,
            "Reply with the contended exact turn.",
          ],
          { cwd: workspaceRoot, env, timeoutMs: 60_000 },
        );
        expect(exact.code).toBe(0);
        expect(exact.stderr).toBe("");
        expect(JSON.parse(exact.stdout).output.trim()).toBe("contended exact turn");
        const tokenPath = join(
          home,
          ".fx",
          "sessions",
          "latest",
          "deferred",
          sessionId,
        );
        expect(existsSync(tokenPath)).toBe(true);

        const listed = await runFx(["sessions", "--json"], {
          cwd: workspaceRoot,
          env: { HOME: home, ...NO_GATEWAY_AUTH },
          timeoutMs: 60_000,
        });
        expect(listed.code).toBe(0);
        expect(listed.stderr).toBe("");
        const listedSessions = JSON.parse(listed.stdout).sessions;
        expect(listedSessions[0]).toMatchObject({
          id: sessionId,
          history_len: 2,
        });
        expect(listedSessions[1]).toMatchObject({
          id: unrelatedSessionId,
          history_len: 1,
        });
        expect(existsSync(tokenPath)).toBe(true);

        const latest = await runFx(
          [
            "ask",
            "--json",
            "--auto",
            "--resume",
            "last",
            "Reply with the contended latest turn.",
          ],
          { cwd: workspaceRoot, env, timeoutMs: 60_000 },
        );
        expect(latest.code).toBe(0);
        expect(latest.stderr).toBe("");
        expect(JSON.parse(latest.stdout).session_id).toBe(sessionId);
        expect(JSON.parse(latest.stdout).output.trim()).toBe("contended latest turn");
        expect(existsSync(tokenPath)).toBe(true);

        lockHolder.kill();
        await lockHolder.exited;
        lockHolder = null;
        const repaired = await runFx(
          [
            "ask",
            "--json",
            "--auto",
            "--resume-id",
            sessionId,
            "Reply with the repairing turn.",
          ],
          { cwd: workspaceRoot, env, timeoutMs: 60_000 },
        );
        expect(repaired.code).toBe(0);
        expect(repaired.stderr).toBe("");
        expect(JSON.parse(repaired.stdout).output.trim()).toBe("repairing turn");
        expect(existsSync(tokenPath)).toBe(false);
        const targetDetail = await runFx(
          ["session", "--id", sessionId, "--json"],
          { cwd: workspaceRoot, env: { HOME: home }, timeoutMs: 60_000 },
        );
        expect(targetDetail.code).toBe(0);
        expect(targetDetail.stderr).toBe("");
        expect(JSON.parse(targetDetail.stdout).history_len).toBe(4);
        const unrelatedDetail = await runFx(
          ["session", "--id", unrelatedSessionId, "--json"],
          { cwd: workspaceRoot, env: { HOME: home }, timeoutMs: 60_000 },
        );
        expect(unrelatedDetail.code).toBe(0);
        expect(unrelatedDetail.stderr).toBe("");
        expect(JSON.parse(unrelatedDetail.stdout).history_len).toBe(1);
        expect(gateway.requests).toHaveLength(5);
      } finally {
        if (lockHolder) {
          lockHolder.kill();
          await lockHolder.exited;
        }
        gateway.stop();
        rmSync(root, { recursive: true, force: true });
      }
    },
    300_000,
  );
});

describe("cli: error handling", () => {
  test(
    "fx ask rejects unknown options before a model turn and -- preserves literal prompt text",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-ask-options-"));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const gateway = startFakeGateway([
        fakeGatewayFinalText("literal option prompt complete"),
      ]);
      try {
        mkdirSync(home);
        mkdirSync(workspace);
        const env = {
          HOME: realpathSync(home),
          OPENAI_API_KEY: "ask-options-key",
                    FX_RESPONSES_BASE_URL: gateway.baseUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
        };

        const rejected = await runFx(["ask", "--definitely-unknown"], {
          cwd: realpathSync(workspace),
          env,
          timeoutMs: TIMEOUT,
        });
        expect(rejected.code).toBe(1);
        expect(rejected.stderr).toContain("usage: fx ask");
        expect(gateway.requests).toHaveLength(0);

        const literal = await runFx(
          [
            "ask",
            "--json",
            "--auto",
            "--no-save",
            "--",
            "--definitely-prompt-text",
          ],
          {
            cwd: realpathSync(workspace),
            env,
            timeoutMs: TIMEOUT,
          },
        );
        expect(literal.code).toBe(0);
        expect(JSON.parse(literal.stdout).output.trim()).toBe(
          "literal option prompt complete",
        );
        expect(gateway.requests).toHaveLength(1);
        expect(gateway.requests[0]!.body).toContain("--definitely-prompt-text");
      } finally {
        gateway.stop();
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "fx ask with no prompt exits 1",
    async () => {
      const r = await runFx(["ask"]);
      expect(r.code).toBe(1);
      expect(r.stderr).toContain("missing prompt");
    },
    TIMEOUT,
  );

  test(
    "fx unknown-command exits 1",
    async () => {
      const r = await runFx(["unknown-command"]);
      expect(r.code).toBe(1);
    },
    TIMEOUT,
  );

  test(
    "fx ask explains no-save resume conflicts before a model turn",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-ask-resume-no-save-"));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const gateway = startFakeGateway([]);
      try {
        mkdirSync(home);
        mkdirSync(workspace);
        const env = {
          HOME: realpathSync(home),
          OPENAI_API_KEY: "ask-conflict-key",
                    FX_RESPONSES_BASE_URL: gateway.baseUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
        };

        for (const args of [
          ["ask", "--no-save", "--resume", "last", "hello"],
          ["ask", "--resume-id", "session.v3", "--no-save", "hello"],
        ]) {
          const rejected = await runFx(args, {
            cwd: realpathSync(workspace),
            env,
            timeoutMs: TIMEOUT,
          });
          expect(rejected.code).toBe(1);
          expect(rejected.stdout).toBe("");
          expect(rejected.stderr).toContain(
            "fx ask: --no-save cannot be used with --resume or --resume-id",
          );
          expect(rejected.stderr).toContain(
            "usage: fx ask [--auto|--yolo] [--image PATH] [--json] [--quiet] [--prompt-permissions] [--no-save]",
          );
        }
        expect(gateway.requests).toHaveLength(0);
      } finally {
        gateway.stop();
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );
});

describe("cli: workspace access", () => {
  test(
    "workspace launch modifiers preserve ask help and report friendly option errors",
    async () => {
      const enabled = {
        ...NO_GATEWAY_AUTH,
      };

      const help = await runFx(
        ["--add-dir", "/tmp/shared", "ask", "--help"],
        { env: enabled },
      );
      expect(help.code).toBe(0);
      expect(help.stdout.startsWith("fx ask\n\n")).toBe(true);
      expect(help.stderr).toBe("");

      const missing = await runFx(["--add-dir"], { env: enabled });
      expect(missing.code).toBe(1);
      expect(missing.stderr).toContain("--add-dir requires a directory path");
      expect(missing.stderr).not.toContain("MissingAddDirectoryValue");

      const duplicate = await runFx(
        ["--no-additional-dirs", "--no-additional-dirs"],
        { env: enabled },
      );
      expect(duplicate.code).toBe(1);
      expect(duplicate.stderr).toContain(
        "--no-additional-dirs may only be specified once",
      );
      expect(duplicate.stderr).not.toContain(
        "DuplicateAdditionalDirectorySuppression",
      );
    },
    TIMEOUT,
  );

  test(
    "workspace commands persist per-primary roots and track availability",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-workspace-access-cli-"));
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        const shared = join(root, "shared");
        const unknown = join(root, "unknown");
        const missing = join(root, "missing");
        mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
        chmodSync(join(home, ".fx"), 0o700);
        mkdirSync(workspace);
        mkdirSync(shared);
        mkdirSync(unknown);
        const workspaceRoot = realpathSync(workspace);
        const sharedRoot = realpathSync(shared);
        const unknownRoot = realpathSync(unknown);
        const baseEnv = {
          ...NO_GATEWAY_AUTH,
          HOME: realpathSync(home),
        };

        const added = await runFx(
          ["workspace", "add", sharedRoot, "--json"],
          { cwd: workspaceRoot, env: baseEnv },
        );
        expect(added.code).toBe(0);
        const addedJson = JSON.parse(added.stdout.trim());
        expect(addedJson).toMatchObject({
          kind: "workspace",
          action: "add",
          changed: true,
          limit: 16,
          path: sharedRoot,
        });
        expect(addedJson.additional_directories).toEqual([
          {
            path: sharedRoot,
            saved: true,
            command_line: false,
            available: true,
            active: true,
          },
        ]);

        const stored = JSON.parse(
          readFileSync(join(home, ".fx", "settings.json"), "utf8"),
        );
        expect(stored.workspaces[workspaceRoot].additional_directories).toEqual([
          sharedRoot,
        ]);

        for (const path of [unknownRoot, missing]) {
          const unknownRemoval = await runFx(
            ["workspace", "remove", path, "--json"],
            { cwd: workspaceRoot, env: baseEnv },
          );
          expect(unknownRemoval.code).toBe(1);
          expect(JSON.parse(unknownRemoval.stdout.trim())).toEqual({
            kind: "workspace",
            error: "directory is not configured as an additional workspace",
            code: "UnknownAdditionalDirectory",
          });
        }

        const removed = await runFx(
          ["workspace", "remove", sharedRoot, "--json"],
          { cwd: workspaceRoot, env: baseEnv },
        );
        expect(removed.code).toBe(0);
        expect(JSON.parse(removed.stdout.trim())).toMatchObject({
          action: "remove",
          changed: true,
          launch_flag_can_restore: false,
          additional_directories: [],
        });

        const readded = await runFx(
          ["workspace", "add", sharedRoot, "--json"],
          { cwd: workspaceRoot, env: baseEnv },
        );
        expect(readded.code).toBe(0);

        const active = await runFx(["workspace", "--json"], {
          cwd: workspaceRoot,
          env: {
            ...baseEnv,
          },
        });
        expect(active.code).toBe(0);
        expect(JSON.parse(active.stdout.trim())).toMatchObject({
          action: "list",
          changed: false,
          additional_directories: [{ path: sharedRoot, active: true }],
        });

        rmSync(sharedRoot, { recursive: true, force: true });
        const unavailable = await runFx(["workspace", "list", "--json"], {
          cwd: workspaceRoot,
          env: {
            ...baseEnv,
          },
        });
        expect(unavailable.code).toBe(0);
        expect(JSON.parse(unavailable.stdout.trim()).additional_directories).toEqual([
          {
            path: sharedRoot,
            saved: true,
            command_line: false,
            available: false,
            active: false,
          },
        ]);

        const unavailableRemoved = await runFx(
          ["workspace", "remove", `${sharedRoot}${sep}`, "--json"],
          { cwd: workspaceRoot, env: baseEnv },
        );
        expect(unavailableRemoved.code).toBe(0);
        expect(JSON.parse(unavailableRemoved.stdout.trim())).toMatchObject({
          action: "remove",
          changed: true,
          additional_directories: [],
        });
        const removedSettings = JSON.parse(
          readFileSync(join(home, ".fx", "settings.json"), "utf8"),
        );
        expect(
          removedSettings.workspaces?.[workspaceRoot]?.additional_directories,
        ).toBeUndefined();

        mkdirSync(sharedRoot);
        const restored = await runFx(
          ["workspace", "add", sharedRoot, "--json"],
          { cwd: workspaceRoot, env: baseEnv },
        );
        expect(restored.code).toBe(0);

        const cleared = await runFx(["workspace", "clear", "--json"], {
          cwd: workspaceRoot,
          env: baseEnv,
        });
        expect(cleared.code).toBe(0);
        expect(JSON.parse(cleared.stdout.trim())).toMatchObject({
          action: "clear",
          changed: true,
          additional_directories: [],
        });
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    30_000,
  );

  test(
    "workspace commands mutate persisted aliases by workspace identity",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-workspace-alias-cli-"));
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        const shared = join(root, "shared");
        const sharedLink = join(root, "shared-link");
        const missing = join(root, "missing");
        const realParent = join(root, "real-parent");
        const parentLink = join(root, "parent-link");
        mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
        chmodSync(join(home, ".fx"), 0o700);
        mkdirSync(workspace);
        mkdirSync(shared);
        mkdirSync(realParent);
        symlinkSync(shared, sharedLink, "dir");
        symlinkSync(realParent, parentLink, "dir");
        const workspaceRoot = realpathSync(workspace);
        const sharedRoot = realpathSync(shared);
        const settingsPath = join(home, ".fx", "settings.json");
        const baseEnv = {
          ...NO_GATEWAY_AUTH,
          HOME: realpathSync(home),
        };

        writeFileSync(
          settingsPath,
          JSON.stringify({
            workspaces: {
              [workspaceRoot]: {
                additional_directories: [
                  `${sharedRoot}${sep}.`,
                  sharedLink,
                ],
              },
            },
          }) + "\n",
          { mode: 0o600 },
        );

        const unchanged = await runFx(
          ["workspace", "add", sharedRoot, "--json"],
          { cwd: workspaceRoot, env: baseEnv },
        );
        expect(unchanged.code).toBe(0);
        expect(JSON.parse(unchanged.stdout.trim())).toMatchObject({
          action: "add",
          changed: true,
          saved_changed: true,
          runtime_changed: false,
        });

        const removedAvailable = await runFx(
          ["workspace", "remove", sharedRoot, "--json"],
          { cwd: workspaceRoot, env: baseEnv },
        );
        expect(removedAvailable.code).toBe(0);
        expect(JSON.parse(removedAvailable.stdout.trim())).toMatchObject({
          action: "remove",
          changed: true,
          additional_directories: [],
        });
        let stored = JSON.parse(readFileSync(settingsPath, "utf8"));
        expect(
          stored.workspaces?.[workspaceRoot]?.additional_directories,
        ).toBeUndefined();

        writeFileSync(
          settingsPath,
          JSON.stringify({
            workspaces: {
              [workspaceRoot]: {
                additional_directories: [
                  `${missing}${sep}.`,
                  join(missing, "child", ".."),
                ],
              },
            },
          }) + "\n",
          { mode: 0o600 },
        );
        const removedUnavailable = await runFx(
          ["workspace", "remove", missing, "--json"],
          { cwd: workspaceRoot, env: baseEnv },
        );
        expect(removedUnavailable.code).toBe(0);
        expect(JSON.parse(removedUnavailable.stdout.trim())).toMatchObject({
          action: "remove",
          changed: true,
          additional_directories: [],
        });
        stored = JSON.parse(readFileSync(settingsPath, "utf8"));
        expect(
          stored.workspaces?.[workspaceRoot]?.additional_directories,
        ).toBeUndefined();

        const realMissing = join(realParent, "missing");
        const linkedMissing = join(parentLink, "missing");
        writeFileSync(
          settingsPath,
          JSON.stringify({
            workspaces: {
              [workspaceRoot]: {
                additional_directories: [realMissing, linkedMissing],
              },
            },
          }) + "\n",
          { mode: 0o600 },
        );
        const removedLinkedPrefix = await runFx(
          ["workspace", "remove", linkedMissing, "--json"],
          { cwd: workspaceRoot, env: baseEnv },
        );
        expect(removedLinkedPrefix.code).toBe(0);
        expect(JSON.parse(removedLinkedPrefix.stdout.trim())).toMatchObject({
          action: "remove",
          changed: true,
          additional_directories: [],
        });
        stored = JSON.parse(readFileSync(settingsPath, "utf8"));
        expect(
          stored.workspaces?.[workspaceRoot]?.additional_directories,
        ).toBeUndefined();
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    30_000,
  );
});
