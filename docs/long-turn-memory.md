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

## Subagent inspection lifetime

Model-facing `subagent inspect` also receives the parent turn allocator. An
inspection selecting `messages` loads the child's durable session, including
recovery checkpoints and event replay, before projecting a bounded history
page. A `wait` repeats this work after each notification or 100 ms poll interval.
Using the turn arena for those temporary allocations retained every replay,
even when the child had no completed history and each inspection returned only
a few kilobytes. The earlier provider and checkpoint-write fixes did not cover
this read path.

Each inspection now uses the host runtime's freeing allocator for manager
results and session replay. Cleanup runs after every poll, including timeout,
completion and error exits. The encoded final tool result still belongs to the
caller's allocator, so subsequent model steps can safely retain it. Polling,
authorization checks, history limits and returned data are unchanged.

The regression keeps a child active with four 256 KiB recovery checkpoints,
performs repeated `messages` inspections using one parent turn arena, waits for
a timeout, and then reads the completed child history. The parent arena must
stay below 256 KiB and earlier results must remain valid. A native fake-Gateway
scenario also exercises checkpoint polling, timeout and completion through the
built binary. It remains in the existing training-classified gateway lifecycle
E2E owner.

### Inspection loading and peak-memory benchmark

Read-only session loading now retains the state produced while validating the
commit boundary. Previously, boundary capture replayed the entire committed log
and freed the state, then the read loaded that same boundary again. The single
replay still checks the generation, sequence, event identity, committed byte
boundary and frame contents under the commit lock. Authority/publication fences
and the usage-sidecar snapshot keep their existing semantics. Boundary-only
callers still receive a validated boundary. This does not introduce a live-state
cache or skip recovery-checkpoint events.

`benchmarks/subagent_inspect_memory.py` exercises the actual native binary with
a local Responses server. A persistent child executes four reads; each response
also contributes 64 KiB of assistant text. It then blocks on its next response,
with nine recovery-checkpoint events, about 1.28 MiB of event-log data, and no
committed history. The parent performs twelve `status,messages` inspections with
`limit: 5` in one turn. Finally, the fixture releases the child, waits for it to
settle, and verifies the returned committed history. Both parent and child run
inside the measured fx process; the Python HTTP server is excluded.

```bash
zig build -Doptimize=ReleaseSafe
python3 benchmarks/subagent_inspect_memory.py --output /tmp/fx-inspect-memory

# Build each revision separately, then compare the native binaries:
python3 benchmarks/subagent_inspect_memory.py \
  --binary before=/tmp/fx-before/zig-out/bin/fx \
  --binary allocator=/tmp/fx-allocator/zig-out/bin/fx \
  --binary optimized=./zig-out/bin/fx \
  --runs 5 --output /tmp/fx-inspect-comparison
```

The Linux benchmark uses GNU time to record the kernel's process peak RSS, plus
sampled RSS, per-inspection observations, binary SHA-256, workload parameters,
stdout/stderr and isolated session files. Peak RSS includes startup, both agent
runtimes, inspections and child completion. It is neither cumulative allocation
traffic nor parent-arena capacity. Runs use fresh processes and profiles and
rotate binary order. GNU time measures its own `prlimit`/fx child so Python's
pre-exec memory is excluded. GNU time and util-linux `prlimit` are required.
The default address-space limit is 2 GiB and the deadline is 120 seconds per
process.

Five ReleaseSafe runs per version on Linux x86_64 / WSL2 (Zig 0.16.0,
2026-09-22) produced the following process high-water marks:

| Implementation | Full replays per history load | Median peak RSS | Peak RSS range |
| --- | ---: | ---: | ---: |
| Before either fix (`e0ae4808`) | 2 | 183.95 MiB | 183.59–196.36 MiB |
| Freeing inspection allocator (`af733b54`) | 2 | 21.88 MiB | 21.62–22.41 MiB |
| Freeing allocator and one validated replay | 1 | 22.11 MiB | 21.97–22.20 MiB |

