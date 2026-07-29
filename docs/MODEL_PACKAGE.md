# Ordinary Model Package

Status: **experimental CPU vertical slice with fixed-result and bounded
early-EOS process-local execution plus a fixed-output POSIX durable route**.

Glacier can turn one supported Safetensors model into a portable model
container, a prepared runtime image, and a fixed package manifest:

```sh
./zig-out/bin/glacier package-model \
  source.safetensors \
  out.glacier \
  out.glrt \
  out.glpkg \
  --license LICENSE \
  --config config.json \
  --experimental-profile ordinary-package-v1 \
  --group-size 64
```

The current profile is deliberately narrow and must be selected explicitly
with `--experimental-profile ordinary-package-v1`. It admits autoregressive
Safetensors, exact F32 source tensors, MHA geometry, untied embeddings, no
bias or extra tensors, INT4 conversion, a separate-layout GLRT V2 image, and
the exact `utf8-byte-v1` tokenizer. `--config FILE` is required; the selected
path never derives geometry from converted tensors or discovers an ambient
sidecar. The tokenizer accepts at most 4,096 input bytes and requires a
vocabulary large enough to represent every byte. `--group-size N` is optional
and defaults to 64; the selected conversion geometry accepts powers of two
from 1 through 128. Other values reject before source or output namespace
mutation. Broader tokenizer behavior, source formats, model
families, numerical profiles, and GPU package production remain roadmap work.

An explicit config is a complete JSON configuration object. It accepts the
canonical/ecosystem pairs `dim`/`hidden_size`,
`hidden_dim`/`intermediate_size`, `num_layers`/`num_hidden_layers`,
`num_heads`/`num_attention_heads`, `num_kv_heads`/`num_key_value_heads`, and
`rms_eps`/`rms_norm_eps`, plus `vocab_size`, `head_dim`, `rope_theta`, and
`tie_word_embeddings`. Supply this narrow contract as a dedicated package
config; unrecognized fields reject because they may carry execution semantics
that the current profile does not bind. Duplicate keys, wrong recognized
types, non-positive or out-of-range numbers,
conflicting aliases, incomplete logical configuration, and inconsistent
supplied head geometry reject. `head_dim` is the only optional logical field:
exact `dim / num_heads` derives it. The resulting complete configuration is
checked against the source tensor inventory before conversion can mutate the
output namespace.

The admitted tensor inventory is exact:

- globals: `model.embed_tokens.weight [vocab, dim]`,
  `model.norm.weight [dim]`, and `lm_head.weight [vocab, dim]`;
- every contiguous layer `0..layers-1`: input norm, Q/K/V/O projections,
  post-attention norm, gate/up projections, and down projection with the
  profile-defined ranks and orientation; and
- canonical names and F32 dtype only, with no aliases, biases, duplicate
  roles, missing layers, or extra tensors.

Equal-element-count substitutions do not bypass admission: rank and every
extent are checked, so a transposed non-square matrix is rejected.

The command performs no network access. It does not download a model,
tokenizer, license, or runtime component.

## Produced artifacts

The three outputs have distinct roles:

- `out.glacier` is the portable converted model container.
- `out.glrt` is the prepared representation used by the current CPU runtime.
  It is architecture and preparation specific.
- `out.glpkg` is one fixed 896-byte admission bundle: the 640-byte
  request-independent `ManifestV2` followed immediately by the 256-byte
  `PreparedRepresentationV1` for the exact `out.glrt`. It is admission evidence,
  not a model-data archive.

`ManifestV2` has a distinct wire ABI, `GLPKG02` magic, and package-root
domain. It activates the model/tensor-profile extension bytes that were
reserved in V1. V1 packages and durable raw-input archives are intentionally
rejected rather than guessed or upgraded in place. Re-run `package-model` and
start a fresh durable request directory; an already selected request directory
has no in-place migration path.

The 640-byte manifest binds:

- source size and SHA-256 identity;
- portable container size, page count, format ABI, and SHA-256 identity;
- exact conversion-profile and conversion-plan identities;
- the explicitly selected model-profile ABI, ID, and identity root;
- the exact tensor-profile ABI, count, and canonical inventory root;
- resolved model geometry and configuration;
- a derived model-content identity that joins the portable artifact,
  conversion profile/plan, model profile, tensor inventory, and resolved
  configuration;
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
| `model_profile` | `ordinary-package-v1` |
| `experimental_profile_explicit` | `true` |
| `model_profile_abi`, `model_profile_id`, `model_profile_sha256` | exact selected-profile identity |
| `tensor_profile_abi`, `tensor_count`, `tensor_inventory_sha256` | exact admitted source inventory identity |
| `tensor_inventory_verified` | `true` |
| `config_source` | `explicit` |
| `config_input_bytes` | raw config-input size |
| `config_input_sha256` | raw config-input SHA-256 |
| `resolved_config_sha256` | canonical resolved configuration identity |

The manifest and prepared-representation receipt use hashes for integrity and
content identity. They are not signatures and do not prove publisher
authenticity, model authorship, licensing rights, safety, or model quality.
Applications that need trusted origin must add their own authenticated
distribution and policy layer.

## Production and publication boundary

The producer consumes the typed durable conversion receipt directly in the
same process. It does not accept conversion hashes through command-line flags
or recover them from rendered output. Before conversion it admits the license
and required explicit config through bounded stable regular-file reads and
strictly parses the config. It then:

1. captures the source once through a no-follow descriptor, validates the
   exact tensor schema on that same descriptor, and revalidates source identity
   before borrowing the output directory or creating a lock/candidate;
