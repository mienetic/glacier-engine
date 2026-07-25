# Provider Evidence Inspector

The experimental Provider Evidence Inspector is a read-only command for
rendering one compact provider evidence join as deterministic JSON. Its trust
boundary is intentionally narrow: it verifies the fixed 712-byte outer
envelope, not the composition or truth of the evidence named inside it.

## Run it

```sh
tools/zig-with-ephemeral-cache.sh build provider-evidence-inspector \
  -Doptimize=ReleaseSafe -Dmetal=false -j2 -- \
  --join path/to/provider.join
```

The command accepts exactly one `--join FILE` argument. It opens the input
read-only, requires the opened object to be a stable regular file of exactly 712
bytes, reads exactly that fixed payload, probes for trailing data, and checks
that its file snapshot did not change during the operation. Normal host
file-open semantics apply: a symbolic link may resolve to a stable regular file.
Following that link does not establish file identity, ownership, or trust.

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

The command deliberately does not:

- open or compare nested journal, gateway, transport, request, pricing, usage,
  settlement, or cost artifacts;
- establish that any rendered scalar or digest describes those artifacts;
- prove authenticity, provenance, provider execution, billed usage, cost,
  confidentiality, closure, or trust;
- grant filesystem, provider, settlement, or action authority; or
- render raw prompts, payloads, responses, tokens, API keys, or credentials.

A caller can change a semantic scalar or named digest and recompute the outer
checksum. The inspector will accept that structurally valid envelope and still
emit `composition_verified: false` and `authority_granted: false`. The full
composition verifier rejects the same contradiction when supplied with the
original nested evidence.

## JSON contract

The top-level fields are emitted in this order:

| Field | Meaning |
| --- | --- |
| `schema` | `glacier.provider-evidence-inspector/v1` |
| `wire_abi` | Lowercase 16-digit outer wire ABI |
| `wire_bytes` | Fixed encoded size, 712 |
| `outer_envelope_verified` | Outer framing/checksum checks passed |
| `composition_verified` | Always `false` in this command |
| `authority_granted` | Always `false` |
| `journal_sequence` | Self-asserted unsigned 64-bit value |
| `gateway_event_index` | Self-asserted unsigned 32-bit value |
| `transport_event_count` | Self-asserted unsigned 32-bit value |
| `journal_frame_bytes` | Self-asserted unsigned 64-bit value |
| `gateway_wire_bytes` | Self-asserted unsigned 64-bit value |
| `transport_wire_bytes` | Self-asserted unsigned 64-bit value |
| `roots` | Ordered map of self-asserted lowercase SHA-256 text |

The `roots` map names journal header, previous chain, entry, cost envelope,
settlement envelope, request, dispatch key, intent, receipt, price, quote, cost
settlement, gateway envelope/event/final chain, transport envelope, provider
request, response chain, transport outcome, and outer envelope digests. Only the
last digest is checked by this command. The other names describe their intended
composition roles, not verified facts.

There is intentionally no generic `verified` or `closed` field.

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
resolution, path redaction, and resealed semantic contradictions. The Python
oracle computes the outer checksum independently and also proves that the full
composition verifier rejects a contradiction accepted at the outer-only
boundary.
