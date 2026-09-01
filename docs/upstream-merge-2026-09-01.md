# Upstream merge review — 2026-09-01

## Review status

This document records the reconciliation of the latest `vercel-labs/fx` mainline into the BYOK fork. The result is intentionally held on `merge/upstream-2026-09-01` for review. It has not been merged into `byok`.

The merge boundary is:

| Item | Commit |
| --- | --- |
| BYOK first parent before the initial content merge | `fe2ec9e05250ccc789d6a3d939fcd0b72cd6157c` |
| Initial upstream main merged | `1685a855868820a1b9f317dc589190c32b011684` |
| Initial content merge | `d7d3f8f2d471cb1c6a6c8cb306b19d312ba64ab0` |
| Prior upstream main merged | `24ff3083cb3e19cdc818403ecbc40ff14ace04c9` |
| Prior update merge | `f3ad5781` |
| Latest upstream main merged | `766e70f0106393b551e2363526cf6a41e60587c3` |
| Latest update merge | `867eddd7` |
| Final merge-regression repair | `8a0e7c90` |
| Final runtime and E2E contract repair | `30ca1e45` |
| Final asynchronous E2E stabilization | `8431e1a4` |
| Final asynchronous completion-boundary repair | `36f0b037` |
| Final committed transcript-navigation repair | `0bffb9db` |
| Final committed scroll-attempt repair | `64c2f6e6` |
| Final verified navigation batching | `6a29c074` |
| Review branch | `merge/upstream-2026-09-01` |

Compared with the pre-merge BYOK tree, the review result changes 248 files with 29,140 insertions and 17,262 deletions. The large count comes primarily from upstream MCP, transcript, rendering, and E2E work. It does not represent a new vendor product route or a large new model-facing tool surface.

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

A terminal `no_match` result now removes `capability_search` from only the immediately following model step. This prevents an empty capability search from broadening or repeating while allowing later tool groups to regain the unified discovery capability. Projection remains centralized in `tool_projection.zig`; the orchestrator does not own a second policy.

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
- the complete top-level `fx mcp` surface for `add`, `remove`, `path`, `list`, `auth`, `logout`, and project `trust` operations;
- side-effect-free MCP configuration snapshots in `status` and `doctor`, with transport discovery reserved for explicit `mcp list --connect`;
- Docker command normalization for configured MCP servers;
- a consolidated MCP catalog/menu instead of separate overlapping screens;
- bounded HTTP content-length handling and runtime compatibility checks.

This does not add a second model-facing MCP search tool. Dynamic selection remains behind `capability_search` and `mcp_select_tool`.

The final merge audit found that upstream's menu worker and state machine had been retained while the composition-root completion poll had been dropped. That omission left authentication, logout, reload, and other generated menu effects waiting indefinitely after their background task finished. `loopCollectFacts` now collects the menu completion, schedules a reload when requested, records failures through the MCP runtime, and requests only the footer frame. This restores the existing generic MCP owner without adding another task loop or product policy.

### Full transcript details and asynchronous loading

Ctrl+O full transcript support now retains richer turn metadata, paginates large histories, and loads detailed pages away from the UI loop. This was kept because it improves observability without changing provider policy.

The composition root now polls both the main and active child full-transcript page workers and requests a modal frame when a page completes. The merge had retained the worker but dropped this completion polling, leaving Ctrl+O and render-lab stuck at `Preparing full detail…`.

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

The merge briefly carried part of upstream's newer explicit submission split: ordinary Enter queued a next turn while Ctrl+Enter used a separate steering intent. That conflicts with the fork contract and duplicated prompt admission policy. The complete product slice was removed: the `steer_submit` action, Ctrl+Enter escape decoding, the second submit intent, the composition-root `steerPrompt` adapter, the streaming `enter queue` hint, and their test-only state. One ordinary submission path again admits same-turn steering by default, including prompts with images or skill bindings. A manual queue review blocks steering consumption, and a late input retains FIFO next-turn fallback.

The queued-prompt preview dropped during conflict resolution was restored. The footer again shows the terminal-safe text of the first pending steering prompt while the active response streams, but yields to explicit queue-review cards while paused so the same prompt is never painted twice.

Primary paths:

- `src/core/agent/worker_runtime.zig`
- `src/core/agent/runtime/orchestrator.zig`
- `src/core/app/app_callbacks.zig`
- `src/ui/footer/input_presentation.zig`

