# Benchmark and Evidence Guide

Glacier treats benchmark output as evidence about one declared configuration,
not as a universal property of the project. A publishable result needs the raw
artifact, machine conditions, correctness gate, paired order, and an explicit
claim boundary.

## Evidence levels

| Level | Meaning | Suitable wording |
| --- | --- | --- |
| Conformance | A deterministic fixture satisfies a contract | “The fixture verifies…” |
| Diagnostic | One run exposes behavior for investigation | “This run observed…” |
| Paired experiment | Randomized same-machine pairs pass validity gates | “On this machine and workload…” |
| Replicated campaign | Several machines/workloads reproduce the effect | “Across the tested matrix…” |
| Release claim | Reproducible campaign, quality gates, and retained artifacts | Wording limited to the published matrix |

Passing a conformance demo does not establish throughput, physical memory,
energy, or production reliability.

The portable W6a report contract, the bounded W6b production-native Metal
producer, the finite W7a controlled-disruption campaign, and the W7b-a
segmented soak are integrated. W7b-b1 adds a separate post-segment
process-kill profile. W7b-b2 adds an accelerator-independent POSIX-host
production-publisher/reference-recovery campaign. W7b-b3 adds a native
paired-thread release-barrier profile with zero-command cancellation/capacity
records and correctness-gated Metal controls. W7b-b4 adds a real PID-only
process kill around one fault-shim event-blocked registered command, followed
by a distinct production-linked 20-command W6 control. W7b-b5 adds two real
PID-only control-plane kills after clean worker reap: exact generation-six
supervisor death, a fresh shared-lock audit, exact ordinal-six resume,
prepared-generation-twelve recovery-process death while generation eleven
remains active, exact `11 -> 12` roll-forward, and a final fresh audit.
W6b runs a fixed real-GPU campaign on a native macOS Metal host and can retain
the independently verified raw wire when an output path is requested. W7a
repeats correctness-gated real commands alongside controlled pre-submit and
full-slot outcomes. W7b-a runs 12 independently verified 50-epoch segments,
1,200 real commands, a paced minimum of 60 seconds, and one clean restart
across two worker generations. Its canonical manifest, selector, optional
content-addressed store, and offline verifier retain exact progress. Process
RSS is a host observation; Metal `currentAllocatedSize` is device-wide
allocation context, not residency or owned GPU memory. The pure supervisor
gate is model evidence, while only the native gate executes these real Metal
commands. Broader retained machine matrices, direct physical telemetry, and
the remaining W7b-b active-kernel, broader supervisor/recovery interruption,
adapter, and physical storage/device/driver/power work remain staged. The
sequence is defined in the [Runtime Workload Lab](RUNTIME_WORKLOAD_LAB.md),
with exact producers and claim boundaries in the
[Native Workload Report](NATIVE_WORKLOAD_REPORT.md),
[Native Metal Disruption Report](NATIVE_METAL_DISRUPTION_REPORT.md),
[Native Metal Cancellation-Storm Report](NATIVE_METAL_CANCELLATION_STORM_REPORT.md),
[Native Metal In-Flight Process-Kill Report](NATIVE_METAL_INFLIGHT_PROCESS_KILL_REPORT.md),
[Native Metal Supervisor and Recovery-Process Death Report](NATIVE_METAL_SUPERVISOR_RECOVERY_DEATH_REPORT.md),
[Native Metal Segmented Soak Report](NATIVE_METAL_SOAK_REPORT.md),
[Native Metal Process-Kill Recovery Report](NATIVE_METAL_PROCESS_KILL_REPORT.md),
and [Native Workload Store-Fault Report](NATIVE_WORKLOAD_STORE_FAULT_REPORT.md).
Accelerator results must keep host, device, synchronization, placement,
residency, fallback, power, and thermal observations distinct.

The Phase F1 concurrent-transport production path and deterministic
same-process native-loopback correctness are retained. The passing ReleaseSafe
`unary-http-test` covers four scenarios: sibling liveness beside a partial
request; one-worker/one-pending accepted-FIFO dispatch with passive
pause/resume; exact queued accept-origin full-request timeout without an HTTP
response followed by a healthy successor; and repeated drain over one running
plus one queued socket. Each retains snapshot/event conservation, joined
shutdown, and final zero service/Bank ownership.

That remains same-process native-loopback evidence. The existing
`unary-server-process-test` separately retains four Phase F1 profiles in
native POSIX child processes over real loopback sockets: queued receive timeout
while active terminal work completes plus a healthy successor; queued
full-request timeout plus a healthy successor; simultaneous two-caller drain
over one active receive and one queued socket; and stale-owner rejection after
slot reuse with fail-closed queued/running cleanup. The stale-owner profile
deliberately corrupts only owner metadata as a white-box fault injection;
generation-mismatch rejection and cleanup use the production drain and failure
paths. The same executable also retains a serial application-rejection profile:
one deadline-infeasible Scheduler rejection, one successful request, one
service-capacity rejection, and one idempotency conflict. It checks exact
request digests, Scheduler event identity, managed connection owners, callback
counts, unchanged rejected-work sequencing, and final zero ownership without a
new artifact or compile root. The campaign checks aggregate event/cause
conservation, unique contiguous event ordinals, joined threads, and final zero
connection, Service,
Scheduler, and Bank ownership. It uses real child processes and TCP loopback
over a generated synthetic tiny-model fixture. Native load/performance, GPU
behavior, native Windows concurrent serving, and native foreign-OS behavior
remain separate pending campaigns.

## Current conformance surfaces

