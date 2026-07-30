# Bounded Prepared-Text Unary Service

Status: **experimental process-local kernel with a bounded loopback HTTP/1.1
adapter, retained client, R1k-b8 Phases A-D through Phase E2b managed
child-process evidence, and a Phase F1 concurrent-transport implementation
with deterministic native-loopback correctness retained**.

`prepared_text_unary_service` composes the existing prepared-model,
`LaneWeave`, `ResourceBank`, publication, and terminal-result contracts into a
bounded multi-request service lifecycle. The kernel remains transport-neutral.
The additive HTTP/1.1 layer maps one strict JSON profile onto that same
lifecycle without creating another execution state machine.

## What it adds

The kernel keeps one loaded prepared model, Scheduler, and Bank alive across
multiple unary requests. The caller owns their storage and lifetime; the
service owns the request state machine.

Each request binds:

- the admitted package and exact prepared representation;
- the tokenizer domain and configuration;
- raw UTF-8 identity and bounded output count;
- logical tenant, deadline, and idempotency key;
- Scheduler, coordinator, Bank, and challenge identity; and
- the accepted Lane receipt.

The current profile accepts nonempty canonical UTF-8 prompts up to 4,096 bytes
and fixed outputs from 1 through 64 tokens. Callers may configure smaller
limits.

## Lifecycle

```text
validate and derive request intent
  -> exact idempotency lookup
  -> local capacity preflight
  -> tokenize and bind plans
  -> SessionV3 start
  -> private token transactions
  -> terminal evidence seal
  -> copy response into service-managed fixed storage
  -> SessionV3 retire and deinitialize
  -> publish unary response
```

An exact retry returns the existing handle or retained terminal record without
another model step. Reusing the same tenant/key pair with a changed canonical
intent returns a conflict. A new request that exceeds the fixed active or
record capacity rejects before Scheduler or Bank mutation.

The current Lane profile admits one active request per logical tenant. A
different concurrent request for an already-active tenant returns the exact
Scheduler `duplicate_tenant` rejection; it is not silently assigned another
fairness identity. A later request may be admitted after that tenant's active
request closes.

Tokens committed to the private sink are not unary output. Cancellation may
report how many private commits occurred and their transcript root, but exposes
zero token IDs. A completed response becomes readable only after terminal
evidence is sealed, Scheduler retirement succeeds, and concrete Session
ownership is released.

Handles contain the service epoch, record slot, generation, and request root.
Evicting a terminal record permits slot reuse; the earlier handle then becomes
stale and cannot inspect or cancel its successor.

## Ownership and failure policy

`ServiceV1.init` requires:

- an address-stable `ServiceV1`;
- one fresh, dedicated Scheduler/Bank pair;
- caller-owned `ActiveSlotV1` and `RecordSlotV1` slices whose addresses remain
  stable; and
- one package binding validated against the loaded `.glrt` representation and
  exact license identity.

Public mutations are serialized. Successful `closeV1` requires no active
requests and verifies zero Scheduler/Bank ownership before closing the
Scheduler. Retained completed, cancelled, or failed records contain fixed
values only and remain readable through `statusV1` and `responseV1` after
close without retaining the loaded model, Scheduler, or Bank. The service and
record backing storage must remain address-stable until those reads finish.

Start-adoption cleanup remains explicitly retryable while the Session retains
its exact single-use authority. Any later publication rollback uncertainty, an
unknown Scheduler permit, private-sink drift, or ownership drift moves the
service to fail-stop. In fail-stop, only a diagnostic snapshot is available;
the owner must replace the runtime instance instead of guessing whether a token
became visible.

## First production-path consumer

The package-aware, process-local, fixed-output `text-run` route now executes
through this kernel. It preserves the existing request epoch, scheduling keys,
private-sink identity, plans, terminal evidence, output, transcript, and JSON
schema; the installed golden path independently verifies those relationships.
The retained built-in fixture remains on its direct compatibility path because
it has no admitted package binding. Durable and explicit early-EOS routes also
retain their separate lifecycle contracts.

## Experimental loopback HTTP/1.1 profile

The bounded adapter accepts HTTP/1.1 connections only on `127.0.0.1` or `::1`.
It serves one request per connection and closes that connection after the
response. Its two routes are:

- `GET /v1/models`, which returns the one loaded package-bound model and its
  binding identity; and
- `POST /v1/chat/completions`, which executes one fixed-output request through
  `ServiceV1`.

The completion request is intentionally narrower than a general chat API. Its
JSON object must contain exactly one message with role `user`, `stream` must be
`false`, `max_tokens` must be from 1 through 64, and the selected model must be
the identifier returned by the model-list route. Unknown or duplicate JSON
fields reject. The prompt must be nonempty strict UTF-8 and at most 4,096
bytes. Request headers are bounded to 8 KiB, the body to 32 KiB, and the
response to 8 KiB.

Every completion requires exactly one `Idempotency-Key` header containing
1..128 visible ASCII bytes and one `Glacier-Tenant-Key` header containing a
canonical nonzero decimal `u64`. An optional `Glacier-Deadline-Tick` contains a
canonical decimal `u64`; zero disables the deadline. This is an absolute
logical Scheduler tick, not a wall-clock timeout or service-level guarantee.
The idempotency key is domain-separated and hashed before it enters the unary
kernel. Retention remains bounded and process-local. The tenant key is an
untrusted scheduling and accounting identity, not authentication.

Framing, headers, JSON, model identity, prompt UTF-8, and limits are checked
before admission. Terminal token bytes must also form strict UTF-8 before the
adapter renders JSON. A non-UTF-8 terminal result fails closed with a
structured error and is not exposed as malformed text.

The retained `ClientV1` owns its bounded request, response, parsing, URI, and
transfer workspaces around `std.http.Client`. `listModelsV1` and `completeV1`
return owned protocol values, accept loopback numeric addresses only, disable
redirects and content encoding, and validate status, schema, model, request,
content, and token-count correlation. Calls are serialized because the client
reuses its bounded workspaces. It does not authenticate the peer or
automatically retry a request.

## Managed lifecycle: Phases A-D through E2b evidence and Phase F1 implementation

`ManagedLifecycleV1` wraps the serial listener without changing `ServiceV1` or
the frozen HTTP profile. One nonzero process generation starts in `starting`,
publishes `ready` after the package-bound runtime and loopback listener exist,
moves once to `draining`, and ends in `stopped`. Lifecycle failure instead
publishes `failed`. Its snapshot retains exact accepted, completed, failed, and
active connection counts. Phase B gives the sole active connection a lease
fenced by process generation, connection sequence, and native handle. Its
phase is exactly `receiving_head` until the HTTP head arrives, then
`request_head_received`; receipt of every byte required by the selected route
advances it to `request_received`. Phase D advances an admitted completion to
`request_admitted`. Phase E1 adds exact `response_ready`, `response_writing`,
and `response_written` phases. Phase E2a makes the managed response writer
nonblocking and interruptible at bounded send checkpoints. Phase E2b adds one
full-request elapsed deadline from accept through response retirement. The
snapshot retains exact receive-drain, receive-timeout, admitted-work
drain-cancellation, peer-reset, peer-reset work cancellation, response-ready
drain-cancellation, response-write drain request, effective response-write
cancellation, and independent response-write transport-failure counts. It also
separates the full-request signal, newly cancelled work, response cancellation
before the first byte, response-write stop request, and effective
response-write cancellation. Every distinct outcome retains its exact count
and last phase.

Drain closes execution admission as well as listener admission. The runtime
uses a short control boundary to disable new completion admission before
`draining` becomes visible. While still holding the lifecycle lock, drain
performs receive-side shutdown only on a fenced lease whose request remains
incomplete; with no active connection, a loopback wake releases a blocked
`accept`. The serving thread remains the only socket closer: it accounts
success or failure and retires the fenced lease before its deferred close.

