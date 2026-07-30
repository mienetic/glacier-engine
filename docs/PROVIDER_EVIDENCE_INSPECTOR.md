# Provider Evidence Inspector

The experimental Provider Evidence Inspector is a read-only command for
rendering one compact provider evidence join as deterministic JSON. Its default
mode verifies only the fixed 712-byte outer envelope. An optional composed mode
accepts every required nested artifact explicitly and replays the existing
composition verifier before promoting the internal cross-wire equality claim.
Neither mode grants authority or establishes the external truth of the
evidence.

## Run it

Inspect only the outer envelope:

```sh
tools/zig-with-ephemeral-cache.sh build provider-evidence-inspector \
  -Doptimize=ReleaseSafe -Dmetal=false -j2 -- \
  --join path/to/provider.join
```

Replay the supplied nested evidence and require exact cross-wire composition:

```sh
tools/zig-with-ephemeral-cache.sh build provider-evidence-inspector \
  -Doptimize=ReleaseSafe -Dmetal=false -j2 -- \
  --join path/to/provider.join \
  --journal-header path/to/provider.journal-header \
  --cost-frame path/to/provider.cost-frame \
  --gateway-events path/to/provider.gateway-events \
  --transport-events path/to/provider.transport-events
```

`--join FILE` is always required. The other four arguments form one all-or-none
group:

- `--journal-header FILE` must be exactly 144 bytes;
- `--cost-frame FILE` must be exactly 1,645 bytes;
- `--gateway-events FILE` must equal the gateway length declared by the join
  and must not exceed 8 MiB; and
- `--transport-events FILE` must equal the transport length declared by the
  join and must not exceed 8 MiB.

The command opens every supplied input read-only, requires each opened object to
be a stable regular file, reads the exact bounded payload, probes for trailing
data, and checks that its file snapshot did not change during the read. Partial
composed arguments, duplicate arguments, empty paths, length mismatches, and
files above the variable-input bound reject. Normal host file-open semantics
apply: a symbolic link may resolve to a stable regular file. Following that link
does not establish file identity, ownership, or trust.

On success, stdout contains exactly one compact JSON object followed by a
newline, and stderr is empty. On an argument, file, framing, or checksum error,
the process exits with status 2, writes no stdout, and reports a generic error
name without echoing the input path.

## What is verified

`outer_envelope_verified: true` means only that all of these checks passed:

- exact encoded length of 712 bytes;
- magic `GPJOINR1`;
- wire ABI `47504a4f00000001`;
- declared length of 712 bytes;
- required outer flag value and zero reserved field;
- exact cursor consumption of the fixed layout; and
- the outer domain-separated SHA-256 checksum.

The decoder returns a nominal outer-inspection result whose payload is named
`self_asserted`. This type boundary makes the weaker framing result explicit and
helps prevent accidental confusion with the full composition verifier.

With only `--join`, the command stops at that boundary. A caller can change a
semantic scalar or named digest and recompute the outer checksum. The inspector
will accept that structurally valid envelope while still emitting
`composition_verified: false` and `authority_granted: false`.

When all four nested paths are present, the command additionally:

- decodes the 144-byte journal header against the header root named by the join;
- verifies the selected 1,645-byte cost-journal frame at the exact sequence and
  previous-chain identity carried by the join;
- independently replays the bounded gateway and transport event wires into
  caller-owned scratch;
- requires the selected gateway settlement, transport settlement, and cost
  frame settlement to be exactly equal;
- derives the terminal transport roots; and
- reconstructs the canonical join and requires byte-for-byte equality with the
  supplied 712-byte envelope.

Only after all of those checks succeed does the report emit
`composition_verified: true`. The same resealed contradiction accepted by
outer-only inspection rejects in composed mode.

Both modes deliberately do not:

- authenticate the origin of any supplied artifact;
- prove historical provider execution, billed-usage truth, billed-cost truth,
  confidentiality, provenance, or trust;
- grant filesystem, provider, settlement, or action authority; or
- render raw prompts, payloads, responses, tokens, API keys, or credentials.

Internal composition proves that the supplied credential-free records agree
under their canonical validators. It does not turn those records into an
externally authenticated observation.

## JSON contract

The top-level fields are emitted in this order:

| Field | Meaning |
| --- | --- |
| `schema` | `glacier.provider-evidence-inspector/v1` |
| `wire_abi` | Lowercase 16-digit outer wire ABI |
| `wire_bytes` | Fixed encoded size, 712 |
| `outer_envelope_verified` | Outer framing/checksum checks passed |
| `composition_verified` | `false` for outer-only inspection; `true` only after successful nested replay and exact cross-wire equality |
| `authority_granted` | Always `false` |
| `journal_sequence` | Unsigned 64-bit value; self-asserted in outer mode and composition-checked in composed mode |
| `gateway_event_index` | Unsigned 32-bit value; self-asserted in outer mode and composition-checked in composed mode |
| `transport_event_count` | Unsigned 32-bit value; self-asserted in outer mode and composition-checked in composed mode |
| `journal_frame_bytes` | Unsigned 64-bit value; self-asserted in outer mode and composition-checked in composed mode |
| `gateway_wire_bytes` | Unsigned 64-bit value; self-asserted in outer mode and composition-checked in composed mode |
| `transport_wire_bytes` | Unsigned 64-bit value; self-asserted in outer mode and composition-checked in composed mode |
| `roots` | Ordered lowercase SHA-256 map; self-asserted except for the outer root in outer mode, and composition-checked in composed mode |

The `roots` map names journal header, previous chain, entry, cost envelope,
settlement envelope, request, dispatch key, intent, receipt, price, quote, cost
settlement, gateway envelope/event/final chain, transport envelope, provider
request, response chain, transport outcome, and outer envelope digests. In
outer-only mode, only the final outer-envelope digest is checked. In composed
mode, the other values must match replayed nested evidence and the reconstructed
canonical join. This stronger internal identity check does not authenticate the
records.

There is intentionally no generic `verified` or `closed` field.

Outer-only output remains byte-for-byte compatible with the original
`glacier.provider-evidence-inspector/v1` report. Composed mode uses the same
schema and field order, changing only `composition_verified` after the stronger
route succeeds. The feature changes neither the provider evidence wire ABI nor
the executable inventory.

## Verification

Run the focused Zig tests and independent Python subprocess oracle:

```sh
tools/zig-with-ephemeral-cache.sh build provider-evidence-inspector-test \
  -Doptimize=ReleaseSafe -Dmetal=false -j2
```

Run the standalone Python contract tests, which compile into temporary cache
directories and remove them afterward:

```sh
PYTHONDONTWRITEBYTECODE=1 \
  python3 -m unittest bench.tests.test_provider_evidence_inspector
```

The retained cases cover exact JSON, malformed lengths and roots, structural
header corruption, directory and argument errors, stable symbolic-link
resolution, path redaction, the all-or-none composed argument contract, valid
nested replay, malformed nested inputs, and resealed semantic contradictions.
The Python oracle computes the outer checksum independently, requires the
composed route to preserve every rendered scalar and root, and proves that the
full composition verifier rejects a contradiction accepted at the outer-only
boundary. Both modes remain under the existing
`provider-evidence-inspector-test` root; no additional compile root is required.
