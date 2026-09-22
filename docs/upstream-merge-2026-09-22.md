# Upstream reconciliation, 2026-09-22

| Boundary | Revision |
| --- | --- |
| Updated BYOK first parent | `a835ea1255f78ccdf0d272f469833e8ba9ad002b` |
| Previous upstream ancestor | `e26e97ec4040827b86a1c70c62273e0a8546d3e5` |
| Upstream merge parent | `1b5a516a2c795f05801332f6ce372ea68299481b` |
| Review branch | `merge/upstream-2026-09-22` |
| PR target | `byok` |

The upstream mirror was fast-forwarded in its existing worktree. BYOK was
fast-forwarded to the merged inspection fix before creating an isolated merge
worktree. The original checkout's untracked `pelican-bike.html` was preserved.

This is a real merge with both parents. Land it using a merge commit or a
fast-forward that retains the upstream ancestry. Squashing or rebasing this
integration would make Git present the same upstream changes again next time.

The incoming range contains 119 first-parent commits and changes 325 files.
The initial merge had 201 conflicted paths, including 62 files already deleted
by the fork. Resolving the ancestry does **not** mean importing every upstream
feature: the following inventory records the actual resulting behavior.

## Accepted shared changes

| Area | Reconciliation |
| --- | --- |
| Custom themes | Native fx and VS Code JSON palettes; profile `theme` and environment precedence; light/dark pins; sibling-variant fallback; live theme updates through the existing UI owner. Keep BYOK reasoning styles and selected-effort presentation. |
| Syntax highlighting | Move the shared highlighter into core presentation; accept additional language profiles, shell flags/operators/variables, theme slots, diff markers, and correct link color restoration while wrapping/streaming. |
| Markdown links | Port the independent balanced-parenthesis and optional-title destination parser. Keep BYOK's existing streaming delimiter behavior. |
| File picker | Load a persisted index as a startup preview, then replace it with a real scan. Adapt to BYOK's immutable access-scope API and retain its scope-change, cancellation, path-validation, and current-candidate checks. |
| Question resolution | Wrap complete questions and answers into hanging continuation rows instead of truncating them. Keep the existing permission/question owner. |
| Search evidence | Normalize absent/empty search roots to `.` while preserving the fork's durable execution-memory masking and tool semantics. |
| PGSO tooling | Accept profile/link qualification, artifact provenance, bounded symbol-output capture, and process-exit timing. Retain the fork's native runners, corpus owners, and release routing. |
| Shared cleanup | Accept unused-field/declaration removals where fork callers do not need them, and retain compatible render-lab coverage. Port the native-clear probe guard for alternate screens so typing in Ctrl+O does not reset the transcript. |

## Preserved architecture and explicit follow-ups

These are coherent fork owners, not mechanically selected conflict markers.
The incoming implementations assume contracts the fork does not currently use.
Their useful new functionality needs a dedicated port; this merge does not
claim that it is available in BYOK.

| Upstream area | Retained BYOK boundary and follow-up |
| --- | --- |
| Schema-4 canonical conversation metadata, history snapshots, session-log compaction, archive-backed Ctrl+O, spilled file-diff snapshots | Keep BYOK's event authority, watermark/checkpoint replay, durable usage, history pagination, result stores, and transcript retention. A future migration must cover existing sessions, opaque Responses compaction, child sessions, and result locators as one change. |
| Configured-provider registry, provider identity union, Chat Completions, gateway provider ordering | Keep direct Responses URL/key bindings, environment/profile configuration, Codex/Grok credentials, connection-local snapshots, and current persisted preferences. The generic registry/Chat Completions feature is useful and is deferred, not rejected as vendor-specific. |
| Shared gateway connection pool | Keep current transport ownership. Port only with the custom endpoint lifetime, provider switching, permission reviewer, compaction, and child route snapshots accounted for. |
| Managed `run`/`message` subagents and their status/model-override wiring | Keep persistent `create`/`send`/`inspect` control, authority checks, approval ownership, and manager UI. Preserve PR #44's allocator and single-replay fixes unchanged. |
| Autonomous response recovery, reviewer transport retries, new embedded SDK steering/tool/image wiring | Keep the fork's current runtime, same-turn steering, single compaction strategy, exact-action review policy, and Responses/ACP host contracts. These changes require owner-specific ports rather than parallel policy paths. |
| Standalone upstream PGSO artifact comparison | Defer `benchmarks/pgso_artifacts.test.ts`: it hard-codes `vercel-labs/fx` artifacts on `main`, Vercel gateway credentials, and the deferred autonomous-recovery scenario. It has no BYOK workflow caller. Keep the existing fork PGSO pipeline and the PR #44 inspection memory/latency benchmark. |
| Notice glyph/casing and streaming delimiter changes | Keep fork plan, reasoning, permission, cancellation, and existing presentation semantics; custom themes and link colors are integrated separately. |
| MCP, Vercel onboarding, old shell tools, automatic vendor upgrade, Slack installer | Keep the removed or unsupported product slices absent. No executable `run_command`/second shell backend, MCP configuration/transport, or Vercel login route is restored. |
| Upstream release versions and release workflow | Keep the fork's version and `byok` release owner; this sync is not a fork release. |

The new upstream-only tests for deferred or excluded product owners are not
added. Existing generic/fork regression tests are retained. The additional
custom-theme E2E cases live in the already-classified `tui-startup.test.ts`
training owner; no root E2E owner or shard entry is orphaned.

## Local evidence

- ReleaseSafe native build and Windows x86_64 cross-build; formatting,
  public-surface audit, and whitespace checks. Cache permission and file-handle
  handling uses BYOK's existing portable helpers; Windows CI also runs the
  cache round-trip/tampering test.
- Focused Zig coverage for themes, file indexing, links/images, inline code,
  highlighting, questions, search evidence, and both PR #44 allocation guards.
- Fresh native binary: seven custom-theme TUI cases plus a 128-step inspection
  loop, persisted stop, and successful follow-up; eight cases passed with clean
  stderr and a live process.
- File-picker TUI: 15 deterministic cases passed, including rapid refresh,
  large indexes, scope/path changes, and two process-resume cycles. One existing
  credentialed live-provider case was skipped.
- Native-clear TUI: all five cases passed, including typing inside Ctrl+O;
  three focused question/approval wrapping cases also passed.
- PGSO Python suite: all 192 tests passed after reconciling the corpus and
  process-exit timing checks.
- Existing native inspect benchmark: 64/64 completed under a 2 GiB address-space
  limit, 40.46 MiB peak RSS, 8.47 ms mean tool span and 10 ms P95. This is one
  regression run during concurrent build activity, not a new controlled
  performance comparison or replacement for PR #44's multi-run results.

Full CI on the exact PR head remains the release/readiness gate. Its final
result belongs in the PR, rather than treating any older BYOK run as evidence
for this merge.

## Upstream memory issue evidence

The [separate investigation](upstream-subagent-memory-2026-09-22.md) contains a
pinned production call chain and reproducible diagnostic patch. It confirms
turn-arena retention in upstream subagent status/result loading, distinguishes
that path from BYOK `inspect`, and records both arena capacity and actual RSS.
No upstream issue is opened; the maintainer will file it separately.