### Prompt history ownership

Recalled slash commands remain prompt-history entries until the user edits them. Plain Up and Down therefore continue navigating history instead of handing control to the slash menu merely because the recalled text begins with `/`. The slash menu is temporarily suppressed for the recall episode, reappears after an edit, and remains normally available for a newly typed slash command. This is a bounded input-state bug fix with focused Zig and deterministic TUI coverage.

Primary paths:

- `src/core/input/composer_history.zig`
- `src/core/input/picker_state.zig`
- `src/core/app/input_completion_runtime.zig`
- `tests/e2e/prompt-history.test.ts`

### Empty slash completion menus

An unmatched slash prefix now remains ordinary editable composer input without reserving a non-selectable `no matching slash commands` row. Escape therefore retains its normal composer behavior when there are zero candidates, while a visible candidate menu still owns Escape. Deleting back to a matching prefix restores the menu, and command arguments retain their existing completion ownership.

The change was kept because it removes a presentation-only empty state without adding product state or a second input policy. The upstream absolute-path scenario was also made host-independent so the same fixture runs on Linux and macOS. Focused Zig coverage and the complete slash-menu and render-stress TUI files exercise the transition.

Primary paths:

- `src/core/app/input_completion_runtime.zig`
- `src/ui/footer/input_presentation.zig`
- `src/ui/footer/surface_frame.zig`
- `tests/e2e/tui-slash-menu.test.ts`
- `tests/e2e/tui-render-stress.test.ts`

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

The final CI reconciliation also fixed two merge regressions and one Windows process bug:

- the WASM no-MCP loader now implements the current workspace-aware loader contract;
- the top-level MCP help, parser, runtime dispatch, profile mutation providers, and status/doctor inspection now form one complete vertical slice instead of a help-only stub;
- Windows child processes that need environment overrides clone the native wide environment into WTF-8, avoiding `InvalidWtf8` when MCP stdio servers are launched from a localized environment.

The final regression audit added four more repairs:

- full-transcript page completion is polled for main and child conversations;
- a terminal capability-search miss suppresses only the next step's duplicate search surface;
- queued steering text and the fork's default same-turn admission contract are restored while upstream's conflicting explicit-submit surface is deleted;
- file-index retry tests now verify the successfully indexed fixture filename instead of asserting the obsolete zero-file count. Their temporary roots are independent Git worktrees with the target file tracked, so production's authoritative Git discovery does not mistake a parent worktree's ignored `.zig-cache` for the fixture contract.

The last CI reconciliation restored the missing MCP menu-completion poll described above. The remaining failures were obsolete or timing-sensitive deterministic fixtures rather than new production branches: ACP and subagent gateways now emit and recognize the current Responses function-call protocol, transcript fixtures use the retained single full-detail screen, settings and page-load assertions wait for their asynchronous owners, recording fixtures use `FX_DEBUG_RECORD` instead of the deliberately removed `--record` input, and remote compaction waits for the actual opaque compaction request instead of a removed transient label.

The arm64 timeout regression was a loaded-runner gap in the test, not a production deadline change. Production still permits the documented 200 ms supervisor handoff fallback. The test effect now lands after that fallback window and proves the command remains bounded rather than depending on a 100 ms scheduling gap.

### Agent step integrity and dynamic MCP execution

The merge now retains the upstream action-oriented decision boundary after every completed tool batch and after confirmed-result recovery. The decision instruction is appended as one no-cache user message, is suppressed when same-step steering already supplies the next instruction, and cannot end a turn with only a progress update while executable work remains.

Subagent turns receive one stable trace and lifecycle identity before finalization. Dynamic MCP calls are validated against the last live runtime generation immediately before execution, so a tool advertised by an earlier generation cannot be redirected into a replacement runtime. Tool errors emit one canonical pair of final trace events after output preparation instead of an early error record plus a second contradictory result record.

### Vision routing and verified image snapshots

Image routing is owned by one `image_input_support` policy:

- native-image models receive verified native image inputs and do not see the `vision` fallback tool;
- non-native models receive the text-only authorized image catalog and see `vision` only when the provider and registry both support the fallback;
- unknown or unavailable capability states fail closed instead of guessing a route.

The same decision source is used for native and fallback message projection. Windows path-backed Vision reads now align native handle flags before positional reads. Verified snapshot loading reuses the shared no-follow regular-file opener, rejects symlinked or reparse-point directory chains, and normalizes the Windows no-follow error into the typed unsafe-path result.

