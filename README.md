```
 ⠀⠀⠀⠀⠀⠀⣠⣾⣿⣿⣿⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⠀⠀⢰⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⣠⣶⣿⣿⣷⣶⡶⣶⣶⣆⠀⠀⠀⣴⣶⣶⠆
 ⠀⠀⠀⠉⢹⣿⣿⠉⠉⠀⠘⢿⣿⣧⣀⣾⣿⡿⠃⠀             Tiny, open, embeddable, native coding agent.
 ⠀⠀⠀⠀⣼⣿⡏⠀⠀⠀⠀⠀⠻⣿⣿⣿⠟⠀⠀⠀
 ⠀⠀⠀⢀⣿⣿⠃⠀⠀⠀⠀⢠⣦⠘⢿⣿⣷⡀⠀⠀             BYOK-first Responses, Codex, and Grok.
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

Goals 1 and 2 remain in progress. The inherited Vercel product runtime has been
removed; the branch currently supports these model-access paths:

- ChatGPT Codex through OAuth with `fx login codex`.
- Grok through xAI OAuth with `fx login grok`.
- Direct Responses API access with `OPENAI_API_KEY`, using OpenAI by default or a configurable Responses-compatible base URL.

The direct API-key, Codex, and Grok paths use the Responses protocol, with provider-specific authentication and transport boundaries. This does not mean every OpenAI-compatible or provider-specific protocol is supported. Chat Completions endpoints, broader provider-specific authentication, and additional catalogs and credential stores are still in progress.

For direct API-key access, `FX_RESPONSES_BASE_URL` takes precedence over `OPENAI_BASE_URL`. fx appends `/responses` unless the configured URL already ends with it. Remote bases must use HTTPS; loopback HTTP is accepted only with an explicit port. These generic variables never redirect a Codex OAuth credential away from ChatGPT. `FX_CODEX_BASE_URL` is the separate explicit Codex override.

Fork changes stay deliberately small and shaped like upstream's own code: divergence costs a merge conflict every time, and a change that fits upstream's structure can still be sent back as a pull request. Bug fixes and features upstream would plausibly accept are contributed to `vercel-labs/fx` rather than kept here. See [AGENTS.md](AGENTS.md) for branch roles, removal boundaries, and the upstream merge routine.

## Install

Download the archive for your platform from [GitHub Releases](https://github.com/acking-you/fx/releases), or build this fork from source using the steps in [Build from source](#build-from-source). Windows x86_64 releases are published as `fx-windows-x86_64.zip` and include `fx.exe`.

## Run fx

Use an eligible ChatGPT subscription through OpenAI Codex OAuth:

```bash
fx login codex
fx
```

Or use an eligible Grok subscription through xAI OAuth:

```bash
fx login grok
fx
```

If Codex CLI or Grok Build is already signed in, import every compatible OAuth
session in one step instead of logging in again:

```bash
fx setup
```

The same provider-neutral importer is available inside the TUI as `/setup` and
through ACP. It reads Codex CLI's `auth.json` from `CODEX_HOME` or `~/.codex`
and Grok Build's `auth.json` from `GROK_HOME` or `~/.grok`. Source files are
read-only, existing fx provider logins are never overwritten, and each
provider reports `imported`, `already_configured`, `not_found`, `incompatible`,
`invalid`, or `unavailable`. Setup never changes the selected provider; use
`/provider codex` or `/provider grok` afterward. Use `fx setup --json` for
structured output.

`fx login codex` and `fx login grok` select that provider and a model from its authenticated catalog. Inside fx, use `/provider` to choose between BYOK Responses, Codex, and Grok, or switch directly with `/provider gateway`, `/provider codex`, or `/provider grok`. Provider credential refresh, catalog loading, and durable subscription logout run in the background, so the composer, status commands, and terminal activity remain responsive while those operations settle. `/login` is reserved for provider sign-in and credential selection. `/model` lists the active provider's fetched models. Subscription model IDs are the raw IDs returned by each authenticated catalog. Use `/logout codex` or `/logout grok` to remove that subscription session; selecting the provider again starts sign-in when needed.

The OpenAI Codex route uses ChatGPT subscription access directly. The session is stored privately at `~/.fx/chatgpt-auth.json` and refreshed when needed. Its unified `web_search` tool uses the authenticated Codex search service directly. On supported Codex models, `/fast` requests OpenAI's priority service tier and consumes ChatGPT credits at the higher Fast mode rate.

The Grok route uses subscription access directly at xAI. Its session is stored privately at `~/.fx/grok-auth.json`, refreshed when needed, and used only with the authenticated xAI catalog and Responses API. Models whose authenticated catalog entry enables backend search receive xAI's hosted web-search tool by default.

For direct BYOK access to the Responses API, set an OpenAI API key:

```bash
export OPENAI_API_KEY="your-key"
fx
```

On Windows PowerShell, use:

```powershell
$env:OPENAI_API_KEY = "your-key"
.\fx.exe
```

To use another endpoint that implements the Responses API, set its base URL before running fx:

```bash
export FX_RESPONSES_BASE_URL=https://gateway.example.com/v1
export OPENAI_API_KEY="your-key"
fx
```

`OPENAI_BASE_URL` is also supported when `FX_RESPONSES_BASE_URL` is unset. This path expects the Responses API, not the Chat Completions protocol.

To persist a Responses URL and API key without putting them in the process environment:

```bash
fx provider gateway https://gateway.example.com/v1 your-key
```

Inside the interactive app:

```text
/provider gateway https://gateway.example.com/v1 your-key
```

fx validates the model catalog, then stores that pair privately at `~/.fx/gateway-auth.json`. Ordinary requests, catalog loading, automatic permission review, remote compaction, and child turns use the binding. Running turns and prompts queued during compaction retain the route captured at submission; later submissions use a replacement. Provider commands containing credentials are excluded from input history. `/logout gateway` or `fx logout gateway` removes the saved pair; an existing environment configuration then becomes available again. Native ACP `fx/provider/configure` writes the same profile binding. A failed save reports an error and keeps the active binding. During activation, prompt submission keeps your draft in the composer; submit it after the switch finishes.

Inside the interactive app, run `/model` to browse the active provider's catalog. After choosing a model, the same picker offers only the reasoning efforts and Fast mode supported by that catalog entry. The **Model** row in `/settings` uses the same flow. `/effort` shows or sets the current reasoning effort, while `/fast` toggles Fast mode for the current model. ACP clients receive the same `model`, `provider`, `effort`, and `fast_mode` configuration options. Native ACP also exposes provider login plus profile-persisted BYOK URL and API-key configuration without requiring those secrets in the process environment; persistent child turns keep their own provider route even when the parent switches or the connection binding is replaced. See [ACP usage](docs/acp.md#provider-control). The JavaScript SDK exposes `setModel`, `setEffort`, and `setFastMode`. On the Responses wire, Fast mode uses the `priority` service tier. Selecting a model that does not support the current effort or Fast mode maps that setting onto the model's catalog default, or clears it, instead of sending an invalid request. `auto` keeps the model's own default on the wire, so Grok 4.6 uses `high` unless you pick another supported level.

For a direct switch, pass the model, effort, and optional speed in one command:

```text
/model gpt-5.6-sol high fast
/model gpt-5.6-sol xhigh normal
/effort max
/effort auto
/fast
```

fx exposes one provider-neutral `web_search` capability to the agent and projects it only at the selected provider boundary. Codex OAuth uses the Codex `web.run` namespace and the account's `/alpha/search` endpoint, keeping one search-session identity across follow-up search, open, click, and find commands. Direct OpenAI-compatible Responses models use the native hosted `web_search` declaration. Grok models use xAI hosted search when their authenticated catalog advertises backend-search support, and completed `web_search_call` items are replayed with later turns. If a direct Responses or Grok model cannot perform native search, fx can use a separately configured Responses search model by setting `FX_WEB_SEARCH_API_KEY` and `FX_WEB_SEARCH_MODEL`; `FX_WEB_SEARCH_BASE_URL` optionally selects another Responses-compatible base instead of OpenAI. Without either route, fx does not advertise a tool that cannot run. Hosted and local searches publish the same TUI, ACP, CLI, and child-session lifecycle. See [Unified web search](docs/web-search.md) for the routing contract.

Manual `/compact`, automatic threshold compaction, context-overflow recovery, TUI, and ACP all use one strategy ladder. An eligible Responses route first requests the provider's native opaque checkpoint. If the route does not support remote compaction or that request is rejected or unavailable, the active model creates a structured full-replacement summary with tools disabled. fx fits recent history to the model window, retries invalid summaries and transient provider failures, and uses a bounded deterministic summary only when model compaction still cannot complete. Fallback notices include the recorded failure reason. See [Unified context compaction](docs/compaction.md) for the lifecycle and failure semantics.

Long turns release temporary request and recovery-snapshot buffers after each operation. Sustained inspections that keep returning known evidence receive a progress reminder, then stop with their history saved if the loop continues. A follow-up prompt can resume work. Useful new evidence, writes, tests, polling, and failed requests remain supported without lowering the default step limit. See [Long-turn memory and repeated inspections](docs/long-turn-memory.md) for the guard and bounded memory measurements.

A successful remote response is stored as the provider's complete opaque replacement output and replayed only while the same provider identity, normalized Responses endpoint, and wire model remain active. Codex checkpoints bind to the ChatGPT account; API-key checkpoints bind to a non-secret key digest plus organization and project. The portable summary is kept beside that checkpoint so a later binding change never sends opaque context to a different identity.

fx consumes each model catalog's context-budget metadata for every provider. The effective context display reserves model-declared headroom, defaulting to 95% of the raw window, and automatic compaction starts when the latest provider-reported total usage reaches the model limit, defaulting to 90% of the raw window. The TUI reports when automatic compaction starts and settles; the background task owns the activity row until the chosen replacement is installed, while ordinary input remains queued for the next turn.

BYOK Responses catalogs can explicitly advertise hosted search with `supports_backend_search` (or `supportsBackendSearch`), independent of model naming. Explicit capability denials are respected. Catalog `reasoning_efforts`, `context_window`, and output limits also apply to custom model IDs. Invalid provider token counts are reported as an accounting error without silently inventing usage or retrying the completed request.

Run fx from a project:

```bash
cd your_project
fx
```

The current directory becomes the primary workspace. Enter a prompt, or run `/help` to browse interactive commands. Run `/ps` to inspect Unified Exec commands that crossed their yield window as well as active durable terminals; open hosted-terminal output from the Ctrl+X process manager. Press Ctrl+V to attach an image from the clipboard, or run `/paste`; macOS uses the native pasteboard, Linux uses `wl-paste` or `xclip`, and WSL can bridge through PowerShell.

Closed `mermaid` code fences render as bounded Unicode diagrams directly in the TUI. Flowcharts, state diagrams, class diagrams, entity-relationship diagrams, and sequence diagrams are supported. Unsupported syntax and diagrams that do not fit the terminal remain visible as ordinary source code blocks.

With a Codex subscription login, the status line also shows remaining account windows such as `5h 88% · week 65%`. Codex Pro accounts without a 5-hour window show only the weekly remaining. A Grok subscription login shows the current billing window, such as `week 57%`. `fx usage --codex` prints the full Codex account snapshot.

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

Each interactive session names its terminal tab. The title prefers the session name, falls back to the workspace name, and keeps the active model as secondary context. While a turn is running, the title uses a low-frequency spinner so terminal tabs expose unfinished work without forcing full-frame redraws. Renaming or resuming a session updates the tab, and exiting clears the fx-owned title. Noninteractive commands do not emit terminal-title controls. Submitting another prompt during an active model turn steers that same turn at its next model-step boundary without cancelling the request already in flight. The footer identifies pending steering explicitly. If the turn finishes before fx can consume the input, it remains a normal next-turn follow-up instead of being lost. Input submitted while between-turn compaction owns the runtime still queues for the next turn.

Press Ctrl+O to open the complete transcript. The reader keeps tool details,
turn metadata, and final command output while loading bounded pages outside the
UI thread, so large sessions remain navigable without rebuilding the whole
transcript on every scroll. The `Collapse tool calls` option in `/settings`
keeps the normal transcript compact while Ctrl+O continues to show full detail.

Run `/trace` to create a private Markdown diagnostic with logs, session context, runtime state, permissions, and recent activity. On macOS, fx copies the `.md` file to the clipboard; on other platforms, it saves the file and prints its path. Review and redact the trace before sharing it.

Use `fx ask` for a single request:

```bash
fx ask "explain the changes in this repository"
fx ask --show-thinking "explain the changes in this repository"
```

During a turn, reasoning-capable models show an animated `Thinking` activity row while no visible response is available; once assistant text streams, that text becomes the progress surface and the redundant status row is hidden. Durable provider summaries are replayed as reasoning context when a session resumes. ACP sessions emit `agent_thought_chunk` updates. `fx ask` writes reasoning to stderr with `--show-thinking`, and `fx ask --json` includes a separate `thinking` field when reasoning is present; it is never merged into `output`.

Inspect usage recorded locally by fx, or query account-wide limits for the
signed-in Codex subscription:

```bash
fx usage --period 7d
fx usage --codex
```

Codex and Grok OAuth use one provider-neutral login boundary. ACP clients may
omit `provider` from `fx/provider/login/start`; fx detects an existing Codex
session first and falls back to Grok when Codex is not connected. The active
session's aggregate usage is available through the same summary used by the
TUI footer (`Usage: Nk`) and ACP `fx/provider/usage`; this local endpoint never
blocks on a remote quota request. See [Unified OAuth and usage](docs/unified-oauth-usage.md).

With `--json`, `output` contains accumulated assistant Markdown across the request, while `final_output` contains only a completed final assistant response and is `""` for interrupted, failed, background, or otherwise absent final responses.

Model shell execution has one Codex-style Unified Exec family: `exec_command` starts a command and `write_stdin` polls or interacts with that same process. There is no `!command`, second model-facing command executor, or command-shaped skill shortcut. `exec_command` defaults to a 10-second yield window; a still-running command becomes a background task and returns a numeric session ID that also appears in `/ps`. In the default Codex mode the model keeps the turn active and calls `write_stdin` with empty `chars` to wait for more output. Non-empty `chars` is reserved for interaction with a `tty=true` command; non-TTY sessions accept only control-C. The shell defaults to the user's configured shell. On Windows, fx prefers an installed Git Bash and otherwise keeps the native configured-shell fallback; the shared tool projection tells the model which command syntax is active. Output is continuously drained, bounded, UTF-8 safe, and streamed into the active TUI tool row without waiting for command completion. TUI, ACP, noninteractive CLI, and child sessions share the same lifecycle labels: `Running` becomes `Ran`, while empty polls and input use `Waiting/Waited` and `Interacting/Interacted`. Yielding never kills the process, and the manager keeps sessions alive across turns until they exit or the owning fx session is closed. Hosts without native process support advertise neither tool and do not fall back to the removed `terminal` API.

`/exec-mode claude` enables an optional session-local detached-loop policy. A command that crosses its yield window finishes the current model turn so the user can continue working. Command completion, failure, or a five-minute running watchdog schedules a separate continuation turn; ordinary user prompts take priority if both are queued. `/exec-mode codex` restores the default. A running turn keeps the mode it captured when it started.

For codebase discovery, `/bash-first` (or ACP `fx/toolMode/set`) hides the overlapping `list_files`, `glob_files`, `grep_files`, and `semantic_search` tools and tells the model to use the unified shell with `rg` and `rg --files`. The setting applies to the next turn and can be toggled back to the standard projection at any time. See [Bash-first workspace mode](docs/bash-first-mode.md).

The hosted terminal engine remains available for explicit interactive terminal takeover and replay. It is separate from the model-facing command tools and is not used as a shell fallback.

fx starts in `auto` permission mode. Routine understood development actions run directly. Each unresolved action receives one narrow safety review based on the current user request and the exact pending action. A clear result authorizes only that action. A caution or unavailable review holds the action and returns advice to the agent without opening a permission prompt or ending the turn.

`web_fetch` is a direct bounded HTTP client. It does not run fx permission rules, automatic review, or approval prompts, and it accepts public, private, local, metadata, and credential-bearing HTTP(S) targets while following redirects across hosts, protocols, and ports. Timeouts, cancellation, response framing checks, and body-size limits still bound transport resource use.

JSON and quiet requests stay noninteractive by default. Add `--prompt-permissions` to allow configured approval prompts when stdin is a TTY. Automatic safety review never opens that prompt. Prompt text is written to stderr, so JSON stdout stays parseable and quiet stdout stays empty. Piped or redirected stdin remains noninteractive and fails instead of waiting for approval.

Inside a saved session, `/permissions remember <allow|deny> <tool-name> <arguments-json>` stores an exact confirmed rule without running the action. `/permissions` lists stable rule IDs, and `/permissions revoke <rule-id>` removes a stored rule even when its original workspace or file state has changed.

## Embed fx

fx builds as a native binary or WebAssembly. Applications embedding fx can provide network transport, session storage, configuration, permission handling, and terminal I/O.

| Surface | Use |
| --- | --- |
| `fx acp` | Connect the native agent to editors and other Agent Client Protocol clients. |
| `createFxAgent()` | Embed the agent core in a JavaScript host with `fx-core.wasm`. |
| `createFxTerminal()` | Embed the interactive terminal with `fx-term.wasm`. |

The WebAssembly SDK is experimental. See the [WebAssembly SDK](sdk/README.md) and the repository's [ACP usage and fx extensions guide](docs/acp.md).

Native ACP clients receive stable command tool-call IDs, structured input,
stream-aware output updates, and the final command result. They can also interact with a running Unified Exec process
directly through `fx/unifiedExec/writeStdin` and `fx/unifiedExec/kill`; those
control requests remain responsive while a model-side output poll is waiting,
and ACP output observation does not consume the model-facing output stream.
ACP clients also receive native `session/update` plan snapshots for the normal
`update_plan` tool, including complete step status replacement and an optional
explanation. See the [ACP guide](docs/acp.md#plan-visualization) for the exact
wire shape and session/process ID contract. Vision-capable models
accept standard ACP base64 image prompt blocks and persist verified image
snapshots.

## Extend fx

Add reusable instructions and supporting resources with skills, or delegate independent work to subagents. This fork intentionally does not include MCP configuration, transports, tools, menus, or authentication; skills are its extension mechanism. Existing `~/.fx/mcp.json` and project `.mcp.json` files are ignored and can be removed. Project instruction files may link within their scope, and read-only workspace or compatibility skill directories and their primary `SKILL.md` files may link within their owning workspace or home; managed skills, secondary resources, and escaping links remain no-follow. Skills installed via symlinks that resolve outside home or workspace (e.g. Nix store paths) are loaded when their resolved target is inside a directory listed in the `FX_SKILL_SYMLINK_AUTHORITIES` environment variable (colon-separated absolute paths).

## Build from source

Building fx requires [Zig 0.16.0+](https://ziglang.org/download/):

```bash
git clone --branch byok https://github.com/acking-you/fx.git
cd fx
zig build -Doptimize=ReleaseSafe
./zig-out/bin/fx
```

On Windows PowerShell, run the built executable as `.\zig-out\bin\fx.exe`.

Run the test suite with `zig build test`. See [CONTRIBUTING.md](CONTRIBUTING.md) for development and contribution guidelines.

## License

[Apache-2.0](LICENSE)

Third-party licenses and attributions are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Credits

Interface sounds by [cuelume](https://github.com/Danilaa1/cuelume).
