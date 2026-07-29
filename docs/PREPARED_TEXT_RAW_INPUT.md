# Verified Raw-Text Runtime Path

Status: **integrated experimental R1k-b1 ingress, process-local bounded
early-EOS completion, R1k-b2 CPU/POSIX recovery, and package-aware fixed-output
durable CLI slice**.

This path gives one supported command sequence a verifiable join from exact
raw UTF-8 bytes to the prepared-text runtime:

```text
Safetensors fixture
  -> sealed portable .glacier publication
  -> recoverable prepared .glrt publication
  -> stable package + prepared-representation identities
  -> canonical UTF-8 byte tokenizer
  -> prepared-text and Common Model Contract plans
  -> one of:
       process-local SessionV3 command
       process-local SessionV2 bounded early-EOS command
       package-aware durable fixed-output command
       durable source/target recovery with exact raw-input retention
  -> terminal result evidence and zero logical ownership
```

It exists alongside the compatibility `generate` command. New code that needs
raw-text identity should use `text-run`; the compatibility tokenizer retains
its older behavior for existing callers.

## Run the download-free sequence

Build the CPU path, generate the retained synthetic source, convert it, prepare
it, and execute one raw prompt:

```sh
zig build install -Doptimize=ReleaseSafe -Dmetal=false -j2

./zig-out/bin/glacier gen-fixture /tmp/glacier-text.safetensors \
  --dim 32 --hidden 32 --layers 1 --vocab 256

./zig-out/bin/glacier convert --int4 --group-size 16 \
  /tmp/glacier-text.safetensors /tmp/glacier-text.glacier

./zig-out/bin/glacier prepare \
  /tmp/glacier-text.glacier /tmp/glacier-text.glrt

printf '%s' 'Ice' > /tmp/glacier-prompt.txt

./zig-out/bin/glacier text-run /tmp/glacier-text.glrt \
  --text-file /tmp/glacier-prompt.txt --license LICENSE --n 3
```

Without `--package`, the R1k-b1 compatibility path deliberately accepts only
this retained `32/32/1/256` fixture profile: the prepared source fingerprint,
complete geometry, tokenizer profile, and repository `LICENSE` digest must
match. The later ordinary-model path accepts `--package model.glpkg` and
decodes its fixed 896-byte manifest-plus-representation bundle, then derives
and validates the package/configuration/tokenizer/license/prepared-image
relationship against the embedded exact GLRT receipt for one supported
Safetensors/INT4/CPU profile. That package can only be produced through a
required named experimental profile and complete explicit config; its
same-descriptor source preflight admits an exact tensor name/dtype/rank/shape
inventory before portable publication.
Both paths prevent an arbitrary subword-tokenized model from being mislabeled
as byte-token compatible. See [Ordinary Model Package](MODEL_PACKAGE.md).

`text-run` requires valid nonempty UTF-8 input and `1..64` requested output
tokens. The current command profile limits input to 4,096 bytes. It emits one
deterministic JSON object and renders model output as token IDs.

For process-local execution, `--eos-token ID` changes `--n` from an exact
count to an upper bound. The token must be inside the admitted vocabulary.
An EOS hit before the bound emits
`glacier.prepared-text-variable-run/v1`, reports
`termination_reason="eos"`, closes unused scheduler quanta, and includes a
`CompletedEarlyV1` root. If the token is not sampled, execution reaches the
bound, reports `termination_reason="length"`, and retires normally without an
early-completion root. Sampling EOS exactly at the bound reports
`termination_reason="eos_at_limit"` and also retires normally because no quota
remains to release. The default command remains the fixed
`SessionV3`/`ResultEnvelopeV1` profile.

```sh
./zig-out/bin/glacier text-run model.glrt \
  --text-file prompt.txt --license LICENSE --package model.glpkg \
  --n 16 --eos-token 2
```

The early-completion sidecar is required to classify the close as successful:
the underlying cancel event by itself retains its ordinary cancellation
meaning. Durable options cannot be combined with `--eos-token`; the command
rejects that combination before reading or mutating the state directory.