### Portable trace append and profile settings

Debug trace files now append through Zig's file writer at the current stat size. The prior C `lseek` call treated a Windows `HANDLE` as a C file descriptor and could overwrite earlier trace lines. A regression verifies that multiple records survive in order.

The existing `collapse_tool_calls` profile setting is now parsed and merged by the profile configuration owner. This completes an already-present setting rather than adding a second presentation switch.

## Exact new files retained

These files did not exist on the BYOK first parent and are present in the review result:

| File | Purpose |
| --- | --- |
| `docs/upstream-merge-2026-09-01.md` | This exact additions, deletions, conflict-decision, and verification record |
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

The unreferenced `src/builtins/system_prompt.md` remains deleted. Its runtime owner is the typed prompt assembled in `src/builtins/context.zig`; the repository has no file reader or build dependency for the Markdown copy. The latest upstream removal of two redundant verification instructions was applied to that typed owner instead of resurrecting the duplicate file.

The final reconciliation also removed the inert `--record` launch parser, its unused intent field, its early-startup special case, and tests for behavior that no longer had a runtime owner. `--record` is now ordinary unknown input. A stale `credits` early-I/O predicate was removed with it because the fork has no top-level credits command. Two E2E assertions that required a model catalog request even when `FX_MODEL` already selects a direct Responses route were also deleted; they tested an unnecessary network side effect rather than the ask contract.

The automatic replay fixture no longer passes the removed `--record` input while also enabling environment-driven recording. It now exercises only the supported `FX_DEBUG_RECORD` path. Full-transcript fixtures no longer require the deleted intermediate `Review` depth or left/right mode switching; Ctrl+O owns one asynchronous full-detail surface. Assertions tied only to a transient resume notice surviving native-scrollback reopening, a hidden row beyond the retained replay cap, or internal animation trace scheduling were deleted. The retained assertions still prove the restored session contents, replay cap, elapsed activity updates, marker animation, and unchanged native scrollback. These deletions remove test-only compatibility expectations and do not remove user-visible runtime behavior.

Upstream's partial Ctrl+Enter steering split was also deleted as a conflicting duplicate. Removed code includes the `steer_submit` input action, Kitty Ctrl+Enter decoder branch, secondary `Intent` dispatch, `steerPrompt` composition adapter, `enter queue` stream hint, and their dedicated fake-app fields and tests. No `/steer` command or second prompt queue remains. The model-facing and user-facing contract is the fork's single default steering path described above.

One permission test for searching outside the workspace was deleted because it depended on the removed semantic-search era target classifier and no longer exercised the registered `grep_files` contract. The live-authority regression was rewritten around the current registered `skill` tool, preserving the authority refresh assertion without resurrecting the deleted `create_folder` implementation. Other failing expectations were updated only where the retained runtime contract had deliberately changed: account picker wording, Unified Exec labels, collapsed code-block borders, action-oriented post-tool messages, and removal of `--record` from resume usage.

The final upstream update also modified the deleted Vercel Gateway transport to shorten Exa highlights and added provider-specific Exa, Parallel, and Perplexity search accounting to trace reports. Those changes were intentionally not retained. After removal of `src/builtins/gateway.zig`, the fork has no production owner for the Gateway Exa provider advertisement; retaining its alias table, hard-coded provider names, fixed tool indices, `terminal` fixtures, and trace-only tests would be unreachable duplicate policy. The provider-neutral `web_search` projection and its existing TUI, ACP, CLI, child-session, Codex, Responses, and Grok lifecycle remain the sole search contract.

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

