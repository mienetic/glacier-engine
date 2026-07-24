# Runtime Support Registry and Inspector

Status: **experimental retained-reference registry**.

Glacier exposes one deterministic, read-only view of the model-family contract
profiles exercised by repository fixtures. The registry answers a narrow
question:

> Does this typed request shape fit one or more retained exact-integer reference
> profiles?

It does not discover hardware or execute a request. Registration is not
execution.

## Inspect the registry

On a POSIX shell, prefer the bounded-cache wrapper:

```sh
tools/zig-with-ephemeral-cache.sh build runtime-support-inspector \
  -Doptimize=ReleaseSafe -Dmetal=false -j2
```

The equivalent direct command is:

```sh
zig build runtime-support-inspector -Doptimize=ReleaseSafe -Dmetal=false
```

The command prints one newline-terminated JSON object to standard output. It
accepts no semantic arguments, reads no model, and performs no host or backend
probe. Repeated runs of the same source revision produce the same byte sequence.
The top-level object contains:

- `schema`: `glacier.runtime-support-registry/v1`;
- `registry_abi`: a fixed-width hexadecimal registry identifier;
- `production_model_support`: always `false` in this schema;
- `host_backend_probed`: always `false` in this schema;
- `claim_scope`: `retained_reference_fixture_contracts`;
- `profile_count` and `max_profiles`; and
- `profiles`, in immutable index order.

Each profile carries a human-readable slug, its adapter-profile ABI, lifecycle,
evidence class, typed family/operation/input/output/numerical fields, maximum
dimensions, and allowed capability mask. Both names and numeric IDs are emitted
for the typed fields so a human can read the output while a tool can compare
fixed values.

The focused test checks valid JSON, byte-for-byte deterministic rendering,
newline behavior, profile order, and the negative production/host-probe flags.
An independent standard-library Python oracle hard-codes the public V1 document
and compares the executable's stdout exactly, including field order and the
terminating newline:

```sh
tools/zig-with-ephemeral-cache.sh build runtime-support-inspector-test \
  -Doptimize=ReleaseSafe -Dmetal=false -j2
```

## Retained profiles

Registry V1 currently contains eight profiles:

| Index | Slug | Lifecycle | Contract shape |
| ---: | --- | --- | --- |
| 0 | `vision-encoder-reference` | stateless | vision encode: image u8 features → i32 embedding |
| 1 | `audio-window-reference` | stateless | audio encode: i16 features → i32 embedding |
| 2 | `audio-transcript-reference` | stateless | audio transcribe: i16 features → transcript |
| 3 | `stateful-transcript-reference` | stateful | audio transcribe: i16 features → transcript |
| 4 | `temporal-video-reference` | stateless | video encode: video u8 features → i32 embedding |
| 5 | `video-segment-reference` | stateless | video segment: video u8 features → typed video segment |
| 6 | `stateful-video-reference` | stateful | video segment: video u8 features → typed video segment |
| 7 | `latent-step-reference` | stateful | image diffuse step: latent tensor → media chunk |

All eight rows have evidence class
`retained_reference_fixture`, numerical policy `exact_integer`, and no allowed
ambient capability. Their exact bounds come from the adapter support constants;
the registry does not maintain a second handwritten copy.

A profile index is also its bit position in a query result. Existing V1 indices
must not be reordered, removed, or repurposed. A new profile is appended, up to
the 64-bit mask limit. Compile-time checks enforce contiguous indices, unique
slugs and profile ABIs, nonzero bounds, and complete coverage of the adapter
support rows included by this registry.

## Query semantics

The typed query contains:

- family, operation, input kind, output kind, and numerical policy;
- nonzero `batch_items`, `input_features`, and `output_dimensions`; and
- a `required_capabilities` bit mask.

A profile matches only when every typed field is equal, each requested
dimension is less than or equal to that profile's maximum, and:

```text
required_capabilities & ~allowed_capabilities == 0
```

The registry scans every row. Therefore one query can return multiple bits; for
example, a small transcript shape can fit both the stateless and stateful
transcript reference profiles. `matching_profile_mask` is the complete set,
not a selected implementation. Callers choose no backend and receive no
execution handle.

For a valid query:

- one or more matching bits produce `compatible = 1` and unsupported reason
  `NONE`;
- no matching bits produce `compatible = 0` and one diagnostic reason;
- a zero dimension is unsupported with reason `DIMENSIONS`; and
- capability bits not allowed by a matching contract shape produce reason
  `CAPABILITIES`.

When nothing matches, the diagnostic is the deepest comparison stage reached
by any scanned profile: family, operation, input kind, output kind, numerical
policy, dimensions, then capabilities. It explains the most specific mismatch
found by the registry search; it does not identify a preferred profile or
prove that any executable implementation exists.

