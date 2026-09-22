# Upstream subagent memory investigation, 2026-09-22

This is evidence for a future upstream issue. No upstream issue or fix is
submitted by this merge.

Audited revision: `vercel-labs/fx` commit
`1b5a516a2c795f05801332f6ce372ea68299481b`.

## Finding

Upstream still has the same **allocation-lifetime problem** in subagent
session reads, but its public tool contract differs from BYOK. Upstream exposes
`run` and `message`, not BYOK's `inspect` action. Do not report this as a
reproduction of an upstream `subagent inspect` command.

The ordinary synchronous completion path passes the parent turn allocator
through the tool boundary into a full child-session load:

1. [orchestrator.zig](https://github.com/vercel-labs/fx/blob/1b5a516a2c795f05801332f6ce372ea68299481b/src/core/agent/runtime/orchestrator.zig#L11054)
   gives file mutations a separate arena; other calls use the turn arena.
2. [tools/agent/subagent.zig](https://github.com/vercel-labs/fx/blob/1b5a516a2c795f05801332f6ce372ea68299481b/src/tools/agent/subagent.zig#L191)
   forwards `ctx.allocator` to the provider.
3. [executeSubagentProvider](https://github.com/vercel-labs/fx/blob/1b5a516a2c795f05801332f6ce372ea68299481b/src/core/tooling/tool_runtime.zig#L2143)
   passes that allocator to `host.executeManaged`.
4. [observeManagedState](https://github.com/vercel-labs/fx/blob/1b5a516a2c795f05801332f6ce372ea68299481b/src/core/subagent/tool_host.zig#L693)
   reads the child to initialize status, then calls `completeManagedResult`
   on completion. The latter calls `managedResultText`.
5. [managedResultText](https://github.com/vercel-labs/fx/blob/1b5a516a2c795f05801332f6ce372ea68299481b/src/core/subagent/tool_host.zig#L939)
   calls `sessions.loadReadOnly(alloc, child_id)`, copies one matching
   assistant result, and calls `state.deinit(alloc)`.

The state destructor is present. With a turn arena, most individual frees
cannot release their backing storage, so temporary decoded history can remain
allocated until the parent turn ends. The admission arena created from
`self.alloc` does not protect these later status/result reads. Yielded-result
paths that explicitly use `self.alloc` are distinct and should not be described
as using the parent arena.

## Isolated reproduction

[Diagnostic patch](evidence/upstream-subagent-memory-2026-09-22.patch) adds one
focused test to the **pinned upstream tree**, and an explicit build filter.
Upstream's build file at this revision does not honor the fork's
`zig build test -- --test-filter ...` convention; the patch avoids running the
entire suite by accident.

```bash
git worktree add --detach /tmp/fx-upstream-memory-probe 1b5a516a2c795f05801332f6ce372ea68299481b
cd /tmp/fx-upstream-memory-probe
git apply --unidiff-zero /path/to/upstream-subagent-memory-2026-09-22.patch
zig build test -Doptimize=ReleaseSafe
```

The fixture writes an ordinary canonical child session with one 1 MiB assistant
message and one 12-byte result. It calls the actual private
`managedResultText` helper 16 times using a single turn arena. Every returned
result equals `SMALL_RESULT` and is freed immediately. A second loop uses
`std.testing.allocator` and validates that ordinary deallocation is balanced.
The test does not simulate an LLM, execute 16 real child turns, or exhaust RAM.

Linux x86_64, Zig 0.16.0, ReleaseSafe:

| Measurement | Result |
| --- | ---: |
| Large history message | 1,048,576 bytes |
| Result returned per read | 12 bytes |
| Reads in one arena | 16 |
| Arena backing capacity after first read | 117,606,990 bytes (112.16 MiB) |
| Arena backing capacity after 16 reads | 1,317,758,756 bytes (1.23 GiB) |
| Maximum RSS for the complete diagnostic executable, including the control loop | 203,176 KiB (198.41 MiB) |
| Exit status | 0 |

`ArenaAllocator.queryCapacity()` measures allocated backing capacity, **not
resident memory**. The GiB capacity must not be presented as a GiB RSS result.
GNU `time -v` measured RSS in a separate direct run of the filtered test
executable; it repeated the exact capacity values and passed all 14 selected
checks (the probe plus anonymous import-discovery tests). The test prints its
measurement on stderr, so Zig's build runner displays the diagnostic command
even though the build exits successfully.

## Additional decoding work

The old BYOK double replay through `captureReadBoundary` is not the current
upstream implementation. However, the canonical conversation branch in
[loadReadOnlyDetailWithHistoryErrors](https://github.com/vercel-labs/fx/blob/1b5a516a2c795f05801332f6ce372ea68299481b/src/core/session/session_store.zig#L1780)
first loads a complete context state, then calls `loadConversationArchive`,
frees `state.history`, and replaces it with the archive. Both paths materialize
history; the first history is discarded. `startStatusPublisher` also uses this
full detail loader merely to read the model and effort.

This is source evidence of avoidable loading, not a measured latency comparison
or proof that the entire first load can be deleted. Metadata, checkpoint,
usage, permission, snapshot-locator, and concurrent-read semantics must be
preserved by any future fix. Upstream's current canonical metadata is schema 4
and supports history snapshots and event-log compaction, so the BYOK patch
cannot be transplanted verbatim.

## BYOK merge boundary

BYOK keeps its own session and persistent-child owners, including the merged
inspection allocator fix, single validated replay, regression tests, and
native memory/latency benchmark. This upstream integration does not reintroduce
the diagnosed upstream allocation path into BYOK.
