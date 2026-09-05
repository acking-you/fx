# Long-turn memory and repeated inspections

The September 2026 WSL incident exposed temporary allocations with the lifetime
of an entire user turn. The recovered turn contained 1,171 tool steps and 3,735
distinct tool calls. Its last complete recovery snapshot was 13,850,650 bytes.
Most steps after step 144 repeated repository and task-history inspections.
The default step limit was unlimited.

## Allocation ownership

`runtime/orchestrator.zig` owns an arena for messages and tool evidence that
must survive subsequent model steps. Two temporary paths incorrectly used it:

* `persistRecoveryCheckpoint` rebuilt all execution memory on each save. The
  persistence sink synchronously duplicates the new checkpoint and releases its
  previous checkpoint, but the temporary reconstruction remained in the turn
  arena. Recovery saves occur after successful responses as well as failures;
  a `network_interrupted` checkpoint cause alone does not establish an outage.
* `runtime/gateway_step.zig` passed the same allocator to provider transports.
  Complete request serialization, HTTP buffers and response parsing could
  therefore survive their cleanup calls, even after a request finished. A
  growing conversation made repeated request construction another source of
  cumulative copies. This applies to Grok as well as Responses BYOK.

Each checkpoint build now has its own scratch arena, destroyed after the
synchronous sink returns, including on error. The sink's borrow contract is
documented in `RecoveryCheckpointEffect`. Each provider request also has a
scratch arena; only an owned completion is copied into the caller's allocator.
Stable borrowed responses from embedding/test providers retain their contract.
Cancellation and request failures destroy the request arena. Inline compaction
uses a freeing allocator and releases the previous result when replaced.

The turn arena remains intact. Its message, tool-result and callback borrows
must survive across steps. The separate overlay arena still resets at model
step boundaries. Retry overlays are bounded by the existing provider-attempt
budget. The fixes do not lower the default agent-step limit or truncate history.

## Deterministic measurements

`benchmarks/long_turn_memory.py` runs the built native binary against a local
Responses HTTP fixture. Each step reads a changing 1,024-byte file; unique call
IDs and changing evidence prevent the loop guard from ending useful work. The
fixture discards request bodies instead of accumulating them. Only the fx
process's `/proc/<pid>/status` RSS is measured, every 100 ms.

The process has a 2 GiB address-space limit, a 600-second wall-clock deadline,
and core dumps disabled. No model credentials or paid requests are needed.

```bash
zig build -Doptimize=ReleaseSafe
python3 benchmarks/long_turn_memory.py --output /tmp/fx-memory-proof --steps 1000
```

The initial before/after run on WSL Ubuntu produced:

| Model request | Before RSS | After RSS |
| --- | ---: | ---: |
| 100 | 133.53 MiB | 18.91 MiB |
| 200 | 370.45 MiB | 28.83 MiB |
| 400 | 1,165.51 MiB | 41.96 MiB |
| 600 | allocation limit reached | 54.04 MiB |
| 800 | allocation limit reached | 68.27 MiB |
| 1,000 | allocation limit reached | 76.49 MiB |

Before: request 407 failed with `OutOfMemory`; peak RSS was 1,197.20 MiB.
The retained execution record held 406 steps, 833,855 JSON bytes and 437,154
tool-output bytes. After: all 1,000 tool steps and the final response completed
with exit code zero; peak RSS was 85.90 MiB. The final retained record had
2,054,530 JSON bytes and 1,076,893 tool-output bytes. Necessary history grew;
previous temporary snapshots did not accumulate. RSS includes allocator
capacity, runtime state, presentation and other owned structures, so it is not
expected to equal the serialized history size.

The benchmark writes raw RSS samples, binary SHA-256, output, errors and an
isolated session directory. Unit regressions additionally run 1,000 checkpoint
saves and 1,000 provider attempts: checkpoint saves must not expand the caller's
turn arena, while request attempts alternate success, server failure, transport
failure and cancellation. The copied checkpoint remains readable after the
scratch arena is destroyed and after a later failed save.

There was no heap snapshot from the WSL crash. These allocation defects and
their growth are reproduced; their exact shares of the incident's approximately
35.3 GiB anonymous RSS and 8.1 GiB swapped memory cannot be reconstructed.

## Progress guard

The guard keeps 256 bounded evidence fingerprints. It compares returned
evidence, ignoring call IDs, shell timing/chunk metadata and search headings.
File reads also retain their arguments, so reading another file is useful even
when its contents match. A window of 64 inspection batches is stalled when at
least 40 return known evidence through
multiple inspection capabilities. The first stalled window adds a visible
reminder and model context; a second stalled window stops and saves the turn.
The user can continue with a follow-up prompt.

Writes, new user steering, unknown actions and test commands reset this
inspection window. Failed observations and running-process results do not
advance it. New evidence prevents a stalled
window. Repeated reads through a single capability are allowed, since they may
be polling one resource. This deliberately detects sustained repeated
reconnaissance rather than inferring task completion or imposing a general
duration limit. The repeated continuation prompt and lack of a guard permitted
the incident's loop; the available records do not establish why the model first
started repeating its inspections.

```bash
python3 benchmarks/long_turn_memory.py --output /tmp/fx-loop-proof --repeat
```

The original private recovery state can also be replayed through the exact guard
using the `progress guard replay saved execution fixture` test and
`FX_PROGRESS_GUARD_FIXTURE`. The input is a reconstructed state object with a
`recovery_checkpoint` field, not the lagging session manifest. Private session
contents and credentials are not checked into the repository.

That replay first reminds at step 366 and stops at step 650, before the recorded
1,171-step endpoint. The fully unchanged native fixture reminds at step 64 and
stops at step 128 with 41.15 MiB peak RSS. A live TUI regression also verifies the
stop is saved and a subsequent useful prompt completes without restarting fx.

The existing ACP, gateway lifecycle and TUI authentication E2E owners retain
their PGSO classifications. No new root E2E owner is introduced.