The remaining `selected_model` compile guards are restricted by `builtin.is_test` inside `provider_runtime.zig`. They adapt existing fake-app fixtures that still own an `ArrayList`; production instantiations require the typed `provider_selection` runtime. They are therefore test scaffolding rather than a second production selection owner.

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
| `399cbf6d` | Restore the generic top-level MCP vertical slice, remove inert recording compatibility, repair WASM loader compilation, and fix Windows MCP child environments |
| `d17eb51a` | Restore post-tool continuation, dynamic MCP generation binding, trace lineage, native-versus-fallback Vision policy, portable image reads, and cross-platform trace append |
| `f3ad5781` | Merge upstream through `24ff3083`, retaining prompt-history ownership while discarding unreachable Vercel Gateway and provider-specific search-trace additions |
| `8a0e7c90` | Restore full-transcript polling, terminal capability no-match projection, queued steering presentation, and default same-turn admission; delete the conflicting explicit-submit slice; align deterministic fixtures and bound the supervisor timeout test |
| `867eddd7` | Merge upstream through `766e70f0`, keep the deleted prompt copy deleted, apply its verification cleanup to the typed prompt owner, and retain the zero-candidate slash-menu and portable-path fixes |
| `30ca1e45` | Restore MCP menu completion polling and align deterministic fixtures with current Responses, transcript, replay, settings, compaction, and asynchronous page-load contracts |
| `8431e1a4` | Replace stale transient-phase waits and make full-transcript and artifact navigation observe their asynchronous page boundaries |
| `36f0b037` | Make full-transcript pagination, full-detail loading, resize, length-truncation lifecycle, and elapsed-time assertions observe their committed asynchronous states |
| `0bffb9db` | Require each brutal full-transcript navigation step to commit a changed viewport offset before sending the next input |
| `64c2f6e6` | Distinguish committed, clamped, and page-loading transcript scroll attempts; retry ignored inputs without consuming navigation progress |
| `6a29c074` | Amortize tmux invocation cost with four-key navigation batches while retaining the committed-scroll verification boundary |

## CI policy for this merge

The authoritative gate is `.github/workflows/full-ci.yml` on the exact review commit. It is the fork's feature-branch workflow and includes:

- ReleaseSafe native build, unit tests, formatting, public-surface audit, and binary smoke on Linux x86_64, Linux arm64, macOS x86_64, and macOS arm64;
- four isolated ReleaseSafe E2E shards on each of those platforms;
- one `Full suite (...)` aggregate per platform that requires its native job and all four E2E shards;
- a separate Windows native job with provider setup, OAuth callback, Unified Exec, CLI, and ACP smoke coverage.

Only a run attached to the commit containing this document is acceptable. All four `Full suite (...)` aggregates must succeed. A passing upstream run, an older fork commit, or only the Windows job is not proof.

An earlier run on `7629b56386572c4c38bda8a45634556e7c10efa4` was cancelled after its Linux and macOS arm64 unit jobs exposed 24 stale or regressed assertions plus one configuration crash. Those failures were audited individually. The complete 201-test `processQueuedPrompt` family now passes locally in ReleaseSafe, and focused ReleaseSafe coverage passes for every remaining failed owner. Because the fixes change the commit, that cancelled run is evidence used during repair and is not accepted as the merge gate. A new Full CI run on the final document commit is required.

Run `33465449602` on `d4abc25a93d7172ae338744a0dcd0351ed6c790f` was also cancelled before qualification when a final fetch showed that upstream had advanced to `24ff3083`. It had no authority over the later merge result. The next run must be attached to the commit containing the latest-upstream merge and this updated document.

Run `33466109301` on `068cc59e378c2ecc1ad76c907914ac80cd612f39` passed Windows native, Linux x86_64 native, and macOS arm64 native, then exposed one loaded-runner arm64 timeout assertion and deterministic E2E shard 2 failures. The E2E audit separated merge omissions from stale expectations: missing full-transcript polling, missing one-step capability projection, missing queued prompt preview, incomplete same-turn steering composition, stale Responses event fixtures, stale post-tool request detection, skill-order assumptions, and presentation-label drift. This run is repair evidence only; commit `8a0e7c90` and the document commit that follows it require a new exact-commit Full CI run.

Run `33474328921` on `8b733899b349eb1d1562d668d1e54f2c15b742c2` passed Windows native and Linux x86_64 and arm64 E2E shard 2, then reproduced the same two file-index retry fixture failures in all three completed Linux and macOS arm64 native jobs. The loader reached `ready`, but the fixture lived beneath the parent worktree's ignored `.zig-cache`; authoritative Git discovery therefore correctly returned an empty generation. The tests now initialize their temporary roots as independent Git worktrees and track `retry.txt` or `queued.txt`, preserving the production discovery path while removing cache-location dependence. This run was cancelled after the shared cause and ext4 reproduction were proven; it is repair evidence, not the final gate.