2. converts, reopens, and fully validates the portable container;
3. resolves the explicit configuration and tokenizer identities;
4. prepares and reopens the GLRT image;
5. derives the prepared representation from the actual image, including its
   format version, ABI fingerprint, source fingerprint, configuration, layout,
   size, and container hash;
6. revalidates the portable path, exact license bytes, and exact explicit
   config bytes; and
7. publishes the 896-byte manifest-plus-representation bundle last.

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

Output paths must not alias the source, license, explicit config, or each
other. File-backed license, config, package, and prompt inputs use bounded
regular-file admission on supported POSIX hosts. Config input is limited to
1 MiB. Symlinks and non-regular files are rejected, reads are nonblocking and
size bounded, and descriptor metadata is checked again after the positional
read. This boundary reduces path substitution and accidental blocking; final
component no-follow is not a hostile-parent-directory security claim.

The raw config size and hash are report provenance, not an additional
artifact root. The existing canonical `resolved_config_sha256` participates in
the model-content, package, and prepared-representation relationships.
Formatting- or alias-equivalent JSON therefore converges on the same artifact
identity while its raw report provenance may differ. Omitting `--config`
rejects; an ambient `<output>.json` is never consulted.

Syntax, type, completeness, range, alias, and internal head-geometry failures
reject before conversion. Unknown profiles and tensor name/dtype/rank/shape
mismatches reject before the portable publisher creates its directory lock,
candidate, or target. The three output files are not one atomic transaction.

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

Add `--eos-token ID` to make `--n` a process-local upper bound. A sampled EOS
before that bound returns the exact prefix with canonical completed-early
evidence and releases the unused scheduler quota; an EOS miss reaches `--n`
and retires normally. EOS exactly at `--n` is reported separately as
`eos_at_limit` and retires because no quota remains. The fixed-result route
remains the default. This option cannot be combined with durable arguments.

The package-aware durable route supports fixed output counts `1..64`:

```sh
mkdir -m 700 /tmp/glacier-package-run

./zig-out/bin/glacier text-run out.glrt \
  --text "Hello" \
  --license LICENSE \
  --package out.glpkg \
  --n 4 \
  --durable-dir /tmp/glacier-package-run \
  --request-id 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
```

Count one selects the sink-free direct-terminal route. Counts `2..64` select
the acknowledged source/target route with result-sink capacity `N - 1`. Both
routes close runtime ownership before rendering selector-rechecked committed
output and omit token payloads unless `--reveal-output` is explicit; exposed
roots remain metadata, not a confidentiality boundary.

Choose and externally retain a new `--request-id` per logical request, then
reuse that exact ID only for continuation or retry. Use one initially empty
private directory per request; once selected, it has no in-place reset or
cleanup command. `--bootstrap-only` makes generation one an intentional
process boundary; the same command without that flag can continue in a fresh
process. The acknowledged request challenge binds the exact output count in
addition to request, package, representation, license, and raw-input identity.
An exact terminal retry returns `already_terminal`; a changed count or other
bound input rejects before mutation. The direct count-one retry remains
`already_selected`.

The command does not yet render general tokenizer text, support
variable-length or early-EOS durable output, or provide a serving API.

## Verification workflow

For ordinary changes, start with path-aware verification:

```sh
tools/verify.sh affected-fast --base origin/main
```

Changes confined to the package producer, package-aware `text-run`,
process-local variable-terminal lifecycle, bounded input helper, or independent
package oracle or strict tensor-profile module select the existing focused
`text-runtime-golden-path-test` DAG. That gate exercises production, portable
and package `already_current` dispositions, deterministic prepared-image
recreation, required explicit-profile/config admission, canonical config retry,
ambient-sidecar isolation, exact tensor-schema rejection before namespace
mutation, bounded-input rejection, independent Python
decoding, process-local admission, distinct
processes for durable bootstrap/resume/retry, direct checkpoint/output-wire
decoding, acknowledged `N=2`, `N=4`, and `N=64` checkpoint/sink lineage
decoding, output-count mismatch rejection without mutation, equality with
ordinary execution, deterministic in-vocabulary EOS hit/miss evidence,
durable-EOS no-mutation rejection, package mutation, changed-license rejection,
and embedded-receipt/prepared-image substitution rejection without compiling
the broad runtime and foreign-target suites.

The complete `affected` tier additionally compiles the selected retained
host-tool portability profiles. Run `tools/verify.sh full` or the deeper
platform matrices at integration, release, shared-ABI, or cross-platform
boundaries. The focused route is a development-time compile reduction, not a
replacement for those promotion gates.

## Roadmap boundary

This slice establishes ordinary model package production, exact process-local
admission with an optional bounded early-EOS terminal, and checked fixed-output
durable continuation for `1..64` tokens on one narrow CPU/POSIX profile. The
next text-runtime boundaries are durable variable-length completion, serving
integration, and broader tokenizer/model/device profiles without weakening
package admission or recovery lineage.

Still open:

- broader tokenizers, model families, source formats, and numerical profiles;
- separately named and evidenced GQA, tied-embedding, bias, F16, and BF16
  profiles;
- GPU/device package preparation and execution evidence;
- native non-POSIX package production and durable recovery;
- signed provenance and authenticated distribution;
- variable-length or early-EOS durable output, general tokenizer rendering,
  and serving integration;
- exhaustive storage-fault and physical power-loss campaigns; and
- production-model quality, compatibility, performance, and stability claims.