Phase C adds `ServerConfig.receive_timeout_ns` to the managed listener. Zero
disables it; valid nonzero values are inclusive from 1 millisecond through
60 seconds. The ordinary unmanaged `serveListenerV1` rejects a nonzero value
instead of silently ignoring it. One monotonic timer starts immediately after
accept and does not reset when the HTTP head arrives. Head transition, complete
request receipt, and every competing retirement path are serialized under the
lifecycle lock. Competing rejection, disconnect, drain, and timer-expiry
retirements linearize by acquiring that lock; exactly one outcome is retained.
Before each managed socket receive, the serving thread waits for readability
only within the remaining monotonic budget. It recomputes that budget after
every read, so a peer that sends bytes incrementally cannot reset or extend the
absolute deadline. Only the exact still-active fenced lease in
`receiving_head` or `request_head_received` can be retired for timeout. The
timer is joined before lease retirement, and the serving thread remains the
sole socket reader and closer. A timeout records separate count and phase
evidence, marks the connection failed, and leaves lifecycle `ready` plus
completion admission open. This elapsed receive deadline is independent of
the logical `Glacier-Deadline-Tick`.

Phase D publishes one active-work lease after exact unary admission and before
the first status or drive operation. The runtime keeps the full
generation-fenced unary handle, while managed lifecycle evidence binds its
runtime work sequence and handle digest to the exact active connection before
advancing that connection to `request_admitted`. Drain first closes completion
admission, then asks `ServiceV1` to cancel only that retained handle. The
service fence prevents a stale handle from cancelling a reused record.
Repeated drain and cancellation-versus-terminal races retain an idempotent,
classified outcome; only a newly cancelled active request increments the
separate admitted-work drain count. Request driving never holds the HTTP
control lock, so drain may wait for the current bounded service drive quantum
but not for the whole response lifecycle. Lifecycle bookkeeping and the
optional process-test observer run outside the HTTP control and service locks.
The serving thread remains the sole response writer and socket closer.

Phase E1 adds two bounded post-admission transport decisions without adding a
second execution state machine. Between service drive quanta, the managed work
checkpoint may classify a reset on the exact active connection. It then
cancels only the generation-fenced active-work handle and records
`peer_reset_connections`, `peer_reset_cancelled_work_connections`,
`last_peer_reset_phase`, and `last_peer_reset_cancelled_work_phase`. The
checkpoint runs outside the service drive quantum, so it cannot preempt a
model call already in progress. A peer reset does not close listener or
completion admission. `peer_reset_poll_timeout_ns` is zero by default, so the
ordinary runtime probe remains non-blocking. A managed host may opt into a
bounded 1-millisecond-to-1-second event-driven wait at each checkpoint when it
needs reset observation to precede the next quantum; only a typed reset or
not-connected result from the non-consuming socket probe counts as reset.

After a bounded response has been encoded, the response control advances the
exact fenced connection to `response_ready` before the first response write.
Drain may win at that boundary, record
`drain_cancelled_response_connections` and
`last_drain_cancelled_response_phase`, and prevent the first response byte
from being written. Otherwise the serving thread alone advances through
`response_writing` and `response_written`, flushes its local writer, and closes
the socket. `response_written` is local-flush evidence, not acknowledgement
that the peer received or processed the response.

Phase E2a replaces the managed response path's blocking writer with one bounded
nonblocking writer. `ServerConfig.response_write_quantum_bytes` is inclusive
from 1 through 4,096 bytes and bounds each kernel send attempt. The writer
checks drain before each nonempty send, publishes a real progress checkpoint
after every positive kernel send, and checks again when the socket reports
`WouldBlock`; a finite writable poll keeps that blocked-socket path
interruptible. The serving thread still owns every send and the final socket
close.

Drain requested in `response_writing` records
`drain_requested_response_write_connections`. Cancellation becomes effective
only when a later writer checkpoint observes it, at which point
`drain_cancelled_response_write_connections` is recorded and the classified
outcome is `cancelled_during_write`. A connection-close or transport failure
that wins independently records
`response_write_transport_failed_connections` instead, so a drain request is
not relabeled as an effective cancellation. A drain requested from a
post-send progress checkpoint is deferred until another nonempty send is
needed. If that positive send completed the response, local
`write_completed` wins and no false cancellation is recorded. These outcomes
remain local transport evidence; none acknowledges peer receipt or
processing.

