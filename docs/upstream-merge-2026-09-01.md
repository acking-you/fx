# Upstream merge review — 2026-09-01

## Review status

This document records the reconciliation of the latest `vercel-labs/fx` mainline into the BYOK fork. The result is intentionally held on `merge/upstream-2026-09-01` for review. It has not been merged into `byok`.

The merge boundary is:

| Item | Commit |
| --- | --- |
| BYOK first parent before the content merge | `fe2ec9e05250ccc789d6a3d939fcd0b72cd6157c` |
| Upstream main merged | `1685a855868820a1b9f317dc589190c32b011684` |
| Merge commit | `d7d3f8f2d471cb1c6a6c8cb306b19d312ba64ab0` |
| Review branch | `merge/upstream-2026-09-01` |

Compared with the pre-merge BYOK tree, the review result changes 242 files with 27,332 insertions and 16,893 deletions. The large count comes primarily from upstream MCP, transcript, rendering, and E2E work. It does not represent a new vendor product route or a large new model-facing tool surface.

## Reconciliation policy

The merge used these rules:

1. Preserve upstream structure where it remains provider-neutral and useful.
2. Preserve every protected BYOK contract in `AGENTS.md`.
3. Remove vendor onboarding, duplicate runtimes, duplicate policy owners, and redundant model-facing tools.
4. Keep historical names only where saved-session replay or presentation compatibility requires them. A historical name must not become executable.
5. Keep tests that prove runtime behavior. Remove or rewrite fixtures whose only owner was a deleted tool or obsolete UI state.
6. Use the fork's exact-commit Full CI as the release gate. Upstream PR CI is not accepted as proof for this merge.

## User-visible and architectural additions retained

### Unified capability retrieval

Upstream's capability-search work was retained as one bounded `capability_search` entrypoint. Skill and MCP discovery share that owner. The separate model-facing `skill_search` and `mcp_search_tools` compatibility tools were removed.

Primary paths:

- `src/core/tooling/capability_retrieval.zig`
- `src/tools/capabilities/capability_search.zig`
- `src/core/tooling/tool_projection.zig`
- `src/core/tooling/tool_dispatch.zig`

### Generic MCP configuration and menu

The MCP work is provider-neutral and useful to BYOK, so the following were retained:

- project and workspace scoped MCP configuration;
- project trust boundaries;
- local and HTTP server management;
- Docker command normalization for configured MCP servers;
- a consolidated MCP catalog/menu instead of separate overlapping screens;
- bounded HTTP content-length handling and runtime compatibility checks.

This does not add a second model-facing MCP search tool. Dynamic selection remains behind `capability_search` and `mcp_select_tool`.

### Full transcript details and asynchronous loading

Ctrl+O full transcript support now retains richer turn metadata, paginates large histories, and loads detailed pages away from the UI loop. This was kept because it improves observability without changing provider policy.

Primary paths:

- `src/core/output/full_transcript_metadata.zig`
- `src/core/output/full_transcript_page.zig`
- `src/ui/transcript/full_transcript_worker.zig`
- `src/ui/full_transcript_screen.zig`

### Provider usage dashboard

The local usage dashboard was wired into the composition root. Remote quota work remains asynchronous, and TUI and ACP use the same aggregate-only snapshot.

Primary paths:

- `src/core/app/usage_dashboard_runtime.zig`
- `src/core/session/provider_usage.zig`
- `src/main.zig`

### Same-turn steering

Interactive input during an active turn is retained as same-turn steering. The next model-step boundary consumes it; input losing the completion race becomes an ordinary next-turn prompt without duplication. Queue review and between-turn compaction retain their separate contracts.

Primary paths:

- `src/core/agent/worker_runtime.zig`
- `src/core/agent/runtime/orchestrator.zig`
- `src/core/app/app_callbacks.zig`
- `src/ui/footer/input_presentation.zig`

### Unified provider activity phases

Upstream's provider activity phases were reconciled with the fork's existing UI activity model. One phase owner now drives worker events, footer text, resize fixtures, render-lab analysis, and E2E expectations. Duplicate status derivation was deleted.

### Session and tool-result detail

The merge retains:

