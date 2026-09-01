# AGENTS.md

Instructions for AI coding agents working with this codebase.

## This Fork and Its Branches

This checkout is `acking-you/fx`, a fork of the upstream `vercel-labs/fx`. It is not a divergent rewrite: upstream remains the source of truth for the shared codebase, and this fork stays close enough to keep merging from it indefinitely.

### Vision for `byok`

`byok` ("bring your own key") is the development branch and the default place to work. It pursues three goals, stated for users in [README.md](README.md):

1. **Remove every hard binding to Vercel.** No default path may assume a Vercel account, gateway, key, setup flow, or login. Generic provider contracts and useful optional transports may remain, but preserving Vercel-specific onboarding such as `fx setup` is not a goal of this fork.

2. **Support any BYOK provider.** Configurable base URLs, credentials from the environment or a local store rather than one vendor's login, and model catalogs that are not the upstream default, so an OpenAI-compatible endpoint, corporate proxy, or local server works.

3. **Improve the agent harness.** Better default agent behavior even where upstream keeps it optional or absent, such as always showing streamed model reasoning and replaying it as reasoning context.

Local experiments that upstream would not want also belong here. The Vercel product route has been removed; generic gateway contracts remain only where they serve the direct BYOK, Codex, or Grok transports. Goal 2 is still incomplete, so read the code before assuming an endpoint, protocol, catalog, or credential source already works.

Keep `byok` changes as small and as close to upstream structure as possible. Every unnecessary divergence is a future merge conflict, and a change shaped like upstream's own code is one that can still be offered back.

### Branch roles

| Branch | Role |
| --- | --- |
| `byok` | Fork development. Default branch for new work. Receives merges from `upstream`. |
| `upstream` | Clean mirror of `vercel-labs/fx` `main`. Never commit here directly; it only ever fast-forwards to the upstream remote. |
| `main` | Base for pull requests sent to upstream. |
| `fix/*`, `feat/*` | Focused branches, usually cut for a single upstream pull request. |

Remotes: `origin` is `acking-you/fx`; `vercel` is `vercel-labs/fx`.

### Merging upstream

Upstream is merged into `byok` periodically so the fork never accumulates a large, unreviewable delta. The routine:

1. `git fetch vercel`
2. Fast-forward the mirror: `git branch -f upstream vercel/main` (it must fast-forward; if it cannot, the mirror was committed to by mistake).
3. `git switch byok && git merge --no-commit upstream`
4. Resolve conflicts in favor of upstream's structure while keeping the fork's behavior. Before committing, inspect the staged first-parent result with `git diff --cached HEAD -- README.md AGENTS.md` and restore any fork-owned material.
5. Commit the merge, then verify the recorded result with `git diff HEAD^1 HEAD -- README.md AGENTS.md`. Build, run the focused tests for every conflicted path, and run the binary per **Declaring Work Ready**.

Prefer a merge over a rebase: `byok` is shared, and a rebase would rewrite published history.

Upstream frequently changes counts and layout that fork tests assert (command totals, settings rows, menu geometry). Expect to update those fixtures as part of the merge rather than treating them as regressions.

A clean merge is not proof that fork-owned documentation survived. Preserve and adapt the `About this fork` section, the BYOK maintenance commitment and status, provider configuration, fork-specific examples, and these repository instructions. Upstream wording may be incorporated, but it must not silently delete or replace the fork's contract.

### BYOK protected behavior inventory

The following fork-owned behavior is a merge boundary, not disposable drift. An upstream merge may reorganize these files, but it must preserve the contracts they implement and their focused regression coverage:

* Codex Responses is the default ChatGPT login route, including its account-bound `/responses` endpoint, beta headers, opaque remote-compaction trigger, and encrypted-reasoning replay (`src/core/gateway/provider_route.zig`, `src/core/gateway/responses_compaction_binding.zig`, `src/gateway/openai_responses.zig`, `src/gateway/client.zig`).
* Every semantic compaction entrypoint uses the single strategy owner in `src/core/agent/runtime/compaction.zig`: eligible Responses routes try the native opaque checkpoint first, then the active model produces a validated full-replacement summary, and a bounded deterministic projection is the final availability fallback. TUI compaction remains asynchronous at the UI boundary, persists its lifecycle/checkpoint, and keeps ordinary input queued for the next turn. ACP, inline overflow recovery, manual compaction, automatic compaction, and turn-window projection must not grow separate fallback policy or summary algorithms (`src/core/agent/runtime/compaction.zig`, `src/core/app/app_session_runtime.zig`, `src/core/session/session.zig`, `src/acp/prompt.zig`).
* Worker and gateway callbacks enqueue stream/reasoning/compaction events; transcript mutation and rendering stay on the UI thread. Streamed tokens must remain visible in the current frame and must not be delayed by native scrollback (`src/core/app/app_callbacks.zig`, `src/core/app/app_worker_runtime.zig`, `src/ui/transcript/runtime.zig`).
* Interactive input admitted during an active model turn is same-turn steering, not a next-turn queue by default. The agent consumes it at the next model-step boundary, transcript presentation remains on the UI thread, and an input that loses the completion race falls back to an ordinary next-turn prompt without duplication or loss. Between-turn compaction keeps its separate next-turn queue contract (`src/core/agent/worker_runtime.zig`, `src/core/agent/runtime/orchestrator.zig`, `src/core/app/app_callbacks.zig`, `src/ui/footer/input_presentation.zig`).
* BYOK provider configuration remains generic and Vercel onboarding stays removed. Do not reintroduce Vercel setup/login, silently replace the fork README contract, or restore vendor-specific defaults while resolving conflicts.
* `/provider` owns TUI provider selection while `/login` owns authentication and credential selection. Credential refresh, catalog loading, durable logout, cancellation, and worker reaping stay off the TUI event loop; logout cancels only an activation for the provider being removed. Native ACP advertises `_meta.fx.providerControl` and supports provider switch, Codex and Grok login, and connection-scoped BYOK URL plus API-key configuration without blocking its read loop. Treat that custom URL and key as one binding: preserve it across temporary provider switches and use it for ordinary requests, automatic permission review, remote compaction, and persistent child turns. A background child builds its tool context only from its owned route snapshot until that turn ends, so connection reconfiguration cannot free or redirect it (`src/core/auth/provider_activation.zig`, `src/core/auth/provider_logout.zig`, `src/core/app/app_auth_runtime.zig`, `src/acp/server.zig`, `src/acp/prompt.zig`).
* ACP Unified Exec control remains nonblocking while the model waits on the same process. Direct ACP observation uses an independent output cursor and never consumes the model-facing stream or claims model-owned terminal cleanup (`src/core/execution/unified_exec.zig`, `src/acp/prompt.zig`).
* Codex and Grok subscription OAuth use the provider-neutral boundary with deterministic stored-session detection (Codex first, Grok fallback). TUI and ACP provider usage expose the same aggregate-only snapshot; remote quota I/O must not run on either event loop (`src/core/auth/provider_oauth.zig`, `src/core/session/provider_usage.zig`, `src/acp/server.zig`, `src/ui/render.zig`).
* Bash-first is an explicit, session/connection-local tool projection preference. `/bash-first` in the TUI and `fx/toolMode/set` in ACP must hide overlapping workspace discovery/search helpers (`list_files`, `glob_files`, `grep_files`, `semantic_search`) while preserving the unified shell, read/write tools, and Codex-style `rg`/`rg --files` guidance. A running turn keeps its captured projection; changes apply to the next turn (`src/core/tooling/tool_projection.zig`, `src/core/app/app_commands.zig`, `src/acp/server.zig`).
* Unified Exec lifecycle presentation is shared across TUI, ACP, noninteractive CLI, and child sessions. Active commands use `Running`, successful commands use `Ran`, and `write_stdin` uses `Waiting/Waited` or `Interacting/Interacted`; ACP terminal updates replace the active title instead of leaving stale progress text (`src/core/tooling/tool_presentation.zig`, `src/acp/prompt.zig`).
* Model-facing shell execution has exactly one tool family: `exec_command` starts the process and `write_stdin` polls or interacts with it. Do not add command-shaped compatibility hooks, skill shortcuts, or a second executable backend. Historical `run_command` records may remain readable for session replay but must never become executable. Unified Exec pipe readers queue bounded owned chunks and never invoke transport or UI callbacks while holding the process-control lock. Output reaches the normal queued TUI worker-event path and stable ACP tool-call updates with structured input, stream identity, incrementally valid UTF-8, bounded accumulated output, and the final command result (`src/tools/shell/unified_exec.zig`, `src/core/execution/unified_exec.zig`, `src/core/tooling/tool_dispatch.zig`, `src/acp/prompt.zig`).
* Model-facing web search has one logical `web_search` capability. Provider projection is centralized: Codex subscription projects it to the reserved `web.run` namespace and account-bound standalone endpoint, compatible Responses routes project it to hosted `web_search`, and Grok uses hosted search only for catalog-confirmed backend-search models. Only the separately configured Responses search client is eligible as a local fallback when native search is unavailable. Hosted calls retain provider output order and publish the same lifecycle to TUI, ACP, CLI, and child sessions (`src/core/gateway/web_search_projection.zig`, `src/core/gateway/provider_set.zig`, `src/gateway/configured_responses_search.zig`, `src/gateway/openai_codex.zig`, `src/gateway/openai_responses.zig`, `src/gateway/xai_grok.zig`).
* `web_fetch` is a direct bounded HTTP client. It bypasses fx allow, ask, and deny rules, automatic review, and human approval, and it accepts public, private, local, metadata, and credential-bearing HTTP(S) targets plus cross-boundary redirects. Only HTTP representability and resource bounds remain (`src/builtins/tools.zig`, `src/core/tooling/tool_admission.zig`, `src/tools/web/url.zig`, `src/tools/web/http_fetch.zig`).

