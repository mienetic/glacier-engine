# Bounded Prepared-Text Unary Service

Status: **experimental process-local kernel with a bounded loopback HTTP/1.1
adapter, retained client, and R1k-b8 Phase A managed child-process lifecycle**.

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

## Managed child-process lifecycle, Phase A

`ManagedLifecycleV1` wraps the serial listener without changing `ServiceV1` or
the frozen HTTP profile. One nonzero process generation starts in `starting`,
publishes `ready` after the package-bound runtime and loopback listener exist,
moves once to `draining`, and ends in `stopped`. Lifecycle failure instead
publishes `failed`. Its snapshot retains exact accepted, completed, failed, and
active connection counts.

Drain closes execution admission as well as listener admission. The runtime
takes its completion mutex and disables new completion admission before
`draining` becomes visible. A loopback wake then releases a blocked `accept`.
An already-running serialized completion holds that same mutex through terminal
response construction, so drain cannot overtake its admission boundary. This
is a bounded clean-drain rule, not request timeout or disconnect cancellation.

The focused real-process fixture uses one executable in supervisor and child
worker modes. The child accepts only `drain\n` followed by EOF or empty stdin
EOF as out-of-band control. Its bounded `READY`, `DRAINING`, and `CLOSED`
frames contain generation, model, port, and lifecycle/close facts but no prompt
or host path. The supervisor proves invalid generation zero produces no ready
frame; generation A serves model-list, completion, and exact replay, survives a
malformed raw peer connect/disconnect followed by a valid barrier request, then
closes with zero active requests and zero Bank ownership. Generation B loads
the same package with a new process generation and idempotency key, proves the
same model, binding, content, and output identity, and closes cleanly. This
fresh restart does not preserve retained idempotency records.

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

The acceptance fixture uses a generated `32/64/1/256` ordinary package. It
checks two-request interleaving against independent generation oracles, active
and completed idempotent replay, conflict and capacity immutability,
cancellation with a hidden private prefix, stale-handle fencing, retained
response ownership, and final zero Scheduler/Bank ownership. The process
acceptance separately reuses one dual-mode executable for its supervisor and
two fresh child generations; it is host real-process lifecycle evidence rather
than a production daemon or native foreign-target run.

`tools/verify.sh affected-fast` selects `unary-http-test` once for HTTP codec,
adapter, API, client, or acceptance-test changes. Managed lifecycle or process
acceptance changes select `unary-server-process-test`. A shared unary-kernel or
server implementation change composes `unary-text-service-test`,
`unary-http-test`, and `unary-server-process-test` in one host Zig invocation.
Complete affected verification selects the corresponding compile-only roots on
retained targets; those foreign builds are compile evidence, not native serving
evidence. Package-aware CLI changes continue to share the unary acceptance root
and installed text-runtime golden path in one Zig invocation.

## Deliberate nonclaims and next work

This slice establishes an experimental serial loopback socket, bounded JSON
profile, retained client, and one focused managed child-process Phase A. It does
not establish a packaged production daemon, non-loopback serving, concurrent
model execution, streaming publication, durable idempotency, request timeout
or disconnect cancellation, accepted-work coverage across every drain phase,
process-death recovery, authentication, authorization, TLS, automatic retry,
quota enforcement, GPU execution, production-model quality, native multi-OS
serving, load evidence, or performance. The next serving slices are:

1. extend the managed process through disconnect, timeout, overload,
   accepted-work drain, forced-death, and durable restart campaigns;
2. add load generation only after that process boundary exists, separating
   admission latency, first-token latency, throughput, fairness, and cleanup;
3. define a bounded per-tenant queue if more than one concurrent request per
   logical tenant is required;
4. add committed-token streaming without exposing an unpublished token; and
5. add authority, quota, and transport-security adapters around the unchanged
   execution state machine.