Run `33475586156` on `8c0a59b1f3275666ae5ca9c131217c4d7298179c` proved that the file-index repair was portable: all four completed Linux and macOS native jobs passed, as did every platform's E2E shard 2. The other E2E shards exposed one real composition omission and several fixtures still asserting removed or asynchronous behavior. The real omission was the MCP menu-completion poll; a focused authentication and logout lifecycle passes after restoring it. The fixture repairs cover current Responses events and function-call output, direct full-detail entry, supported environment-driven recording, asynchronous settings persistence, remote-compaction request admission, child approval takeover, and completed page loading. A native-scrollback test now waits for the initial one-copy retention invariant before resizing, then still requires exactly one copy afterward. The macOS brutal transcript case now waits until asynchronous full-detail preparation has completed before sending its next navigation input.

The same run's Windows native job failed the Unified Exec cleanup test while terminating an intentionally still-running process and reported leaked allocations. The immediately preceding exact run passed that Windows job with the same production implementation, so this is treated as a possible loaded-runner timing failure, not waived. The next exact-commit Full CI must pass Windows native; a repeat will be diagnosed before review is considered qualified. Run `33475586156` was cancelled after its failures were reproduced locally and the commit was superseded.

Run `33480305376` on `55a7d97344ea0c599489d750ffc61b1ab10526e1` passed every native job on Windows, Linux x86_64, Linux arm64, macOS x86_64, and macOS arm64. It also passed E2E shard 2 on all four Unix platforms and shard 3 on both Linux architectures. The prior Windows Unified Exec cleanup failure did not reproduce.

The stable E2E failures in this run reduced to four test contracts. Two held-text cases waited for the transient `Thinking` frame after the unified phase owner had already entered the stable `Generating` phase. The full-transcript brutal test treated a loaded newest page as proof that its final marker was already inside the visible viewport; it now pages down until the durable tail is visible before paging up to prove that the oldest entry remains reachable. The cancelled-command artifact test sent 500 PgDn sequences in one tmux input burst; macOS could discard part of that burst even though the greater-than-1-MiB artifact was intact. It now sends bounded batches, observes the viewport after each batch, and still requires the final artifact marker. All four focused scenarios pass locally after the repair.

Several macOS 30-second or 90-second slow frames occurred in only one of the two file attempts while the same scenario passed in the other attempt and on other platforms. They did not share a production trigger with the stable failures. No production timeout, synchronization, or compatibility path was added for those one-attempt runner delays. Run `33480305376` is diagnostic evidence only because commit `8431e1a4` changes the tested tree; a new exact-commit Full CI run remains required.

Run `33484200868` on `3966902feaa600d77ee05e5dcf35cc3222c1eac8` proved the bounded artifact navigation repair on macOS x86_64 and the stable `Generating` phase repairs on Linux arm64. Its transcript-brutal failure on both macOS architectures showed that sending even 64 PgDn events as one tmux batch could still discard input: each attempt advanced only a few visible markers. The test now sends one navigation event at a time and waits for a later render trace before issuing the next event, preserving the full oldest-to-newest reachability assertion.

The same run exposed three other premature observations. A compact full-detail assertion accepted the footer while `Preparing full detail…` was still visible; the shared helper now requires preparation to finish. The remote-compaction fixture required an irrelevant exact `0s` elapsed label while still retaining exact token counts; it now accepts the committed elapsed duration. The resize and provider-length-limit tests sampled after the trigger text or debounce delay but before the final footer or failed-tool lifecycle frame; each now waits for the exact stable state it asserts. Focused WSL/tmux runs pass for these boundaries. Different single-attempt macOS slow frames passed in the adjacent attempt or on the other platforms, so they did not justify a production timeout or synchronization branch. Because commit `36f0b037` supersedes this diagnostic run, a new exact-commit Full CI run remains required.

Run `33487617463` on `9e50d1e03691ea366188bac816b1e9258d61128e` passed Windows native, both Linux native jobs, all eight Linux E2E shards, macOS arm64 native, and macOS x86_64 shard 2 before the transcript-brutal test failed twice on macOS arm64 shard 3. The test sent one key at a time, but it accepted any later projection frame as completion; asynchronous page-loading frames could satisfy that condition before the requested scroll committed. Both attempts therefore exhausted 1,024 sent keys while still around live marker 310–325. The repair records the previous viewport offset and uses the existing trace contract to require a different committed offset after every PageUp or PageDown. The complete focused stress then passed locally with 118 assertions in 71.8 seconds, compared with approximately 150 seconds for each failed CI attempt. The run was cancelled after this stable cause was proven and commit `0bffb9db` superseded it.