| Command | Contract exercised |
| --- | --- |
| `zig build lane-weave-demo -Dmetal=false` | Exact admission, deterministic weighted service, rejection, cancellation, final release |
| `zig build dense-tensor-family-test -Dmetal=false` | One shared download-free dense-family Zig test artifact covering canonical reranking, exact Q30 L2 dense embedding, bounded exact-integer classification, and tenant-filtered fixed-corpus retrieval, including direct/scheduled publication, cancellation, independent recomputation, and final zero ownership. Existing family compatibility targets reuse the same compiled artifacts while retaining distinct oracle dependencies; this is not ANN, production quality, or performance evidence |
| `zig test src/core/workload_pressure.zig -OReleaseSafe` plus `python3 -m unittest bench.tests.test_workload_pressure` | Versioned mixed-media explicit-open-loop pressure, capacity/resource rejection, exact `1:2:4` fairness, timeout, cancellation, logical delay/high-water summaries, zero-orphan close, exact replay, and independent cross-language roots |
| `tools/zig-with-ephemeral-cache.sh build workload-scenario-corpus-test -Dmetal=false -Doptimize=ReleaseSafe -j2` plus `python3 -m unittest bench.tests.test_workload_scenario_corpus` | Four retained seeds × eight generated deterministic open-loop classes, coordinate-addressed SHA-256 decisions, unchanged W0/W1 contracts and reference goldens, independent scenario/evidence verification, zero-orphan close, and one synthetic exact-signature local-minimum shrink fixture |
| `tools/zig-with-ephemeral-cache.sh build workload-closed-loop-test -Dmetal=false -Doptimize=ReleaseSafe -j2` plus `python3 -m unittest bench.tests.test_workload_closed_loop` | Separately versioned finite-source deterministic closed-loop plan/result wires, exact four-phase ordering, terminal-driven FIFO next-step successors, lineage and target bounds, direct cross-language replay, mutation rejection, preserved W0/W1/W2 goldens, and final zero ownership |
| `tools/zig-with-ephemeral-cache.sh build typed-workload-test -Dmetal=false -Doptimize=ReleaseSafe -j2` plus `python3 -m unittest bench.tests.test_typed_workload_conformance` | Separate W4a profile/item/plan contract, generic scheduler lifecycle callbacks, retained exact-integer vision/audio-window/temporal-video execution under scheduler-owned receipts, independently replayed logical roots, native concrete-evidence mutation gates, semantic-substitution rejection, and final zero model/cache ownership |
| `tools/zig-with-ephemeral-cache.sh build typed-tool-workload-test -Dmetal=false -Doptimize=ReleaseSafe -j2` plus `python3 -m unittest bench.tests.test_typed_tool_conformance` | W4b-a process-local tool transaction: separate proposal/policy authority, retained fixed-storage integrity, execute/reuse/deny/conflict semantics, scheduler-before-mutation precommit plus exact-event publish, independent replay, cancellation/timeout/rejection absence, and final zero authority |
| `tools/zig-with-ephemeral-cache.sh build action-outbox-record-test -Dmetal=false -Doptimize=ReleaseSafe -j2` plus `python3 -m unittest bench.tests.test_action_outbox_conformance` | W4b-b portable ActionOutbox protocol: canonical body/footer records, stable remote-request identity, uncertainty-preserving restart, a reconciliation record required before safe retry, separately authorized compensation, all 7,521 retained cuts from the complete header through the journal, and independent byte-for-byte replay; no authenticated provider truth, filesystem durability, or live external effect |
| `tools/zig-with-ephemeral-cache.sh build action-outbox-recovery-test -Dmetal=false -Doptimize=ReleaseSafe -j2` | W4b-c descriptor-relative POSIX store: clean committed `320 + 752n` prefixes, semantic preflight, exclusive advisory lock and namespace/identity fences, ordered body/footer sync, exact snapshot/lease/repair roots, explicit repair/reacquisition, Zig/Python matrices covering 40 append phases + 754 section-prefix cases + 751 repair tails + 8 repair faults, and 49 host process deaths; no power-loss, live-dispatch, provider-truth, external exactly-once, Windows-durability, or performance claim |
| `tools/zig-with-ephemeral-cache.sh build action-outbox-dispatch-test -Dmetal=false -Doptimize=ReleaseSafe -j2` | W4b-d pointer-free adapter contract, trusted StoreV1 driver, and bounded same-process fake authority: one protected future reconciliation slot per existing uncertain action plus three additional dispatch slots, status admitted only when free slots cover every uncertain action, durable intent before dispatch, atomic `not_applied_fenced(G)`, stale `<= G` rejection before and after terminal completion, exact `G + 1` retry with stable request and a new dispatch root, pending/unknown no-retry, terminal duplicate application count one, deterministic same-process faults at four terminal-transition plus four fenced-transition append phases followed by fresh reopen/repair/reconciliation, integrated Zig coverage, 20 independent Python tests, and a separate live canonical Zig-to-Python reference validation |
| `zig build native-observation-test -Dmetal=false` | W5a fixed portable observer ABI and family-neutral runner: explicit present/missing/denied/unsupported, stable source identity separate from per-event provenance, nonzero unavailable-reason identity and no present-reason identity (all-zero fixed field), host/accelerator planes, sample-clock identity on every record and value-clock identity only on present time-valued metrics, fail-closed probe and pre-run admission, retained post-run contamination, correctness/zero-orphan/fallback gates, a download-free three-profile/six-item report checked independently, shared macOS system parsers and native read-only macOS smoke on Darwin, plus a platform-neutral JSON validator and bounded Linux available-memory adapter model; no throughput, latency, direct GPU/power/thermal, or multi-OS native claim |
| `tools/zig-with-ephemeral-cache.sh build native-workload-report-test -Dmetal=false -Doptimize=ReleaseSafe -j2` | W6a portable report conformance: a versioned allocation-free scenario/raw-record/summary/closure wire, a deterministic two-warmup/four-measured synthetic runner, measured-only counts and nearest-rank distributions, exact throughput rational and logical in-flight/fairness facts, availability-bearing metric slots, zero-orphan closure, rejection of a one-bit mutation at every byte plus truncation/extension/reorder/duplicate/semantic forgeries, and independent standard-library Python decode/recomputation of the live raw wire; it opens no device and is not native load or performance evidence |
| `tools/zig-with-ephemeral-cache.sh build native-workload-report-cross-compile -Dmetal=false -Doptimize=ReleaseSafe -j2` | Compile-only W6a codec-test and reference-runner coverage for Linux x86_64/AArch64 GNU, Windows x86_64 GNU, and FreeBSD x86_64; it does not execute those binaries and is not native evidence for any foreign target |
| `tools/zig-with-ephemeral-cache.sh build native-metal-workload-report-test -Dmetal=true -Doptimize=ReleaseSafe -j2` | W6b hard production-native macOS Metal report gate: 4 warmup plus 16 measured real 37x64 INT4 matrix-vector dispatches, two logical adapter slots and flows, both requests in each pair submitted before either wait, per-request CPU-oracle error at most `2e-5`, generation-fenced slot reuse, direct same-command GPU timing, sampled `currentAllocatedSize` context, independent portable-plus-profile wire verification, and terminal zero ownership. It is one exact correctness/evidence campaign, not throughput or latency evidence; logical slot coexistence is not physical GPU parallelism or hardware queue occupancy, `currentAllocatedSize` is not residency, and direct physical metrics remain unsupported. Add `-Dnative-metal-report-output=PATH` to retain the raw wire only after complete verification. |
| `tools/zig-with-ephemeral-cache.sh build native-metal-disruption-report-test -Dmetal=true -Doptimize=ReleaseSafe -j2` | W7a hard production-native macOS Metal controlled-disruption gate: 50 fixed epochs retain 250 ordered records around 100 CPU-oracle-checked real commands, 50 cancel-before-submit outcomes, 50 malformed pre-submit rejections, and 50 full-two-slot capacity rejections. Both commands are submitted before the capacity probe, B settles before A, every epoch returns to its fixed reusable eight-buffer boundary, and final closure proves 200/200 pins with zero live ownership. The three disruption branches are controlled runtime conditions, not physical device removal, driver crash, power loss, duration soak, performance, residency, utilization, or physical-parallelism evidence. Add `-Dnative-metal-disruption-report-output=PATH` to retain the raw wire only after complete verification. |
| `tools/zig-with-ephemeral-cache.sh build native-metal-cancellation-storm-report-test -Dmetal=true -Doptimize=ReleaseSafe -j2` | W7b-b3 hard production-native macOS Metal concurrent-caller gate: eight blocks of eight waves retain 128 cancel-before-submit and 64 capacity records with zero GPU commands, then 16 CPU-oracle-checked real Metal controls, for 208 records and 144/144 pin closure. Both real host threads reach the ready barrier before one shared release store in every wave; this proves the ready-before-release boundary, not simultaneous scheduling or execution, lock overlap, physical parallelism, hardware queue occupancy, kernel cancellation, preemption, or performance. Portable and exact profile verification bind the 163,132-byte wire, event partial order, challenge-selected settlement order, zero-command roots, unique generations, measured 91:91 flow balance, component identities, and terminal zero ownership. Add `-Dnative-metal-cancellation-storm-report-output=PATH` for verified retention. |
| `tools/zig-with-ephemeral-cache.sh build native-metal-inflight-process-kill-report-pure-test -Dmetal=false -Doptimize=ReleaseSafe -j2` | Portable W7b-b4 ready-frame and controller conformance: validates the exact 512-byte ABI, committed/scheduled nonterminal shapes, event values `1/1/2`, fixed live counts and roots, mutation rejection, signal/status/EOF protocol, and fresh-control composition without opening Metal, sending a native signal, or claiming a native process kill |
| `tools/zig-with-ephemeral-cache.sh build native-metal-inflight-process-kill-report-test -Dmetal=true -Doptimize=ReleaseSafe -j2` | W7b-b4 hard native macOS gate: a build-isolated fault-linked victim registers one real INT4 command, signals a private `MTLSharedEvent` at `1` after compute, and waits for `2`; its verified ready frame requires committed-or-scheduled status, completion unobserved, four live native buffers, one live command, and four active allocation references. The controller sends real `SIGKILL` to that PID only, requires exact `-9` and EOF, then a distinct production-linked W6 process completes 20 CPU-oracle-checked real Metal commands. The exact 19,468-byte outer report retains the ready frame, kill receipt, and complete W6 wire. The event barrier is controlled and synthetic; the command, process kill, and fresh control are real. This is not active-kernel interruption/preemption, victim-output recovery, state preservation, physical device-loss/reclamation, performance, or physical-telemetry evidence. Add `-Dnative-metal-inflight-process-kill-report-output=PATH` for verified retention. |
| `tools/zig-with-ephemeral-cache.sh build native-supervisor-recovery-death-report-test -Dmetal=false -Doptimize=ReleaseSafe -j2` | Portable W7b-b5 Python/Zig report conformance: independently constructs and verifies the exact 3,520-byte header/ready/kill/audit/footer layout, generation-six and prepared-generation-twelve semantics, derived resume/finalizer grants, component and machine bindings, canonical roots, mutations, truncation, extension, and substitution. It opens no GPU, sends no signal, and makes no native durability claim. |
| `tools/zig-with-ephemeral-cache.sh build native-supervisor-recovery-death-report-cross-compile -Dmetal=false -Doptimize=ReleaseSafe -j2` | Compile-only W7b-b5 codec tests and standalone Zig verifier for the retained foreign targets. It executes no foreign binary, filesystem protocol, signal, or Metal command and is source-portability evidence only. |
| `tools/zig-with-ephemeral-cache.sh build native-supervisor-recovery-death-host-test -Dmetal=false -Doptimize=ReleaseSafe -j2` | Two-layer W7b-b5 host conformance: the deterministic staged-store model accepts caller-supplied opaque nonzero grants and checks their exact use receipts across generation-six resume, prepared generation twelve, and `11 -> 12` roll-forward; a separate real-process fixture uses static challenges while covering advisory-lock contention, challenge-bound acknowledgements, two PID-only `SIGKILL` operations, exact `-9`/EOF, fresh role PIDs, cleanup, and selector replacement. It runs no GPU work and does not claim causal composition between the layers; only the native hard gate composes derived grants, audits, deaths, store, and workers end to end. |
| `tools/zig-with-ephemeral-cache.sh build native-metal-supervisor-recovery-death-report-compile -Dmetal=true -Doptimize=ReleaseSafe -j2` | Compile-only W7b-b5 native frontier. It builds every focused-gate artifact and static check without opening a device or launching the campaign. |
| `tools/zig-with-ephemeral-cache.sh build native-metal-supervisor-recovery-death-report-test -Dmetal=true -Doptimize=ReleaseSafe -j2` | W7b-b5 hard production-native macOS Metal gate: worker one completes ordinals `0..5` and exits cleanly before real supervisor `SIGKILL` and a fresh generation-six audit. Worker two completes ordinals `6..11` and exits cleanly after generation-twelve objects and the 192-byte selector temporary are synchronized while generation eleven remains active; real recovery-process `SIGKILL` is followed by a separately authorized exact `11 -> 12` roll-forward and final fresh audit. The campaign executes 1,200 CPU-oracle-checked real Metal commands plus real locks, file writes, hard links, replacements, and `fsync`; the exact 3,520-byte report passes Python and Zig verification. Controlled barriers/timing/pause/grants are not active-kernel, victim-output, physical storage/power/device/driver fault, residency, performance, or leak-freedom evidence. Add `-Dnative-metal-supervisor-recovery-death-output-dir=PATH` for verified private-directory retention. |
| `tools/zig-with-ephemeral-cache.sh build native-workload-campaign-test native-workload-campaign-compile native-workload-campaign-cross-compile -Dmetal=false -Doptimize=ReleaseSafe -j2` | Portable W7b campaign conformance: the canonical fixed-width manifest and selector, contiguous verified-prefix publication with exact zero padding, dual predecessor chains, process-generation and memory-observation rules, independent Python recomputation, store-compatible roots, byte-identical zero-flag clean-restart goldens, and exact forced-action/provenance/`SIGKILL` semantics. It opens no device, sends no signal, and supplies no native GPU, RSS, durability, or foreign-platform execution evidence. |
| `tools/zig-with-ephemeral-cache.sh build native-workload-store-fault-report-cross-compile -Dmetal=false -Doptimize=ReleaseSafe -j2` | Compile-only W7b-b2 report-codec tests and standalone Zig verifier for Linux x86_64/AArch64 GNU, Windows x86_64 GNU, and FreeBSD x86_64. It executes no foreign binary or filesystem campaign and is not native recovery evidence for those targets. |
| `tools/zig-with-ephemeral-cache.sh build native-workload-store-fault-test -Dmetal=false -Doptimize=ReleaseSafe -j2` | W7b-b2 production-publisher/reference-recovery campaign-store gate: one exact prepared generation advances through 27 ordered publication calls under 27 real writer `SIGKILL` deaths, 27 controlled `EIO` returns, 27 controlled `ENOSPC` returns, and one clean control. Every case uses two fresh recovery children and one fresh strict verifier; the 42,880-byte report is then checked in fresh Python and Zig processes. Host processes and filesystem calls are real; workload bytes and errno injection are deterministic, no GPU/model runs, and this is not a general production recovery API or physical disk-full, quota, media/controller, power-cut, reboot, Windows, distributed-filesystem, or performance evidence. Add `-Dnative-workload-store-fault-output=PATH` to retain the verified report. |
| `tools/zig-with-ephemeral-cache.sh build native-metal-soak-report-pure-test -Dmetal=true -Doptimize=ReleaseSafe -j2` | Pure W7b supervisor/store conformance: deterministic worker protocol, exact scheduled-kill and natural-exit rejection, descendant watchdog cleanup, checkpoint, content-addressed store, recovery, component replacement, malformed-prefix, and offline-verification tests. It does not run either 60-second campaign or execute a Metal command. |
| `tools/zig-with-ephemeral-cache.sh build native-metal-soak-report-test -Dmetal=true -Doptimize=ReleaseSafe -j2` | W7b-a hard production-native macOS Metal segmented-soak gate: 12 independently verified segments of 50 paced epochs each execute 1,200 CPU-oracle-checked real commands across two persistent worker generations with one planned clean restart and a 60-second minimum schedule. Every checkpoint is canonical and auditable but grants no append or resume authority; complete verification covers all 600 epochs, 3,000 records, exact resource closure, process RSS, and bounded `currentAllocatedSize` context. After the writer closes, a fresh process verifies the store before ephemeral cleanup. RSS is process-level observation, while `currentAllocatedSize` is device-wide allocation context—not residency, owned GPU memory, utilization, or a physical-parallelism measurement. Add `-Dnative-metal-soak-output-dir=PATH` to retain the verified campaign store; omit it for an ephemeral verified run. |
| `tools/zig-with-ephemeral-cache.sh build native-metal-process-kill-report-test -Dmetal=true -Doptimize=ReleaseSafe -j2` | W7b-b1 hard production-native macOS Metal process-kill gate: it retains the same 12-segment, 1,200-command geometry under a distinct sealed schedule, verifies and synchronizes segment six, sends a real `SIGKILL` to that quiescent worker, requires wait status `-9`, publishes and re-reads generation six, and completes in a fresh Metal process before fresh-process offline store verification. The kill occurs after logical closure, not during a GPU command; it proves no supervisor-crash resume, driver reclamation, device loss, storage fault, performance, or leak freedom. Add `-Dnative-metal-process-kill-output-dir=PATH` for retention. |
| `tools/zig-with-ephemeral-cache.sh test src/core/device_lifecycle_contract.zig -OReleaseSafe` | Pointer-free Device-loss Observation V1: every source/state mapping, exact status/domain/code `5/1/11` classification, explicit native versus synthetic evidence, canonical prior-inventory recomputation, present-to-newer-unavailable/lost transition receipts, capability/policy preservation, selection exclusion, and mutation/replay/substitution rejection. This deterministic contract gate opens no Metal device and proves no physical failure or recovery. |
| `tools/zig-with-ephemeral-cache.sh test src/core/device_loss_dispatch_reconciliation.zig -OReleaseSafe` plus `python3 -m unittest bench.tests.test_device_loss_dispatch_reconciliation` | Device-loss Dispatch Reconciliation Phase A contract models: fixed pointer-free 440-byte retention, 240-byte plan, and 448-byte receipt values; exact lifecycle, selection, lease, active-pin, terminal-failure, dispatch-completion, and Bank-completion replay; stable independent roots; native-only production eligibility for command-specific `5/1/11`; synthetic structural coverage; replay and authority-drift rejection; and separate later allocation retirement. These deterministic gates open no Metal device, execute no GPU work, and do not prove physical device loss. |
| `tools/zig-with-ephemeral-cache.sh test src/core/device_loss_dispatch_callback_retirement.zig -OReleaseSafe` plus `python3 -m unittest bench.tests.test_device_loss_dispatch_callback_retirement` | Device-loss Dispatch Callback Retirement Phase B contract models: fixed pointer-free 464-byte retention, 240-byte plan, 408-byte callback fence, and 504-byte receipt; exact pending/submission-ambiguous/completion-unknown/invalid-completion shapes; callback-detached/record-retained fencing without callback-exit inference; dedicated zero-output ownership-retired terminal; Bank/native settlement composition; production-native eligibility; and mutation, substitution, duplicate, foreign, replay, and late-settlement rejection. These deterministic gates open no Metal device and execute no GPU work. |
| `tools/zig-with-ephemeral-cache.sh test src/core/device_loss_retirement.zig -OReleaseSafe` plus `python3 -m unittest bench.tests.test_device_loss_retirement` | Device-loss Retirement V1 contract models: fixed plan/receipt ABIs, canonical roots, exact loss/selection/allocation/terminal binding, native-versus-synthetic production eligibility, unavailable and substitution rejection, exact replay, and forced zero physical-reclaim/output/migration/reset authority. These deterministic tests open no Metal device and make no native-removal claim. |
| `tools/zig-with-ephemeral-cache.sh test src/core/device_allocation_lease_tree.zig -OReleaseSafe` plus `python3 -m unittest bench.tests.test_device_allocation_lease_tree` | Portable dispatch-lifetime contract models: Zig fake-adapter/state tests cover sealed pre-Bank intent reservation and exact abort, callback/source drift, object-set pins, terminal shapes, `MetalAsyncDispatchTicketV1`, exact submit replay, pending ownership retention, sticky nonterminal quarantine, private settlement retry, slot release, and allocation fencing; the independent Python oracle rebuilds the ticket/quarantine ABI roots and rejects coherent substitutions. These deterministic tests open no device, create no native resource, and execute no GPU command. |
| `tools/zig-with-ephemeral-cache.sh build native-metal-observation-test -Dmetal=true -Doptimize=ReleaseSafe -j2` | Hard native macOS Metal diagnostic-readiness gate: exactly one real GPU dispatch total for a fixed synthetic 37x64 INT4 matrix-vector operation, CPU-oracle correctness, completed command-buffer GPU timestamps, registry-bound device/placement identity, `currentAllocatedSize`, zero leaked ownership, explicit no fallback, composed observation/run/dispatch roots, and an independent live-output verifier; no throughput, latency, performance, utilization, residency, queue, thermal, frequency, power, energy, cryptographic-origin, broad-device, or multi-OS claim |
| `tools/zig-with-ephemeral-cache.sh build native-metal-correctness-test -Dmetal=true -Doptimize=ReleaseSafe -j2` | Native Metal correctness and lifecycle no-event gate: installs the real per-context device observer, confirms selected-device initial membership, runs one real GPU command, and requires the lifecycle snapshot to remain unchanged around that successful command. The completed development-host run used a built-in M1 GPU; it did not exercise removal-requested, removed, or exact code `11`, and proves no safe recovery or migration. |
| `tools/zig-with-ephemeral-cache.sh build native-metal-allocation-test -Dmetal=true -Doptimize=ReleaseSafe -j2` | Hard native macOS Metal allocation and dispatch-lifetime gate: opens a real `MTLDevice` and creates/inspects real Shared `MTLBuffer` resources through ChildLease and LeaseTree coordinators; verifies exact logical precharge/reserve/release, private FreePermit settlement, partial-allocation cancellation, per-object device/length/`allocatedSize`, foreign/stale-token rejection, distinct adapter authorities, registry balance, and generation-fenced reuse. Its four-buffer profile uses an adapter-issued generation-fenced `MetalMatvecDispatchRequestV1` root plus sealed pre-Bank `DispatchPinIntentV1`; the valid branch separately submits, polls or waits, validates exact completed output, settles Bank ownership, finalizes the retained native command, and checks a CPU oracle. Malformed attempts may inspect the real context/resources but construct and submit no command buffer; the valid pure-cancellation branch performs no native inspection. Both no-submit branches produce zero submission/backend/output roots, execute zero GPU commands, and share the private Bank-pin/adapter settlement and replay tombstone. Public acknowledgement only verifies the settled tombstone. Sticky quarantine detects ambiguous/unknown/invalid/error outcomes but does not reconcile or clear them. No device-loss recovery, multi-slot scheduling, residency, heap, performance, broad-device, or multi-OS claim. |
| `tools/zig-with-ephemeral-cache.sh build native-metal-fault-test -Dmetal=true -Doptimize=ReleaseSafe -j2` | Build-isolated native macOS Metal fault/reconciliation/retirement conformance: verifies production-symbol isolation; races the Phase A one-shot overlay with exactly one winner; keeps physical success separate from a synthetic code-`11`-shaped publication; proves Bank-first Phase A finalization and confirmation retry; and separately releases a real-buffer allocation under synthetic loss. The Phase B matrix submits real commands over four real buffers for pending, submission-ambiguous, completion-unknown, and invalid-completion ownership. It combines a held handler, a post-commit ambiguous disposition authenticated by the native record, a valid unknown projection that changes only `callback_fault` after independently verified physical success, and an exact completed-output-read rejection before caller memory is written. It derives retention through the adapter, consumes each Bank pin before exact native unlink, replays each tombstone, preserves caller output, and performs allocation release separately. Identity-matched production 256-byte retirement-telemetry snapshots verify successful fresh/replayed prepare and commit deltas, live prepared ownership, detach-before-exit, frozen native fact buckets, exact one-record/four-reference retirement, tombstones, generations, and unchanged rejected operations. Adapter-only receipt replay is correctly absent from native commit-replay telemetry. Separate backend validator tests cover canonical mutation and sticky-saturation snapshot shapes; they do not constitute runtime native saturation evidence. The seams and loss/error controls are synthetic and test-only: this gate does not reproduce physical removal or driver/hardware failure and is not output-recovery, migration, reset, physical-reclaim, residency, queue-depth, utilization, power, thermal, frequency, energy, or performance evidence. |
| `tools/zig-with-ephemeral-cache.sh build native-metal-suite-compile -Dmetal=true -Doptimize=ReleaseSafe -j2` | Compile-only native Metal frontier: completes every test, executable, shared artifact, and static check consumed by the serialized suite before its first device process starts through one explicit suite-consumer inventory, the content-addressed shader library, and the build-isolated fault-symbol check. It deliberately excludes the wider device and host-tool profile umbrellas, keeping eleven unrelated compile artifacts deferred. The shader cache key tracks the selected Xcode tools, SDK settings, and Metal standard-library contents. `tools/verify.sh` then reuses the same build graph, private caches, and Metal output directory for the separate `-j1` hardware phase, avoiding duplicate compilation through independent cold invocations. It opens no device and executes no GPU campaign, so success is build and static-isolation evidence only. |
| `tools/zig-with-ephemeral-cache.sh build native-metal-suite-test -Dmetal=true -Doptimize=ReleaseSafe -j1` | Serialized native macOS device suite: readiness → allocation ownership → production-native workload report → controlled disruption → cancellation storm → segmented clean-restart soak → post-segment process-kill recovery → controlled in-flight process kill → supervisor/recovery-process death → fault/reconciliation → focused correctness and lifecycle no-event validation, with no overlap between those device gates. Before each 60-second campaign, a bounded stabilizer requires two explicit nominal admission observations ten seconds apart within 180 seconds; timeout fails, while the campaign's own retained before/after checks still reject an in-run excursion. The suite combines their evidence boundaries and does not create a benchmark. Suite W6b report retention remains explicit through `-Dnative-metal-suite-report-output=PATH`; focused W7b reports and stores use their separate retention options. |
| `zig build lane-publication-demo -Dmetal=false` | One-token prepare/commit/abort with KV, RNG, sampler, output, schedule, and resource roots |
| `zig build lane-contiguous-demo -Dmetal=false` | Concrete contiguous KV row publication and portable receipt |
| `tools/zig-with-ephemeral-cache.sh build test -Doptimize=ReleaseSafe -Dmetal=false -j2` | Full retained suite, including receipt-funded prepared-text activation at sequence `N`, one uninterrupted/restored synthetic-model transition comparison, and target teardown to zero |
| `tools/zig-with-ephemeral-cache.sh build text-runtime-golden-path-test -Dmetal=false -Doptimize=ReleaseSafe -j2` | One compile-root package/raw-text gate using the staged production `bin/glacier`: the Python controller runs CLI children from an empty working directory with isolated ambient state, requires the installed binary namespace to remain byte-identical, derives deterministic in-vocabulary process-local early-EOS, EOS-at-limit, and EOS-miss cases, independently recomputes variable-terminal and completed-early roots, proves unused-quanta closure and durable-EOS rejection before mutation; retains the direct `N=1` bootstrap/retry/fresh-process/terminal checks; exercises acknowledged `N=4` bootstrap retry, changed-count and foreign-input no-mutation rejection, fresh-process continuation, complete independent checkpoint/sink lineage decoding, ordinary-output equality, and byte-identical terminal retry; adds a trusted-parent all-grants control plus real child-only `SIGKILL` after source advance and target ordinal one, then requires exact signal/EOF/no-JSON evidence, independent fresh-process namespace and output convergence, no duplicate acknowledgement or suffix, and immutable terminal retry; rejects preloaded, wrong-field, and short-control grants without changing generation one; and covers one-shot `N=2` and `N=64` endpoints so capacities `1`, `3`, and `63` are verified. The explicit paired POSIX supervisor protocol and death cases add no executable or compile root. This is installed-shape, same-host synthetic CPU correctness and recovery evidence, not exhaustive storage/power-loss, native multi-OS, remote orchestration, authentication, hostile-writer resistance, GPU, production-quality, or performance evidence. |
| `tools/zig-with-ephemeral-cache.sh build unary-server-process-test -Dmetal=false -Doptimize=ReleaseSafe -j2` | R1k-b8 Phases A-D through Phase E2b plus Phase F1 managed unary-server host-process gate. One dual-mode executable supervises and re-executes itself against a generated `32/64/1/256` ordinary package. Generation zero exits nonzero without `READY`; generation A proves model-list, completion/replay, malformed-peer survival, clean drain, restart identity, and zero ownership. Phase B uses exact `receiving_head` and `request_head_received` barriers to prove fenced receive-side drain cancellation with one failed connection and no service record. Phase C uses the same partial-head/body shapes to prove one bounded monotonic pre-admission receive deadline, distinct timeout evidence, same-child liveness, and no admission closure. Phase D adds synchronous barriers after exact active-work publication and before the serving thread's first drive operation. The cancellation-wins child invokes ordinary drain twice, validates a correlated `request_cancelled` error with retry policy `never`, and closes with one admitted-work cancellation at `request_admitted`. The completion-wins child first drives the one-token service request terminal while its HTTP lease remains published, invokes drain twice, and preserves the oracle-matched successful completion with zero work cancellations. Both close with one accepted and completed connection, zero failed connections, zero receive-drain and receive-timeout signals, zero active service requests, one terminal record, and zero Bank ownership. Phase E1 adds deterministic peer-reset and response-ready drain/completion controls. Phase E2a adds a bounded nonblocking `1..4096`-byte send quantum, real post-send progress and `WouldBlock` checkpoints, distinct drain-request/effective-cancellation/independent-transport-failure counters, and final-send completion-winner semantics. Two deterministic process siblings meet after the first real one-byte send: one drains and proves `cancelled_during_write`, while the other completes the oracle response. A focused native-loopback saturation primitive separately reaches real `WouldBlock`. Phase E2b adds one accept-origin monotonic full-request deadline through response retirement, exact signal/work/response/write-request/effective-write-cancellation evidence, three phase-targeted timeout siblings, no synthesized post-deadline HTTP response, and same-child liveness with zero ownership. The barriers are deterministic rather than sleep or model-duration proxies. Frames remain bounded and expose no prompt or host path. Phase C remains the shorter pre-admission timeout; Phase E2b owns the separate full-request elapsed boundary, orderly-FIN abandonment remains open, and local `response_written`/`write_completed` evidence does not prove peer delivery. Phase F1 adds four native POSIX child-process profiles over real loopback sockets and the production fixed-worker/FIFO/shared-watchdog entrypoint: queued receive timeout while active terminal work completes plus a healthy successor; queued full-request timeout plus a healthy successor; simultaneous two-caller drain over one active receive and one queued socket; and stale-owner rejection after exact slot reuse with fail-closed queued/running cleanup. The last profile deliberately corrupts only retained owner metadata as a white-box fault injection; exact generation-mismatch rejection and cleanup use the production drain/failure path. A serial application-rejection child in the same executable retains exact service-capacity and deadline-infeasible Scheduler observations, canonical request digests, managed owners, unchanged work sequencing, and zero ownership. The F1 profiles prove aggregate event/cause conservation, unique contiguous event ordinals, joined threads, and final zero connection, Service, Scheduler, and Bank ownership. The campaign uses real child processes and TCP loopback over the generated synthetic tiny-model fixture; it is not load/performance, concurrent model execution, GPU behavior, production-model quality, or native Windows/FreeBSD serving proof. Process-wide overload policy, orderly-FIN abandonment, durable idempotency/crash recovery, streaming, authentication/TLS, and native foreign-OS runtime behavior remain open. |
| `zig build unary-http-test -Dmetal=false -Doptimize=ReleaseSafe -j2` | Passing Phase F1 deterministic native-loopback correctness over the production concurrent entry points. On POSIX, the serving call temporarily makes the listener nonblocking, polls readiness for at most 100 milliseconds per quantum with lifecycle revalidation before `accept`, returns every accepted socket to blocking mode before FIFO or worker handoff, and restores the exact listener flags captured before serving after every worker and the watchdog join. Managed receive revalidates lifecycle on every readiness-wait iteration, with each quantum capped at 100 milliseconds even when the configured timeout is zero, so drain and fatal convergence do not depend on cross-thread `shutdown` succeeding. An unexpected shutdown error advances no successful signal counter or event for that connection and leaves it unclaimed, allowing failure convergence to retry and take over. Drain holds the lifecycle lock across runtime receipt capture and exact-owner application. Fatal convergence uses `transport_failure`, emits `running_failure` for newly claimed running leases, and retains failure-specific counters without incrementing drain counters. Scenario A keeps one worker live beside a sibling partial HTTP head. Scenario B proves one-worker/one-pending FIFO dispatch, exact passive pause/resume, and healthy follow-up service. Scenario C retires the exact queued lease under its accept-origin full-request timeout without an HTTP response, then serves a successor. Scenario D makes two concurrent drain calls converge over one active receive plus one queued socket. All four check event/snapshot conservation, joined shutdown, and final zero service/Bank ownership. The model gate remains serialized and FIFO covers accepted-queue dispatch only. This is not Phase F1 real-process, native-load/performance, GPU, or native foreign-OS evidence. Phase F1 concurrent serving is explicitly unsupported on Windows today: the entrypoint returns `ConcurrentListenerModeUnsupported` before worker/watchdog startup because it cannot prove and restore the caller's original `FIONBIO` mode. Native Windows serving therefore remains pending and unproven. |
| `tools/zig-with-ephemeral-cache.sh build unary-server-process-compile -Dmetal=false -Doptimize=ReleaseSafe -j2` | Compile-only closure for the same managed controller/worker artifact. Phases B-F1 and application-rejection evidence reuse this target and add no compile root. Complete affected verification selects it on retained targets only during explicit manual or milestone promotion; it launches no child and is portability evidence only, not native serving or lifecycle evidence for a foreign target. |
| `tools/zig-with-ephemeral-cache.sh build prepared-text-acknowledged-delivery-test -Dmetal=false -Doptimize=ReleaseSafe -j2` | Compile-once focused prepared-text delivery gate for canonical generation-one replay, exact empty-sink admission, acknowledgements, idempotent sink replay/conflict/gap handling, ACK-bound progress/terminal generations, restored grant advancement, the sink-free fixed-output-count-one terminal-source contract, exact generation-one-to-two lineage, terminal source-claim completion, and read-only direct-output selector-race rejection. It is deterministic local POSIX synthetic-fixture evidence; real-process-death evidence is supplied by the separate bounded smoke below. It does not claim remote exactly-once, hostile-writer or physical power-loss, GPU, Win32, production-model, or performance behavior. |
| `tools/zig-with-ephemeral-cache.sh build prepared-text-direct-terminal-recovery-smoke-test -Dmetal=false -Doptimize=ReleaseSafe -j2` | Focused four-boundary direct-terminal smoke reusing the prepared-text recovery worker: real `SIGKILL` after the one model step, after runtime retirement, after the checkpoint selector rename, and after generation-two publication. An independent Python oracle admits exact generation one for the first two cases and exact generation two for the last two, then requires fresh recovery, a fresh zero-step already-selected audit, exact embedded predecessor lineage, terminal token/semantic/state/view roots, and a checkpoint-only namespace with no result sink. It compiles no separate worker and is bounded host-process-death evidence over a synthetic CPU fixture, not exhaustive I/O/storage faults, physical power loss, GPU, Win32, production-model, or performance evidence. |
| `tools/zig-with-ephemeral-cache.sh build prepared-text-result-inspector-test -Dmetal=false -Doptimize=ReleaseSafe -j2` | Focused R1k-b3 committed-output inspection gate for aligned and sink-exactly-one-ahead reconciliation, terminal aligned state with a nonempty acknowledgement prefix, exact `utf8-byte-v1` token bytes bounded to `0...255`, payload-omitting default output with non-confidential metadata, explicit exact-byte disclosure, nullable strict UTF-8 text, shared Zig/Python roots, failure-atomic caller output, one real `after_sink_before_selector` process death, and unchanged bounded directory manifests around both inspector calls. This is deterministic read-only evidence over a cooperative local POSIX fixture. It creates no lease or authority and proves no hostile-writer defense, authentication, payload privacy, physical power-loss persistence, remote exactly-once delivery, GPU or Win32 behavior, native multi-OS support, production-model execution, ordinary serving integration, or performance. |
| `tools/zig-with-ephemeral-cache.sh build prepared-text-recovery-test -Dmetal=false -Doptimize=ReleaseSafe -j2` | Combined compile-once recovery gate reusing one worker across the 49-boundary R1j acknowledged campaign and the four-boundary direct-terminal smoke. R1j covers seven generation-one bootstrap, 23 source-transition, and 19 target-transition deaths; the direct smoke covers post-step, post-retirement, selector-rename, and post-generation-two deaths. Independent decoding admits only each boundary's exact allowed state and requires the applicable terminal oracle. Scope is the local POSIX synthetic CPU fixture; source replay after external effects, exhaustive storage faults, remote delivery, hostile writers, physical power loss, GPU/Win32 behavior, and production execution remain outside the claim. |
| `zig build continuation-capsule-demo -Dmetal=false` | Fixed-size committed-checkpoint manifest, typed external object binding, and substitution rejection |
| `zig build continuation-resolver-demo -Dmetal=false` | Tenant-scoped exact-object lookup, bounded quotas, caller-owned output, and full composition verification |
| `zig build continuation-bundle-demo -Dmetal=false` | Fixed tenant bundle, semantic/blob identity separation, canonical ordinals, and exact logical/unique totals |
| `zig build continuation-store-demo -Dmetal=false` | Atomic bundle import, duplicate reuse, generation-fenced leases, quarantine repair, exact accounting, and v1/v2 snapshots |
| `zig build continuation-collection-demo -Dmetal=false` | Exact root multiplicity, complete lease coverage, bounded classification, and a non-mutating collection-plan root |
| `zig build continuation-sweep-demo -Dmetal=false` | Separately scoped plan regeneration, staging ceilings, functional prepare/abort roots, and zero payload deallocation |
| `zig build continuation-sweep-commit-demo -Dmetal=false` | Exact no-mutation preview, real file publication before deallocation, injected-boundary recovery, idempotent old/new reconciliation, exact accounting, and allocator tail reclamation |
| `zig build continuation-sweep-record-demo -Dmetal=false` | Fixed record verification, anchored tail classification, snapshot-bound append/repair capabilities, ordered sync, and deterministic crash-storage conformance |
| `zig build continuation-sweep-file-demo -Dmetal=false` | Descriptor-relative lock/identity/sync checks and six native subprocess-death recovery boundaries |
| `zig build continuation-payload-file-demo -Dmetal=false` | Canonical payload snapshots, fixed exact-target reclaim plans, copy-on-write promotion, and seven native subprocess-death recovery boundaries |
| `zig build continuation-live-restart-demo -Dmetal=false` | Fresh-process ownership/KV/RNG/output restore and exact-once publication of the next token |
| `zig build continuation-checkpoint-file-demo -Dmetal=false` | Immutable whole-checkpoint archive, atomic selector switch, seven process-death phases, and fresh live resume after each recovery |
| `zig build media-contract-demo -Dmetal=false` | Fixed image/audio/video descriptors, exact rational mapping, explicit event lineage, two logical chunk commits, and stale-replay rejection |
| `zig build media-decode-fixture-demo -Dmetal=false` | Sealed plans plus bounded RGB8, PCM s16le, and intra-frame gray8 fixture decode with complete per-unit source mapping |
| `zig build media-transform-demo -Dmetal=false` | Sealed image/audio/video transform plans, caller-owned allocation-free execution, exact output-unit mappings, and shared cross-language plan/receipt roots |
| `zig build media-runtime-demo -Dmetal=false` | Exact image/audio/video ResourceBank admission, provisional execution, candidate revalidation, atomic commit/abort/retry, fixed receipts, and complete release |
| `zig build media-runtime-lease-demo -Dmetal=false` | Per-buffer LeaseTree charge-before-use, abort reclamation, early provisional retirement, retained output ownership, fixed hierarchical receipts, and final zero state |
| `zig build media-stream-demo -Dmetal=false` | Six bounded image/audio/video chunks, two retained outputs per stream, cancellation-safe retry, exact target gap/overlap rejection, portable chunk chaining, and final zero state |
| `zig build media-stream-continuation-demo -Dmetal=false` | Three portable 2,048-byte checkpoints, fresh-Bank charge-before-materialization output restore, exact next-chunk publication, and final zero state |
| `zig build media-stream-live-restart-demo -Dmetal=false` | Distinct source/target PIDs, synced image/audio/video checkpoints and retained outputs, three resumed chunks, zero duplicates, and explicit non-atomic-set disclosure |
| `zig build media-stream-checkpoint-set-demo -Dmetal=false` | Six-object materialized image/audio/video generations, canonical retained-output, processor-state, and cache-payload bundles, seven `SIGKILL` boundaries, restore-before-visible cache ownership, fresh-process generation three, idempotent recovery, and final zero ownership |
| `zig test src/core/vision_encoder_adapter.zig -OReleaseSafe` | Canonical model artifact/plan/result records, explicit support negotiation, a live-cache exact-integer vision projection, scheduler-receipt adoption, final-service typed publication, candidate drift rejection, and final zero ownership |
| `zig test src/core/audio_window_adapter.zig -OReleaseSafe` | Live signed feature windows, exact sample/window/hop source mapping, scheduler-receipt adoption, final-service stateless publication, abort/drift rejection, and final zero ownership |
| `zig test src/core/audio_transcript_adapter.zig -OReleaseSafe` | Canonical overlap and transcript wires, context-only versus publishable sample ranges, live cache ownership, predecessor/candidate substitution rejection, transactional text visibility, and final zero ownership |
| `zig test src/core/temporal_video_adapter.zig -OReleaseSafe` | Live temporal cache, canonical strided-frame selection, keyframe/eviction lineage, charged-and-scrubbed gather scratch, exact target-time mapping, scheduler-receipt adoption, final-service publication, candidate drift rejection, and final zero ownership |
| `zig test src/core/video_segment_adapter.zig -OReleaseSafe` | Canonical 512-byte video segments, exact frame/time bounds, live selection/cache lineage, predecessor binding, mutation rejection, transactional visibility, and final zero ownership |
| `zig test src/core/video_segment_timeline.zig -OReleaseSafe` | Canonical 384-byte timeline/merge wires, same-event overlap coalescing, gap/event separation, raw/decision lineage, mutation and candidate-drift rejection, and final zero ownership |
| `zig test src/core/audio_video_result_link.zig -OReleaseSafe` | Canonical 320-byte state and 576-byte cross-modal result wires, publish-only audio mapping, exact time conversion, positive-overlap relations, dual-modality lineage, mutation/drift rejection, and final zero ownership |
| `zig test src/core/audio_transcript_continuation.zig -OReleaseSafe` | Exact 32-byte transcript state, canonical 576-byte composed checkpoint, previous/next sample continuity, foreign-lineage rejection before admission, fresh-Bank restore, second transcript/link publication, and final zero ownership |
| `zig build audio-transcript-live-restart-demo -Dmetal=false` | Distinct source/target PIDs, synced transcript/state/link evidence, charge-before-materialization restore, context reuse without duplicate text, exact next sample range, cross-modal link continuation, and final zero ownership |
| `zig test src/core/speech_annotation_publication.zig -OReleaseSafe` | Fixed annotation state/plan/result wires, exact transcript-word/sample/speaker bindings, canonical palette ordering, mutation/substitution rejection, abort/drift preservation, atomic publication, and final zero ownership |
| `zig build speech-annotation-live-restart-demo -Dmetal=false` | Distinct source/target PIDs, state validation before admission, exact `ice`/`berg` sample ranges, two speaker turns, one cancellation-safe retry, zero duplicate words, and final zero ownership |
| `zig test src/core/latent_step_adapter.zig -OReleaseSafe` | Canonical retained-state wire, pinned model/state snapshots, buffer-alias rejection, exact latent candidate, atomic state/result publication, abort/drift preservation, and final zero ownership |
| `zig build stateful-model-live-restart-demo -Dmetal=false` | Canonical intermediate checkpoint, distinct source/target PIDs, fresh-Bank charge-before-materialization latent restore, chained terminal plan, zero duplicate results, and final zero ownership |
| `zig test src/core/generated_image_publication.zig -OReleaseSafe` | Fixed generated-image plan/provenance/result wires, exact terminal-latent lineage, bounded private decode, abort/drift visibility preservation, atomic image publication, mutation rejection, and final zero ownership |
| `zig build generated-image-live-restart-demo -Dmetal=false` | Distinct source/target PIDs, charge-before-materialization latent restore, exact terminal step, one cancelled image publication, atomic retry, bound provenance, zero duplicate images, and final zero ownership |
| `zig test src/core/generated_audio_playback.zig -OReleaseSafe` | Seven canonical generated-audio/acknowledgement wires, exact PCM/frame/resource/sink lineage, one-buffer backpressure, mutation and partial/duplicate rejection, abort/drift preservation, atomic publication, and final zero ownership |
| `zig build generated-audio-live-restart-demo -Dmetal=false` | Distinct source/target PIDs, pending-state validation before admission, publication blocked before acknowledgement, partial acknowledgement rejection, one cancellation-safe successor retry, two exact PCM chunks, zero duplicates, and final zero ownership |
| `zig test src/core/generated_video_display.zig -OReleaseSafe` | Seven canonical generated-video/display wires, two ordered frame roots and durations, exact media/resource/sink lineage, one-segment backpressure, mutation and partial/duplicate rejection, abort/drift preservation, atomic publication, and final zero ownership |
| `zig build generated-video-live-restart-demo -Dmetal=false` | Distinct source/target PIDs, all retained records and frame roots validated before admission, publication blocked before acknowledgement, partial display rejection, one cancellation-safe successor retry, two exact raw-video segments, zero duplicates, and final zero ownership |
| `zig test src/core/generated_media_checkpoint.zig -OReleaseSafe` | Canonical typed member/checkpoint/selector wires, exact image/audio/video completion binding, aggregate totals and continuity, mutation/substitution rejection, and independent golden roots |
| `zig build generated-media-checkpoint-restart-demo -Dmetal=false` | Two immutable generated-output generations, four selector durability deaths, two previous and two successor recoveries, complete three-member validation in fresh processes, and zero mixed-generation observations |
| `zig test src/core/generated_media_payload_archive.zig -OReleaseSafe` | Canonical 864-byte payload manifest, eight-object archive, exact raw/encoded/encoder/format binding, two-generation lineage, mutation/substitution rejection, and independent golden roots |
| `zig build generated-media-payload-archive-restart-demo -Dmetal=false` | Exact image/audio/video encoded payloads, one outer selector, seven process deaths, five previous and two successor selections, zero mixed generations, and idempotent recovery |
| `zig test src/core/generated_media_output_registry.zig -OReleaseSafe` | Independent registry ABI, fixed 544-byte manifest and entries, canonical bounded multi-output ordering, exact ordinal/unit/timeline/payload/predecessor binding, structural completion fields, mutation plus stale-root/mixed-lineage substitution rejection, and independent golden roots |
| `zig build generated-media-output-registry-restart-demo -Dmetal=false` | `2/3/2` then `2/2/3` image/audio/video outputs in exact three-object archives, one existing selector, seven process deaths, five previous and two successor selections, zero mixed generations, exact payload recovery, and idempotent convergence |
| `zig test src/core/generated_media_producer_admission.zig -OReleaseSafe` | Canonical typed image/audio/video record decoding, exact raw pixel/PCM/frame-byte checks, common-envelope derivation, one-based image-position normalization, strict state/result/completion predecessor continuity, and construction of the unchanged registry contract mirrored by an independent Python test |
| `zig test src/core/generated_media_producer_transition.zig -OReleaseSafe` | Host replay of retained deterministic source-model/materializer profiles, exact one-shot image and complete audio/video transitions, fixed per-output receipts, derived collection order, and paired sidecar/unchanged-registry lineage mirrored by an independent Python test |
| `zig build provider-gateway-demo -Dmetal=false` | Request coalescing, reservation, settlement, fixed-point cost, and journal append |
| `zig build provider-transport-demo -Dmetal=false` | Credential-free chunk and terminal-usage transport replay |
| `zig build provider-cancel-demo -Dmetal=false` | Consumer withdrawal and active transport cancellation |
| `zig build provider-context-pack-demo -Dmetal=false` | Lossless exact-duplicate mapping and deterministic token fixture |
| `zig build provider-context-reconciliation-demo -Dmetal=false` | Raw/packed full-wire token observations bound to one execution identity |
| `zig build provider-context-adapter-demo -Dmetal=false` | Allocation-free renderer/token-counter adapter fixture |