The preferred input is `--text-file`, which keeps prompt bytes out of process
arguments and shell history. `--text` remains available for non-sensitive
fixture experiments, but its value is visible to normal process inspection.

The `--license` value is evidence input: the command hashes the exact stable
file bytes and binds that digest into the Common Model Contract plan. The
unpackaged compatibility path requires the retained fixture digest; package
admission requires the byte count and digest recorded by that package. This
proves which bytes were supplied; it does not interpret the license or decide
whether a model may legally be used.

## Durable package run

The package-aware durable command supports fixed output counts `1..64`. Count
one reuses the public sink-free direct-terminal writer and view. Counts
`2..64` reuse the public acknowledged source/target writer and committed-output
view with sink capacity `N - 1`. Neither route introduces a CLI-specific
journal, selector, or recovery format.

Create a private, existing state directory and run:

```sh
mkdir -m 700 /tmp/glacier-run-001

./zig-out/bin/glacier text-run model.glrt \
  --text-file prompt.txt \
  --license LICENSE \
  --package model.glpkg \
  --n 1 \
  --durable-dir /tmp/glacier-run-001 \
  --request-id 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
```

`--durable-dir` must be absolute and is opened without following the final
symlink. `--request-id` is a caller-chosen 32-byte lowercase hexadecimal
identity, not a secret. Choose and retain a new ID outside the state directory
for each logical request; reuse that exact ID only to continue or retry that
request. Use one initially empty private directory per logical request. A
selected directory is bound to that request and has no in-place reset or
cleanup command. The command combines the ID with the admitted package, exact
prepared representation, license, and raw-text roots to derive the request
challenge and all process-stable runtime identities. Changing any
challenge-bound request or artifact input therefore rejects before writer
authority or selected-checkpoint mutation. The acknowledged route uses a
separate challenge domain and also binds the exact output count, so changing
`--n` cannot resume an existing request.

By default the terminal report omits the token payload. Add `--reveal-output`
to include the checked token IDs with `output_encoding="token-ids"`. Digest and
lineage metadata can still reveal or correlate low-entropy output; the default
is not a confidentiality boundary. The default checkpoint-set allocation bound
is 8 MiB. `--max-set-bytes` accepts a cap in the parser range
`1..67108864`; a cap smaller than the encoded set still fails closed.

The normal command creates or recovers generation one. Count one advances it
to sink-free terminal generation two. Counts `2..64` advance the source to
generation two, then reconstruct one target runtime per remaining token until
terminal generation `N + 1`. Both routes close runtime ownership and render
only a selector-rechecked view. Exact terminal retry returns
`already_selected` for count one or `already_terminal` for acknowledged
counts without another model step. `--bootstrap-only` stops after generation
one so an orchestrator can deliberately hand execution to a fresh process:

```sh
mkdir -m 700 /tmp/glacier-run-002

./zig-out/bin/glacier text-run model.glrt \
  --text-file prompt.txt --license LICENSE --package model.glpkg --n 1 \
  --durable-dir /tmp/glacier-run-002 \
  --request-id 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
  --bootstrap-only

# Run the same command again without --bootstrap-only in a fresh process.
```

`--bootstrap-only` cannot be combined with `--reveal-output`. Repeating the
bootstrap command for the same generation-one request returns
`bootstrap_disposition="already_selected"` without changing the directory.

The JSON schema `glacier.prepared-text-durable-run/v1` is discriminated by
`operation`; fields not listed for that operation are absent:

| Operation | Required fields |
| --- | --- |
| `bootstrap` | `profile`, `route`, `selection_before`, `bootstrap_disposition`, `durable_checkpoint`, `fresh_process_boundary_ready`, `checked_committed_output`, `terminal`, `ownership_closed`, `request_epoch`, `generation`, `publication_next_sequence`, `max_set_bytes`, request/artifact identity roots, and the selected set/selector, source-contract, and input-archive roots; the acknowledged profile also reports requested count, sink capacity, and sink identities |
| `advance` | `profile`, `route`, `selection_before`, `disposition`, nullable bootstrap/source dispositions, `durable_checkpoint`, `fresh_process_continuation_supported`, `preexisting_generation_continuation_performed`, `checked_committed_output`, `terminal`, `ownership_closed`, `model_execution_performed`, route-specific counters and committed roots, and the three output-disclosure fields |