After every upstream merge, inspect the first-parent diff for these paths and run focused tests for each changed boundary. Search for stale `selected_model` compile guards, synchronous compaction admission, direct callback transcript mutation, delayed newline-less stream handling, and Vercel setup/login entrypoints before declaring the merge safe.

### Contributing back to upstream

When a change on this fork is a bug fix or a feature upstream would plausibly accept, send it to `vercel-labs/fx` as a pull request instead of letting it live only here. Fewer fork-only patches means less merge cost forever.

Cut the branch from `main` (not `byok`) so the pull request carries only that change and none of the fork's opinionated defaults. Follow upstream's own rules in **Pull Request Classification** and **Before Marking a PR Ready** — a PR from a fork is held to the same standard as any other. Keep BYOK-specific behavior out of it: if a fix is entangled with fork defaults, split the upstreamable part out first.

## Declaring Work Ready

Do not say the work is "ready", "done", "good to go", "complete", or similar until you have personally run the binary and exercised the change on its happy path. A passing test suite is necessary, not sufficient — tests in this repo do not always construct the full runtime, attach a TTY, or spawn background threads, so they will not catch startup crashes, render regressions, or thread-lifetime bugs.

Before reporting the work as ready:

1. Build succeeds.
2. Focused tests for the changed path pass locally.
3. The **Full CI** run for the exact current commit passes on every required Linux and macOS runner.
4. Run the built binary locally and drive at least one real interaction that exercises the change end to end. If the change touches streaming display (assistant tokens, thinking, tool output, notices), drive a live stream in the TUI, not only `--help` or a unit test.
5. Confirm the process did not abort, stderr is clean, and the behavior matches what you are about to tell the user. A SIGABRT, SIGSEGV, or "segmentation fault (core dumped)" on the happy path means the work is not done, even if tests passed.

If you cannot run the binary in your environment, say so explicitly and ask the user to verify. Do not silently skip this step and declare the work ready. "The tests pass" is not a substitute for running the app.

### Always use the built binary in this repo

When running fx for verification, **always use the freshly-built binary at** **`./zig-out/bin/fx`** from this checkout. Never run `fx` from `PATH`, never rely on whatever is at `~/.fx/bin/fx`, and never assume an installed copy reflects your change.

* The user may have an older `fx` on their PATH. Running that one will not exercise your edits.

* `zig build` writes to `zig-out/bin/fx`. That is the only binary that contains your latest change.

* When a user reports "still not working" after you believe you fixed something, do not assume they are running the wrong binary. Assume your fix is incomplete and investigate further. If you genuinely suspect a PATH mismatch, ask — do not silently copy binaries into `~/.fx/bin/`.

* In any shell invocation — tmux, direct run, scripts — reference fx as `/Users/<you>/path/to/repo/zig-out/bin/fx` (absolute) or `./zig-out/bin/fx` (when cwd is the repo root). Bare `fx` is always wrong for dev verification.

## Language and Toolchain

This project is written in **Zig 0.16+**. There is no Node.js runtime, no `package.json` at the root, and no JavaScript build step for the main binary.

Build and test commands:

```bash
zig build          # build the binary
zig build test     # run all unit tests
zig build run      # build and run
zig fmt src/       # format all source files
```

The test suites under `tests/` use Bun but are separate from the Zig codebase. See **Testing** below.

## Code Style

* Format all Zig source with `zig fmt` before committing. The canonical check is `zig fmt src/`.

* Do not use emojis in code, output, or documentation. Unicode symbols (e.g. checkmark, arrow) are acceptable.

* In documentation, never use double hyphens (`--`) as a dash. Use an emdash (—) sparingly, or rewrite to avoid dashes.

* CLI flags use kebab-case (e.g. `--no-save`, `--json`). Never use camelCase for flags.

* Prefer `snake_case` for all Zig identifiers. Types use `PascalCase` per Zig convention.

* Keep `pub` surface area minimal. Only mark declarations `pub` when they are used outside the file.

## Architecture

Key rules:

* `src/main.zig` is the composition root. Do not add leaf feature logic here.

* `src/core/` owns contracts, runtimes, config, sessions, permissions, and skills. MCP is intentionally unsupported in this fork; do not reintroduce its configuration, transports, tools, menus, or authentication.

* `src/tools/` owns built-in tool implementations. Generic tool contracts and dispatch live in `src/core/tooling/`. Default tool specs are centralized in `src/core/tooling/tool_specs.zig` or `src/builtins/tools.zig`, not in individual tool files.

* `src/ui/` owns terminal rendering, event loop, input, transcript. It must not own product state.

* Agent and gateway callbacks are not the UI thread. They may queue `WorkerEvent`s. They must not mutate the transcript store or other render state. Apply those mutations on worker-event drain. See **Memory Safety**.

* `src/gateway/` owns provider transport. It must not absorb product-state logic.

* `src/acp/` owns the ACP (Agent Client Protocol) JSON-RPC 2.0 server.

### Adding a Feature

Before implementing, answer in order:

1. Which module owns the behavior?
2. What is the typed contract?
3. Does it need persistence?
4. Does it need both text and JSON output?
5. What docs and tests land with it?
6. How is its deterministic E2E owner classified in the macOS arm64 PGSO corpus?

If unclear, define the contract first.

Every root `tests/e2e/*.test.ts` file must have exactly one classification in
`scripts/pgso/corpus.json`:

* **Training:** common or performance-sensitive product behavior that should
  influence LLVM's hot and cold decisions

* **Verification-only:** important correctness, recovery, security, or rare
  behavior that the final candidate must pass without making it hot

* **Intentional exclusion:** nondeterministic, live-network, credentialed,
  sound-related, or harness-only coverage, with a concrete reason

New tests inside an already classified file inherit that file's classification,
but feature work must reconsider whether the existing classification still
matches the file's product role. When removing a feature or E2E owner, remove
its stale corpus entry. Normal PR CI loads the corpus and rejects missing,
duplicate, stale, or unclassified files without running the expensive PGSO
qualification.

### Removing Fork-Unneeded Features and Tests

`byok` does not retain upstream code merely because upstream ships it. Treat a feature as a removal candidate when it conflicts with the BYOK vision, duplicates or conflicts with a fork-owned implementation, or adds a product capability this fork does not need. Vercel-specific setup and login onboarding are examples of extra product surface that the fork is not committed to preserving.

Trace live entrypoints and dependencies before deleting anything. A generic protocol, provider contract, or transport that remains useful to BYOK must not be removed only because it originated in Vercel code or still uses a Vercel name. Conversely, upstream origin is not a reason to preserve a vendor-specific product flow that has no remaining fork use.

Keep tests that protect real product behavior, including stability, crashes, recovery, security boundaries, resource limits, portability, and reproduced user-visible bugs. Remove tests whose only owner is a removed feature, duplicate assertions already covered at the proper boundary, unrelated assertions attached to another scenario, brittle upstream layout or count snapshots with no product contract, and harness-only coverage that cannot fail for a meaningful runtime regression.

Do not delete a test solely to make CI green. First diagnose the failure and establish that the assertion is redundant, meaningless, or belongs to an unsupported feature. When removing a feature, remove its complete vertical slice in the same change: entrypoints, dispatch, configuration, state, protocol and UI wiring, documentation, tests, fixtures, and any PGSO corpus entry. Prefer the smallest coherent deletion, then build, run focused tests, and exercise the affected real runtime path.

### Applying Code Review Findings

Do not change code merely because a review finding is theoretically valid. Before implementing it, trace the production entrypoint and classify it using realistic trigger conditions, expected frequency, user impact, and available runtime or incident evidence.

Treat a finding as actionable for the current change when it affects a normal supported workflow, reproduces an observed failure, or has a plausible path to a crash, data loss, credential exposure, security-boundary violation, or persistent user-visible corruption. A concurrency concern that requires a contrived sequence of rapid, contradictory user actions and has no production evidence is normally not a hotfix. Explain the sequence and rationale in the review, then defer or close it instead of adding state, synchronization, compatibility logic, or tests solely to satisfy the reviewer.

When priority is uncertain, first seek the smallest source or runtime proof that distinguishes a reachable product bug from a hypothetical race. Keep accepted fixes proportional to the proven risk and keep rejected findings out of the implementation and test surface.

### Adding a Command

1. Add the spec to `src/core/slash_commands/command_specs.zig`
2. Add dispatch wiring in `src/core/cli/cli_surface.zig`
3. Add a snapshot type if it has structured output
4. Render text and JSON from the same snapshot via `src/core/output/output_contracts.zig`

Do not scatter help text or argument parsing across multiple files.

## Configuration and State

Profile configuration and runtime state lives under `~/.fx/`. Project `.fx.json` contains committed project defaults only.

Config precedence (highest wins):

1. Environment variables such as `FX_MODEL`, `FX_PERMISSION_MODE`, and `FX_MAX_AGENT_STEPS`
2. `~/.fx/settings.json` → `workspaces["<workspace_path>"]` (profile workspace overrides)
3. `~/.fx/settings.json` top-level (profile global settings)
4. `<workspace>/.fx.json` (committed project defaults)
5. Built-in defaults

Project `.fx.json` accepts only repo-safe defaults: `sandbox`, `max_agent_steps`, `max_tool_result_bytes`, and `context`. Profile-owned keys such as `model`, `effort`, `fast_mode`, `slash_menu_categories`, `startup_scrollback`, `prompt_history`, `statusLine`, `skill_match_fuzzy`, `first_call_tool_choice`, `permission_mode`, `credential_source`, and `permission` are ignored from project config before their values are parsed.

Runtime state lives under `~/.fx/sessions/<session-id>/` (`session.json`, `background/`, `subagent/`, `logs/`). Sessions are global and portable across workspaces — each session tracks its `workspace_root` which updates when resumed in a different workspace. A subagent child is an ordinary session with its own directory; `subagent/` holds create-operation identities on a parent and the control record on a child.

## Permissions

Security is permission-first. All sensitive tool behavior must integrate with `src/core/permissions/permissions.zig`.