- completed-turn summaries in the session codec;
- assistant block publication before tool entries;
- typed tool result output and durable result handles;
- collapsed compact tool groups while full transcript keeps complete detail;
- ACP session pagination and workspace filtering;
- cancellation and terminal-outcome integrity fixes.

### Runtime and release maintenance

Useful upstream maintenance was kept where it matches the fork:

- native runtime and binary layout reductions;
- shared runtime deduplication;
- idle activity animation fixes;
- subagent lifecycle and trace-lineage fixes;
- macOS signing script fixes that apply to the fork's existing release path;
- vision capability routing coverage;
- deterministic PGSO corpus updates for changed E2E owners.

The upstream stable-signing job that conflicted with the fork's release workflow was not restored. The local signing script and tests were reconciled instead.

## Exact new files retained

These files did not exist on the BYOK first parent and are present in the review result:

| File | Purpose |
| --- | --- |
| `src/core/app/app_mcp_menu_runtime.zig` | App-owned MCP menu coordination |
| `src/core/app/usage_dashboard_runtime.zig` | Asynchronous provider usage runtime |
| `src/core/mcp/docker_run.zig` | MCP Docker command representation |
| `src/core/mcp/menu_state.zig` | Typed MCP menu state |
| `src/core/mcp/project_config.zig` | Project-scoped MCP configuration |
| `src/core/mcp/workspace_config.zig` | Workspace MCP configuration and resolution |
| `src/core/output/full_transcript_metadata.zig` | Full transcript metadata contract |
| `src/core/output/full_transcript_page.zig` | Paged full transcript output contract |
| `src/core/tooling/capability_retrieval.zig` | Unified capability retrieval owner |
| `src/ui/footer/mcp_menu_presentation.zig` | MCP menu presentation |
| `src/ui/transcript/full_transcript_worker.zig` | Off-UI-thread transcript page loading |
| `tests/e2e/fixtures/mcp-content-length-http.ts` | Bounded MCP HTTP fixture |
| `tests/evals/vision-capability-routing.test.ts` | Live vision route evaluation owner |

## Deletions

### Exact deleted files

These files existed on the BYOK first parent and were removed from the review result:

| File | Reason |
| --- | --- |
| `src/core/tooling/tracked_file_mutations.zig` | Duplicate mutation tracking after the typed file mutation owner was consolidated |
| `src/core/workspace/list_files_listing.zig` | Only served the removed `list_files` tool |
| `src/tools/filesystem/copy_file.zig` | Redundant command-shaped filesystem operation |
| `src/tools/filesystem/create_folder.zig` | Redundant command-shaped filesystem operation |
| `src/tools/filesystem/delete_file.zig` | Redundant command-shaped filesystem operation |
| `src/tools/filesystem/file_info.zig` | Redundant with direct reads and Unified Exec |
| `src/tools/filesystem/list_files.zig` | Redundant with `glob_files` and `rg --files` |
| `src/tools/filesystem/open_file.zig` | Host-specific side effect with no required agent contract |
| `src/tools/filesystem/rename_file.zig` | Redundant command-shaped filesystem operation |
| `src/tools/filesystem/semantic_search.zig` | Duplicate search surface without a distinct required contract |
| `src/tools/memory/memory.zig` | Removed product feature with no supported BYOK persistence contract |
| `src/ui/catalog_screen_layout.zig` | Replaced by the consolidated menu state and presentation |
| `src/ui/skills_screen.zig` | Replaced by unified capability retrieval and the consolidated menu |

### Removed model-facing tool surfaces

The following names are not executable and are not advertised:

| Removed name | Current owner or replacement |
| --- | --- |
| `terminal` | `exec_command` starts a process; `write_stdin` polls or interacts |
| `run_command` | Historical replay only; execution uses Unified Exec |
| `list_files` | `glob_files` or `exec_command` with `rg --files` |
| `file_info` | `read_file` or Unified Exec |
| `delete_file` | Unified Exec under the ordinary permission system |
| `rename_file` | Unified Exec under the ordinary permission system |
| `copy_file` | Unified Exec under the ordinary permission system |
| `create_folder` | Unified Exec under the ordinary permission system |
| `open_file` | Removed without a model-facing replacement |
| `semantic_search` | `grep_files`, Unified Exec, or unified capability retrieval depending on intent |
| `memory` | Removed without replacement |
| `skill_search` | `capability_search` |
| `mcp_search_tools` | `capability_search` plus `mcp_select_tool` |