Phase E2b adds `ServerConfig.full_request_timeout_ns` to the managed listener.
Zero disables it; valid nonzero values are inclusive from 1 millisecond
through 60 seconds. The ordinary unmanaged listener rejects a nonzero value
rather than silently dropping the contract. One monotonic clock starts
immediately after `accept`, shares that accept origin with the receive
deadline, and bounds the connection through response retirement. When both
elapsed timers are enabled, `receive_timeout_ns` must be strictly less than
`full_request_timeout_ns`; this makes the receive timeout the unique winner
while an incomplete request is still in `receiving_head` or
`request_head_received`.

The full-request deadline is server-local elapsed time. It is not
`Glacier-Deadline-Tick`: that header remains an absolute logical Scheduler
tick, is not converted to wall time, and remains part of request intent. The
elapsed timeout is neither a wall-clock timestamp nor part of the
idempotency-key identity. Expiry is generation-, connection-sequence-, native
handle-, and, after admission, full-work-handle-fenced. An accepted kernel or
model call already in progress is not asynchronously preempted; the timeout
wins at the next bounded managed checkpoint.

Expiry before complete request receipt shuts down the receive side and creates
no unary service record. Expiry at `request_received` or
`request_admitted` prevents further drive, cancels only the exact published
work, and retains the service's normal terminal cancellation evidence. Expiry
at `response_ready` prevents the first response byte. Expiry at
`response_writing` requests a stop; the bounded writer makes it effective at
its next before-send or `WouldBlock` checkpoint. Positive progress records the
request but defers effective cancellation so a final successful send is not
relabeled. A kernel
send that was already in flight may return, and a locally retired complete
write that won before timeout observation remains complete, but no later send
starts after the timeout has been observed.

The adapter does not synthesize an HTTP timeout response after this deadline.
It retires the current transport as failed and closes it, so a timed-out peer
receives no new structured error; a writing peer may have only the bounded
prefix sent before expiry. This preserves exact retry semantics without an
automatic client retry: a pre-admission retry may execute, a retained
cancelled record remains `request_cancelled` with retry policy `never`, and a
service completion that became terminal before transport suppression remains
available through exact process-local replay.

The full-request outcomes are retained without merging their meanings:

| Outcome | Exact counter | Exact last-phase field |
| --- | --- | --- |
| Deadline signal | `full_request_timeout_signaled_connections` | `last_full_request_timeout_signaled_phase` |
| Newly cancelled work | `full_request_timeout_cancelled_work_connections` | `last_full_request_timeout_cancelled_work_phase` |
| Response cancelled before write | `full_request_timeout_cancelled_response_connections` | `last_full_request_timeout_cancelled_response_phase` |
| Response-write stop requested | `full_request_timeout_requested_response_write_connections` | `last_full_request_timeout_requested_response_write_phase` |
| Response-write stop observed | `full_request_timeout_cancelled_response_write_connections` | `last_full_request_timeout_cancelled_response_write_phase` |

A work count increments only when timeout newly cancels the exact active
handle; a response-write request is distinct from a later effective writer
cancellation. Drain, receive-timeout, peer-reset, and independent
transport-failure counters are not relabeled.

### Phase F1 bounded concurrent transport and native-loopback correctness

The implemented Phase F1 path adds `ManagedConcurrentLifecycleV1`,
`serveManagedConcurrentListenerV1`,
`serveManagedConcurrentListenerWithObserverV1`,
`serveManagedConcurrentListenerWithControlsV1`, and
`requestManagedConcurrentDrainAndWakeV1`. Its
`ManagedConcurrentConfigV1` accepts a fixed `1..16` workers and a fixed
`1..64` pending connections (defaults `2/8`). Worker plus pending capacity is
the fixed connection-slot capacity and cannot exceed 80.

The pending structure is a FIFO of connections the process has already
accepted. Its ordering promise ends at worker dispatch: it does not promise
response completion order, Scheduler fairness, simultaneous model execution,
or preferential service among peers still in the kernel backlog. The existing
HTTP request mutex continues to serialize unary admission, model execution,
and exact active-work retirement. Response encoding survives that boundary,
and response-control callbacks plus socket writes occur after the mutex is
released. Slow transport output can therefore overlap later serialized model
work without making model work parallel.