For `advance`, `preexisting_generation_continuation_performed` is true when
the invocation starts from any preexisting nonterminal generation and performs
at least one model transition. A zero-step terminal retry reports false.
`fresh_process_continuation_supported` is a capability, not proof of the prior
publisher's process identity.
`model_execution_performed` records whether the model step ran;
`ownership_closed` separately records closed runtime ownership on return.
`checked_committed_output` means structural receipt, selected-wire,
predecessor, contract, archive, and view reconciliation—not a model-quality
oracle. `output_encoding` is `token-ids`, and `output_tokens` is `null` unless
explicitly revealed.

Both operations include `request_id_sha256`, `package_sha256`,
`representation_sha256`, and `challenge_sha256`. Direct-terminal reports keep
their predecessor, terminal-source, semantic, output, state, and direct-view
roots. Acknowledged reports instead expose the requested count, capacity,
source/target transition counts, input/local-plan/tokenizer roots, selected
checkpoint and sink roots, acknowledgement head/prefix, visible token/byte
roots, and committed `view_sha256`. The disclosure fields remain
`output_disclosed`, `output_encoding`, and `output_tokens`.

The count-one state directory contains only the checkpoint lock, active
selector, and content-addressed predecessor/successor sets. Counts `2..64`
also contain the existing result-sink lock, selector, and immutable ledgers.
The CLI creates neither a new namespace nor a second recovery format.

## Canonical tokenizer profile

`utf8-byte-v1` is deliberately narrow:

- input is strict UTF-8 with no normalization;
- every input byte becomes one `u32` token with the same unsigned value;
- vocabulary size must be at least 256;
- BOS, EOS, PAD, and every other implicit special token are disabled;
- unsupported vocabulary shapes reject instead of applying a modulo fallback;
- one exact raw byte string and token stream receive separate domain-separated
  SHA-256 roots.

The general wire limit is 1 MiB even though the supported command currently
chooses the smaller 4,096-byte profile. Since this tokenizer emits one token per
UTF-8 byte, it is an identity and integration profile rather than a
token-efficiency feature. It does not reduce token use at an external AI
provider.

### `Utf8ByteManifestV1`

The manifest is exactly 192 bytes:

| Offset | Bytes | Field |
| ---: | ---: | --- |
| 0 | 8 | `GTOKV1\0\0` |
| 8 | 8 | ABI |
| 16 | 8 | encoded length |
| 24 | 4 | profile |
| 28 | 4 | encoding |
| 32 | 4 | normalization |
| 36 | 4 | flags |
| 40 | 4 | vocabulary size |
| 44 | 4 | reserved zero |
| 48 | 4 | byte-token count |
| 52 | 12 | disabled PAD/BOS/EOS IDs |
| 64 | 8 | maximum input bytes |
| 72 | 32 | tokenizer-domain root |
| 104 | 32 | behavior root |
| 136 | 24 | reserved zero |
| 160 | 32 | manifest/configuration root |

The final root hashes the first 160 bytes under
`glacier-utf8-byte-tokenizer-manifest-v1`.

### `Utf8BytePromptReceiptV1`

The prompt receipt is exactly 256 bytes:

| Offset | Bytes | Field |
| ---: | ---: | --- |
| 0 | 32 | magic, ABI, length, and zero flags |
| 32 | 32 | tokenizer-domain root |
| 64 | 32 | tokenizer-configuration root |
| 96 | 32 | exact raw-text root |
| 128 | 32 | canonical little-endian `u32` token-stream root |
| 160 | 8 | raw byte count |
| 168 | 8 | token count |
| 176 | 48 | reserved zero |
| 224 | 32 | prompt-receipt root |

Validation recomputes the raw-text and token-stream roots and compares every
token with its source byte. A structurally valid receipt alone is not proof
that retained text or tokens match; callers use
`utf8BytePromptValidForTokensV1` for that complete check.

## Raw-input plan binding