The ActionOutbox recovery gate deliberately separates two evidence classes.
The Zig/Python matrices deterministically enumerate logical persistence
outcomes without opening a real file. The native host campaign separately
spawns and kills 49 workers—3 during initialization, 40 during append, and 6
during repair—then requires fresh replay and convergence. Neither class is a
latency benchmark or a storage-device power-cut test.

The W4b-d dispatch gate is a third, narrower evidence class. Its same-process
fake authority holds an opaque synthetic credential and performs no network,
provider, or tool effect. Pointer-free portable values exclude credential
material. Only the driver entry points establish durable ordering: low-level
contract callbacks validate composition but cannot prove that an intent was
synced first. Dispatch protects one future slot per existing uncertain action
and requires three additional records; status runs only when free slots cover
all uncertain actions. Only an atomic `not_applied_fenced` result permits a
next-generation retry. The gate runs 20 Python tests that independently rebuild
the model, then separately invokes the Python CLI to compare a live canonical
Zig report; no JSON fixture is retained. Integrated Zig coverage injects
deterministic same-process faults at four terminal-transition and four
fenced-transition append phases, then freshly reopens, repairs when required,
and reconciles.

This gate uses no real credential and proves no OS sandbox or credential
security, cryptographic origin, fake-service restart persistence, new
process-death behavior, native platform behavior, performance, power behavior,
or external exactly-once delivery. The W4b-c 49-death campaign remains the
separate process-death evidence.