The C boundary additionally rejects unknown numeric enum values as
`GLACIER_MODEL_CONTRACT_INVALID_QUERY`. That is an ABI error, distinct from a
well-formed but unsupported query, which returns
`GLACIER_MODEL_CONTRACT_OK` with `compatible = 0`.

## C, Python, and Rust

Build the experimental shared/static libraries and installed header:

```sh
tools/zig-with-ephemeral-cache.sh build contract-c \
  -Doptimize=ReleaseSafe -Dmetal=false -j2
```

The C header exposes four registry operations alongside Model Contract
verification:

```c
uint64_t glacier_model_support_registry_abi_v1(void);

uint64_t glacier_model_support_profile_count_v1(void);

uint32_t glacier_model_support_profile_get_v1(
    uint64_t index,
    glacier_model_support_profile_v1_t *out_profile,
    size_t out_profile_size);

uint32_t glacier_model_support_query_v1(
    const glacier_model_support_query_v1_t *query,
    size_t query_size,
    glacier_model_support_result_v1_t *out_result,
    size_t out_result_size);
```

The registry ABI function lets a caller compare the library to the JSON
`registry_abi`. The profile getter copies fixed-width values into caller-owned
storage. The query writes `compatible`, `unsupported_reason`, and the full
matching mask. Both output-writing functions require exact V1 structure sizes,
allocate no memory, retain no pointer, and zero a correctly sized output before
any later failure.

The standard-library Python example declares the same structures with
`ctypes`; the dependency-free Rust example uses `#[repr(C)]` structures and
`extern "C"`. Both validate the registry ABI, enumerate all eight profiles, and
make supported and capability-rejected queries in addition to verifying the
canonical contract chain. Their final summary contains
`profile_count=8 transcript_mask=0x000000000000000c`:

```sh
python3 examples/interop/python_verify.py

rustc examples/interop/rust_verify.rs \
  -L native=zig-out/lib \
  -o /tmp/glacier-contract-rust
DYLD_LIBRARY_PATH=zig-out/lib /tmp/glacier-contract-rust
```

Use `LD_LIBRARY_PATH` on Linux. See
[Language interop](LANGUAGE_INTEROP.md) for platform-specific library paths,
status values, and the named cross-language gates.

## Fixture-authoring guide

Registry rows are derived evidence, not a shortcut for introducing a family.
Add a retained profile in this order:

1. Implement a bounded adapter fixture with deterministic accepted output,
   rejection paths, explicit resource ownership, and no external model
   download.
2. Define its `SupportRecordV1` beside the adapter. Set exact typed fields,
   conservative nonzero maxima, numerical policy, and only the capabilities
   the fixture actually exercises.
3. Retain adapter tests proving the declared boundary: maximum accepted values,
   first rejected values, malformed input, candidate drift, abort behavior,
   publication behavior, and exact release where applicable.
4. Append one new `ProfileIndexV1` and registry row. Never change an existing
   index, slug, profile ABI, or meaning.
5. Extend the C constants and mask, language consumers, expected profile count,
   query-mask tests, and deterministic inspector tests.
6. Run the focused native tests and compile-only target gates before describing
   broader portability:

   ```sh
   tools/zig-with-ephemeral-cache.sh build runtime-support-inspector-test \
     -Doptimize=ReleaseSafe -Dmetal=false -j2
   tools/zig-with-ephemeral-cache.sh build contract-interop-test \
     -Doptimize=ReleaseSafe -Dmetal=false -j2
   tools/zig-with-ephemeral-cache.sh build contract-c-compile \
     -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe -Dmetal=false -j2
   tools/zig-with-ephemeral-cache.sh build contract-c-compile \
     -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe -Dmetal=false -j2
   tools/zig-with-ephemeral-cache.sh build contract-c-compile \
     -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe -Dmetal=false -j2
   tools/zig-with-ephemeral-cache.sh build contract-c-compile \
     -Dtarget=x86_64-freebsd -Doptimize=ReleaseSafe -Dmetal=false -j2
   ```

Document the fixture's accepted inputs, maximum logical resources, authority,
failure paths, evidence command, and nonclaims in the same change. If a row
cannot be traced to retained adapter tests, it does not belong in this
registry.

## What this does not claim

The registry and inspector cover only the eight retained exact-integer reference
fixtures listed above. They make no claim about:

- a production model or checkpoint;
- model loading, weight containers, or tokenizers;
- CPU or GPU execution, placement, or the current host;
- native support for any operating system;
- output quality or correctness outside the retained fixtures;
- throughput, latency, memory use, cache size, or energy use; or
- the ability to execute a registered shape.

Cross-compilation shows that a source surface compiles for a target; it does not
turn a registry row into native execution evidence. Production, platform,
backend, quality, and performance promotion each require their own retained
evidence.