`PreparedTextRawInputBindingV1` is a 480-byte fixed wire. It joins the tokenizer
receipt to the local prepared-text plan and the Common Model Contract
artifact/execution/residency records.

| Offset | Bytes | Field |
| ---: | ---: | --- |
| 0 | 32 | magic, ABI, length, and zero flags |
| 32 | 32 | tokenizer-domain root |
| 64 | 32 | tokenizer-configuration root |
| 96 | 32 | tokenizer prompt-receipt root |
| 128 | 32 | raw-text root |
| 160 | 32 | token-stream root |
| 192 | 32 | prepared prompt root |
| 224 | 32 | local plan root |
| 256 | 32 | bound-plan root |
| 288 | 32 | Common artifact root |
| 320 | 32 | Common execution-plan root |
| 352 | 32 | residency-binding root |
| 384 | 32 | exact license-byte root |
| 416 | 8 | request epoch |
| 424 | 8 | prompt token count |
| 432 | 8 | raw byte count |
| 440 | 8 | reserved zero |
| 448 | 32 | binding root |

Construction fails unless:

- the prompt receipt validates against the exact raw text and tokens;
- the local plan's prompt count and root match those tokens;
- the bound plan validates and retains the same local-plan root;
- tokenizer domain and configuration roots occupy the Common processor fields;
- the prepared prompt root occupies the Common media-object field;
- input geometry is exactly one batch item of little-endian `u32` tokens; and
- the artifact license and request epoch are present and consistent.

The command report carries every field required for an independent process to
reconstruct the binding root. It also carries prepared-image identity,
local/bound-plan roots and reconstruction fields, terminal output/result
evidence, the boundary-snapshot root, and the final publication transcript
root. Canonical tokenizer, prompt, raw-input, artifact, execution, residency,
and result wires are exported as hex so the standard-library Python gate
decodes their actual bytes rather than trusting reported roots. No
boundary-snapshot wire is exported in R1k-b1, so that root and the transcript
root remain opaque bound leaves.

Raw-text and token-stream digests are deterministic evidence, not
anonymization. They reveal equality across runs and may permit guessing of
low-entropy prompts. Do not publish reports containing sensitive prompt
identities without an application-specific privacy policy.

## Stable package and durable input archive

R1k-b2 separates portable package identity from both requests and native
preparation:

- `package_manifest.ManifestV2` is exactly 640 bytes. It binds source and portable
  artifact identities, conversion profile and plan, resolved model geometry,
  the explicit model-profile ABI/ID/root, the tensor-profile ABI/count/root,
  tokenizer domain/configuration/behavior, and the license byte count plus
  SHA-256 identity. It excludes the license payload, prompt, request epoch,
  output limit, Scheduler identity, and `.glrt` bytes.
- `package_manifest.PreparedRepresentationV1` is exactly 256 bytes. It binds one package/config
  pair to an exact prepared container plus source and ABI fingerprints. A
  second platform preparation may therefore have another representation root
  without changing the package root.
- The `prepared_text_input_archive` V1 wire has a 1,952-byte fixed prefix, the exact nonempty
  raw UTF-8 bytes, and a 32-byte footer. Its prefix contains the package and
  representation wires, the 192-byte tokenizer manifest, 256-byte prompt
  receipt, and 480-byte raw-input binding.

The archive decoder revalidates every inner wire, byte count, package/
representation relationship, tokenizer behavior, receipt, token-stream root,
binding, and whole-archive root. A fresh source or target re-tokenizes the
retained bytes and revalidates the current prepared-text/Common plan before
model admission.

The additive durable path carries the exact archive as extension ordinal 2 in
generation one and extension ordinal 6 in restart and acknowledged-progress
sets. Every later nonterminal generation requires byte-identical archive bytes;
the terminal generation retains them transitively through its immediate
predecessor. Compatibility five-object restart and seven-object progress
decoders remain available for pre-tokenized callers.

The independent standard-library Python oracle decodes the actual package,
representation, and input-archive bytes, reconstructs the same roots and
re-tokenization relationship, rejects every component/archive byte mutation,
and rejects coherently re-rooted substitutions.

