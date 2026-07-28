# Native Workload Store-Fault Report

W7b-b2 adds an accelerator-independent POSIX-host publication/recovery campaign
for the workload campaign store. It exercises the production `CampaignStore`
writer, kills real child processes at fixed publication boundaries, opens
recovery in fresh processes, and emits a fixed binary report checked
independently by Zig and Python.

This gate runs no model and opens no accelerator. It complements the native
Metal gates; it does not replace their real-GPU evidence.
The publisher is the production `CampaignStore`; prepared roll-forward is a
bounded campaign reference engine, not yet a general production recovery API.

## Exact campaign

The prepared transaction advances one canonical workload campaign from
generation one to generation two. It binds the predecessor and successor plan,
manifest, selector, environment object, report-wire object, byte/file bounds,
and transaction root before recovery is allowed.

The publication schedule has 27 ordered phases:

| Object | Phases |
| --- | --- |
| Final environment | create, prefix write, remainder write, file sync, target link, temporary unlink, directory sync |
| Report wire | create, prefix write, remainder write, file sync, target link, temporary unlink, directory sync |
| Successor manifest | create, prefix write, remainder write, file sync, target link, temporary unlink, directory sync |
| Active selector | create, prefix write, remainder write, file sync, atomic replace |
| Store root | directory sync |

The hard gate runs:

- 27 real `SIGKILL` cases immediately after the selected host-filesystem call;
- 27 controlled `EIO` cases immediately before the selected call;
- 27 controlled `ENOSPC` cases immediately before the selected call; and
- one clean publication control.

Each of the 81 fault cases starts from a newly synchronized canonical
predecessor. A fresh recovery child then accepts only the exact predecessor or
successor selector, cleans only residue whose name, type, link count, prefix,
and content match the prepared transaction, and rolls forward to the exact
successor. A second fresh recovery must report `already_applied`, and a third
fresh process performs a strict shared-lock audit. The clean control follows
the same two-recovery and strict-audit sequence.

Among the 81 fault cases, 77 first recoveries begin from the predecessor and
four already expose the successor. The clean control also begins at the
successor. All 82 second recoveries report `already_applied`, and all 82 strict
audits verify the successor.

## Commit and recovery rules

Selector replacement is the logical visibility point. Root-directory `fsync`
is the following durability-call boundary. Once publication I/O begins, an
error poisons that writer instance; the writer does not start a second
unjournaled rollback transaction.

Recovery is deliberately narrow:

- authority comes from an exact `PreparedPublicationV1`, not from the active
  selector alone;
- the active selector must be the bound predecessor or successor;
- base and candidate objects must have exact names, bytes, modes, link counts,
  and directory identities;
- root, object-directory, and lock inodes are fenced while the lease is held;
- unknown entries, corrupt objects, symlinks, foreign hard links, namespace
  replacement, or a third selector fail closed before recovery mutation; and
- the final store must contain only the canonical successor set.

This is prepared roll-forward publication. It grants no general append,
arbitrary campaign resume, or workload-process restoration authority.

## Report wire

`NativeWorkloadStoreFaultReportV1` is separate from the existing campaign
manifest, attempt, and selector ABIs. Their layouts and golden wires remain
unchanged.

The report layout is:

```text
960-byte header
192-byte predecessor selector
192-byte successor selector
N × 512-byte fault cases
64-byte footer
```

For this campaign `N = 81`, so the report is 42,880 bytes. The wire binds the
exact logical failpoint coordinates, raw and recovered selector states,
canonical store snapshots, real-signal versus synthetic-errno provenance,
child termination, recovery receipts, component identities, host/filesystem
profiles, ordered case chain, and body/footer roots. Logical duplicate
failpoints are rejected even if their ordinal, challenge, or observed outcome
is changed.

The outer matrix root also commits the clean-control receipt. The binary case
table contains only the 81 actual faults because V1 has no no-fault case kind.
The wire is self-asserted canonical evidence. Its two verifiers establish fixed
layout, hashes, ordering, uniqueness, and campaign consistency; they do not
establish authenticity, freshness, a source-control commit, build or history
provenance, executable attestation, or OS causality. The live hard gate checks
process status and filesystem results before it constructs those receipts.

Source-integrity provenance is point-in-time evidence. Before the matrix, the
live gate hashes its tracked repository-local Python dependency set for the
campaign runner, production-store import closure, and Python report codec. It
checks those paths at process and verification boundaries and commits the
resulting component graph through existing report-header identities. The
separately compiled Zig verifier, its source and build graph, and compiler or
toolchain provenance are outside this source snapshot. This is not executable
attestation: it does not authenticate loaded code pages, the interpreter,
loader, or OS, and a hostile swap-and-restore entirely between checkpoints is
outside the claim. Namespace-swap checks assume the gate's cooperative
single-writer, controlled-state boundary; they are not protection against a
hostile concurrent writer.

A retained output receipt covers only its completed verification window.
Before later use, re-read and reverify the retained report and compare its
encoded and report digests with the retained receipt.

## Running it

Run the portable report-codec tests plus the focused POSIX host-filesystem
publication, recovery, and negative-state suite (including one representative
real `SIGKILL` case):

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-workload-store-fault-report-test \
  native-workload-store-fault-pure-test \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
```

Run the hard host campaign:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-workload-store-fault-test \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
```

Retain the verified binary report:

```sh
tools/zig-with-ephemeral-cache.sh build \
  native-workload-store-fault-test \
  -Dmetal=false -Doptimize=ReleaseSafe -j2 \
  -Dnative-workload-store-fault-output=PATH
```

The hard build passes the report through a fresh Python campaign verifier and
a separately compiled Zig verifier before success.

## What is real and what is controlled

Real in the hard gate:

- host subprocess creation, wait status, and 27 `SIGKILL` deaths;
- production store code;
- native `open`, write, `fsync`, hard-link, unlink, replace, directory-sync,
  and advisory-lock calls on the invoking filesystem; and
- fresh process boundaries for recovery and verification.

Controlled or synthetic:

- the workload plan and report-wire bytes execute no model;
- `EIO` and `ENOSPC` are returned by a deterministic software adapter;
- the gate does not actually fill a filesystem or damage a medium; and
- no GPU command is submitted.

Therefore a pass is not evidence of physical disk exhaustion, quota
exhaustion, controller/media failure, power cut, reboot, kernel panic,
hardware-flush persistence, network/distributed filesystem semantics, Windows
durability, hostile concurrent writers, storage performance, or in-flight GPU
recovery. Recovery-process kill/error boundaries and integration of prepared
roll-forward into a general production recovery API are also still open.
Those require separate native campaigns and implementation gates.
