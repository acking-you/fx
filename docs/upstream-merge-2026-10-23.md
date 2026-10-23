# Upstream reconciliation, 2026-10-23

| Boundary | Revision |
| --- | --- |
| BYOK starting point | `baa531681e5f4f87440006d245f0b615cec00b78` |
| Previously integrated upstream | `1b5a516a2c795f05801332f6ce372ea68299481b` |
| Upstream merge parent | `d824f609cfbb6262e6bb9272f1c2f89d6cd24bec` |
| Review branch | `codex/merge-upstream-2026-10-23` |
| PR target | `acking-you/fx` `byok` |

The mirror was fast-forwarded to the fetched `vercel/main`. The September
integration was subsequently squashed into BYOK as `57153dab`, despite the
previous reconciliation's instruction to preserve its parents. Its tree is
identical to the saved `origin/merge/upstream-2026-09-22` tree. An ancestry-only
merge first records the already-integrated September upstream revision without
changing BYOK's tree. The following real merge records the October revision.
Keep both parents when landing this PR: do not squash or rebase it.

The incoming history has 1,493 commits not reachable from the original BYOK
head. After restoring the September ancestry, the initial merge had 448
conflicted paths. This record distinguishes imported changes from coherent
fork owners retained across that merge. Upstream ancestry does not mean every
upstream product feature is now available in BYOK.

## Accepted shared changes

| Area | Result |
| --- | --- |
| Request watches | Adopt upstream `select_watch` and extend its stop-and-join pattern to the fork's generic bounded requests, catalog fetches, direct HTTP fetch, OAuth callback reads, terminal monitor networking, and image-normalizer process waits. |
| Zig toolchain | Adopt Zig 0.17.0 across source, build configuration, CI, native packaging, and development documentation. Keep the fork's binary, embedded C ABI, NAPI and WASM build owners. Test filters now use repeated `-Dtest-filter=...` options. |
| Workspace discovery | Adopt upstream's native indexer and its single public facade for picker, glob, and grep discovery. Git metadata is read as data without spawning git. Preserve BYOK's immutable access scopes, captured index prefixes, generation ownership, and cancellation. |
| Terminal and input | Accept compatible shared terminal engine, Unicode width, OSC hyperlink, parser, keypad, navigation, and rendering fixes. Keep transcript mutation and paint ownership on the UI thread. |
| Shared utilities | Accept compatible text, shell parsing/classification, GitHub, path, search, and process changes. Retain saved fuzz regression inputs for the six imported parser/index/terminal test owners. |
| PGSO | Accept compatible compiler/profile tooling updates; retain BYOK's corpus classification, native matrices, release routing, and established E2E owners. |

## Cancellation and deadline audit

A successful operation now stops and joins its watch before disposing the
select. This avoids sending SIGIO to a watch worker that may already be
returning to the thread pool. Cancellation of real unfinished work remains
necessary for an actual user cancellation, timeout, spawn failure, or failed
wait; these paths stop the watch and drain/dispose any late result.

| Owner | Lifetime and cleanup |
| --- | --- |
| `gateway/client.zig` | One bounded-operation owner serves OAuth, Grok, Codex catalogs, usage, and ordinary gateway operations. Cancellation-only catalog fetches use the same owner with no deadline. Late owned results are deinitialized; request opens preserve route and transport ownership. |
| `tools/web/http_fetch.zig` | DNS waits and Windows connects use watches. Failure to start or await the competing task joins DNS work before its stack storage can disappear. Late connections are closed. |
| `core/shared/socket_poll.zig` | Windows accept stops its deadline watch on success and closes a late accepted connection on cancellation. |
| `core/auth/browser_callback.zig` | Callback reads watch both cancellation and the silence deadline; late requests are deinitialized. |
| `core/terminal/native_session.zig` | Monitor resolution and connection share the same watch contract and dispose late addresses/streams. |
| `core/images/image_attachments.zig` | A normal child exit stops the watch. A canceled child wait kills and reaps the normalizer on its owning worker before join, including the POSIX case where the interrupted wait cleared the process handle. |

All remaining `Select.cancel`/`cancelDiscard` calls are exceptional drains,
completed-watch disposal, or the intentional regression test. Command-runner
futures terminate their process and await it instead of canceling a live
future. Application methods named `cancel` set product state or cancellation
flags; they are not std task cancellation.

The watch checks its absolute clock deadline after every wakeup. A regression
repeatedly wakes an unset event and verifies that the actual deadline elapses.
The old gateway and HTTP deadline loops are removed. `io.waitEventUntil` remains
for two non-watch owners found in the audit: child notification waits and the
terminal host's idle grace period. They now use the clock-checking helper so a
spurious wakeup cannot expire the wait or stop an idle host early. Reaper and
monitor wakeups are polling hints and already re-check their own state.