## Verification gate

Run the complete retained gate with:

```sh
zig build text-runtime-golden-path-test \
  -Doptimize=ReleaseSafe -Dmetal=false -j2
```

The gate:

1. independently reconstructs tokenizer, prompt, prepared-prompt, and binding
   identities in standard-library Python;
2. rejects every single-byte mutation of both tokenizer wires;
3. freezes source and portable-artifact digests plus the prepared provenance
   fingerprint, and requires the platform-bound prepared image to remain
   byte-identical across same-platform retries;
4. requires a repeated conversion to report `already_current`;
5. requires repeated preparation and a fresh identical execution to produce
   identical evidence without calling that a replay-safe retry;
6. proves a changed prompt creates a distinct identity, while a changed license
   or foreign valid fixture rejects;
7. independently decodes the Common artifact, execution, residency, and result
   wires and reconstructs local/bound-plan, terminal-output, adapter,
   source-mapping, publication-state, and terminal-evidence relationships while
   treating the boundary-snapshot and transcript roots as opaque bound leaves;
   and
8. stages an ordinary package-aware direct-terminal request, proves an exact
   bootstrap retry is byte-identical, rejects changed prompt, request, license,
   valid package-root, and valid alternate-representation inputs while
   generation one is live, and then continues it in a fresh process;
9. independently decodes the selected generation-one and generation-two
   checkpoint wires, including the embedded predecessor and checked output
   view root;
10. proves a terminal retry returns `already_selected` without changing the
    directory and separately covers the empty-directory one-shot route;
11. requires the durable token to equal the first token from ordinary execution
    of the same admitted package and prompt; and
12. independently decodes acknowledged counts `2`, `4`, and `64`, covers sink
    capacities `1`, `3`, and `63`, proves count-bound identity and a
    generation-one fresh-process continuation for count four, and requires all
    durable tokens to equal ordinary execution; and
13. derives in-vocabulary EOS hit and miss cases from the ordinary output,
    independently recomputes the variable-terminal and completed-early roots,
    verifies exact unused-quanta closure, and rejects durable EOS before
    directory mutation; and
14. rejects incompatible durable options, unsafe directory selection,
    oversized input, and malformed UTF-8 before model execution.

The gate neither reconstructs the boundary snapshot nor independently replays
the internal publication proposal/acknowledgement transcript; the report states
`boundary_snapshot_independently_verified=false` and
`publication_transcript_replayed=false`. Both roots remain bound inputs to the
independently reconstructed terminal source mapping.

Foreign targets can compile the command closure without executing it:

```sh
zig build text-runtime-golden-path-compile \
  -Dtarget=x86_64-windows-gnu \
  -Doptimize=ReleaseSafe -Dmetal=false -j2
```

This is cross-compilation evidence, not native Windows execution evidence.

## Scope and next boundary

The retained fixture is synthetic and download-free. Its output tokens do not
claim language quality. Ordinary execution remains a process-local CPU path.
The package-aware durable CPU/POSIX command supports fixed counts `1..64`:
count one is intentionally sink-free, while counts `2..64` use acknowledged
result-sink state with capacity `N - 1`.
The separate process-local `--eos-token` profile supports successful
fewer-than-admitted output without changing the fixed durable contracts.

The Common artifact manifest remains a request-profile identity and changes
with prompt context. R1k-b2 supplies a separate stable package identity, but it
is still an experimental wire rather than a stable public distribution ABI.
`BoundPlanV1` likewise remains an experimental Zig/direct structure rather
than a fixed cross-language wire.

The package-aware command carries exact tokenizer/raw-input identity through
every retained generation and renders checked committed output only after
runtime ownership closes. Durable variable-length or early-EOS output, general
tokenizer text rendering, and serving integration remain open.
The overall invocation still enters the idempotent writer/lease workflow before
calling the read-only view; it is not a post-hoc read-only inspector.
The retained durable path is CPU execution on the descriptor-relative POSIX
adapter. GPU/device-resident recovery, production model quality, performance,
remote delivery, hostile writers, native multi-OS durability, and physical
power-loss persistence are not claimed.
