# Ordinary Model Package

Status: **experimental CPU vertical slice with process-local execution and a
one-token POSIX durable route**.

Glacier can turn one supported Safetensors model into a portable model
container, a prepared runtime image, and a fixed package manifest:

```sh
./zig-out/bin/glacier package-model \
  source.safetensors \
  out.glacier \
  out.glrt \
  out.glpkg \
  --license LICENSE \
  --group-size 64
```

The current profile is deliberately narrow: autoregressive Safetensors,
INT4 conversion, a separate-layout GLRT V2 image, and the exact
`utf8-byte-v1` tokenizer. The tokenizer accepts at most 4,096 input bytes and
requires a vocabulary large enough to represent every byte. `--group-size N`
is optional and defaults to 64. Broader tokenizer behavior, source formats,
model families, quantization modes, and GPU package production remain roadmap
work.

The command performs no network access. It does not download a model,
tokenizer, license, or runtime component.

## Produced artifacts

The three outputs have distinct roles:

- `out.glacier` is the portable converted model container.
- `out.glrt` is the prepared representation used by the current CPU runtime.
  It is architecture and preparation specific.
- `out.glpkg` is one fixed 896-byte admission bundle: the 640-byte
  request-independent `ManifestV1` followed immediately by the 256-byte
  `PreparedRepresentationV1` for the exact `out.glrt`. It is admission evidence,
  not a model-data archive.

The 640-byte manifest binds:

- source size and SHA-256 identity;
- portable container size, page count, format ABI, and SHA-256 identity;
- exact conversion-profile and conversion-plan identities;
- resolved model geometry and configuration;
- a derived model-content identity;
- exact tokenizer manifest/configuration/behavior identities; and
- the license byte count and SHA-256 identity.

The 640-byte manifest excludes the license payload, prompt bytes, token IDs,
output limit, request and Scheduler epochs, native prepared bytes, and runtime
state. Those exclusions keep its `package_sha256` root portable and stable
across requests. The following 256-byte receipt pins one exact prepared
container hash, size, format ABI/version, source fingerprint, and resolved
configuration relationship. Another valid prepared representation needs
another 896-byte bundle, but can retain the same request-independent package
root.

The producer report makes this framing explicit:

| Field | Value |
| --- | --- |
| `package_bytes` | `896` |
| `package_manifest_bytes` | `640` |
| `prepared_representation_bytes` | `256` |
| `prepared_representation_embedded` | `true` |
| `prepared_representation_separate` | `false` |

The manifest and prepared-representation receipt use hashes for integrity and
content identity. They are not signatures and do not prove publisher
authenticity, model authorship, licensing rights, safety, or model quality.
Applications that need trusted origin must add their own authenticated
distribution and policy layer.

## Production and publication boundary

The producer consumes the typed durable conversion receipt directly in the
same process. It does not accept conversion hashes through command-line flags
or recover them from rendered output. It then:

1. reopens and fully validates the converted portable container;
2. derives the complete configuration and tokenizer identities;
3. prepares and reopens the GLRT image;
4. derives the prepared representation from the actual image, including its
   format version, ABI fingerprint, source fingerprint, configuration, layout,
   size, and container hash;
5. revalidates the portable path and exact license bytes; and
6. publishes the 896-byte manifest-plus-representation bundle last.

On a retry, the portable conversion and an exact existing `.glpkg` may report
`already_current`. The prepared `.glrt` is deterministically recreated and
revalidated; the command does not promise that every artifact inode, timestamp,
or byte-writing operation is unchanged across the whole retry. A pre-existing
different observed bundle is a conflict instead of being overwritten when all
publishers cooperate with the directory-scoped lock. The package write uses a
private candidate, file synchronization, atomic replacement, and
parent-directory synchronization on the current POSIX path. A non-cooperating
hostile process with namespace-write authority is outside this no-overwrite
claim. This is host-filesystem protocol evidence, not a hostile-directory,
physical power-loss, or remote-filesystem guarantee, and the three outputs are
not one cross-file atomic transaction.

