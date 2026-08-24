```
 ⠀⠀⠀⠀⠀⠀⣠⣾⣿⣿⣿⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⠀⠀⢰⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⣠⣶⣿⣿⣷⣶⡶⣶⣶⣆⠀⠀⠀⣴⣶⣶⠆
 ⠀⠀⠀⠉⢹⣿⣿⠉⠉⠀⠘⢿⣿⣧⣀⣾⣿⡿⠃⠀             Tiny, open, embeddable, native coding agent.
 ⠀⠀⠀⠀⣼⣿⡏⠀⠀⠀⠀⠀⠻⣿⣿⣿⠟⠀⠀⠀
 ⠀⠀⠀⢀⣿⣿⠃⠀⠀⠀⠀⢠⣦⠘⢿⣿⣷⡀⠀⠀             curl -fsSL https://fx.sh/setup.sh | bash
 ⠀⠀⠀⣸⣿⡟⠀⠀⠀⠀⣰⣿⣿⠗⠀⠻⣿⣿⣄⠀
 ⠀⠀⠀⣿⣿⠇⠀⠀⠀⠾⠿⠿⠋⠀⠀⠀⠘⠿⠿⠦             ⚠ Status: Experimental. Use at your own risk.
  ⠀⣸⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 ⣿⣿⣿⠟⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
```

fx is a coding agent harness and CLI written in Zig, optimized for research and embeddability as part of larger systems.

It focuses on minimalism and performance across the board, from system prompt design to its tools, feature set, and 7.8 MiB binary.

For end users, its CLI output style and form factor aim to be closer to a Unix shell than a heavy "IDE in the terminal" TUI.

It's open source (Apache-2.0), model-agnostic, and suitable for both local and cloud inference.

## About this fork (`byok`)