The setup-only `Unexpected` to `ConnectionSetupFailed` recovery stays. Zig
0.17.0 still cancels `connectMany` in `std/Io/net/HostName.zig` after connection
selection, and `std/Io/Threaded.zig` still retries `connect` after `EINTR` while
treating `EISCONN` as an errno bug. That signal source belongs to std and remains
outside fx's watch ownership. The mapping is limited to connection setup;
arbitrary transport or application failures are not made retryable.

## Preserved fork owners and deferred ports

These boundaries are retained coherently because the incoming implementations
assume a different session, provider, or permission contract. Their useful
changes require a dedicated port, as in the September integration.

| Upstream area | Retained BYOK contract |
| --- | --- |
| New session manager, journal/schema migration, archived transcript and compactor | Existing session event authority, full-replacement semantic compaction, native opaque Responses checkpoints, asynchronous TUI admission, replay, result stores, and persistent children. |
| Provider registry, Chat Completions, shared connection pool, new provider choices | Existing generic Responses URL/key binding, Codex/Grok subscription login, route snapshots, separate provider/auth controls, credential refresh/logout, and account usage. No Vercel onboarding or vendor-specific default returns. |
| Agent orchestration, managed subagents, revised review/recovery | Same-turn steering, queued UI events, a single compaction strategy, exact-action review, persistent child control and independent ACP Unified Exec observation. |
| New SDK and hosted session/runtime APIs | Existing C ABI and INFX behavior, embedded environment isolation, JS host contracts and NAPI/WASM entrypoints. No journal-dependent or MCP SDK methods are partially imported. |
| UI tied to deferred product state | Existing fork transcript/footer, permission and question owners, model picker contract, reasoning replay, queued compaction input, and active-turn steering. |
| MCP, vendor setup/login, legacy executable shell tools, Slack installer, automatic vendor upgrades | These unsupported slices remain absent. Historical shell records remain readable; `exec_command` and `write_stdin` remain the only executable shell family. |
| Web search and fetch | Central provider search projection and the separately configured search fallback remain. Direct `web_fetch` retains its explicitly unrestricted HTTP target/redirect contract and bounded transport. |
| Releases and documentation | Version stays 0.0.11. Fork README contract, provider examples, protected-behavior inventory, native archive release owner, and existing docs remain. No release or upstream filing is part of this merge. |

Tests for deferred or excluded upstream owners are not imported. Existing
fork regression coverage and E2E classifications remain. Saved fuzz inputs
protect the imported code without introducing the upstream session-manager or
MCP fuzz owners. Darwin archive realignment with `zig ar --format=darwin qcsL`
and packaging's eight-byte member validation are preserved; macOS 13 remains
the explicit native-package deployment target.

## Verification record

The initial ReleaseSafe executable and embedded library build locally. Four
live TUI interactions against local Responses fixtures pass with empty stderr:
streamed reasoning/text token progress and consecutive turns through three
custom BYOK model routes. INFX tools and authentication binaries link against
the merged library with the default macOS linker.

The six watch tests pass, including no SIGIO on normal completion and the
spurious-wakeup deadline regression. Native packaging passes its initialization,
shutdown, silent-stream cancellation, and session reuse checks. Every Darwin
archive member reports `data%8=0`. The full INFX workspace suite and infx-sys
link check pass with the default macOS linker.

Remaining focused regression checks, the requested contention stress runs, and
exact-head Full CI are recorded in the draft PR as they finish. The
PR must stay draft until the maintainer authorizes readiness, and must not be
merged, released, or filed upstream without separate authorization.

### CI compatibility follow-up

The first CI pass exposed test-only assumptions from the old toolchain and
Windows-specific APIs. The repair resolves generated executable paths before
child launches, uses Zig 0.17's explicit array-list construction and public test
hooks, and applies upstream's non-resizing allocator to fault-injection sweeps.
The resulting focused process and allocation regression set passes 13 tests.

Windows HTTP I/O now uses the operation API and complete socket handles. Native
index snapshots use the fork's existing permission and synchronous-file helpers;
POSIX mode-bit rejection stays POSIX-specific, with Windows profile ACLs retaining
their existing ownership contract. Windows executable builds keep the target's
unwind-table default because its CRT registers structured exception handlers.
The obsolete v1 file-index cache owner is removed in favor of the shared v3
snapshot implementation.

The file-picker E2E assertion now checks the native loader thread instead of a
removed git subprocess. All 15 deterministic picker scenarios pass, including
rapid large-index refreshes, scope changes, and two resume cycles; the credentialed
live-provider scenario remains skipped. The 18 embedded ownership tests pass.
The tools contention run reports zero failures across all 1,800 runs. PGSO's
Python checks pass after running their build tests with the pinned Zig 0.17.0.