The W5a observation gate is contract and observer conformance, not a benchmark.
Its deterministic reference elapsed value verifies the host time metric's
value-clock composition and report identity. The macOS capture separately
proves that the bounded read-only adapter can classify directly observed,
malformed, denied, and unsupported host fields. The portable contract declares
accelerator metrics and fallback rules, while the W5a host adapter does not
directly measure device utilization, residency, timing, power, temperature, or
energy. Cross-compiling the contract does not establish native observation on
the foreign target. Stable source identity is the field used for source
matching; per-sample provenance may legitimately change. Portable unavailable
records retain a nonzero reason identity, while the macOS JSON adds a bounded
readable reason and present records add neither. Logical CPU count must be
positive;
physical temperatures may be negative but not below absolute zero. See
[Native Observation Contract](NATIVE_OBSERVATION.md).

The first post-W5a Linux source is also conformance work, not benchmark
evidence. Cross-host tests prove its strict bounded `MemAvailable` parser,
adapter dispatch, source/provenance separation, and unavailable-state mapping.
Only a required smoke executed on Linux can establish that the native
`/proc/meminfo` source was observed; a skipped smoke or foreign-target compile
cannot.

The W6a workload-report gate is also portable conformance, not a benchmark.
Its allocation-free codec retains one exact scenario, every warmup and measured
request, a measured-only summary, and terminal zero-orphan closure in a
versioned binary wire. The deterministic reference contains two warmup and four
measured records, including completed, capacity-rejected, and timed-out
outcomes. Zig and independently encoded Python fixture coverage flip one bit at
every serialized byte and separately test truncation, extension, record
reorder/duplication, and rehashed semantic forgeries. The standard-library
Python verifier parses the raw runner output independently and recomputes the
record chain, roots, summary, metric availability, and closure rather than
accepting a producer projection.