Run `33489826458` on `2d3eee8fbf3a56c13689a77b058964dc53aadedf` passed all five native jobs, all eight Linux E2E shards, macOS x86_64 shards 1, 2, and 4, and macOS arm64 shard 1. Its macOS arm64 shard 3 trace showed a legitimate page-tail clamp: the scroll state advanced from 7,332 to 7,358 rows, while the rendered window remained at the current page's 7,332-row maximum. Requiring the visible offset itself to differ was therefore too strict. The final test state machine instead requires a non-ignored scroll event followed by its committed viewport frame, permits a clamped offset, and separately recognizes `page_loading` rejection so it can wait for the loading frame and resend without consuming progress. The full focused stress passes locally with 118 assertions in 71.5 seconds. The run was cancelled after commit `64c2f6e6` superseded the failed assertion.

Run `33493575103` on `e3ab35bb25525b6f1a58b89404623e7367748127` passed the other 19 underlying jobs, including all native platforms, all Linux E2E shards, and every macOS shard except shard 3 on each architecture. The final state machine correctly rejected page-loading loss and accepted committed page-tail clamps, but one tmux process invocation per Page key remained too expensive: after 1,024 verified calls, macOS x86_64 reached live marker 460–467 in roughly 162–169 seconds and macOS arm64 reached marker 305–317 in roughly 148–152 seconds. Raising the limit would exceed the test's 240-second budget once reverse navigation is included. The test now sends four Page keys per tmux invocation, then requires the same non-ignored scroll event and committed frame before proceeding. This is far below the discarded 64-key burst, retains deterministic progress verification, and reduced the complete local stress from 71.5 to 39.3 seconds with all 118 assertions retained.

The smaller `.github/workflows/ci.yml` workflow is not used as the merge decision. Benchmark and binary-size workflows are retained because startup latency and unexplained binary growth are useful signals; neither replaces Full CI.

## Local verification completed before push