* `permission_mode` controls baseline (`ask`, `auto`, or `yolo`). Yolo bypasses fx permission policy and uses an effective sandbox of `none` without rewriting saved sandbox configuration

* Configured denies are evaluated before saved-session rules; an exact saved-session deny can narrow a configured allow, while an exact saved-session allow can satisfy an unresolved configured ask

* Session `always` approvals are non-persistent; command approvals match the exact command while other grant categories may use patterns

* `/permissions remember allow|deny <tool-name> <arguments-json>` confirms and stores an exact rule only for an active saved session; list and revoke those rules by their stable IDs

* Routine parsed development commands and reversible new-file creation can execute without model review after configured and saved-session policy. Every remaining unresolved `auto` action receives one review using the current proven root request, the exact action and targets, origin and call identity, optional host-proven current-branch evidence, exact-copy provenance, and bounded masked terminal-safe excerpts of earlier current-turn tool results. Those excerpts are untrusted evidence and never authority; assistant prose, permission feedback, the pending tool group, later results, and historical requests do not enter review

* A `clear` review authorizes only the exact unchanged action. A `caution` or unavailable review holds only that action, returns advice to the agent, and never opens a human permission screen, disables tools, or ends the turn

* Exact cautions are reused only for the current turn. Changed actions receive a new review. Legacy `permission_request_id` input is rejected without prompting

* `web_fetch` is an explicit fork exception to permission-first admission. It bypasses configured and saved allow, ask, and deny rules, automatic review, and human approval; the transport accepts public, private, local, metadata, and credential-bearing HTTP(S) targets and cross-boundary redirects. Keep only HTTP representability, cancellation, timeout, framing, and body-size bounds on this path

Do not bypass the permission system for new tools.

## Memory Safety

Zig does not check aliasing, lifetimes, or data races. `zig build test` will not catch use-after-free or worker/UI races: most tests never attach a TTY or run the agent worker next to a paint. Treat every new mutation of shared state as unsafe until you can name the owner thread and the lifetime of every slice.

### Allocators

* Allocators are passed explicitly. Never use a global allocator except the documented `std.heap.c_allocator` worker-event path.

* Free what you allocate. Use `defer` for cleanup at the call site.

* Prefer `ArenaAllocator` for request-scoped work that can be freed in bulk.

* When a function returns allocated memory, document who owns it (caller or callee).

### Slices

* `[]u8` and `[]const u8` are borrows, not owned strings. Storing `array_list.items` on another object without `dupe` is a use-after-free as soon as the list reallocates.

* Helpers such as `types.dupeSemanticNotice` copy topic and body. Passing a live `ArrayList` slice into that call is only valid for the duration of the call, and only because the callee dupes before it returns.

* Do not keep replaceable entry IDs, pins, or notice handles across a path that can drop or rebuild the transcript without clearing them.

### Threads and transcript mutation

The agent worker and the UI event loop are different threads.

* The worker may **queue** `WorkerEvent`s. It must not mutate the transcript store, `thought_body`, replaceable semantic notices, paint flags, or any other UI-owned render state.

* Transcript mutation happens on the UI thread during worker-event drain, and never while `TranscriptRuntime.painting` is true. `assertCanMutateTranscript` is a ReleaseSafe abort if it fires, not a recoverable error.

* Existing marshaled paths include assistant text, tables, code blocks, semantic notices, command output, and tool lifecycle. A new stream (reasoning, progress, status, or anything that updates the transcript while a turn is running) needs a `WorkerEvent` variant and a drain arm.

* Do not call `pushThoughtDisplay`, `appendReplaceableSemanticNotice`, `refreshReplaceableSemanticNotice`, `rebuildTranscriptCacheFromEntries`, or equivalent store methods from `agentPushText`, `agentPushEvent`, or gateway stream callbacks. Queue the event; apply it on drain.

Cross-thread transcript mutation has already crashed the TUI twice on one path: SIGABRT from `assertCanMutateTranscript` during paint, then SIGSEGV from a freed `std.Io.Writer` vtable (`call [rbp+0x18]`). The reproduction was running `./zig-out/bin/fx` while reasoning chunks streamed, which every turn now does because the reasoning display is unconditional. The fix is to queue `WorkerEvent.thought` and apply it only on drain. Do not reintroduce a second apply path.

### When writing the code

Before landing a mutation, answer:

1. Which thread owns this buffer?
2. Does any stored slice outlive a realloc, a drain, or a paint?
3. If this is an agent or gateway callback, does it only enqueue a `WorkerEvent`?
4. Are errors logged? Swallowing `replaceSemanticNotice` or finalize failures hides pin leaks and aborted updates.
5. Is there a test that the event is **queued**, not applied immediately? A single-threaded call to the App method will not catch the race.

If the change streams into the TUI, run `./zig-out/bin/fx` and drive that stream. A core dump on the happy path is a failed change.

## Zig-Specific Patterns

### Error Handling

* Return errors rather than panicking. `@panic` is for programmer bugs, not runtime conditions.