The focused host compile gate and the separate Linux x86_64/AArch64 GNU,
Windows x86_64 GNU, and FreeBSD x86_64 cross-compile gate establish source
portability for the codec and deterministic runner only. They execute no
production-native workload, produce no retained machine artifact, and do not
establish CPU or GPU performance, physical concurrency, queue depth,
utilization, residency, power, thermal, frequency, energy, or native behavior
on a foreign target.

W6b is a separate hard native macOS Metal conformance gate. Its fixed
closed-loop campaign reuses one persistent eight-buffer lease for 20 real
production-adapter dispatches: 4 warmup and 16 measured requests, balanced
across two logical slots. Both requests in each pair submit before either is
waited, every result is compared with a precomputed CPU oracle, and each pair
settles fully before the slots are reused. The producer keeps one global host
monotonic sequence, retains the Metal command-buffer start/end clock
separately, rejects lifecycle or identity drift, and fails closed without
publishing a partial report after an ambiguous native submission.

The portable verifier first recomputes the wire and summary. A second native
profile verifier then checks the exact geometry, flow balance, generation
roots, same-command device durations, sampled `currentAllocatedSize` context,
and zero Bank/pin/dispatch/command/buffer closure. An explicitly requested
artifact is written only after both verification layers pass. This proves the
composition and correctness of that exact captured campaign. It does not
authenticate the producer, establish performance, reveal hardware queue
occupancy, prove physical GPU parallelism, or turn `currentAllocatedSize` into
residency. Utilization, physical queue depth, residency, power, energy,
temperature, frequency, and physical parallelism remain unsupported. See
[Native Workload Report](NATIVE_WORKLOAD_REPORT.md).

The first retained production-native capture is the
[17,996-byte raw wire](../bench/results/native-metal-workload-report-macos-arm64-2026-07-28.bin)
plus its
[machine and claim manifest](../bench/results/native-metal-workload-report-macos-arm64-2026-07-28.manifest.json).
It was captured from clean source commit `36011d4` on an Apple M1 macOS host
connected to AC power. Its wire SHA-256 is
`933d0eb3ffdffacfe0e49a95467d5d781133caadd9c9814d3b90fc19f042fa2b`
and its report root is
`df7c8e20c5e682410d9bd92ff207bc180b5ef9a6b94767a4a24e9fdc60d719ec`.
It is one diagnostic machine result, not a performance or replication claim.

The separate native Metal gate is readiness conformance, not a microbenchmark.
It performs exactly one real GPU dispatch across the full gate for one fixed
synthetic 37x64 INT4 matrix-vector operation. The CPU oracle, completed command
buffer, GPU start/end timestamps, Metal registry identity,
`currentAllocatedSize`, ownership closure, no-fallback receipt, and composed
roots must all agree. The derived device duration remains internal diagnostic
evidence and must not be reported as latency or used to calculate throughput.
`recommendedMaxWorkingSetSize` is capacity context only. Accelerator
utilization, committed/resident bytes, queue depth, temperature, frequency,
power, and energy remain explicitly `unsupported`.

The device-lifecycle gate is another conformance layer, not a fault or
recovery campaign. A real `MTLCopyAllDevicesWithObserver` is installed for the
selected context. On the built-in M1 development host, the selected registry
ID was present initially and the snapshot stayed unchanged while one real GPU
command succeeded. A native two-thread race against exact initial-snapshot
consumption requires one consumed and one stale result while the snapshot
remains readable. The native path therefore exercises retained device identity,
at-most-once snapshot claim, and admission on the normal no-event path.
Source-specific removal-requested, removed, and exact native
command-buffer-removed paths use a sticky monotone source set and a native
admission lease shared by work and live `deviceInfo`/`allocationLimits`
property reads; the latter is fenced from status/domain/code `5/1/11` before
any test overlay. The source-instance digest binds a 256-bit per-context nonce,
observer-generation reset discriminator, registry ID, and stable
device/placement identities rather than relying on the 64-bit generation
alone. Operations admitted before a loss may settle, while new admission after
loss rejects. No such loss event occurred in that run. Portable
transition/error tests and the isolated published-error overlay are synthetic
or model evidence, not physical-removal evidence. The fixed-width cursor,
observation, and transition hashes prove composition and integrity rather than
authenticity or attestation.