The remaining registered built-ins are exactly:

`glob_files`, `grep_files`, `read_file`, `write_file`, `edit_file`, `update_plan`, `web_fetch`, `web_search`, `exec_command`, `write_stdin`, `capability_search`, `skill`, `install_skill`, `subagent`, `mcp_select_tool`, `mcp_features`, `ask_user_question`, `vision`, and `read_tool_result`.

`vision` and `read_tool_result` are projected conditionally. The other 17 form the base advertisement set subject to provider, permission, host, and bash-first projection.

### Deleted duplicate runtime and test logic

The reconciliation commits also removed code inside surviving files:

- a second execution-memory and orchestration path introduced by the merge;
- duplicate worker steering/status state and duplicate rendering derivation;
- old terminal and `run_command` execution compatibility branches;
- old file-tool admission, dispatch, CLI, system-prompt, and presentation branches;
- copied test registries that advertised deleted tools;
- stale Vercel credential wording in the render replay fixture;
- E2E scenarios whose only owner was a removed memory or filesystem tool;
- empty negative assertions that claimed bash-first hid tools already absent globally.

Historical `run_command`, `list_files`, and `memory` strings remain only where a saved session codec, replay renderer, migration test, redaction test, or explicit non-executability test needs them. Internal terminal-session state is unrelated to the removed model-facing `terminal` tool.

## Protected BYOK conflict decisions

### Provider transports and OAuth

- Kept Codex Responses as the default ChatGPT subscription route.
- Kept the account-bound Responses endpoint, beta headers, remote compaction trigger, and encrypted reasoning replay.
- Kept Grok and Codex behind the provider-neutral OAuth boundary.
- Kept deterministic stored-session detection with Codex first and Grok fallback.
- Kept Windows loopback callback handling, including delayed request bytes and Windows AFD reset classification.
- Kept provider-neutral `fx setup` as an importer for Codex CLI and Grok Build credentials. It is not Vercel setup.
- Kept `/provider` for selection and `/login` for authentication.
- Kept durable asynchronous logout and provider-specific activation cancellation.
- Kept ACP `_meta.fx.providerControl`, including connection-scoped BYOK URL and API key binding.

No Vercel setup, login, key, gateway default, or product route was reintroduced. Source search found no Vercel references under `src/`.

### Compaction

Every semantic compaction entrypoint still delegates to `src/core/agent/runtime/compaction.zig`. Eligible Responses routes try the native opaque checkpoint, then the active model produces a validated full replacement, and the bounded deterministic projection is the availability fallback. ACP, TUI, overflow recovery, and turn-window projection do not own separate fallback policy.

### Worker and UI ownership

Gateway and agent callbacks enqueue worker events. Thought, assistant text, semantic notices, command output, and lifecycle mutation are applied during UI-thread drain. Newline-free assistant chunks retain a render request and are not held until a hard line.

### Unified Exec

`exec_command` and `write_stdin` remain the only executable command family. ACP direct observation uses its own cursor and does not consume model output or claim model-owned cleanup. Pipe readers queue bounded owned chunks and invoke presentation callbacks outside process-control locks.

### Web tools

`web_search` remains one logical capability:

- Codex projects it to the reserved `web.run` namespace;
- compatible Responses routes project hosted `web_search`;
- Grok projects hosted search only for a catalog-confirmed capable route;
- the separately configured Responses search client is the local fallback.

`web_fetch` remains a direct bounded HTTP client and bypasses fx allow, ask, deny, automatic review, and human approval. URL representability and resource bounds remain; private, local, metadata, credential-bearing, and cross-boundary redirect targets are accepted.

### Bash-first

The session or connection-local projection hides `glob_files` and `grep_files` and guides the model to `rg` and `rg --files`. The prompt no longer lists `list_files` or `semantic_search`, because those tools are absent globally. A running turn retains its captured projection.