The five raw peaks for each row, in KiB, were:

```text
before:    188364, 188416, 188064, 201072, 188000
allocator:  22948,  22688,  22136,  22408,  22352
optimized:  22600,  22500,  22640,  22640,  22728
```

The fixed RSS ranges overlap. Removing the second, sequential replay does not
halve simultaneous memory: the first replay was already freed before the next
one. The allocation regression measures its separate benefit: cumulative
requested bytes for one checkpoint load fall from 11,886,167 to 5,959,409,
about 50%. These allocation figures are not peak RSS. No further RSS reduction
or wall-clock speedup is inferred from the native runs, and the Linux figures
are not a macOS measurement.

The Benchmarks workflow runs three repetitions with a 64 MiB peak-RSS budget
and uploads the evidence. A focused allocation regression separately compares
loading four 256 KiB checkpoints against validating the same boundary: loading
must stay within one replay's allocation traffic, with a 256 KiB allowance for
metadata. Existing history-page allocation-failure and corruption tests cover
ownership cleanup and invalid commit boundaries.

### GB-scale inspection stress

The larger workload uses the same production path with 256 KiB of assistant
text per child response and 64 parent inspections. The blocked child has nine
checkpoint events and about 5.03 MiB of event-log data. A 12 GiB virtual-address
limit lets the original implementation finish so all variants can be compared
at the same completed work count. Three fresh processes per variant on the same
Linux host produced:

| Implementation | Median peak RSS | Peak RSS range | Completed inspections |
| --- | ---: | ---: | ---: |
| Before either fix | **3,100.39 MiB (3.03 GiB)** | 3,091.84–3,101.16 MiB | 64/64 |
| Freeing inspection allocator | **40.93 MiB** | 40.50–40.94 MiB | 64/64 |
| Freeing allocator and one validated replay | **40.63 MiB** | 40.35–40.65 MiB | 64/64 |

Every run also verified the completed child history. The raw peaks in KiB were:

```text
before:    3174804, 3175588, 3166044
allocator:   41472,   41916,   41920
optimized:   41316,   41624,   41604
```

```bash
python3 benchmarks/subagent_inspect_memory.py \
  --binary before=/tmp/fx-before/zig-out/bin/fx \
  --binary allocator=/tmp/fx-allocator/zig-out/bin/fx \
  --binary optimized=./zig-out/bin/fx \
  --runs 3 --inspections 64 --text-bytes 262144 \
  --limit-mib 12288 --timeout 600 --output /tmp/fx-inspect-gib
```

Repeating the same workload with `--runs 1 --limit-mib 2048` and a fresh output
directory reproduced an explicit
`OutOfMemory` result from the original fx process: it completed 17 inspections,
failed on the eighteenth, and exited with code 1. Both fixed variants completed
all 64 inspections and verified the final history under that same limit.

| Implementation | Peak RSS with 2 GiB address-space limit | Result |
| --- | ---: | --- |
| Before either fix | 831.66 MiB | `OutOfMemory`, 17/64 completed, exit 1 |
| Freeing inspection allocator | 40.68 MiB | 64/64 completed, exit 0 |
| Freeing allocator and one validated replay | 40.66 MiB | 64/64 completed, exit 0 |

These are single-run failure/completion checks. The baseline failed at the same
inspection on a second run (833.88 MiB peak). `RLIMIT_AS` bounds virtual address
space, so an allocation can fail with RSS below 2 GiB. This reproduces fx's
allocation failure without relying on a machine-wide OOM kill.

The CI stress gate uses this larger workload once, with a 2 GiB virtual-address
limit and a 96 MiB peak-RSS budget. The benchmark records completed inspection
counts, exit codes and explicit OOM diagnostics, and preserves GNU time's peak
measurement if the fixture must stop a failed run. A failed variant makes the
comparison command exit nonzero while still writing all measurement reports.

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