The independent verifier checks bounded output plus composition and corruption
of a self-asserted live capture. It provides no cryptographic authenticity or
historical attestation. A passing invocation is native evidence for that exact
host session, but no addressable readiness result is currently retained in the
repository. The separate retained W6b workload campaign does not substitute for
a W5 readiness-observer artifact. Implementation evidence and retained
readiness evidence must therefore remain separate, and W5b remains open.

The W6b hard gate also supplies a fresh 256-bit challenge through a dedicated,
sanitized environment variable and accepts no runner arguments. The runner
binds the challenge and a domain-separated build identity over the producer
ABI, its exact executable SHA-256, and the external `shaders.metallib` SHA-256
into the scenario. The verifier hashes both files before and after execution
and rejects a changed host program, changed GPU program, stale replay, or
identity mismatch. This strengthens live-run binding but is not cryptographic
code attestation, so a retained artifact still requires a separate source
commit and capture manifest.

The native Metal allocation gate is separate real-resource conformance. Its
ChildLease and LeaseTree cases create and inspect direct Shared `MTLBuffer`
objects on the selected device. The LeaseTree ownership case reserves the
complete logical wave before allocation, frees under a private `FreePermit`,
and includes a cancellation path that stops after two real buffers and returns
the charge only after both are freed. A separate pinned case submits one exact
four-buffer command into an adapter-owned async slot, validates exact replay,
observes pending without output mutation when available, polls or waits for
completion, checks the CPU oracle, settles Bank ownership before native
finalization, and proves that release cannot pass the live pin.

Before Bank mutation, core sends a sealed `DispatchPinIntentV1` to the adapter
reserve callback; an atomic acquisition failure invokes the exact abort path,
and callback/source boundaries are revalidated. The Metal pin uses the
adapter-issued generation-fenced dispatch-request root rather than the raw
attempt root. On the same real context and live resources, malformed preflight
cases may inspect device/resource identity but submit zero commands, while the
pure cancellation case performs no native inspection. Both set
`submission_sha256`, `backend_completion_sha256`, and `output_sha256` to zero
and use the same private settlement callback as submission. Core
consumes the private Bank pin before that callback clears adapter state and
records the replay tombstone; public acknowledgement only verifies it.

These native checks establish ownership and per-adapter bounded two-slot async
completion delivery for that successful host run. The build-isolated pressure
case uses one eight-object lease with two disjoint four-buffer role sets,
observes two live native records, completes both commands, deliberately settles
B before A, rejects a third distinct request before native mutation, checks
both outputs against CPU oracles, and returns commands, pins, and buffers to
zero. This establishes bounded ownership isolation, not physical GPU
parallelism, command-completion order, or performance. Separate portable
Zig/Python checks authorize one exact quarantined command-buffer `.error` as
core `terminal_failure`, reject substitutions, and retain ownership before
settlement; they are deterministic contract models and execute no GPU work.

The build-isolated native fault gate adds a real successful Metal execution
without relabeling the physical outcome. It records the physical `.completed`
snapshot separately, then applies a test-only `.error` overlay to the published
snapshot. The real adapter path quarantines and reconciles that published fact.
The same gate uses a real two-thread arm race and actual coordinator settlement
retry to prove one winner, Bank-first release, exact native finalization/state
clearing, and no double release or finalization after the first confirmation is
deliberately rejected. Production artifacts expose no fault controls.

A separate Phase B matrix uses real Metal commands and four real buffers for
all four retained states. A test-only hold stops the pending completion handler
before the ARC-owned callback gate. Context-local one-shot seams separately
retain a post-commit ambiguous disposition authenticated by the native record;
after independently verified physical success, publish a valid unknown
projection by changing only `callback_fault`; and reject one exact completed
output read before caller memory is written. The adapter therefore derives the
matching submission-ambiguous, completion-unknown, and invalid-completion
retention from its live state rather than accepting hand-built evidence.
Synthetic injected loss then exercises
detachment and settlement for every state. Coordinator settlement consumes
each Bank pin before exact native unlink and tombstone storage; caller output
stays unchanged, held handlers are released safely afterward, and allocation
ownership is retired separately.

The overlay, state seams, and injected loss do not induce or prove a physical
command-buffer, driver, hardware, or device-loss fault. None of these
conformance layers measures throughput or latency or establishes residency,
dynamic queue scheduling beyond the fixed two slots, physical device-loss
recovery, automatic migration, reset, or physical reclaim behavior. The bounded
allocation-retirement branch proves only quiesced reference and
logical-ownership cleanup; the Phase B matrix proves only dispatch
callback/record ownership retirement for the four retained states.

All commands should normally use `-Doptimize=ReleaseSafe` when validating
contracts. None requires a real credential. Portable evidence is
credential-free; W4b-d injects a synthetic value only into the opaque context
of its same-process fake authority. Most commands are model-free; the vision
adapter test runs only a deterministic exact-integer reference fixture.

The typed model-family proof records canonical artifact/plan/result roots,
explicit support decisions, exact integer fixture output, provisional candidate
behavior, publication state, and zero logical ownership after close. It is
adapter-contract evidence, not vision quality, production-model compatibility,
accelerator performance, or physical memory evidence.

The audio and temporal-video adapters add exact signed-window projection,
strided frame gathering, and cross-language source-mapping roots. The segment
fixture adds a fixed source/time-bound event result and predecessor lineage;
the timeline fixture adds deterministic overlap decisions and accumulated-tail
state. The cross-modal fixture maps only newly visible transcript samples onto
that tail, rejects fractional and non-overlapping ranges, and retains both
histories in one link. These fixtures do not measure transcription or video
quality, semantic alignment, streaming model restart, latency, throughput, or
physical memory. The transcript fixture's fixed ASCII text is not
recognition-quality evidence.

The stateful transcript continuation fixture adds a deterministic
`audio_understanding / transcribe` model transition, a fixed composed
checkpoint, and a real source/target process handoff. The first process
publishes samples `2..10`; the target reuses context `8..10`, publishes only
`10..18`, and advances the cross-modal link once. These fixed strings and tiny
integer features prove restart mechanics, not recognition quality, word
alignment, production-model compatibility, latency, throughput, or physical
memory.

The stateful VFR video continuation fixture adds explicit per-frame ordinal,
PTS, duration, keyframe, feature-payload, and declared-gap evidence. A source
process publishes frames `0,1` over ticks `[0,20)`; a fresh target restores the
model and publishes frames `2,3` over `[25,50)` after the exact five-tick gap,
then advances timeline and cross-modal link state. The retained durations
`8,12,10,15` prove contract-level VFR handling. They do not measure decode
correctness for external containers, event quality, production-model
compatibility, latency, throughput, energy, or physical memory.

The latent-step fixture adds state/result atomicity and a cross-language
transition root. The live-restart fixture then chains two exact steps across
distinct processes through a cross-language 512-byte checkpoint and fresh
retained-state ownership. It does not measure generation quality, production
scheduler fidelity, accelerator performance, crash-atomic checkpoint
publication, or production compatibility.

The generated-image fixture consumes that exact terminal lineage through a
bounded decoder. It emits four raw gray8 pixels plus fixed provenance and result
wires, preserves sentinel visibility through one abort, then publishes once in
the fresh target process. This is conformance evidence for binding,
cancellation, atomic visibility, and release—not image quality, production
decoder compatibility, external format support, latency, throughput, memory,
energy, or durable multi-file publication.

The generated-audio fixture converts four bounded reference audio tokens into
two raw mono PCM s16le chunks across distinct processes. It preserves sentinel
visibility through one abort, rejects a partial observation, gates the
successor until the first exact buffer is acknowledged, and rejects duplicate
acknowledgement. This proves wire, ordering, backpressure, cancellation,
restart, and ownership semantics. It does not measure speech/music quality,
production renderer or codec compatibility, latency, throughput, memory,
energy, device behavior, audibility, or durable multi-file publication. Its
playback observation is application evidence, not proof of physical sound.

The generated-video fixture expands four bounded reference tokens into two
ordered two-frame raw gray8 segments across distinct processes. It binds each
frame root and duration, preserves sentinel visibility through one abort,
rejects a one-frame observation, gates the successor until complete application
display acknowledgement, and rejects duplicate acknowledgement. This proves
wire, ordering, timeline, backpressure, cancellation, restart, and ownership
semantics. It does not measure generative-video quality, temporal coherence,
production renderer/codec compatibility, latency, throughput, memory, energy,
compositor or device behavior, physical display, or crash-atomic multi-file
publication.

The generated-media checkpoint fixture composes one typed image result, one
fully acknowledged PCM result, and one fully acknowledged raw-video result into
one checkpoint generation. A fixed selector is promoted across write, file-sync,
rename, and directory-sync process-death boundaries; fresh recovery accepts
only the complete previous or successor set. This proves canonical composition,
selector ordering, and process-death recovery. It does not prove encoded payload
durability, production model compatibility, power-loss behavior, physical
playback/display, or quality and performance.

The generated-media payload-archive fixture adds one fixed manifest and three
exact encoded payload objects to the checkpoint and its three members. It keeps
raw source-output roots and byte counts distinct from encoded payload roots and
lengths, and binds separate encoder-implementation and format roots for image,
audio, and video. One generic outer selector publishes the canonical
eight-object generation. The independent Python oracle checks all manifest and
archive bytes plus split-binding and predecessor substitutions. Seven native
publisher deaths expose generation one five times and generation two twice;
recovery then converges idempotently to generation two with exact payload
slices and no mixed generation. The fixture uses bounded identity envelopes
rather than production containers, executes no model or encoder, and does not
establish native Linux behavior, storage-device power-loss durability, initial
archive power-loss durability, codec compatibility, quality, latency,
throughput, memory, energy, or physical playback/display.

The generated-media output-registry fixture extends that fixed shape through an
independent ABI; the older V1 wires remain unchanged. One fixed 544-byte
manifest, an ordered table of fixed 544-byte entries, and one exact
concatenated payload pack form exactly three archive extension objects.
Generation one contains `2/3/2` image/audio/video entries; generation two
contains `2/2/3`. Image entries carry the no-completion-required shape, while
audio/video entries structurally require a nonzero opaque completion root.
Validation reconstructs ordinal, unit, timeline, and predecessor continuity;
checks the modality-specific structural completion fields; binds the opaque
state/completion, raw-output, encoded-payload, encoder, and format roots; and
requires the exact previous archive bytes. It does not decode the earlier typed
producer acknowledgement/state wires. The independent Python oracle checks the
same registry contract. Seven native publisher deaths expose only a complete
previous archive five times or successor archive twice before recovery
converges idempotently. This is model-free conformance evidence, not production
encoder/container compatibility, native Linux execution, storage-device
power-loss durability, physical playback/display, media quality, latency,
throughput, memory, or energy evidence.

The generated-media producer-admission fixture exercises the pre-publication
gateway in front of that registry. It decodes a 2,080-byte fixed image record
set, a 2,624-byte fixed audio record set, or a 3,072-byte fixed video record
set, verifies the exact caller-supplied raw media bytes, reconstructs the common
request/scope/policy/challenge envelope, and derives registry generation,
publication sequence, ordinal, state, result, completion, and previous-entry
lineage. The independent Python model reconstructs the same mapping before
calling its registry oracle. The gateway has no selector or filesystem
authority; it feeds the already restart-verified unchanged three-object
registry. This proves structural typed admission and exact raw-to-registry
mapping. It does not prove model or renderer execution, encoder/codec
correctness, authorization, physical playback/display, native Linux or
power-loss behavior, media quality, latency, throughput, memory, or energy.

The generated-media producer-transition fixture is a higher-assurance
conformance path layered beside that structural admission. For every retained
image, audio, or video output it replays the exact deterministic source-model
and materializer callbacks over canonical byte witnesses, reconstructs
publication and any required acknowledgement transition, and emits a fixed
1,728-byte receipt. A separate `640 + output_count × 1,728`-byte sidecar binds
the ordered receipt table to the exact unchanged registry manifest/archive and
to the preceding evidence/registry pair. Image replay uses a fresh one-shot
local transaction; its collection ordinal is derived separately from validated
registry lineage. Audio/video replay includes observation,
acknowledgement-plan, acknowledgement-result, and final quiescent state.

