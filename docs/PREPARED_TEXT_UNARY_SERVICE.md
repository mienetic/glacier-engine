# Bounded Prepared-Text Unary Service

Status: **experimental process-local kernel**.

`prepared_text_unary_service` composes the existing prepared-model,
`LaneWeave`, `ResourceBank`, publication, and terminal-result contracts into a
bounded multi-request service lifecycle. It is transport-neutral: HTTP, RPC,
background workers, streaming, authentication, and durable restart remain
separate work.

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

The acceptance fixture uses a generated `32/64/1/256` ordinary package. It
checks two-request interleaving against independent generation oracles, active
and completed idempotent replay, conflict and capacity immutability,
cancellation with a hidden private prefix, stale-handle fencing, retained
response ownership, and final zero Scheduler/Bank ownership.

`tools/verify.sh affected-fast` selects only this focused native root for
service-only changes. Complete affected verification selects its compile-only
companion on retained targets. If the package-aware CLI changes in the same
worktree, the unary acceptance root and installed text-runtime golden path
share one Zig build invocation.

## Deliberate nonclaims and next work

This slice does not establish a network server, concurrent model execution,
streaming publication, durable idempotency, process-death recovery, GPU
execution, authentication, quota enforcement, production-model quality, or
performance. The next serving slices are:

1. add a versioned bounded unary transport wrapper and real client;
2. add disconnect, timeout, overload, graceful-drain, and restart campaigns;
3. add load generation only after a real service boundary exists, separating
   admission latency, first-token latency, throughput, fairness, and cleanup;
4. define a bounded per-tenant queue if more than one concurrent request per
   logical tenant is required;
5. add committed-token streaming without exposing an unpublished token; and
6. add authority, quota, and transport-security adapters around the unchanged
   execution state machine.