* Use `errdefer` to clean up partial state on error paths.

* Prefer specific error sets over `anyerror` when the set is bounded.

### Strings and JSON

* Zig strings are `[]const u8`. There is no implicit null termination.

* For JSON serialization, use `std.json.Stringify.value` with an allocating writer (`std.Io.Writer.Allocating`).

* For JSON string escaping (writing raw JSON), use the project's `writeJsonStr` helper in `src/acp/jsonrpc.zig` rather than assuming `std.json.encodeJsonString` exists.

* Zig 0.16 uses `std.Io.File.stdin()` / `.stdout()` / `.stderr()`, not `std.io.getStdIn()`.

### I/O (Zig 0.16 "Juicy Main")

* `main` uses `pub fn main(init: std.process.Init) !void` signature.

* All I/O goes through `std.Io`, passed explicitly or via the project's `src/core/shared/io.zig` helper (`io_mod.getIo()`).

* File operations use `std.Io.Dir` and `std.Io.File` (not `std.fs`). Most methods require an `io` parameter.

* Environment variables: use `io_mod.getenv(key)` (returns `?[]const u8`), not `std.process.getEnvVarOwned`.

* Time: use `io_mod.milliTimestamp()`, `io_mod.nanoTimestamp()`, `io_mod.sleep(ns)`.

* File reading: use `io_mod.readFileToEnd(alloc, &file, max_bytes)`.

* Realpath: use `io_mod.realpathAlloc(alloc, path)` or `io_mod.dirRealpathAlloc(alloc, dir, sub_path)`.

* Process spawning: use `std.process.spawn(io, opts)` and `std.process.run(alloc, io, opts)`.

* Mutexes: `std.Io.Mutex`, initialized with `.init`, locked with `.lockUncancelable(io)`.

* HTTP: `std.http.Client` requires `.io = io_mod.getIo()` in its initializer.

* `std.mem` renames: `trimLeft` is `trimStart`, `trimRight` is `trimEnd`, `indexOf` is `find`, `indexOfScalar` is `findScalar`.

* `ArrayList(T)` initializes with `.empty` (not `.{}`).

### Testing

* Zig unit tests go inside the source file they test, using `test "description" { ... }` blocks.

* Run the narrowest relevant tests while developing. The complete `zig build test` suite runs in ReleaseSafe in **Full CI** after the feature branch is pushed, and it must pass before the draft PR is marked ready.

* Use `std.testing.expect`, `std.testing.expectEqual`, `std.testing.expectEqualStrings` for assertions.

* In test blocks, use `std.testing.io` for the `Io` parameter. `io_mod.getIo()` automatically returns `std.testing.io` in test builds.

* Use `io_mod.dirRealpathAlloc(alloc, dir, sub_path)` to resolve paths within `std.testing.tmpDir()`.

## Testing (TypeScript)

### `tests/e2e/` — End-to-End Tests

Deterministic runtime tests (CLI commands, ACP protocol, TUI via tmux). No API key needed for most.

```bash
cd tests/e2e && bun install && bun test              # run all e2e tests
cd tests/e2e && bun test cli.test.ts                 # just CLI tests
cd tests/e2e && bun test acp.test.ts                 # just ACP tests
cd tests/e2e && bun test tui-*.test.ts               # just TUI tests (requires tmux)
```

TUI tests use tmux to drive the interactive terminal. They require `tmux` to be installed.

## Pull Request Classification

Every pull request must have exactly one `type:` label, chosen by its primary intent:

* `type: bug`: fixes incorrect behavior

* `type: feature`: adds a new user-facing capability

* `type: improvement`: improves existing user-facing behavior

* `type: docs`: changes documentation only

* `type: maintenance`: changes internal tooling, dependencies, CI, or implementation structure without a user-facing behavior change

* `type: release`: prepares or repairs a release

* `type: security`: fixes or hardens a security boundary

Assign the label when the PR is opened and keep it accurate when the PR changes. If the authenticated contributor cannot manage labels, state the required label and keep the PR in draft until a maintainer or repository agent applies it. For a mixed PR, choose the label that describes the primary reason the PR exists. If that is ambiguous, ask before applying or changing the label.

Keep PR titles as clean imperative sentences, such as `Restore diagnostic trace clipboard`. Do not add bracketed prefixes such as `[bug]`, `[feature]`, or `[improvement]`. Type belongs in the label, not the title.

## Full CI on Feature Branches

Do not run the complete deterministic test suite locally as the default development loop. Run the focused test for the changed path, build the binary, and exercise that path with `./zig-out/bin/fx`.

After the focused checks pass, create a clean checkpoint commit, push the non-`main` feature branch, and open a draft PR immediately. `.github/workflows/full-ci.yml` runs on feature-branch pushes and manual dispatches, but not on pushes to `main` or `byok`; a squash merge into `byok` must not repeat the Full CI already proven for the exact feature commit. It runs the following on all four supported native runner architectures:

* `ubuntu-24.04` (x86_64)
* `ubuntu-24.04-arm` (aarch64)
* `macos-15-intel` (x86_64)
* `macos-15` (aarch64)