- `zig fmt --check src/`
- `zig build -Doptimize=ReleaseSafe`
- `zig build -Dwasm-surface=core -Doptimize=ReleaseSmall`
- `zig build -Dwasm-surface=term -Doptimize=ReleaseSmall`
- ReleaseSafe filtered Zig tests covering compaction, same-turn steering, worker/UI thought queueing, newline-free assistant display, Unified Exec observer isolation and nonblocking direct control, web-fetch policy bypass, web-search projection, provider activation cancellation, bash-first projection, and shared usage snapshots
- Focused Zig tests covering top-level MCP parsing, one-pass status/doctor MCP inspection, and Windows wide-environment cloning for child process overrides
- The complete 201-test ReleaseSafe `processQueuedPrompt` family, including post-tool continuation, confirmed-result recovery, same-step steering suppression, Vision routing, MCP runtime generation binding, lifecycle presentation, and trace identity
- ReleaseSafe verified-snapshot coverage for inline bytes, ordinary files, symlinked files, and symlinked directory chains, including the Windows no-follow path
- ReleaseSafe focused regressions for `collapse_tool_calls`, canonical multi-line trace append, current registered-tool live authority, provisional tool labels, account picker and approval rendering, resume usage, evidence-led prompts, and collapsed semantic code blocks
- ReleaseSafe prompt-history regressions for slash-command recall suppression, plain-arrow ownership, draft restoration, and re-enabling slash completion after editing
- ReleaseSafe focused regressions for one-step terminal capability suppression, default same-turn admission, queue-review exclusion, late FIFO fallback, and the bounded supervisor handoff deadline
- ReleaseSafe build plus focused Zig filters for slash-completion ownership and the typed gateway system prompt after merging upstream through `766e70f0`
- Complete `tui-slash-menu.test.ts`: 38 passed, including the zero-candidate transition, candidate restoration, Escape ownership, command arguments, and active-stream behavior
- Complete `tui-render-stress.test.ts`: 1 passed, exercising unmatched slash input together with repeated resize and local transcript writes
- Complete `acp.test.ts`: 129 passed, including the current Responses markdown stream and child function-call-output continuation
- Complete `tui-resume.test.ts`: 45 passed, including replay-cap, full-detail spacing, session-picker, scrollback, and resume ownership cases
- Focused live-stream `/resume` refusal passed while waiting on the current stable `Generating` phase
- Focused active-turn image steering passed while retaining its request-order, instruction-snapshot, image-byte, and stderr assertions
- Focused greater-than-1-MiB cancelled-command artifact navigation passed with bounded PgDn batches and 60 retained assertions
- Focused full-transcript brutal stress passed with 118 assertions after four-key verified batches distinguished committed or clamped scroll frames from page-loading rejection and explicitly proved both the newest tail and oldest entry are reachable
- Focused height-shrink footer and provider length-truncation lifecycle cases passed through the stable post-resize and failed-tool states
- Focused MCP authentication and logout lifecycle passed after restoring menu-completion collection in the composition root
- Focused remote native compaction and Codex Vision failure cases passed with request-level and current structured-result assertions
- Focused asynchronous statusline persistence, native-scrollback resize retention, and brutal full-transcript page-load cases passed
- Focused automatic-recording and replay cases passed through the supported environment-driven recording contract
- Three sensitive subagent cases passed together: reusable child file approval, approval takeover across Ctrl+X reopen, and selected-child live chat
- The idle running-activity case passed after deletion of its trace-internal scheduler assertion; it still proves elapsed-time progression, both animation marker states, native-scrollback stability, final output, and empty stderr
- The exact Linux E2E shard 2 selected by `tests/e2e/ci-shards.ts`: all 12 files passed with CI's isolated tmux and one-file-at-a-time execution, including 115 terminal-host tests, 55 gateway lifecycle tests, render-lab, composer editing, file paths, web fetch, prompt history, and native clear recovery
- The four previously failing queued steering TUI scenarios passed together: post-cancel recovery, image-bearing steering, ordinary next-step steering, and paused FIFO queue review
- The complete ReleaseSafe Zig suite passed on a WSL ext4 copy with CI-equivalent default `.zig-cache` and Zig on PATH. The initial `/mnt/d` run was discarded because DrvFS cannot represent the private mode and rename contracts tested by the suite
- File-index allocation and queued-refresh recovery now assert that `retry.txt` and `queued.txt` are actually searchable after the successful retry
- The two file-index retry regressions pass in an ext4 checkout with parent Git metadata and the default in-worktree `.zig-cache`, matching the directory condition that failed on Linux and macOS CI
- Windows provider tests covering Codex CLI parsing, Grok Build parsing, setup secret redaction, OAuth fallback order, ChatGPT and Grok callback path/state validation, ephemeral ports, delayed callback bytes, and Windows AFD reset handling
- Repository-wide `bun x tsc --noEmit` was attempted and remains blocked by pre-existing baseline errors in untouched fixtures and library targets, including unavailable `findLast` declarations, legacy fixture shapes, and nullability mismatches. Full CI compiles and runs each selected Bun test file; no TypeScript-only success is claimed for this merge.
- Bun E2E: removed filesystem tools are absent and Unified Exec completes the flow
- Bun E2E: removed memory is not advertised, cannot mutate the legacy store, and does not prevent a surviving tool call
- Bun E2E: no-save ask advertises the Unified Exec surface and completes through a fake Responses gateway
- Bun E2E: all nine focused CLI cases for removed recording input, explicit skill binding, stdin above the former 1 MiB boundary, MCP status/doctor inspection, MCP connection, profile add/remove/path/list, concurrent mutation, and invalid syntax pass on Windows
- Fresh binary smoke with `./zig-out/bin/fx help`, `status --json`, and provider-neutral `setup --json`
- Fresh binary MCP smoke with an isolated HOME covering `mcp path`, local `add`, passive `list`, connected discovery, `remove`, plus MCP snapshots in `status --json` and `doctor --json`
- Fresh binary ACP interaction covering initialize, session creation, setup start, and nonblocking setup status
- Current-tree Windows x86_64 ReleaseSafe cross-build followed by direct execution of `./zig-out/bin/fx.exe`: `help`, `status --json`, and provider-neutral `setup --json` exited cleanly; setup detected `codex_cli` and `grok_build` without access-token or API-key fields
- Current-tree Windows ACP smoke returned initialize, session creation, provider setup start, and nonblocking setup status with empty stderr

The local setup smoke detected both `codex_cli` and `grok_build` sources without printing credential bytes. The full unfiltered Zig suite was run locally on WSL's native ext4 filesystem because the test graph requires POSIX private-mode, lock, rename, and process semantics; Windows still runs the explicit native subset in Full CI.

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
