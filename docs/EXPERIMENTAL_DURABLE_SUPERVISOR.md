# Experimental Durable CLI Supervisor Protocol

Status: **integrated experimental POSIX protocol for the package-aware
acknowledged durable command**.

This protocol lets a trusted local parent observe exact durable transition
boundaries in an installed `glacier text-run` child. The parent either grants
the next transition or terminates that child itself. The command contains no
environment-selected crash hook and never grants the parent checkpoint,
result-sink, or model authority.

The protocol is available only on Linux, macOS, and FreeBSD for the
package-aware acknowledged durable route with fixed output count `2..64`. It
rejects the sink-free direct route, process-local execution, `--bootstrap-only`,
one missing descriptor, equal descriptors, non-canonical descriptor values,
and descriptors below `3`.

## Descriptor contract

The trusted parent must create two distinct anonymous blocking `pipe(2)`
channels and inherit these child-side endpoints:

- `--experimental-supervisor-progress-fd N` must be the child-side
  `O_WRONLY` endpoint for child-write/parent-read progress; and
- `--experimental-supervisor-control-fd N` must be the child-side
  `O_RDONLY` endpoint for parent-write/child-read control.

Once the paired flags reach the acknowledged route, endpoint ownership
transfers to the child. It rejects non-FIFO descriptors, nonblocking endpoints,
the wrong access direction, or endpoints with the same `(device, inode)`
identity. It immediately sets and verifies `FD_CLOEXEC` on both accepted
endpoints, then closes them when the supervised command leaves scope. This
keeps a later executed process from retaining the capability or delaying EOF.
The portable `S_IFIFO` admission check cannot distinguish an anonymous pipe
from a named FIFO, so anonymous `pipe(2)` channels remain a trusted-caller
precondition rather than a hostile-parent defense.

Before each progress publication the child requires the control pipe to be
empty. A preloaded control frame is rejected. The child then makes one atomic
64-byte pipe write and reads exactly one complete matching control frame before
continuing. EOF, a short frame, or any field mismatch fails closed.

The grant wait has no child-side timeout: a parent that stays alive but sends
nothing intentionally leaves the child blocked at that checkpoint. Closing the
control writer produces EOF and a fail-closed error; the retained controller
owns its own deadline and can terminate the exact child. Losing the progress
reader can likewise fail-stop the child through a pipe write error or
`SIGPIPE`.

The inherited pipes are the local capability boundary: a process that does not
hold the control endpoint cannot grant progress. The request challenge in each
frame is correlation data, not authentication, a secret, or a MAC. This
experimental surface assumes a trusted local parent and does not defend
against a hostile process that already holds either endpoint.

## Fixed frame

Both directions use one 64-byte little-endian record with the layout
`<8sQBBBBIQ32s>`:

| Offset | Bytes | Field |
| --- | ---: | --- |
| `0` | 8 | Progress magic `GLDSPV1\0` or control magic `GLDSCV1\0` |
| `8` | 8 | Progress ABI `0x474c445300000001` or control ABI `0x474c445343000001` |
| `16` | 1 | Phase |
| `17` | 1 | Durable selection |
| `18` | 1 | Target ordinal |
| `19` | 1 | Reserved, required to be zero |
| `20` | 4 | Child process ID |
| `24` | 8 | Request epoch |
| `32` | 32 | Acknowledged durable request challenge |

Selection values are `absent=1`, `source_live=2`, `target_ready=3`, and
`terminal=4`; `absent` is encoded by the shared selection type but is not a
valid supervised checkpoint. The frame contains no prompt, output token,
filesystem path, or model payload. Its PID, epoch, challenge, phase, selection,
and ordinal remain correlatable metadata.

The control frame repeats the phase, selection, ordinal, reserved byte,
process ID, request epoch, and challenge from the progress frame, changing only
the direction-specific magic and ABI. There is no kill or fault action in the
wire. A valid matching control frame is the only continue grant; a parent that
wants to test process death sends a real signal to the exact child PID.

## Checkpoint sequence

The command accepts supervision only from an already bootstrapped
`source_live` selection:

| Phase | Value | Required selection | Ordinal | Meaning |
| --- | ---: | --- | ---: | --- |
| `ready` | 1 | `source_live` (`2`) | 0 | Identity and selection are validated; no supervised mutation has started |
| `source_advanced` | 2 | `target_ready` (`3`) | 0 | The source advance is verified and its runtime ownership is retired |
| `target_advanced` | 3 | `target_ready` (`3`) | `1..N-2` | One target advance is verified and its runtime ownership is retired |
| `target_advanced` | 3 | `terminal` (`4`) | `N-1` | The final acknowledged target advance is selected and verified |

Every target checkpoint is published after the corresponding durable
transition. The terminal selection is valid only at the final target ordinal.
The ready checkpoint is deliberately not an implicit bootstrap operation:
callers create or recover generation one with a separate ordinary invocation,
then start the supervised child.

## Retained installed-command evidence

The existing `text-runtime-golden-path-test` root stages the production
`bin/glacier` once and runs an `N=4` campaign from an empty working directory
with isolated home, configuration, cache, and temporary paths. It requires the
installed binary and install namespace to remain byte-identical.

The campaign independently validates:

- one all-grants control reaching the exact uninterrupted terminal result;
- real PID-only `SIGKILL` immediately after `source_advanced`;
- real PID-only `SIGKILL` after target ordinal one;
- exact signal exit, progress EOF, and no terminal JSON from each victim;
- fail-closed preloaded, wrong-field, and short-control grants with the
  generation-one manifest unchanged;
- fresh unsupervised continuation to the same namespace and lineage oracle;
- no duplicate acknowledgement or output suffix; and
- an immutable terminal retry with zero retained runtime ownership.

This reuses the existing installed CLI, package/raw-text Python controller, and
golden-path compile root. It adds no executable or compile root.

## Claim boundary

This is a narrow same-host correctness and recovery protocol. It is
experimental and carries no compatibility or release-stability promise. It
does not establish:

- remote orchestration, authentication, authorization, or hostile-writer
  resistance;
- physical power-loss or storage-device fault persistence;
- Windows support or native multi-OS recovery evidence;
- GPU execution, model quality, throughput, latency, or other performance
  behavior; or
- a production supervisor, distributed delivery, or general exactly-once
  protocol.

The current evidence uses a trusted local supervisor, inherited POSIX pipes, a
synthetic CPU fixture, and deterministic `SIGKILL` boundaries.

## Related documents

- [Public Prepared-Text Durable Runtime](PREPARED_TEXT_DURABLE_RUNTIME.md)
- [Benchmark and Evidence Guide](BENCHMARKS.md)
- [Glacier AI Runtime Roadmap](AI_RUNTIME_ROADMAP.md)
