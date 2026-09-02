# Upstream merge review — 2026-09-01

## Review status

This document records the final reconciliation of `vercel-labs/fx` into the
BYOK fork. The reviewed tree was fast-forwarded from
`merge/upstream-2026-09-01` into `byok` on 2026-09-02 after every required
check passed.

| Boundary | Commit |
| --- | --- |
| BYOK first parent before this merge series | `fe2ec9e05250ccc789d6a3d939fcd0b72cd6157c` |
| Earlier upstream merge checkpoint | `5fabddd7` via `821634d5` |
| Latest upstream main included | `d424f1a8` |
| Tree before the final product pruning | `ccf8680a` |
| MCP pruning checkpoint | `32a8e6f6` |
| Last code-bearing review candidate | `95be8bb3` |
| Final reviewed and merged tree | `f3c7b7bc` |
| Pull request | [#29](https://github.com/acking-you/fx/pull/29) |

The final product decision is explicit: this fork does not support MCP. Skills
are the extension mechanism. No MCP configuration, transport, authentication,
catalog, prompt, resource, dynamic tool, menu, ACP bridge, fixture, or
conformance suite remains executable.

## Reconciliation policy

1. Preserve upstream structure when it is provider-neutral and useful to BYOK.
2. Preserve every protected BYOK contract in `AGENTS.md`.
3. Remove vendor onboarding, duplicate policy owners, redundant model-facing
   tools, and capabilities this fork does not intend to support.
4. Diagnose tests by product ownership. Delete a test only when its sole owner
   was removed, its assertion duplicated a stronger boundary, or it measured a
   harness detail rather than supported behavior.
5. Keep generic crash, persistence, concurrency, rendering, and protocol tests
   even when their old fixture happened to use a removed feature.
6. Use the fork's exact-commit Full CI as the merge gate. Upstream CI is not
   accepted as proof for this branch.

## Consolidated change inventory

### Upstream additions and their disposition

This table is the review index for functionality introduced by the upstream
series included through `d424f1a8`. The detailed owner and behavior sections
below remain authoritative.

| Area | What upstream introduced or changed | BYOK disposition |
| --- | --- | --- |
| Capability retrieval | Bounded `capability_search`, natural-intent routing, and distinct skill-resource activity | Retained as a skill-only boundary; MCP catalogs and dynamic tools were removed |
| Full transcript | Complete Ctrl+O metadata, background page building, bounded viewport windows, wheel and page navigation, restored viewport intent, and large snapshot support | Retained with UI-thread adoption and stale-view invalidation |
| Terminal responsiveness | Focused polling, prepared-page reuse, stable visible pages, lifecycle performance gates, and transient resource bounds | Retained; BYOK repaired pending-frame delivery and removed only observer-noise or unsupported-backend samples |
| Skills catalog | Canonical home resolution, generation-safe refresh, overlap handling, and hot discovery inside an existing candidate directory | Retained; the timing-sensitive regression test now uses a bounded wait |
| Sessions and ACP | Shorter new session IDs, paginated ACP `session/list`, stable tool-call input and output metadata, and session/process lifecycle preservation | Retained without changing existing session compatibility |
| Agent integrity | Approval ownership, child approval binding, post-tool reassessment, recovery guidance, and canonical tool-result finalization | Retained where it reinforces the fork's existing agent harness |
| TUI presentation | Collapsible tool-call groups, live activity beside native scrollback, code-block rule refinements, and current-menu rendering | Retained with BYOK's `Thinking` wording and full detail still available in Ctrl+O |
| Provider lifecycle | Logout recovery, asynchronous credential inventory, portable credential probes, and usage-dashboard refresh | Retained only for direct BYOK, Codex, and Grok sources; Vercel account and team flows were removed |
| Vision | Capability-gated advertisement, native route recovery, ACP image support, and a live routing evaluation | Retained as a conditional provider capability |
| Portable hosts | Host-owned WASM prompt admission and cross-target build repairs | Retained; the BYOK credential probe also received a single-threaded WASM path |
| Test and release policy | Exact PGSO ownership, deterministic sharding, terminal benchmarks, binary-size gates, and cross-platform compile coverage | Retained under fork-owned CI; stale MCP, Vercel, signing-product, and removed-feature registrations were deleted |
| MCP product surface | Interactive menus, prompts, resources, tools, authentication, transports, conformance, and compatibility paths | Removed completely; skills are the only extension mechanism |

### BYOK reconciliation changes

These are the fork changes applied while accepting the upstream series. They
are not upstream features and should be reviewed as the local delta.

| Change | Result |
| --- | --- |
| Removed the complete MCP vertical slice | Deleted production runtime, configuration, transports, menus, ACP bridge, dynamic tools, authentication, fixtures, conformance packages, CI registrations, and documentation that presented MCP as supported |
| Restored the provider-neutral product surface | Kept generic setup import, direct Responses configuration, Codex and Grok OAuth, deterministic Codex-first fallback, provider selection, refresh, durable logout, and ACP provider control without Vercel onboarding |
| Preserved protected agent behavior | Reconciled native compaction, reasoning replay, UI-thread event adoption, same-turn steering, Unified Exec, Web Search projection, Web Fetch admission, child route snapshots, and provider usage against upstream structure |
| Fixed completed-summary presentation | Routed completed turn summaries through the full append boundary so cache, cursor, retention, and repaint state update together |
| Fixed Windows stored-session detection | Replaced a POSIX-only mode conversion with the shared private-file permission contract used by Codex and Grok session loading |
| Fixed portable credential inventory | Added a synchronous single-threaded completion path for WASM while retaining threaded native TUI and ACP behavior |
| Fixed native asynchronous UI delivery | Pending active-surface frames now commit without the 50ms native idle delay; skills, account inventory, and full-transcript cache misses returned to one-frame latency |
| Reconciled test fixtures with BYOK | Replaced Vercel environment variables and presentation labels, converted the approval fixture to `exec_command`, and removed obsolete `terminal` backend samples |
| Removed tests without a surviving product contract | Deleted removed-feature owners, duplicate brittle snapshots, an unprovable retry token count, a stale cache-null assertion, the redundant brutal transcript profiler, and one host-observer subagent microbenchmark |
| Kept meaningful regression coverage | Preserved portability, crash, recovery, concurrency, resource, security, rendering, provider, skill, subagent, and runtime behavior tests even when their old fixture originated upstream |
| Strengthened fork CI | Kept fork-owned deterministic sharding and added exact Windows, Linux, macOS, and portable WASM gates without adopting upstream release cadence as the merge authority |
| Updated fork documentation | README, AGENTS, CONTRIBUTING, CHANGELOG, and this audit now state the skill-only extension contract and enumerate retained and removed behavior |

## Additions retained from upstream

### Skill-only capability retrieval

`capability_search` remains the single bounded discovery entrypoint and now
searches only installed skills. A terminal `no_match` result suppresses the
search tool for only the immediately following model step. The old standalone
`skill_search` compatibility name is not executable.

Owners:

- `src/core/tooling/capability_retrieval.zig`
- `src/tools/capabilities/capability_search.zig`
- `src/core/tooling/tool_projection.zig`
- `src/core/tooling/tool_dispatch.zig`

### Full transcript details

Ctrl+O retains richer turn metadata, bounded pagination, off-UI-thread page
loading, final command-output revisions, and viewer-lifetime invalidation. Page
completion is collected by the composition root and rendered only on the UI
thread.

Owners:

- `src/core/output/full_transcript_metadata.zig`
- `src/core/output/full_transcript_page.zig`
- `src/ui/transcript/full_transcript_worker.zig`
- `src/ui/full_transcript_screen.zig`

The latest upstream terminal-performance series is retained where it improves
bounded preparation, viewport stability, installed-page ownership, focused
polling, and large transcript snapshots. Closing the full transcript may keep a
safe prepared page cached, so the stale test assertion that required the cache
to become null was removed. Tail anchoring and viewer invalidation remain the
product contracts.

The reconciliation also fixed a real presentation regression exposed by those
lower incidental repaint rates: a completed turn summary was appended only to
the structured store and could remain invisible indefinitely. Turn-summary
insertion now updates the transcript cache, cursor, retention state, and repaint
request through the same full transcript append boundary.

### Provider-neutral help and authentication

The consolidated help aliases, compact command summaries, generic setup import,
Codex login, Grok login, provider selection, logout, model listing, and usage
commands remain. Vercel Gateway setup, teams, credits, upgrade, feedback, and
hosted product links remain removed.

The Windows OAuth callback repair remains part of the provider-neutral Codex and
Grok login path. Setup still detects stored Codex first and Grok second, and the
automatic fallback remains independent of the removed extension stack.

The latest asynchronous credential-inventory worker is retained only for the
three supported sources: a direct Responses API key, Codex OAuth, and Grok
OAuth. It probes stored-session presence off the TUI thread without restoring
the upstream Vercel account, team, Keychain, or fx-login product flow.

The first exact Windows Full CI compile caught a POSIX-only permission call in
that new presence probe. It now uses the existing cross-platform private-file
contract shared by Codex and Grok session loading. A focused native profile-file
test is part of both Windows lanes so future setup or fallback changes compile
and exercise this boundary on Windows rather than only Linux.

The retained background inventory contract now also has an explicit
single-threaded implementation: WASM runs the bounded three-source probe
synchronously and publishes it through the same completion boundary. Native
TUI and ACP builds continue to use the worker thread. This fixes the actual
WASM compile regression without removing the portable SDK surface.

### Provider usage dashboard

The local usage dashboard and aggregate provider snapshot remain wired into the
composition root. Remote quota work stays asynchronous for both TUI and ACP.

### Same-turn steering

Ordinary interactive input during an active turn remains same-turn steering.
The next model-step boundary consumes it; input that loses the completion race
becomes one ordinary next-turn prompt without loss or duplication. The partial
upstream Ctrl+Enter steering split was removed as a conflicting second policy.

### Prompt history and slash completion

Prompt history keeps durable command filtering, draft restoration, and normal
arrow ownership. Empty slash-completion results remain an explicit menu state,
and editing can repopulate candidates without reopening a second picker owner.

### Skills presentation

Dollar-trigger skill completion works after ordinary composer text. Selected
skills use the compact name-only display while their instructions continue to
load only through the typed skill invocation boundary.

Upstream's canonical-home skill refresh and overlap-safe catalog generations
are retained. Its refresh regression used a fixed count of tight thread yields,
which could finish before the worker was scheduled and then report the prior
completion value. The test now clears each phase result and waits with a bounded
one-millisecond polling interval. This preserves meaningful hot-refresh and
coalescing coverage instead of deleting it as a flaky test.

### Short session identifiers

New session IDs use the shorter upstream form while existing IDs and resume
lookups remain readable. This reduces routine CLI and TUI identifier noise
without changing session ownership or recovery semantics.

### ACP tool-call metadata

ACP retains stable tool-call IDs, structured and redacted input, incremental
output, terminal replacement updates, plan visualization, provider control,
Codex and Grok authentication, connection-local BYOK configuration, and
nonblocking Unified Exec control. No extension-server bridge is advertised.

### Unified provider activity

Provider activation, refresh, catalog loading, cancellation, and logout retain
one shared lifecycle vocabulary across the TUI, ACP, CLI, and child sessions.

### Session and tool-result detail

Large results keep bounded previews, durable handles, range reads, replay, and
redaction. Session resume retains canonical turn ownership, recovery markers,
usage sidecars, terminal lifecycle state, and asynchronous picker loading.

### Agent-step integrity

Subagent turns retain stable trace and lifecycle identities. Tool errors publish
one canonical final result, post-tool continuation remains intact, and selected
tools are validated against the captured turn projection before execution.

### Vision routing

Vision remains conditional on model capability. ACP image blocks, verified
image snapshots, native provider routing, and the configured fallback path keep
their existing typed owners.

### Portable tracing and settings

Cross-platform trace append, profile setting ownership, provider-specific model
preferences, slash-menu category persistence, and runtime environment handling
remain. Windows child-process environment conversion is retained where generic
provider and execution subprocesses still need it.

### Release tooling

The PGSO corpus manifest, exact test-file classification, deterministic shard
planning, benchmark checks, and binary-size checks remain fork-owned. The
manifest was reduced only where a product owner was deleted.

The terminal performance owner was also converted from the removed Vercel
Gateway fixture variables to `OPENAI_API_KEY` and
`FX_RESPONSES_BASE_URL`. Its missing-home, canonical skill refresh, and real
performance assertions remain useful; only their stale product route was
removed.

The browser, headless terminal, and performance owners still exercise active
turn cancellation, prompt visibility, animation, and login-menu latency. Their
upstream-only presentation markers were updated from `Working` to the fork's
`Thinking` lifecycle and from `Connections` to the fork's `Accounts` login
menu. No production compatibility state was added solely to satisfy those old
labels.

The performance fixture's last model-facing `terminal` calls and its
informational-only hosted-input sample were deleted. They targeted the removed
executable backend, enforced no latency budget, and duplicated dedicated
Unified Exec TUI and ACP coverage. The useful approval-navigation benchmark now
uses `exec_command`, the fork's single supported shell family.

The retained benchmark then exposed a real BYOK integration regression rather
than an obsolete assertion. Native idle polling had been relaxed to 50ms after
the model worker gained an event-wake fd, but catalog refresh and transcript
page workers do not publish through that fd. A completion collected at the top
of the event loop could therefore request a frame and then wait for the full
idle timeout before the frame was committed. Pending active-surface frames now
force a nonblocking poll and immediate commit; the bounded one-millisecond
cadence remains limited to workers that are still running. This removes the
measured 50ms delay from skills, account inventory, and full-transcript cache
misses without adding another wake mechanism.

The `subagentManagerOpen` microbenchmark was removed after the repaired run
reached it. Unlike the retained tape-based stdin-to-stdout measurements, it
timed host-side `tmux capture-pane` polling. Its median was 5ms and p90 was 9ms,
but runner scheduling outliers made the p95 exceed a 17ms one-frame budget.
There is no separate product contract for that observer-inclusive number, and
the dedicated TUI subagent-manager suite already owns manager state,
navigation, approval, recovery, live updates, and nested-child behavior. The
subagent manager and its correctness coverage remain; only this duplicate,
host-noise-sensitive timing assertion is deleted.

## Exact new files retained

The following files did not exist on the BYOK first parent and remain in the
review tree:

| File | Purpose |
| --- | --- |
| `docs/upstream-merge-2026-09-01.md` | Final merge additions, deletions, decisions, and verification record |
| `src/core/app/usage_dashboard_runtime.zig` | Asynchronous provider usage runtime |
| `src/core/auth/session_presence.zig` | Provider-neutral stored-session presence probe for Codex and Grok |
| `src/core/output/full_transcript_metadata.zig` | Full transcript metadata contract |
| `src/core/output/full_transcript_page.zig` | Paged full transcript output contract |
| `src/core/tooling/capability_retrieval.zig` | Skill capability retrieval owner |
| `src/ui/transcript/full_transcript_worker.zig` | Off-UI-thread transcript page loading |
| `tests/e2e/tui-performance.test.ts` | Terminal performance lifecycle benchmark and regression owner, without removed extension actions |
| `tests/evals/vision-capability-routing.test.ts` | Live vision route evaluation owner |

## Deletions

### Complete MCP vertical slice

The final pruning removes the entire MCP capability, including code introduced
by the upstream merge and older fork code that served the same feature.

Production removal:

- every file under `src/core/mcp/`, including local and HTTP transports,
  protocol negotiation, JSON schema handling, discovery caches, prompts,
  resources, tools, completion, elicitation, trust, authentication, health,
  subscriptions, and runtime coordination;
- `src/acp/mcp_servers.zig`, `src/builtins/mcp.zig`,
  `src/core/app/app_mcp_runtime.zig`, the merge-added app menu runtime,
  `src/ui/footer/mcp_menu_presentation.zig`, and `src/mcp_test_exports.zig`;
- `src/core/tooling/tool_mcp_dispatch.zig`,
  `tool_mcp_feature_dispatch.zig`, `tool_mcp_registry.zig`, and
  `tool_mcp_runtime.zig`;
- `src/core/auth/oauth_session.zig`, `src/core/hosts/native_keychain.zig`, and
  `src/core/hosts/native_secret_store.zig`, whose latest upstream owners were
  the removed Vercel/fx login flow or removed extension authentication. Codex
  and Grok continue through `provider_oauth.zig`, their provider session
  owners, and the provider-neutral stored-session probe;
- build registrations, composition-root imports, NAPI and WASM adapters, ACP
  initialization capabilities, provider host fields, and background menu
  polling for the removed runtime;
- profile and project configuration parsing, `.mcp.json` trust state,
  settings fields, status and doctor diagnostics, top-level and slash commands,
  menus, approval copy, and startup discovery;
- dynamic tool advertisement, selection, schema serialization, admission,
  review, dispatch, lifecycle presentation, tool-result conversion, compaction
  request fields, Responses output-item variants, and child inheritance;
- extension-specific context budgets and prompt guidance. The remaining
  capability budget belongs only to skills.

Test and release removal:

- `tests/e2e/mcp-auth.test.ts`, `mcp-http.test.ts`,
  `mcp-legacy-remote.test.ts`, and `mcp-stdio.test.ts`;
- all `tests/e2e/fixtures/mcp-*` fixtures;
- the complete `tests/e2e/conformance/` package;
- the standalone `tests/json-schema/` corpus, whose production owner was the
  removed dynamic-tool schema validator;
- pure MCP blocks embedded in CLI, ACP, gateway, startup, slash-menu, and TUI
  lifecycle suites;
- obsolete `mcpServers` placeholders in unrelated ACP and recovery requests,
  plus SDK tests and documentation that described a disabled extension bridge;
- stale E2E shard weights, PGSO training scenarios, corpus expectations, and
  Keychain exceptions that belonged only to those deleted files;
- stale normal-CI package installation, deleted-suite invocations, and ACP
  request placeholders. The fork-owned exact-commit Full CI remains the merge
  gate.

Generic tests were not discarded with those blocks. Unknown-tool rendering,
slash-menu metadata layout, response output ordering, permission presentation,
capability prompt exclusion, and provider subprocess diagnostics now use
generic fixtures and continue to protect their actual owners.

One additional TUI assertion was deleted after runtime diagnosis. It required
an exact token summary after an HTTP retry whose first request was already sent
but returned no usage. That number cannot be proven. Retry behavior remains
covered by the Gateway suite, and the adjacent TUI route-recovery test still
requires the visible retry state, final response, normal summary, two requests,
and clean stderr.

One upstream transcript test assertion was also deleted after tracing its live
owner. It required the installed full-transcript page cache to be null after
closing the viewer, but the new bounded paging design intentionally retains a
safe prepared page. The test still requires the real contract: returning to the
tail anchor without reviving stale viewer state.

README and repository instructions now state that skills are the extension
mechanism and that legacy MCP profile files are ignored.

### Other product and duplicate surfaces removed

These files existed on the BYOK first parent and remain deleted:

| File or slice | Reason |
| --- | --- |
| `src/core/tooling/tracked_file_mutations.zig` | Duplicate mutation tracking after typed file-mutation consolidation |
| `src/core/workspace/list_files_listing.zig` | Only served the removed `list_files` tool |
| `src/tools/filesystem/copy_file.zig` | Redundant command-shaped filesystem operation |
| `src/tools/filesystem/create_folder.zig` | Redundant command-shaped filesystem operation |
| `src/tools/filesystem/delete_file.zig` | Redundant command-shaped filesystem operation |
| `src/tools/filesystem/file_info.zig` | Redundant with direct reads and Unified Exec |
| `src/tools/filesystem/list_files.zig` | Redundant with `glob_files` and `rg --files` |
| `src/tools/filesystem/open_file.zig` | Host-specific side effect without a required agent contract |
| `src/tools/filesystem/rename_file.zig` | Redundant command-shaped filesystem operation |
| `src/tools/filesystem/semantic_search.zig` | Duplicate search surface without a distinct contract |
| `src/tools/memory/memory.zig` | Product feature without a supported BYOK persistence contract |
| `src/ui/catalog_screen_layout.zig` | Replaced by current typed menu presentation |
| `src/ui/skills_screen.zig` | Replaced by skill capability retrieval and inline presentation |
| `tests/e2e/tui-full-transcript-brutal.test.ts` | Redundant profiler, trace, RSS, and timing harness with deterministic coverage elsewhere |

The inert `--record` parser, old `terminal` and `run_command` execution paths,
duplicate orchestration state, copied tool registries, the partial Ctrl+Enter
steering policy, old full-detail modes, stale Vercel copy, and provider-specific
search aliases also remain removed.

### Model-facing tool surface after pruning

The remaining registered logical built-ins are:

`glob_files`, `grep_files`, `read_file`, `write_file`, `edit_file`,
`update_plan`, `web_fetch`, `web_search`, `exec_command`, `write_stdin`,
`capability_search`, `skill`, `install_skill`, `subagent`,
`ask_user_question`, `vision`, and `read_tool_result`.

`vision`, `web_search`, and `read_tool_result` are projected only when their
route and runtime contracts permit them. Bash-first can hide overlapping file
discovery tools for the next turn. Historical removed names may remain only in
session replay codecs or explicit non-executability tests and never become
dispatch targets.

## Protected BYOK decisions

- Codex Responses remains the default ChatGPT login route with account-bound
  endpoint behavior, encrypted reasoning replay, and native compaction.
- Grok and Codex OAuth, deterministic stored-session fallback, refresh, durable
  logout, TUI provider activation, and ACP provider control remain intact.
- Semantic compaction still has one strategy owner and one ordered fallback
  policy.
- Worker and gateway callbacks enqueue events; transcript mutation and rendering
  stay on the UI thread.
- Same-turn steering remains the default interactive contract.
- Unified Exec remains the only executable shell family and ACP observation
  keeps its independent cursor.
- Web Search keeps one logical capability with centralized provider projection.
- Web Fetch retains its explicit direct bounded-client admission exception.
- Connection-local BYOK URL and key snapshots remain bound together for parent,
  child, review, search, and compaction requests.

## Verification record

Local checks for the final pruning tree:

- [x] Debug Zig build completes.
- [x] The complete Zig test graph compiles and starts under WSL on `/mnt/d`.
- [x] That DrvFS run is classified as non-qualifying: 856 tests requiring POSIX
  private modes, locks, rename, and durable filesystem behavior fail across
  unrelated modules. The same suite must be rerun from native Linux storage.
- [x] `zig fmt --check src/` and `git diff --check` pass.
- [x] ReleaseSafe native build passes and writes the current binary to
  `./zig-out/bin/fx`.
- [x] Complete ReleaseSafe Zig tests pass from a clean native ext4 clone of
  merge commit `deac46be`: 7,750 tests passed and 24 were skipped by their
  declared guards.
- [x] Final affected Bun owners pass: ACP, session recovery, and Web Fetch
  119/119; the real `/skills` TUI happy path 1/1; shard planning 8/8; and PGSO
  corpus validation 32/32. Earlier reconciliation owners also passed: CLI
  77/77, Gateway 48/48, TUI Gateway lifecycle 62/62, and
  slash/skills/startup 56/56.
- [x] The three simplified SDK JavaScript test owners pass syntax validation.
- [x] Repository source, tests, scripts, build registration, and tracked file
  names contain no MCP implementation or fixture.
- [x] The freshly built binary opens the `/skills` TUI with clean stderr, its
  top-level help has no MCP entry, and `fx mcp` is rejected as an unknown
  subcommand with empty stdout.
- [x] The freshly built binary also completes `help`, `status --json`, and the
  isolated provider-neutral `setup --json` smoke path with clean stderr.
- [x] On the current review tree, native Windows ReleaseSafe builds and the
  focused credential-inventory plus native-profile presence tests pass. The
  freshly built Windows binary repeats the clean `help`, `status --json`, and
  isolated `setup --json` smoke paths; `fx mcp` remains non-executable.
- [x] Both `core` and `term` WASM surfaces compile locally in ReleaseSmall with
  the single-threaded credential-inventory path.
- [x] The focused Node/WASM terminal lifecycle test passes with the BYOK
  `Thinking` presentation, including stalled-fetch animation, Ctrl+C abort,
  active `/clear`, `/new`, and `/reset` recovery.
- [x] The complete ReleaseSafe Zig test graph passes on the current Windows
  review tree after the pending-frame scheduling repair.
- [x] The last code-bearing candidate `95be8bb3` passes
  [Full CI run 33567116826](https://github.com/acking-you/fx/actions/runs/33567116826):
  25/25 jobs across Windows, Linux, macOS, every deterministic E2E shard, and
  the portable WASM builds.

The final inventory commit `f3c7b7bc` also passed
[Full CI run 33591560365](https://github.com/acking-you/fx/actions/runs/33591560365)
with 25/25 jobs before it was fast-forwarded into `byok`. Ordinary CI passed
14/14 on its successful second attempt, the performance workflow passed, and
the binary-size matrix passed 4/4 on the same commit.

## Reviewer checklist

- [x] No Vercel onboarding or default product route returned.
- [x] Codex and Grok login, setup import, fallback, refresh, logout, and ACP
  provider control remain intact.
- [x] MCP has no executable, configurable, documented-as-supported, or tested
  product surface.
- [x] Skills remain the only extension mechanism.
- [x] Removed tests have no surviving product owner; generic contracts retain
  focused coverage.
- [x] Compaction still has one strategy owner.
- [x] Worker callbacks do not mutate transcript state directly.
- [x] Same-turn steering and its completion-race fallback remain intact.
- [x] Unified Exec retains one model-facing command family and independent ACP
  observation.
- [x] Web Search projection and Web Fetch admission exceptions remain intact.

The reviewed commit was fast-forwarded into `byok`, so the merge did not create
an additional unverified tree or merge commit.