This is the `byok` branch of a fork of upstream [`vercel-labs/fx`](https://github.com/vercel-labs/fx). Upstream stays the source of truth for the shared codebase and is merged in regularly; this branch exists for work upstream would not take, aimed at three goals.

> [!IMPORTANT]
> **Long-term maintenance commitment for BYOK and third-party OAuth**
>
> This branch is maintained as a daily-use distribution, not a one-time experiment. The maintainer uses it for real fx work, continuously exercises BYOK, ChatGPT Codex OAuth, xAI Grok OAuth, remote compaction, tool calls, permission review, token refresh, and session resume, and fixes regressions found through that use. The commitment is to keep these supported paths working across provider changes and future upstream merges, with focused regression coverage for failures already seen.
>
> Upstream remains the source of truth for shared fx development, but BYOK and third-party OAuth are not its primary maintenance focus, and fixes in these paths can move slowly. For example, merging an upstream revision reintroduced a Codex Responses request that failed to provide valid input, even though this branch had already fixed that failure class. Owning and repairing independent provider behavior without waiting for upstream is a central reason this fork and the `byok` branch exist.
>
> This is a promise of ongoing ownership rather than a claim that external providers will never change. Regressions in supported BYOK and OAuth paths are treated as branch bugs: they are reproduced against real runtime behavior, fixed here, and kept under regression coverage.

**1. Remove every hard binding to Vercel.** No default path should require a Vercel account, gateway, key, setup flow, login, catalog, or request endpoint. Generic provider contracts and useful optional transports can remain, but Vercel-specific onboarding is not a capability this fork promises to preserve.

**2. Support any BYOK provider.** The target is to bring the key you already pay for and point fx at a compatible commercial, corporate, self-hosted, or local endpoint. That requires configurable base URLs, multiple credential sources, provider protocols, and model catalogs.

**3. Improve the agent harness.** Better default agent behavior belongs here even where upstream keeps it optional or absent. Streamed model reasoning, for example, is shown during work and durable provider summaries are replayed as reasoning context when available.

### Status

Goals 1 and 2 remain in progress. The branch currently supports these model-access paths:

- ChatGPT Codex through OAuth with `fx login codex`.
- Grok through xAI OAuth with `fx login grok`.
- Direct Responses API access with `OPENAI_API_KEY`, using OpenAI by default or a configurable Responses-compatible base URL.
- The inherited Vercel Gateway route remains present, but its dedicated setup and login onboarding are not a required target for this fork and may be removed as a coherent feature slice.

The direct API-key, Codex, and Grok paths use the Responses protocol, with provider-specific authentication and transport boundaries. This does not mean every OpenAI-compatible or provider-specific protocol is supported. Chat Completions endpoints, broader provider-specific authentication, and additional catalogs and credential stores are still in progress.

For direct API-key access, `FX_RESPONSES_BASE_URL` takes precedence over `OPENAI_BASE_URL`. fx appends `/responses` unless the configured URL already ends with it. Remote bases must use HTTPS; loopback HTTP is accepted only with an explicit port. These generic variables never redirect a Codex OAuth credential away from ChatGPT. `FX_CODEX_BASE_URL` is the separate explicit Codex override.

The inherited Vercel route retains one existing limitation: `FX_GATEWAY_BASE_URL` is honored only for a loopback address because the base URL carries the bearer token. A remote override is ignored rather than used.

Fork changes stay deliberately small and shaped like upstream's own code: divergence costs a merge conflict every time, and a change that fits upstream's structure can still be sent back as a pull request. Bug fixes and features upstream would plausibly accept are contributed to `vercel-labs/fx` rather than kept here. See [AGENTS.md](AGENTS.md) for branch roles, removal boundaries, and the upstream merge routine.

## Install

```bash
curl -fsSL https://fx.sh/setup.sh | bash
```

## Run fx

Sign in with Vercel AI Gateway:

```bash
fx login
```

Or use an eligible ChatGPT subscription through OpenAI Codex OAuth:

```bash
fx login codex
fx
```

Or use an eligible Grok subscription through xAI OAuth:

```bash
fx login grok
fx
```

`fx login codex` and `fx login grok` select that provider and a model from its authenticated catalog. Inside fx, open `/setup` and choose **Switch provider** to move between Gateway, Codex, and Grok. `/model` lists the active provider's fetched models. Subscription model IDs are the raw IDs returned by each authenticated catalog. Use `/logout codex` or `/logout grok` to remove that subscription session without affecting other providers; choosing it again from **Switch provider** starts sign-in.

The OpenAI Codex route uses ChatGPT subscription access directly and never sends its OAuth token to Vercel AI Gateway. The session is stored privately at `~/.fx/chatgpt-auth.json` and refreshed when needed. Its `web_search` tool uses the authenticated Codex search service directly. On supported Codex models, `/fast` requests OpenAI's priority service tier and consumes ChatGPT credits at the higher Fast mode rate.

The Grok route uses subscription access directly at xAI and never sends its OAuth token to Vercel AI Gateway or OpenAI. Its session is stored privately at `~/.fx/grok-auth.json`, refreshed when needed, and used only with the authenticated xAI catalog and Responses API.

For direct BYOK access to the Responses API, set an OpenAI API key:

```bash
export OPENAI_API_KEY="your-key"
fx
```

To use another endpoint that implements the Responses API, set its base URL before running fx:

```bash
export FX_RESPONSES_BASE_URL=https://gateway.example.com/v1
export OPENAI_API_KEY="your-key"
fx
```

`OPENAI_BASE_URL` is also supported when `FX_RESPONSES_BASE_URL` is unset. This path expects the Responses API, not the Chat Completions protocol.

Inside the interactive app, run `/model` to browse the active provider's catalog. After choosing a model, the same picker offers only the reasoning efforts and Fast mode supported by that catalog entry. The **Model** row in `/settings` uses the same flow. `/effort` shows or sets the current reasoning effort, while `/fast` toggles Fast mode for the current model. ACP clients receive the same `model`, `effort`, and `fast_mode` configuration options; the JavaScript SDK exposes `setModel`, `setEffort`, and `setFastMode`. On the Responses wire, Fast mode uses the `priority` service tier. Selecting a model that does not support the current effort or Fast mode clears that stale setting instead of sending an invalid request.

For a direct switch, pass the model, effort, and optional speed in one command:

```text
/model gpt-5.6-sol high fast
/model gpt-5.6-sol xhigh normal
/effort max
/effort auto
/fast
```

Web search follows the selected direct provider instead of routing a direct credential through Vercel. With an OpenAI API key, fx advertises the hosted Responses `web_search` tool only when the current permission policy allows it and retains returned URL citations in the answer. With Codex OAuth, fx uses the Codex `web.run` namespace and the account's `/alpha/search` endpoint, keeping one search-session identity across follow-up search, open, click, and find commands. Standalone search receives only the previous verified user and assistant turn plus the current verified user request; the assistant excerpt is capped at 1,000 estimated tokens, and the in-progress assistant that invoked the tool is excluded.

For a saved conversation, `/compact` uses the active direct Responses provider's remote compaction transport. Codex OAuth and API-key Responses providers append a `compaction_trigger` to a non-streaming `/responses` request. A successful response is stored as the provider's complete opaque replacement output and replayed only while the same provider identity, normalized Responses endpoint, and wire model remain active. Codex checkpoints bind to the ChatGPT account; API-key checkpoints bind to a non-secret key digest plus organization and project. If any binding changes, fx falls back to the portable local summary instead of sending old opaque context to a new provider identity. If a BYOK endpoint does not implement remote compaction, or the request is rejected or unavailable, fx applies local compaction once instead.

For Codex OAuth models, fx also consumes the model catalog's context-budget metadata. The effective context display reserves model-declared headroom, defaulting to 95% of the raw window, and automatic compaction starts when the latest provider-reported total usage reaches the model limit, defaulting to 90% of the raw window. The TUI reports when automatic compaction starts and settles; background remote compaction owns the activity row until the replacement checkpoint is installed or local fallback completes.

To use an AI Gateway API key instead:

```bash
fx setup
```

Run fx from a project:

```bash
cd your_project
fx
```

The current directory becomes the primary workspace. Enter a prompt, or run `/help` to browse interactive commands. Run `/ps` to inspect active durable terminals and background command history; open terminal output from the Ctrl+X process manager, or use `/background logs <id>` for legacy background tasks.

The status line hides the workspace path and Git branch by default. Enable the `Status line workspace` option in `/settings`, run `/statusline workspace`, or set it in `~/.fx/settings.json`:

```json
{
  "statusLine": {
    "workspace": true
  }
}
```

List saved sessions with `fx sessions`. Resume the latest session for the current workspace, or select an exact session ID, through the same command group:

```bash
fx session resume last
fx session resume --id <id>
```

Each interactive session names its terminal tab. The title prefers the session name, falls back to the workspace name, and keeps the active model as secondary context. Renaming or resuming a session updates the tab, and exiting clears the fx-owned title. Noninteractive commands do not emit terminal-title controls.

Run `/feedback` to open the feedback form at `fx.sh/feedback`. It does not create a diagnostic or change the clipboard.

Run `/trace` to create a private Markdown diagnostic with logs, session context, runtime state, permissions, and recent activity. On macOS, fx copies the `.md` file to the clipboard; on other platforms, it saves the file and prints its path. Review and redact the trace before sharing it.

Use `fx ask` for a single request:

```bash
fx ask "explain the changes in this repository"
fx ask --show-thinking "explain the changes in this repository"
```

During a turn, reasoning-capable models show their current activity while they work, then keep a compact recent summary in the transcript. Durable provider summaries are replayed as reasoning context when a session resumes. ACP sessions emit `agent_thought_chunk` updates. `fx ask` writes reasoning to stderr with `--show-thinking`, and `fx ask --json` includes a separate `thinking` field when reasoning is present; it is never merged into `output`.

Inspect usage recorded locally by fx, or query account-wide limits for the
signed-in Codex subscription:

```bash
fx usage --period 7d
fx usage --codex
```

fx starts in `auto` permission mode. Routine understood development actions run directly. Each unresolved action receives one narrow safety review based on the current user request and the exact pending action. A clear result authorizes only that action. A caution or unavailable review holds the action and returns advice to the agent without opening a permission prompt or ending the turn. See [Permissions](https://fx.sh/docs/configure-fx/permissions) for other modes and persistent rules.

JSON and quiet requests stay noninteractive by default. Add `--prompt-permissions` to allow configured approval prompts when stdin is a TTY. Automatic safety review never opens that prompt. Prompt text is written to stderr, so JSON stdout stays parseable and quiet stdout stays empty. Piped or redirected stdin remains noninteractive and fails instead of waiting for approval.

Inside a saved session, `/permissions remember <allow|deny> <tool-name> <arguments-json>` stores an exact confirmed rule without running the action. `/permissions` lists stable rule IDs, and `/permissions revoke <rule-id>` removes a stored rule even when its original workspace or file state has changed.

## Embed fx

fx builds as a native binary or WebAssembly. Applications embedding fx can provide network transport, session storage, configuration, permission handling, and terminal I/O.

| Surface | Use |
| --- | --- |
| `fx acp` | Connect the native agent to editors and other Agent Client Protocol clients. |
| `createFxAgent()` | Embed the agent core in a JavaScript host with `fx-core.wasm`. |
| `createFxTerminal()` | Embed the interactive terminal with `fx-term.wasm`. |

The WebAssembly SDK is experimental. See the [WebAssembly SDK](sdk/README.md), the repository's [ACP usage and fx extensions guide](docs/acp.md), and the hosted [ACP documentation](https://fx.sh/docs/using-fx/acp).

## Extend fx

Add reusable instructions with [skills](https://fx.sh/docs/capabilities/skills), connect external tools through [MCP](https://fx.sh/docs/capabilities/mcp), or delegate independent work to [subagents](https://fx.sh/docs/capabilities/subagents). Project instruction files may link within their scope, and read-only workspace or compatibility skill directories and their primary `SKILL.md` files may link within their owning workspace or home; managed skills, secondary resources, and escaping links remain no-follow. Skills installed via symlinks that resolve outside home or workspace (e.g. Nix store paths) are loaded when their resolved target is inside a directory listed in the `FX_SKILL_SYMLINK_AUTHORITIES` environment variable (colon-separated absolute paths). `fx status` and `fx doctor` report an invalid trusted MCP profile without starting its servers.

## Documentation

Read the [fx documentation](https://fx.sh/docs).

## Build from source

Building fx requires [Zig 0.16.0+](https://ziglang.org/download/):

```bash
git clone https://github.com/vercel-labs/fx.git
cd fx
zig build -Doptimize=ReleaseSafe
./zig-out/bin/fx
```

Run the test suite with `zig build test`. See [CONTRIBUTING.md](CONTRIBUTING.md) for development and contribution guidelines.

## License

[Apache-2.0](LICENSE)

Third-party licenses and attributions are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Credits

Interface sounds by [cuelume](https://github.com/Danilaa1/cuelume).