`ManagedConcurrentLifecycleV1` is the one central registry. The existing
lifecycle mutex linearizes queue membership, fixed-slot phases, ownership
handoff, counters, and snapshots. One shared watchdog evaluates deadlines for
all queued and running slots; the concurrent path does not create one
watchdog thread per connection. The timer begins immediately after `accept`,
so time spent waiting in FIFO consumes both the receive timeout and the
accept-origin full-request timeout. It starts before the accepted socket is
returned to blocking mode, so scheduler or socket-normalization delay cannot
extend either budget. When the shorter receive deadline is enabled, it remains
the unique incomplete-request winner. A queued expiry retires the fenced lease
and closes the socket without reading a request, creating a service record, or
synthesizing an HTTP response.

When the accepted FIFO reaches its configured capacity, the acceptor pauses
before the next `accept` and waits for capacity. Additional peers remain under
the operating system's passive listen backlog. Dispatch or queued retirement
resumes the acceptor. On POSIX, the serving call temporarily makes the listener
nonblocking, waits for readiness for at most 100 milliseconds per poll quantum,
and revalidates lifecycle state before entering `accept`. Every accepted socket
is returned to blocking mode before FIFO or worker handoff. Managed receive
revalidates lifecycle on every readiness-wait iteration, with each quantum
capped at 100 milliseconds even when the configured timeout is zero, so drain
and fatal convergence do not depend on cross-thread `shutdown` succeeding.
After readiness, the POSIX read itself is nonblocking; stale or concurrently
consumed readiness returns to the bounded poll/revalidation loop instead of
stranding a worker in `recv`. An unexpected shutdown error advances no
successful signal counter or event for that connection and leaves it
unclaimed, allowing failure convergence to retry and take over. This bounded
transport path does not return an unparsed-request HTTP 429 or 503; the existing
429 for service or Scheduler capacity remains a distinct post-parse
application response.

Socket ownership moves exactly once from acceptor to FIFO to one worker.
Queued timeout, drain, or failure first detaches the still-queued connection
and then closes it once. After dispatch, its worker is the sole socket reader,
response writer, and closer. The generation, connection sequence, slot index,
slot generation, and native handle fence every live lease; an opaque transport
owner routes an exact active-work drain receipt without exposing the native
handle to the HTTP runtime.

`ManagedConcurrentSnapshotV1` retains queue and running high-water marks,
enqueued and dispatched totals, listener pause and resume totals, queued
drain/failure/receive-timeout/full-request-timeout totals, and counts for every
connection phase. The registry enforces four exact conservation rules:

- active connections equal queued plus running connections;
- the sum of phase counts equals active connections;
- accepted equals completed plus failed plus active connections; and
- enqueued equals dispatched plus every queued retirement cause plus the
  current FIFO length.

Concurrent drain closes unary admission before mutating transport state,
and the lifecycle mutex remains held across runtime receipt capture and
application to the exact fenced transport owner. Drain then detaches all
queued sockets and signals all dispatched sockets. Fatal convergence instead
closes runtime admission and cancels its exact work with `transport_failure`,
retires queued connections under the failure cause, emits one
`running_failure` event for each newly claimed running lease, and records
signal/work/response/write-request/effective-write-cancellation failure
counters without incrementing drain counters. The serving call joins every
worker and the shared watchdog. On POSIX, it then restores the exact listener
flags captured before serving. It may publish `stopped` only when the FIFO and
all connection slots are empty; the existing service close separately verifies
zero Scheduler and Bank ownership. The optional observer runs outside
lifecycle, runtime, service, and socket-control locks and cannot select a
production winner. Its callback may execute concurrently on acceptor, worker,
watchdog, or drain-caller threads and may arrive out of ordinal order. Observer
context must therefore remain alive until the serving call returns and
synchronize every shared access; `event.ordinal`, not callback arrival, is the
canonical event order.

The deterministic native-loopback gate continues to pass through
`zig build unary-http-test -Dmetal=false -Doptimize=ReleaseSafe -j2`.
Scenario A keeps a worker live beside a sibling partial HTTP head. Scenario B
proves one-worker/one-pending FIFO dispatch, exact passive pause/resume, and
healthy successor service. Scenario C retires the exact queued lease at its
accept-origin full-request deadline without an HTTP response, then serves a
successor. Scenario D makes two concurrent drain calls converge over one
active receive and one queued socket. All four validate snapshot/event
conservation, joined shutdown, and final zero service/Bank ownership.