These deterministic byte counts and replay results are conformance evidence,
not a throughput benchmark. They do not establish that either callback ran
historically, that a live resource authority approved the work, that a physical
speaker/display consumed output, that an external codec/container is correct,
or that any latency, throughput, memory, energy, quality, durability, or
production target was met. Benchmark reports must keep transition correctness
separate from measurements and name the artifact, adapter, machine, power
state, workload, and retained raw results for every performance claim.

The speech-annotation fixture maps `ice` and `berg` onto exact adjacent sample
ranges and two opaque speaker identities. Its fresh target validates the
persisted annotation predecessor before resource admission, aborts one
candidate without visibility, then publishes word and turn two. This proves
wire, ordering, restart, cancellation, and ownership semantics—not ASR,
alignment, diarization, confidence calibration, language, latency, throughput,
memory, energy, or production compatibility.

## Shared media contract

The media conformance fixture accepts one synthetic image, audio, and video
descriptor through the same 272-byte wire. Zig and an independent Python model
share the audio-object and first-publication golden roots. Both verify
kind-specific fields, canonical rational bases, and exact publication lineage;
the descriptor test flips all 272 serialized bytes and rejects every mutation.

The demo maps a one-second 48 kHz audio span exactly into a 16 kHz timeline,
rejects one-sample conversion into a 44.1 kHz base, commits two ordered chunks,
and rejects replay of the first prepared commit without state mutation. It
loads no model or media library and requests no file, network, device, camera,
or microphone authority.

This is contract conformance, not an execution benchmark. It supports no claim
about codec coverage, model quality, provider units, throughput, latency,
memory, storage, or energy.

The bounded decode fixture adds three canonical inputs totaling 1,108 encoded
bytes and 52 decoded payload bytes. It maps four RGB pixels, eight stereo PCM
frames, and two video frames—14 units total—without heap allocation, scratch
storage, ambient capabilities, external codecs, or model execution. The
independent Python oracle shares all fixture, plan, and decode-receipt roots and
mutation-checks every byte of all six wires.

These deliberately tiny counts describe test coverage, not performance or
format support. See [Bounded Media Decode Fixtures](MEDIA_DECODE_FIXTURES.md)
for the exact claim boundary.

The transform conformance fixture adds three operations over those decoded
bytes: crop/nearest/tile mapping for the image, weighted stereo-to-mono mix with
an exact factor-three decimation for audio, and keyframe selection for video.
It emits 20 output bytes and seven exact mappings with zero heap allocation,
zero scratch, and zero ambient capabilities. Zig and the independent Python
oracle share all three 512-byte plan roots and all three receipt roots.

These are correctness fixtures, not latency, throughput, signal-quality,
format-coverage, or model-execution results. See
[Deterministic Media Transforms](MEDIA_TRANSFORMS.md).

The runtime-transaction fixture composes those operations with exact logical
admission and publication. Across the three requests it admits 3,752 host bytes,
publishes 20 output bytes with seven exact mappings, exercises one explicit
abort/scrub/retry path, commits three media transitions, emits three fixed
640-byte receipts, releases all three claims, and ends with zero Bank usage.
The independent Python verifier reconstructs each transform, mapping chain,
resource receipt, timeline event, publication commit, and runtime receipt.

The hierarchical runtime demo admits the same 3,752 host bytes but separates
control-plane admission from six live allocation leaves per scratch-free
request. Across the three modalities it retires six provisional allocations
early, retains exactly one output allocation per committed request, performs 12
reclamation commits including the explicit audio abort/retry path, and returns
all Bank usage and live allocations to zero. Its fixed 1,536-byte receipt binds
the parent, tree state, and ordered scope/allocation evidence. A separate Python
oracle reconstructs the same no-abort golden roots and rejects every serialized
byte mutation.

The bounded stream demo commits six chunks—two per modality—while retaining two
output allocations at each stream's peak. It retires 12 provisional allocations
after successful publication, reclaims one cancelled audio chunk, rejects one
target gap and one target overlap before admission, performs 21 total
reclamation commits, and closes with zero Bank usage, live allocations, and
active trees. The fixed 352-byte chunk record chains each publication to its
predecessor; the independent oracle shares a two-chunk golden chain and
mutation-complete wire coverage.

The media continuation demo checkpoints after chunk zero for all three
modalities, releases each source Bank, restores one output allocation in a
fresh Bank, and appends chunk one. The two-process companion repeats the same
three paths under distinct source and target PIDs after file and directory
sync. Both finish with zero Bank usage, live allocations, and active trees. The
independent oracle shares the fixed 2,048-byte image checkpoint root and rejects
every serialized byte mutation. These first two commands are
restart-conformance counts and do not claim that their separate files form one
crash-atomic set.

The checkpoint-set demo closes that visibility gap. It packs three fixed
checkpoints, six retained outputs, one processor-state bundle, and one
cache-payload bundle into six archive objects, then publishes generation two
over generation one. Seven
publisher deaths expose generation one five times and generation two twice;
fresh targets resume all three streams both before repair and after idempotent
recovery. The observed campaign performs 42 resumed modality-chunks with zero
duplicates and zero final Bank usage. A fresh worker then restores generation
two, rebinds six output leases, charges and verifies `1,104` cache bytes,
advances processor state, appends three chunks, publishes a six-object
nine-output generation three with `1,288` cache bytes, and releases all
ownership. Another fresh worker opens that new root, restores its caches, and
resumes three more chunks, bringing the demo total to 45. It exercises real
process death and sync calls, not storage-device power loss.

The processor-state demo advances two generations of a fixed 2,272-byte
image/audio/video state bundle. Generation two records two processed image
tiles, two audio feature windows with a 400-sample window and 160-sample hop,
and two temporal video-cache entries. Exact integer mapping produces audio tick
560, video tick 800, and synchronized watermark 560 under a 400-tick skew
ceiling. Rehashed processor substitution, ownership replay, and skipped audio
windows reject. These are logical state and cache-byte conformance values, not
processor throughput or physical memory measurements.

These values are deterministic conformance counts. They do not measure process
memory, physical device residency, throughput, latency, model quality, codec
coverage, or provider usage. See
[Media Runtime Transaction](MEDIA_RUNTIME_TXN.md) and
[Hierarchical Media Buffer Ownership](MEDIA_RUNTIME_LEASE.md), followed by
[Multimodal Processor and Cache State](MEDIA_PROCESSOR_STATE.md),
[Bounded Media Stream Runtime](MEDIA_STREAM_RUNTIME.md) and
[Media Stream Continuation](MEDIA_STREAM_CONTINUATION.md), followed by
[Atomic Media Stream Checkpoint Sets](MEDIA_STREAM_CHECKPOINT_SET.md), then the
[Generated-Media Encoded Payload Archive](GENERATED_MEDIA_PAYLOAD_ARCHIVE.md)
and
[Host-Verified Generated-Media Producer Transitions](GENERATED_MEDIA_PRODUCER_TRANSITION.md).

## Continuation checkpoint

The current fixture encodes a 608-byte manifest over nine external object types.
The demo's object payloads total 264 bytes but zero payload bytes are embedded in
the manifest; production model and KV objects can be much larger. Zig encoding
and verification are allocation-free. The independent Python suite shares the
golden root, flips every one of the 608 serialized byte positions, reseals the
outer digest where applicable, and requires rejection. A separately valid
foreign KV object also rejects.

This proves deterministic identity composition for the fixture. Later fixtures
exercise durable payload storage and a model-free live process restart, but the
capsule alone does not grant either property. No reduced RSS, storage savings,
or recovery after power loss follows from this identity proof.

The resolver fixture then admits all nine objects under a 16-entry catalog-scan
limit, 64-byte per-object limit, exact 264-byte total limit, and nine-resolution
limit. It rejects stale, denied, repeated, cross-tenant, corrupt, ambiguous,
oversized, over-budget, overlapping, substituted, and post-resolution-mutated
inputs in native tests; an independent Python model checks the portable
identity and state semantics. This is conformance evidence for bounded lookup,
not a storage, RSS, latency, deduplication, or restart-performance result.

The bundle fixture describes 280 logical payload bytes as eight unique blobs
totalling 255 bytes, so its canonical duplicate-payload delta is 25 bytes. The
bundle wire itself is 1,136 bytes, the capsule remains an external 608 bytes,
and the demo performs no storage writes. This proves the fixture's deterministic
tenant-scoped plan and totals—not net disk savings, cache savings, lower RSS, or
restore performance. Physical claims require a real store and complete overhead
measurement.

The in-memory store fixture imports nine semantic references into eight payload
allocations: 280 naive per-reference payload bytes become 255 allocated payload
bytes. It also uses a 1,024-byte logical index charge, a 3,200-byte fixed slot
array and 3,480-byte store value on the current 64-bit build, inside a
4,096-byte caller-provided payload backing buffer. Lifecycle metadata increased
the fixed slot array from the earlier 2,304 bytes; receipt-root compaction avoids
1,152 bytes versus the initial expanded layout. This proves one 25-byte
duplicate payload allocation is avoided, atomic rollback works, and counters
are exact. It does not establish net memory savings; the fixture's lifecycle,
index, and backing overhead is larger than its duplicate payload.

The same demo acquires and renews a model-object lease from generation 1 to 2,
releases it with the exact current receipt, then acquires a KV-object lease that
quarantine invalidates. A target/reason/source-scoped repair grant admits the
verified KV payload and produces a shared Zig/Python repair receipt and v2
snapshot. These are deterministic conformance results—not wall-clock lease
safety, replica attestation, crash durability, or repair-latency measurements.

The collection fixture presents all eight remaining semantic roots and the one
current lease receipt against an exact audit snapshot. Across eight occupied
entries it classifies five entries/five references as reachable, one entry/two
references as leased, one entry/one reference as quarantined, and one retired
30-byte entry as collectible. The store retains all 255 payload bytes and frees
zero. Zig and the independent Python model share the grant, input, snapshot,
and plan roots. This proves bounded dry-run classification for the fixture—not
safe deletion, lower RSS, durable sweep recovery, or global reachability across
stores.

The sweep fixture separately authorizes that plan, regenerates it from the same
eight roots and one lease receipt, stages one entry/30 bytes, and aborts while
the store remains at the exact audit snapshot. Its caller-owned journal is 184
bytes on the current 64-bit build, performs zero sweep heap allocations, and
does not enlarge the 3,480-byte store value. All 255 payload bytes remain
allocated and zero bytes are freed. Zig and Python share the sweep grant,
prepare, and abort roots. This is functional in-memory staging evidence—not a
destructive commit, durable journal, exactly-once transition, secure erase, or
memory reduction.

The sweep-commit fixture uses a separate prepared plan whose one collectible
object is the final 39-byte payload allocation. A second capability binds the
exact sweep grant, prepare root, snapshot, plan, and removal ceilings. Native
commit changes the store from 8 to 7 occupied entries, 1 to 0 retired entries,
255 to 216 payload-ledger bytes, and 1,024 to 896 logical-index bytes. It invokes
the allocator deallocation once. Because the target is deliberately the
fixed-buffer allocator tail, observed allocator consumption also changes from
255 to 216 bytes. The 3,480-byte fixed store value and 184-byte caller-owned
journal remain unchanged.

Zig and Python share the commit grant, target-set, store-commit, outer-commit,
and post-state roots. This proves exact atomic single-owner in-memory removal
for the fixture. The 39-byte allocator delta is a tail-layout observation—not a
general allocator, fragmentation, RSS, secure-erasure, durability, or garbage-
collection throughput result.

The sweep-record fixture encodes that transition evidence as a fixed 736-byte
body and 48-byte commit footer. Zig and Python share the record root
`a9adfd09…bba06` and complete-wire SHA-256 `3b3fb1ad…d7c6d3`. Both reject every
one-byte mutation across 784 positions, every truncation, an extension, a
correctly rehashed accounting contradiction, and a valid foreign record under a
pinned expectation. This proves the codec and semantic verifier for the named
fixture. It is not a filesystem throughput, sync latency, crash recovery, or
durability result; the append plan performs no I/O.

The anchored classifier then scans a two-record 1,568-byte stream with shared
Zig/Python SHA-256 `25009ee1…ee5538`. Both implementations classify all 785
possible second-record append lengths, reject a mutation at every second-record
byte, reject rehashed semantic contradictions and valid foreign chains, and
verify an authenticated suffix anchor. Native classification allocates no heap
memory and returns only committed-prefix metadata; this is not evidence of file
repair, sync behavior, restart correctness, or storage performance.

