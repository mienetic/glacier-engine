# Verified Raw-Text Runtime Path

Status: **integrated experimental R1k-b1 slice**.

This path gives one supported command sequence a verifiable join from exact
raw UTF-8 bytes to the prepared-text runtime:

```text
Safetensors fixture
  -> sealed portable .glacier publication
  -> recoverable prepared .glrt publication
  -> canonical UTF-8 byte tokenizer
  -> prepared-text and Common Model Contract plans
  -> SessionV3 execution
  -> transactional in-process token publication
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

R1k-b1 deliberately accepts only this retained `32/32/1/256` fixture profile:
the prepared source fingerprint, complete geometry, tokenizer profile, and
repository `LICENSE` digest must match. Another valid `.glrt` image or changed
license file rejects. This fixture restriction prevents an arbitrary
subword-tokenized model from being mislabeled as byte-token compatible while a
stable package manifest remains roadmap work.

`text-run` requires valid nonempty UTF-8 input and `1..64` requested output
tokens. The current command profile limits input to 4,096 bytes. It emits one
deterministic JSON object and renders model output as token IDs.

The preferred input is `--text-file`, which keeps prompt bytes out of process
arguments and shell history. `--text` remains available for non-sensitive
fixture experiments, but its value is visible to normal process inspection.

The `--license` value is evidence input: the command hashes the exact stable
file bytes, requires the retained fixture license digest, and binds that digest
into the Common Model Contract plan. This proves which bytes were supplied; it
does not interpret the license or decide whether a different model may legally
be used.

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
8. rejects oversized and malformed UTF-8 input before model execution.

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
claim language quality. The current execution and publication sink are
process-local CPU paths: `transactional_publication=true`, while
`durable_result_sink=false` and `fresh_process_recovery=false` are explicit in
the command report.

The prepared image has an exact platform-bound file digest, but the current
Common artifact manifest remains a request-profile identity and changes with
prompt context. It is not yet a stable distributable package identity.
`BoundPlanV1` also remains an experimental Zig/direct structure rather than a
fixed cross-language wire.

R1k-b remains open. The next slice must carry this exact tokenizer/raw-input
identity into the durable result sink and fresh-process source/target recovery
path, then add a stable package manifest and retained native multi-OS
execution. GPU execution, production model quality, performance, remote
delivery, hostile writers, and physical power-loss persistence are not claimed
by R1k-b1.