Output paths must not alias the source, license, or each other. File-backed
license, package, and prompt inputs use bounded regular-file admission on
supported POSIX hosts. Symlinks and non-regular files are rejected, reads are
nonblocking and size bounded, and descriptor metadata is checked again after
the positional read. This boundary reduces path substitution and accidental
blocking; it is not a hostile-directory security claim.

`package-model` currently derives configuration from the converted model and
does not read an ambient `<output>.json` sidecar for any output. It has no
`--config` option. A future explicit configuration input must use the same
bounded, no-follow, stable regular-file boundary before it can affect package
identity.

## Admission and execution

Use the package with its prepared image:

```sh
./zig-out/bin/glacier text-run out.glrt \
  --text "Hello" \
  --license LICENSE \
  --package out.glpkg \
  --n 4
```

`text-run --package` decodes the fixed 896-byte bundle, reconstructs the
supported tokenizer profile, verifies the supplied license bytes, loads the
prepared image, and derives its representation identity from the image rather
than trusting caller-supplied hashes. Admission compares that identity to the
embedded 256-byte receipt, including the exact container hash and size, format
ABI/version, source fingerprint, package/configuration roots, and separate
layout. A different prepared representation, even for the same portable
package root, needs its own matching bundle.

The normal `1..64` output route returns token IDs in deterministic JSON and
publishes transactionally in process.

The package-aware durable route currently supports exactly one output token:

```sh
mkdir -m 700 /tmp/glacier-package-run

./zig-out/bin/glacier text-run out.glrt \
  --text "Hello" \
  --license LICENSE \
  --package out.glpkg \
  --n 1 \
  --durable-dir /tmp/glacier-package-run \
  --request-id 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
```

This route creates or recovers the existing sink-free generation-one
checkpoint, advances or replays its generation-two terminal selection, closes
runtime ownership, and renders the selector-rechecked view. It omits the token
payload unless `--reveal-output` is explicit; exposed roots remain metadata,
not a confidentiality boundary. Choose and externally retain a new
`--request-id` per logical request, then reuse that exact ID only for
continuation or retry. Use one initially empty private directory per request;
once selected, it has no in-place reset or cleanup command. `--bootstrap-only`
makes generation one an intentional process boundary; the same command without
that flag can continue in a fresh process. Exact terminal retries return
`already_selected`.

The command does not yet expose the acknowledged source/target chain for
counts `2..64`, render general tokenizer text, or provide a serving API.

## Verification workflow

For ordinary changes, start with path-aware verification:

```sh
tools/verify.sh affected-fast --base origin/main
```

Changes confined to the package producer, package-aware `text-run`, bounded
input helper, or independent package oracle select the existing focused
`text-runtime-golden-path-test` DAG. That gate exercises production, portable
and package `already_current` dispositions, deterministic prepared-image
recreation, independent Python decoding, process-local admission, distinct
processes for durable bootstrap/resume/retry, direct checkpoint/output-wire
decoding, package mutation, changed-license rejection, and
embedded-receipt/prepared-image substitution rejection without compiling the
broad runtime and foreign-target suites.

Run `tools/verify.sh full` or the deeper platform matrices at integration,
release, shared-ABI, or cross-platform boundaries. The focused route is a
development-time compile reduction, not a replacement for those promotion
gates.

## Roadmap boundary

This slice establishes ordinary model package production, exact process-local
admission, and checked durable one-token continuation for one narrow CPU
profile. The next text-runtime milestone is to expose the existing acknowledged
source/target chain for package-aware fixed output counts `2..64` without
duplicating its recovery protocol.

Still open:

- broader tokenizers, model families, source formats, and numerical profiles;
- an explicit bounded/no-follow `--config` input instead of ambient sidecar
  discovery;
- GPU/device package preparation and execution evidence;
- native non-POSIX package production and durable recovery;
- signed provenance and authenticated distribution;
- acknowledged multi-token durable rendering and serving integration;
- exhaustive storage-fault and physical power-loss campaigns; and
- production-model quality, compatibility, performance, and stability claims.