The writer fixture binds the first record to exclusive storage epoch 41 and
lease generation 1. Zig and Python share snapshot SHA-256
`b02d101a…ee3897`, then append the second record through body-write, body-sync,
footer-write, and footer-sync. The fault campaigns cover all eight before/after
I/O outcomes, all 737 body prefixes, all 49 footer prefixes, every incomplete
tail from 1 through 783 bytes, and both crash lengths around an uncertain
truncate. Append and repair capabilities expose disjoint operations, and every
uncertain error poisons the local state until fresh lease/snapshot reopen. This
is allocation-free deterministic storage-model evidence—not proof of real lock,
filesystem sync, directory durability, process restart, or storage performance.

The file-adapter demo adds retained host-filesystem evidence for four append
process deaths and two repair process deaths. It verifies exclusive advisory
locking, no-follow final lookup, one-link/private-mode admission, file and
directory sync, identity checks, replacement detection, and fresh-descriptor
reopen. The independent Python adapter repeats those child deaths and
cross-process lock contention. These are correctness fixtures, not throughput
benchmarks. They do not emulate device power loss, establish native Linux
behavior, or justify filesystem latency, energy, RSS, or durability claims
beyond the recorded host run.

The sweep-commit demo separately encodes its actual native store receipts into
the same 784-byte format and verifies record root `6f60f970…c7fa52`. Version 2
first predicts that exact receipt without mutation, publishes and syncs it
through the POSIX adapter, injects a failure before deallocation, then recovers
against the old snapshot, proves a second recovery is already applied, and
rejects a valid third store state. This specific commit fixture keeps payloads
and lifecycle metadata in memory, so it proves ordering and reconciliation, not
process-death mutation or power-loss behavior.

The payload-file demo then exercises the downstream durable byte plane. Its
three-entry canonical snapshot contains 55 logical payload bytes; one exact
13-byte target is removed into a two-entry, 42-byte successor. A fixed 968-byte
record binds the published sweep root, exact target list, old/new snapshot roots
and lengths, accounting, preview root, and challenge. Native workers terminate
after seven plan and promotion boundaries. Fresh recovery observes the old
snapshot in five cases and the already-promoted new snapshot in two, then a
second recovery is always `already_applied`. Zig and independent Python
implementations share sweep-record SHA-256
`871e9f22…a2a7cc977` and reclaim-record SHA-256
`f1105b70…35f926de34`; Python also rejects mutation of every reclaim-record
byte and a valid unrelated third snapshot.

The ownership fixture then consumes a capsule-bound 3,360-byte resource-state
plan. It requires a fresh target Bank epoch, charges two allocation nodes before
private materialization, keeps both nodes pending after a wrong-byte attempt,
commits exact bytes to `live`, acquires the restored publication sequence, and
rejects same-Bank replay plus the old source receipt. Zig and Python share
ownership root `59c777c9…fe68f394f` and reject mutation of every serialized
position plus a re-rooted semantic contradiction.

The paged-KV fixture adds two layers, dimension two, and 17 committed positions
across two real page allocations. It reconstructs the complete source
ownership chain from durable page images, restores the same logical KV
SHA-256 into a fresh cache instance, emits new target page generations, and
rejects source refs in the target. A changed source generation leaves a probe
cache fresh and publication remains blocked while ownership is pending. The
shared 752-byte codec fixture has root `e052306f…3437d1e4` and mutation-complete
Zig/Python coverage.

The live-restart fixture then joins the exact sequence, KV length/digest, RNG,
sampler count, output prefix, previous commit, and challenge in one fixed
304-byte runtime wire. A source process publishes token `503`, synchronizes six
checkpoint objects plus its process identity, releases its LeaseTree and Bank,
then exits. A different target process verifies and restores the checkpoint,
forces a target cache instance distinct from the source, publishes token `504`
at sequence `18`, observes output `[501, 502, 503, 504]`, chains the source
commit, and tears down to zero Bank usage. The runtime wire, output root, and
receipt root have independent Python fixtures with complete wire mutation and
stale-position rejection.

The checkpoint-file fixture packages seven real restart objects into one
6,421-byte archive in the observed run, then selects it with a fixed 192-byte
record. Workers die after archive write, archive sync, archive directory sync,
selector write, selector sync, selector rename, and selector directory sync.
Fresh recovery observes the previous root in five cases and the successor root
in two, reaches the successor idempotently, and launches a separate live-resume
process after every phase. The independent Python codec shares fixed two-object
archive/selector roots and rejects every serialized-byte mutation, re-rooted
semantic contradictions, and foreign recovery roots.

Together these fixtures prove canonical payload-byte encoding, exact target
reconstruction, copy-on-write ordering, fresh-process old/new reconciliation,
safe logical ownership reacquisition, model-free paged-KV reconstruction, and
one natural-exit process restart with exact-once next-token publication, and an
atomic whole-checkpoint root switch across seven process-death phases on the
retained host. They do not restore object-store lifecycle metadata, compare an
uninterrupted and resumed production model, restore accelerator allocations,
emulate device power loss, establish native Linux filesystem behavior, or
measure disk use, latency, RSS, or energy.

## Provider evidence checkpoint

The current provider fixture joins three independently replayed planes:

- one 1,645-byte committed cost-journal frame;
- one 5,984-byte gateway event stream;
- one 2,758-byte transport event stream;
- one fixed 712-byte `ProviderEvidenceJoinWire` manifest.

The manifest binds 20 digest fields representing the envelope and 19 semantic
roots. It does not copy the nested evidence. The Zig verifier replays each nested
format and the independent Python verifier checks the shared golden fixture. The
mutation suite rejects a single-byte change at every one of the 712 manifest byte
positions and rejects substitution of a valid but foreign transport stream.

This proves composition for the retained fixture. It does not prove the truth of
a provider's upstream usage report or grant filesystem/network authority.

The durable journal harness exercises process termination across append phases,
including 12 child-process kill cases. It checks body sync, footer sync, torn-tail
repair, poison/reopen behavior, advisory locking, path rejection, and replay.
Filesystem guarantees still need validation on each promoted platform.

## Context-efficiency checkpoint

The deterministic context fixture maps 440 logical tokens to 250 emitted tokens
and changes a conservative reservation from 490 to 300. The adapter fixture uses
one wiped 64-byte execution buffer where its comparison oracle uses two buffers
totalling 128 bytes.

These numbers are deliberately narrow:

- only exact rendered duplicates declared idempotent may share an emitted span;
- core stores hashes, mappings, and counts rather than prompt text;
- an external observer counts the exact rendered provider wire;
- the 64-byte result is a scratch-fixture property, not a general memory claim;
- logical and reserved-token reductions are not guaranteed billed-token savings.

## Measurement contract

### Identity

Retain:

- source commit and dirty-tree state;
- compiler, optimization mode, target, and feature flags;
- model/tokenizer hashes and runtime format identity;
- prompt or token fixture hash, seed, token count, and execution policy;
- benchmark harness version and schema.

### Machine envelope

Capture at minimum:

- hardware model, architecture, logical CPU count, and memory capacity;
- operating-system and kernel versions;
- power-source state when available;
- process priority, affinity policy, and requested worker count;
- load and memory state before each pair;
- warmup, cooldown, and execution timestamps;
- explicit present, missing, denied, or unsupported status for thermal,
  frequency, core-residency, energy, and device data;
- stable source identity, per-sample provenance, subject, unit, and
  sample-clock identity for every physical metric;
- a portable nonzero reason identity for unavailable records, plus bounded
  diagnostic text only when an adapter exposes it;
- value-clock identity only for a present time-valued metric, without treating
  that field as cross-clock calibration; and
- separate host and accelerator fallback, timing, and residency evidence.

The current envelope does not directly measure CPU temperature, effective
frequency, performance/efficiency-core residency, or package energy on every
host. “Plugged in” is useful context, not proof of equal machine state.

### Paired execution

Use randomized or balanced order within the same process and machine session:

```text
A B B A   or   B A A B
```

Each observation must name its pair and order. Reject a pair when cooldown, load,
correctness, configuration, or requested machine-state gates fail. Do not delete
valid slow samples because they are inconvenient.

### Metrics

For latency and throughput, retain per-sample values and report median, tail
quantiles, effect size, and uncertainty. Separate time-to-first-token, inter-token
latency, prefill, decode, and end-to-end latency.

Those token-stream metrics apply only when a streaming profile exposes token
events. The current prepared-text HTTP profile is unary and non-streaming, so
its transport campaign must report HTTP first-byte latency and terminal
response latency, not “first-token latency.” Report accept/admission and queue
delay separately, and do not derive completion order or fairness from FIFO
dispatch order.

For resources, label the evidence source:

- logical runtime ledger;
- allocator-observed bytes;
- process RSS or peak RSS;
- mapped/virtual bytes;
- device allocation or residency;
- energy/thermal sensor.

Never substitute one source for another in the claim.

### Correctness and quality

Performance pairs are invalid if the compared paths do not satisfy their declared
output contract. Depending on the experiment, use byte-identical tokens, bounded
numerical error, perplexity, task quality, or an explicitly different sampling
contract. Record the chosen gate before running the campaign.

## Reproduction

Core verification:

```sh
zig build native-observation-test -Dmetal=false
tools/zig-with-ephemeral-cache.sh build native-workload-report-test \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
tools/zig-with-ephemeral-cache.sh build native-workload-report-compile \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
tools/zig-with-ephemeral-cache.sh build native-metal-workload-report-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
tools/zig-with-ephemeral-cache.sh build native-metal-disruption-report-test \
  -Dmetal=true -Doptimize=ReleaseSafe -j2
zig build test -Doptimize=Debug -Dmetal=false
zig build test -Doptimize=ReleaseSafe -Dmetal=false
zig build test -Doptimize=ReleaseFast -Dmetal=false
python3 -m pip install --only-binary=:all: --require-hashes \
  -r bench/requirements-test.txt
python3 -m unittest discover -s bench/tests
```

`tools/verify.sh quick` gives compatible host roots one Zig DAG. The `full` and
`matrix` profiles run `host-runtime-compile`, covering the complete
`test-compile` graph plus the contract runtime artifacts, before starting the
broad runtime suite, then reuse the same private caches. A failed frontier
prevents runtime execution rather than spending time on a partially compiled
suite. Selected foreign targets remain one invocation per target because their
target configurations are distinct; selected roots within that target still
share one DAG. The verifier deletes its temporary caches and install products
on normal exit, so these compile-frontier rules are build orchestration and
disk-boundary properties, not benchmark results.

Dense-family production-only promotion uses `dense-tensor-family-compile`;
full promotion retains the broader test-compile frontier. Existing reranker,
embedding, and retrieval compile names remain compatibility targets backed by
its shared compiled artifact, and their demo names resolve to one shared demo
artifact with mode selection. The focused test targets retain distinct oracle
dependencies; Python-test-only tensor, embedding, and retrieval changes run
their exact unittest modules. `affected-fast` uses the family test for
embedding/classifier/retrieval changes. Hosted cache reuse is soft-pruned above
900 MiB for
affected jobs and 1,800 MiB for exhaustive/Metal jobs, below the setup action's
1,024/2,048 MiB hard limits. Local verification retains no persistent cache.
Exhaustive, retained-target, GPU/native, and manual promotion gates stay
outside the ordinary fast loop.

Concurrency and portability gates:

```sh
zig build test -Doptimize=ReleaseSafe -Dmetal=false -Dsanitize-thread=true
tools/zig-with-ephemeral-cache.sh build native-workload-report-cross-compile \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
zig build test-compile -Dtarget=x86_64-linux-gnu -Dmetal=false -Doptimize=ReleaseSafe
zig build test-compile -Dtarget=aarch64-linux-gnu -Dmetal=false -Doptimize=ReleaseSafe
```

Benchmark harnesses under `bench/` have their own `--help`, configuration, and
schema checks. Start with a tiny smoke run, inspect the artifact, then schedule a
campaign. Never publish only terminal output.

## Stop rules

Stop or redesign an experiment when:

- correctness or quality fails;
- the claimed resource is not directly observed;
- machine-state gates repeatedly fail;
- the effect disappears under paired order;
- overhead exceeds the declared budget;
- a representation adds complexity without a plausible end-to-end path;
- retained artifacts cannot be independently parsed.

Negative results are useful project evidence. Record the configuration and stop
reason in the relevant design document instead of hiding the result.