That gate is same-process native-loopback correctness, not real-process
overload, native load, latency, throughput, GPU, or native foreign-OS evidence.
Phase F1 concurrent serving is explicitly unsupported on Windows today: the
entrypoint returns `ConcurrentListenerModeUnsupported` before worker/watchdog
startup because it cannot prove and restore the caller's original `FIONBIO`
mode. Native Windows serving therefore remains pending and unproven. The
real-process fixture described next now separately retains Phase F1
correctness in native POSIX child processes over real loopback sockets; that
does not turn the same-process gate into process evidence or establish native
Windows behavior.

The Phase F1 child-process campaign has four profiles. A queued receive
deadline expires while active terminal work completes, and the child then
serves a healthy successor. A queued accept-origin full-request deadline
expires before another healthy successor. Two drain callers start
simultaneously against one active receive plus one queued connection. Finally,
a retired connection slot is reused at a higher slot generation before a
stale owner is rejected and queued/running connections converge through
fail-closed cleanup. The receive-timeout profile closes with
accepted/completed/failed `3/2/1` and two completed service records. The
full-request-timeout profile closes at `3/1/2` with one completed and one
cancelled service record. That last profile deliberately corrupts only the
retained owner metadata as a white-box fault injection; the exact
generation-mismatch rejection and cleanup use the production drain and
failure paths. Drain has already won the model-work cancellation before that
injected mismatch is applied, so this profile does not prove
transport-failure-driven model cancellation. Every profile verifies exact
aggregate event/cause conservation, unique contiguous event ordinals, joined
threads, and final zero connection, Service, Scheduler, and Bank ownership.
The campaign uses real child processes and TCP loopback over a generated
synthetic tiny-model fixture. It is correctness evidence, not load, latency,
throughput, GPU, or native foreign-OS evidence.

The focused real-process fixture uses one executable in supervisor and child
worker modes. The ordinary clean path accepts `drain\n` followed by EOF or
empty stdin EOF as out-of-band control; phase-targeted fixture controls select
the two partial-receive cases. Its bounded `READY`, `DRAINING`, and `CLOSED`
frames contain generation, model, port, and lifecycle/close facts but no prompt
or host path. The supervisor proves invalid generation zero produces no ready
frame; generation A serves model-list, completion, and exact replay, survives a
malformed raw peer connect/disconnect followed by a valid barrier request, then
closes with zero active requests and zero Bank ownership. Separate real child
generations hold one partial header open in `receiving_head` and one complete
head with a declared but partial body open in `request_head_received`. Drain
receive-cancels each peer and records exactly one accepted, zero completed, one
failed, and zero active connection; each child closes with zero active service
requests, zero terminal service records, and zero Bank ownership. Two
additional child generations use a one-second Phase C deadline for the same
partial-header and partial-body shapes without drain. Each sends no response
before peer EOF or reset, reports the exact timeout phase with zero drain
signals, remains ready with completion admission open, serves a valid
model-list request in the same child, and then drains with two accepted, one
completed, one failed, zero active service requests, zero terminal service
records, and zero Bank ownership.