The native matrix builds, tests, and smoke-tests ReleaseSafe on every platform; formatting and the public-surface audit run in those ReleaseSafe jobs. The E2E matrix runs four duration-balanced, isolated ReleaseSafe shards per platform with Bun and tmux. Checked-in weights assign every test file to exactly one shard on each platform, and files inside each shard run sequentially in separate Bun processes so terminal fixtures and process state cannot leak between files. A failed file receives one bounded retry after its tmux server is reset. Live model evals remain separate because they require credentials and are not deterministic.

A Full CI result is valid only when it belongs to the exact current commit and all four `Full suite (...)` jobs succeed. Each platform aggregate requires its ReleaseSafe native check plus all four ReleaseSafe E2E shards. Do not mark the draft PR ready or request review from a stale, partial, queued, cancelled, skipped, or failed run. If Full CI fails, make the smallest repair, rerun the focused local proof, push the new commit to the same draft PR, and wait for Full CI on the new exact commit. After CI passes, run the final ship gate and mark the PR ready only when it reports `SHIP` for that exact commit.

## Reproducing Render Bugs

fx's rendering is inline by default and deliberately emits a small ANSI subset. Five owner classes are the narrow exceptions, and each takes the alternate buffer exclusively through `AlternateScreenOwner` in `src/ui/shell_runtime.zig`: interactive permission review, the full-transcript screen, catalog menus, the ctrl+x subagent manager, and a hosted child-terminal takeover. The terminal-session owner is entered only by an explicit manager handoff after the host grants the human write lease; it renders the shared terminal-engine grid without permanent fx chrome and releases that lease on detach. Only one class may own the buffer at a time, and each must leave it and restore the main grid, composer, cursor, paste, mouse, focus, and keyboard modes when it closes. Transcript rendering, question prompts, and command-output expansion remain inline. Three tools exist for reproducing and regression-proofing render bugs:

### tmux (live TTY repros)

Best for resize and SIGWINCH interactions. The helper in `tests/e2e/tmux-helpers.ts` exposes `resizeWindow(cols, rows)`, `capturePaneGrid()`, and `capturePaneEscapes()`. See `tests/e2e/tui-resize.test.ts` for the canonical resize matrix.

```bash
cd tests/e2e && bun test tui-resize.test.ts
```

### Debug terminal recording and replay

Set `FX_DEBUG_RECORD=1` to create an automatic private tape under
`~/.fx/recordings/`. Set `FX_DEBUG_RECORD_SILENT_BANNER=1` as well when the
developer-only recording notice must stay out of the inline transcript during
a screen share. The notice remains available in the Ctrl+O full transcript.
Use `FX_RECORD=<path>` when a test or investigation needs an exact destination.
Recording dumps every byte fx writes and every resize into a framed binary tape.
Replay the tape through the built-in virtual terminal:

```bash
FX_DEBUG_RECORD=1 ./zig-out/bin/fx
FX_RECORD=/tmp/bug.fxtape ./zig-out/bin/fx
./zig-out/bin/fx replay /tmp/bug.fxtape
./zig-out/bin/fx replay /tmp/bug.fxtape --frames
./zig-out/bin/fx replay /tmp/bug.fxtape --json
./zig-out/bin/fx replay /tmp/bug.fxtape --golden out.txt
```

The tape is deterministic — any reviewer can replay it without a TTY, and a golden file can be checked in as a regression test.

### Shared terminal engine (sub-second unit tests)

`src/core/terminal/engine.zig` is the shared bounded text-terminal engine for hosted terminal sessions, recovery, replay, and deterministic rendering tests. `src/ui/resize_tests.zig` drives `TranscriptRuntime` against it in process so resize behavior can be exercised with no fd or timing dependence.

```bash
zig build test                      # runs every VT and resize test
```

When a tmux or tape-based scenario exposes a bug, reproduce it as a Zig unit test in `resize_tests.zig` (or a new sibling) before fixing. The test lands the fix as a regression.

## Benchmarks

Startup latency benchmarks live in `benchmarks/` and run in CI via `.github/workflows/bench.yml`.

```bash
./benchmarks/startup.sh            # full run (100 iterations, builds ReleaseSafe, needs hyperfine)
./benchmarks/startup.sh --quick    # quick run (20 iterations)
```

The CI workflow builds a ReleaseSafe binary, measures six CLI paths with hyperfine, and enforces per-command latency budgets. PRs that exceed a budget fail the check.

The startup benchmark uses `FX_BENCH=1`, an environment variable that runs through arg parsing and CLI dispatch, then exits before TTY initialization. This lives in `src/core/app/app_entry_runtime.zig`.

Current raw wall-clock contract:

* Linux CI: 2ms for every command
* Non-Linux local runs: informational raw means

The Linux CI runner is the authoritative product budget. Local macOS process
and dynamic-loader floors vary enough to exceed 2ms independently of fx, so
local runs report raw means without assigning a substitute product budget. The
process baseline is diagnostic only and is never subtracted.

