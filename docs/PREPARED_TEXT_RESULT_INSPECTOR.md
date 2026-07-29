# Prepared-Text Result Inspector

Status: **integrated experimental R1k-b3 read-only inspection slice**.

The prepared-text result inspector joins one selected recovery checkpoint to
one selected durable result-sink ledger and emits a deterministic JSON view. It
opens existing objects read-only, takes no writer lease, performs no recovery,
and grants no execution, storage, publication, or repair authority.

This is a diagnostic surface over the retained R1k-b2 fixture. It is not the
ordinary `text-run` output path, a serving API, or a stable public ABI.

## Accepted sequence states

The pure reconciler accepts only two states:

| State | Required relationship | Meaning |
| --- | --- | --- |
| `aligned` | Checkpoint and sink have the same next sequence and the same acknowledgement/prefix heads | Every visible sink acknowledgement is already represented by the selected checkpoint |
| `sink-exactly-one-ahead` | The sink next sequence is exactly checkpoint next plus one, and its final acknowledgement extends the checkpoint heads | One durable sink token is visible while its immediate checkpoint successor is still pending |

A terminal checkpoint is valid only when it is `aligned` and has a nonempty
acknowledgement prefix. A terminal one-ahead state, a sink behind the
checkpoint, a gap larger than one, a mismatched token, a foreign request or
sink identity, or a broken acknowledgement chain rejects.

The selected checkpoint must carry the exact package, prepared representation,
input archive, tokenizer, local plan, request, sink, selector, selected-set,
state, and output-prefix bindings admitted by the existing recovery decoders.
The tokenizer must be the canonical `utf8-byte-v1` profile. Every visible token
must be in `0..255` and maps to the byte with the same value. The complete view
is bounded to 16,384 tokens.

## Read-only observation

The checkpoint and sink readers:

- open only the active selectors and their hash-named immutable objects;
- require exact regular, private, single-link files with stable descriptor
  identity and size;
- decode and validate the complete selector/object or selector/ledger pair;
- reread each active selector after its selected object is verified; and
- return `SelectionChanged` when the final selector reread observes a
  concurrent cooperative publication. An identity or storage failure during
  the initial read remains its underlying typed error.

The inspector does not create, lock, rename, truncate, repair, recover, or
delete files. It does not inspect candidate files and does not acquire either
writer lease. Its final checkpoint and sink selector rereads establish an
overlapping observed interval for the two accepted selections.

This boundary detects ordinary cooperative selector replacement. It is not a
defense against a hostile writer capable of replacing namespace entries,
replaying valid bytes, or controlling the directory while inspection runs.

## Run the inspector

Run the focused Zig tests and independent standard-library Python oracle:

```sh
tools/zig-with-ephemeral-cache.sh build \
  prepared-text-result-inspector-test \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
```

Compile the inspector without running it:

```sh
tools/zig-with-ephemeral-cache.sh build \
  prepared-text-result-inspector-compile \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
```

Inspect a directory containing the active prepared-text checkpoint and result
sink:

```sh
tools/zig-with-ephemeral-cache.sh build \
  prepared-text-result-inspector \
  -Dmetal=false -Doptimize=ReleaseSafe -j2 -- \
  --directory PATH
```

`--max-set-bytes N` may lower or raise the caller-selected checkpoint-set read
bound. It does not raise the 16,384-token committed-output bound.

## Metadata-only default

Without another flag, the command emits one newline-terminated
`glacier.prepared-text-committed-output/v1` object with
`output_disclosed:false`. It includes:

- the sequence state, terminal and checkpoint-pending flags;
- checkpoint, sink, visible-sequence, token-count, acknowledgement-count, and
  request-epoch metadata;
- the strict UTF-8 validity bit; and
- package, representation, input-archive, tokenizer, plan, request,
  checkpoint, sink, acknowledgement-prefix, visible-token, visible-byte, and
  composed-view roots.

The composed-view root binds the sequence state, terminal flag, checkpoint
generation, reported counts and sequences, and every reported context,
checkpoint, sink, and visible-output root. Derived UTF-8 validity,
checkpoint-pending state, and the disclosure choice are intentionally outside
that root.

It does not emit token IDs, byte payloads, prompt text, raw input, license
bytes, or model bytes.

Metadata is still information. Counts, epochs, generations, stable identities,
and content roots can correlate requests, artifacts, executions, and repeated
observations. The default is payload-minimizing, not anonymous or
privacy-preserving.

## Explicit output disclosure

Output disclosure requires an explicit flag:

```sh
tools/zig-with-ephemeral-cache.sh build \
  prepared-text-result-inspector \
  -Dmetal=false -Doptimize=ReleaseSafe -j2 -- \
  --directory PATH --reveal-output
```

The additional `output` object contains four lossless projections:

- `token_ids`: the exact `0..255` token IDs;
- `bytes_hex`: lowercase hexadecimal for every visible byte;
- `escaped_bytes`: printable ASCII with backslash escaped and every other byte
  represented as lowercase `\xhh`; and
- `utf8_text`: the exact JSON string only when strict UTF-8 validation
  succeeds, otherwise `null`.

The inspector never replaces invalid UTF-8 with a replacement character.
`bytes_hex` and `escaped_bytes` are byte evidence, not a claim that the output
is natural-language text.

## Evidence and nonclaims

The focused gate covers aligned and exactly-one-ahead reconciliation,
terminal-state restrictions, identity and acknowledgement substitution,
sequence gaps, token mismatch, tokens above 255, invalid UTF-8, failure-atomic
formatting, and shared Zig/Python golden roots. It also kills the retained
worker at the real `after_sink_before_selector` boundary, inspects the
generation-two one-ahead selection, converges in fresh processes to the
terminal selection, and compares a bounded content manifest of the inspected
directory before and after each inspector invocation.

It establishes a bounded read-only view for cooperative local publication of
the retained synthetic CPU fixture. It does not establish:

- hostile-writer resistance, authentication, historical attestation, or
  multi-tenant isolation;
- confidentiality, anonymity, redaction, or a complete privacy policy;
- physical power-loss persistence;
- remote or distributed exactly-once delivery;
- GPU execution or GPU-resident continuation;
- Win32 durable-file behavior;
- native multi-OS execution or recovery evidence;
- production model/tokenizer quality or general tokenizer coverage; or
- ordinary `text-run`, unary serving, streaming serving, or stable SDK result
  rendering.

See [Acknowledged Prepared-Text Delivery](PREPARED_TEXT_ACKNOWLEDGED_DELIVERY.md)
for the writer-side protocol and
[Evidence Policy](EVIDENCE_POLICY.md) for publication and disclosure rules.