## Merge repair commits

| Commit | Review purpose |
| --- | --- |
| `536f22d1` | Remove duplicate upstream runtime paths |
| `40141b5d` | Align merged tests with the BYOK tool surface |
| `aec38ec3` | Remove obsolete tool compatibility paths |
| `fd2772c0` | Activate the asynchronous local usage dashboard |
| `4d956451` | Unify turn phase presentation |
| `0ce8472c` | Restore merged history and transcript metadata |
| `3c9319a3` | Reconcile the fork release workflow and signing tests |
| `e6658276` | Persist completed turn summaries |
| `6955aad7` | Align resize tests with unified turn phases |
| `1d251b2e` | Align E2E fixtures with unified turn phases |
| `c43bec52` | Remove stale merged tool fixtures |
| `0c4d91aa` | Remove stale Vercel fixture wording |
| `a91bcc82` | Repair explicit steering tests, Windows Unified Exec coverage, and stale bash-first guidance |

## CI policy for this merge

The authoritative gate is `.github/workflows/full-ci.yml` on the exact review commit. It is the fork's feature-branch workflow and includes:

- ReleaseSafe native build, unit tests, formatting, public-surface audit, and binary smoke on Linux x86_64, Linux arm64, macOS x86_64, and macOS arm64;
- four isolated ReleaseSafe E2E shards on each of those platforms;
- one `Full suite (...)` aggregate per platform that requires its native job and all four E2E shards;
- a separate Windows native job with provider setup, OAuth callback, Unified Exec, CLI, and ACP smoke coverage.

Only a run attached to the commit containing this document is acceptable. All four `Full suite (...)` aggregates must succeed. A passing upstream run, an older fork commit, or only the Windows job is not proof.

The smaller `.github/workflows/ci.yml` workflow is not used as the merge decision. Benchmark and binary-size workflows are retained because startup latency and unexplained binary growth are useful signals; neither replaces Full CI.

## Local verification completed before push

- `zig fmt --check src/`
- `zig build -Doptimize=ReleaseSafe`
- ReleaseSafe filtered Zig tests covering compaction, same-turn steering, worker/UI thought queueing, newline-free assistant display, Unified Exec observer isolation and nonblocking direct control, web-fetch policy bypass, web-search projection, provider activation cancellation, bash-first projection, and shared usage snapshots
- Windows provider tests covering Codex CLI parsing, Grok Build parsing, setup secret redaction, OAuth fallback order, ChatGPT and Grok callback path/state validation, ephemeral ports, delayed callback bytes, and Windows AFD reset handling
- TypeScript checking for every E2E file changed during reconciliation
- Bun E2E: removed filesystem tools are absent and Unified Exec completes the flow
- Bun E2E: removed memory is not advertised, cannot mutate the legacy store, and does not prevent a surviving tool call
- Bun E2E: no-save ask advertises the Unified Exec surface and completes through a fake Responses gateway
- Fresh binary smoke with `./zig-out/bin/fx help`, `status --json`, and provider-neutral `setup --json`
- Fresh binary ACP interaction covering initialize, session creation, setup start, and nonblocking setup status

The local setup smoke detected both `codex_cli` and `grok_build` sources without printing credential bytes. Full unfiltered Zig tests are intentionally delegated to the Linux and macOS Full CI matrix because the complete test graph contains POSIX-only process fixtures; Windows runs the explicit native subset in Full CI.

## Reviewer checklist

- [ ] No Vercel onboarding or default product route returned.
- [ ] Codex and Grok login, setup import, fallback, refresh, logout, and ACP provider control remain intact.
- [ ] The 19-tool registry is intentional and no deleted compatibility tool is executable.
- [ ] MCP additions are generic and do not create a second discovery policy.
- [ ] Compaction still has one strategy owner.
- [ ] Worker callbacks do not mutate transcript state directly.
- [ ] Same-turn steering and its completion-race fallback remain intact.
- [ ] Unified Exec retains one model-facing command family and independent ACP observation.
- [ ] Web Search projection and Web Fetch admission exceptions remain intact.
- [ ] All four exact-commit `Full suite (...)` jobs pass before merge into `byok`.