When adding features, consider their impact on startup latency. The `fx help` path is the baseline cold-start benchmark.

## Binary Size Observability

Every pull request runs `.github/workflows/binary-size.yml` across Linux x86_64,
Linux arm64, macOS x86_64, and macOS arm64. Each matrix job builds the pull
request merge commit and its base commit as stripped ReleaseSafe binaries on
the same native runner, then reports the exact byte and MiB delta plus ELF or
Mach-O section changes.

Each platform check is informational. An increase of at least 52,429 bytes
(0.050000 MiB) emits a warning and retains that platform's binaries for
investigation, but does not reject the pull request. Investigate notable
unexplained growth before changing the threshold. The full macOS arm64 PGSO
release qualification remains authoritative for the 7.800 MiB production
ceiling and performance gates.

## Documentation

When adding or changing user-facing features, update **all** relevant files:

1. `--help` output via command specs in `src/core/slash_commands/command_specs.zig`
2. `README.md` — feature descriptions, usage examples
3. `CONTRIBUTING.md` — if build steps, config, or collaboration rules change

Do not document intended behavior as if it already exists.

## Releasing

Releases use the GitHub Release workflow. The maintainer controls the changelog voice and format.

To prepare a release by hand:

1. Create a branch (e.g. `prepare-v0.3.0`)
2. Bump `pub const version` in `src/main.zig`
3. Write the changelog entry in `CHANGELOG.md` at the top, under a new `## <version>` heading, wrapped in `<!-- release:start -->` and `<!-- release:end -->` markers. Remove the markers from the previous release entry so only the new release has them.
4. Update `README.md` install example version
5. Open a PR and merge to `main`

When the PR merges, the release workflow compares the version tag to what exists in git. If the tag is missing, it cross-compiles all platform binaries, creates the git tag, and publishes a GitHub Release with the binaries attached. The release body is extracted from the content between the `<!-- release:start -->` and `<!-- release:end -->` markers in `CHANGELOG.md`.

### Writing the changelog

Whether automated or manual, the changelog is public product copy. Describe observable user behavior, not the engineering process behind it. Use the diff, commits, and merged pull requests as research evidence only.

Public changelog entries must:

* Spell the product name `fx`. Preserve different casing only when it is part of an exact code identifier such as `FX_MODEL`.
* Use only relevant sections from `### Breaking Changes`, `### New Features`, `### Improvements`, `### Bug Fixes`, and `### Security`. Omit empty sections.
* Bold a short feature or fix name, then describe the user-visible change after a colon.
* Omit pull request numbers, issue numbers, commit hashes, contributor names, and author attribution.
* Omit internal details such as repository moves, website or marketing work, CDN layout, CI workflows, test fixtures, branch history, and implementation-only refactors. Translate relevant work into its public user outcome or leave it out.
* Avoid forcing every merged change into the notes. A change without a public user outcome does not need a bullet.

Only the current release should have markers; remove `<!-- release:start -->` and `<!-- release:end -->` from any previous entry:

```markdown
## 0.3.0

<!-- release:start -->
### New Features

- **Live command output:** Show Unified Exec output while a command is still running
<!-- release:end -->

## 0.2.5

### Improvements

- **Inline rendering:** Keep the active conversation visible in terminal scrollback
```

Do not add a `### Contributors` section or tracker references. Use descriptive section names.

Do not create version tags manually. Do not change `build.zig.zon` version (it is a placeholder).

## Repository and License

The canonical upstream repository is `vercel-labs/fx` on GitHub. All URLs, links, and references to the project must use `vercel-labs/fx` (not `vercel/fx`, `user/fx`, or any other org/owner), including in code and documentation written on this fork — a reference that points at the fork would break for upstream users and in any pull request sent back. This checkout is the `acking-you/fx` fork; see **This Fork and Its Branches**. Licensed under Apache-2.0.

## What Not To Do

* Do not grow `main.zig` with leaf feature logic

* Do not add hidden product state that only exists in the live shell

* Do not mutate the transcript or other UI render state from the agent worker or gateway stream callbacks. Queue a `WorkerEvent` and apply it on drain.

* Do not add a second execution path for the same feature without a clear reason

* Do not commit generated state from `.fx/`, `.zig-cache/`, or `zig-out/`

* Do not add dependencies outside the Zig standard library without discussion

* Do not use `@import` with runtime-computed paths — Zig imports are comptime only

* Do not ignore `zig fmt` failures

* Do not create git tags manually (the release workflow owns tag creation)

* Do not report work as ready without running the binary. See **Declaring Work Ready**.

* Do not treat a green unit-test run as proof that a streaming TUI path is memory-safe.

## Before Marking a PR Ready

1. Run `zig fmt --check src/` and the focused tests for the changed path.
2. Build and exercise the change locally with `./zig-out/bin/fx`.
3. Push a clean checkpoint commit and open a draft PR immediately.
4. Require **Full CI** and the final ship gate to pass on the exact current commit across all four native runners.
5. Update docs if behavior changed.