Two Phase D children use a synchronous observer after active-work publication
and before the serving thread's first drive operation; no sleep or
model-duration assumption chooses either race. In the cancellation-wins child,
the ordinary control thread invokes drain twice before releasing the observer.
The retained client receives a correlated `request_cancelled` error with retry
policy `never`; lifecycle records one accepted and completed connection, zero
failed connections, zero receive-drain and receive-timeout signals, and exactly
one admitted-work drain cancellation at `request_admitted`. In the
completion-wins child, the control thread drives the one-token service request
terminal while the HTTP lease remains published, then invokes drain twice and
releases the observer. The client receives the successful oracle-matched
completion and lifecycle records no work cancellation. Both close with zero
active service requests, one terminal service record, and zero Bank ownership.
Phase E1 reuses that executable with three further synchronous controls. The
peer-reset child resets the real peer after admitted-work publication. The next
between-quantum checkpoint uses the maximum bounded event wait so kernel reset
readiness, rather than a sleep or model-duration proxy, precedes the next work
quantum. It cancels only the exact active handle; a timeout fails the fixture
instead of allowing work to complete. The same child then serves a valid
model-list request and closes with two accepted, one completed, one failed, one
peer reset and one peer-reset work cancellation at `request_admitted`, one
cancelled service terminal, and zero Bank ownership.
The response-drain child reaches `response_ready`, invokes ordinary drain
before releasing the serving thread, and closes with one accepted, zero
completed, one failed, one response cancellation at `response_ready`,
`cancelled_before_write`, one completed service terminal, and zero Bank
ownership. A completion control releases the same boundary without drain,
retains the oracle-matched response, records `write_completed`, closes with one
accepted and completed connection, and leaves every new cancellation counter
zero. Each child keeps the unrelated receive, timeout, work-drain, peer-reset,
and response-drain counters unchanged. No race is selected by a sleep or
model-duration assumption.
Phase E2a adds two deterministic response-writing siblings to the same
executable and compile root. Both configure a one-byte send quantum and cross
the exact progress barrier after the first real one-byte kernel send. The
drain sibling requests drain at that barrier and requires one requested and
one effective response-write cancellation at `response_writing`, a
`cancelled_during_write` outcome, and zero independent transport failures. The
completion sibling releases the same barrier without drain, completes the
oracle-matched response, and leaves the new counters at zero. The writer's
focused native-loopback saturation primitive separately fills a real socket
until `WouldBlock` and proves cancellation at that checkpoint. This is bounded
correctness and lifecycle evidence, not a throughput or latency measurement.

Phase E2b adds three deterministic siblings at exact
post-admission/pre-drive, `response_ready`, and post-first-positive-send
`response_writing` barriers. Each timer starts at accept. The supervisor waits
for the lifecycle's full-request-timeout signal at the selected phase, rather
than sleeping or inferring model duration, before it releases the serving
thread. The admitted child retains one newly cancelled exact work handle; the
response-ready child retains one cancellation before the first byte; the
response-writing child separates one stop request from one effective
cancellation and permits only the bounded prefix sent before the timeout won.
Each timed-out connection is failed without a post-deadline HTTP response,
leaves completion and listener admission open, serves a valid model-list
request in the same child, then drains with zero active service requests and
zero Bank ownership. Unrelated receive-timeout, drain, reset, response, and
transport-failure counters remain zero, while the general signal and selected
phase-specific subset are exactly one.

Generation B then loads the same package with a new process generation and
idempotency key, proves the same model, binding, content, and output identity,
and closes cleanly. This fresh restart does not preserve retained idempotency
records.

## Focused verification

Run the bounded acceptance root without compiling the broad model-forward
suite:

```sh
zig build unary-text-service-test \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
```

Compile the same root without executing it:

```sh
zig build unary-text-service-compile \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
```

Run or compile only the bounded HTTP codec, adapter, and loopback acceptance
root:

```sh
zig build unary-http-test \
  -Dmetal=false -Doptimize=ReleaseSafe -j2

zig build unary-http-compile \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
```

Run or compile the focused managed real-process acceptance:

```sh
zig build unary-server-process-test \
  -Dmetal=false -Doptimize=ReleaseSafe -j2

zig build unary-server-process-compile \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
```

The ReleaseSafe `unary-http-test` command above retains Phase F1 same-process
native-loopback scenarios A-D: sibling liveness, accepted-FIFO
backpressure/order, exact queued full-request timeout, and repeated drain with
conservation plus zero ownership.

The existing process commands retain Phases A-D through Phase E2b and the four
Phase F1 native POSIX child-process profiles described above. Phase F1 uses
the production fixed-worker/FIFO/shared-watchdog path and the existing
dual-mode executable, test root, and compile companion; it adds no artifact or
build target. The same-process HTTP root and the child-process root remain
separate evidence surfaces.

The acceptance fixture uses a generated `32/64/1/256` ordinary package. It
checks two-request interleaving against independent generation oracles, active
and completed idempotent replay, conflict and capacity immutability,
cancellation with a hidden private prefix, stale-handle fencing, retained
response ownership, and final zero Scheduler/Bank ownership. The process
acceptance separately reuses one dual-mode executable for its supervisor,
clean/restart children, Phase B drain children, Phase C receive-timeout
children, the Phase D cancellation-wins and completion-wins children, and the
Phase E1 reset/response-ready children plus the Phase E2a response-writing
drain/completion siblings, Phase E2b elapsed-timeout children, and the Phase
F1 queued-timeout, simultaneous-drain, and stale-owner children; Phases B-F1
add no artifact or build target. It is
host real-process lifecycle evidence rather than a production daemon or native
foreign-target run.

`tools/verify.sh affected-fast` selects `unary-http-test` once for HTTP
contract, client, or focused acceptance-test changes. Managed lifecycle or
process-acceptance changes select `unary-server-process-test`. A unary-kernel
implementation change selects `unary-text-service-test`, `unary-http-test`, and
`unary-server-process-test`. A shared server adapter/API implementation change
selects the HTTP and managed-process roots without the service-only root. A
process-fixture-only change selects the managed-process root alone. All
selected host roots share one Zig invocation.
Ordinary pull requests and `main` pushes run this bounded Debug
`affected-fast` plan. Complete affected verification selects only the
corresponding compile-only companions on retained targets and remains an
explicit manual or milestone promotion action; broad exhaustive, retained
target, and hardware work remains manual, tagged-release, or milestone work.
For this surface, the retained compile targets are x86_64 and AArch64 Linux
musl, x86_64 Windows GNU, and x86_64 FreeBSD. Those foreign builds are
multi-OS compile evidence, not native socket, timer, cancellation, or serving
evidence. The Phase B receive-drain, Phase C receive-timeout, and Phase D
admitted-work drain cases plus Phase E1 reset/response-ready, Phase E2a
interruptible response-write, and Phase E2b full-request-timeout cases remain
inside the existing process executable, test target, and compile-only
companion.
Shared prepared-text session and package-aware CLI changes continue to share
the unary acceptance root and
installed text-runtime golden path in one Zig invocation.

## Deliberate nonclaims and next work

This surface establishes an experimental loopback socket, bounded JSON
profile, retained client, focused managed child-process evidence through Phase
E2b, and a Phase F1 concurrent-transport implementation with deterministic
same-process plus native POSIX child-process loopback correctness retained.
Phase C remains the shorter pre-admission receive boundary. Phase D
cancels admitted execution only when managed drain wins. Phase E1 detects a
reset only at a between-quantum checkpoint and cancels a response at
`response_ready`, before its first write. Phase E2a bounds managed kernel sends
and makes progress/`WouldBlock` cancellation observable after writing starts.
Phase E2b adds a full-request elapsed boundary, but it does not detect orderly
FIN abandonment, preempt an in-flight model drive or kernel call, acknowledge
peer receipt, or turn the logical Scheduler deadline into wall time. A
successful local writer completion is not a delivery acknowledgement.

Phase F1 makes multiple transport workers available around one bounded
accepted FIFO, but model admission and execution remain serialized. FIFO
therefore says nothing about completion order or scheduler fairness. Passive
accept backpressure leaves peers in the kernel backlog and sends no pre-parse
429/503. The retained real-process campaign validates bounded correctness,
cleanup, and ownership; it is not a native-load or performance campaign.

This work does not establish a packaged production daemon, non-loopback
serving, streaming publication, durable idempotency or crash recovery,
process-death recovery, authentication, authorization, TLS, automatic retry,
quota enforcement, GPU execution, production-model quality, native load, or
performance. Retained-target compilation is not native Windows or FreeBSD
serving proof, and native reset, response-write, deadline, queue, watchdog, and
drain behavior on those systems remains unproven. The next serving slices are:

1. run a separate native-load campaign reporting
   accept/admission and queue delay, HTTP first-byte latency for this
   non-streaming unary profile, terminal-response latency, throughput, outcome
   mix, and cleanup under a declared machine/OS/backend/power/thermal
   envelope; do not label HTTP first byte as first-token latency or infer
   fairness, GPU performance, or native foreign-OS behavior;
2. extend abandonment detection to orderly FIN with exact connection outcome
   accounting;
3. add forced process-death evidence independently of checkpoint-aware drain
   and durable restart;
4. add committed-token streaming without exposing an unpublished token; and
5. add authenticated authority, quota, and transport-security adapters around
   the unchanged execution state machine.
