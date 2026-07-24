# Language interop

Glacier's first non-Zig library boundary is an **experimental, allocation-free
C ABI** for Model Contract V1 verification. C can call it directly, while
Python, Rust, and other languages can use their normal C foreign-function
interface.

This first slice is deliberately narrow. It verifies a canonical artifact
manifest, execution plan, and result envelope as one bound chain. It does not
load model weights, run inference, create a session, invoke a backend, or make
the wider runtime API stable.

## Build without retaining a large Zig cache

On macOS, Linux, or another POSIX shell:

```sh
tools/zig-with-ephemeral-cache.sh build contract-c \
  -Doptimize=ReleaseSafe -Dmetal=false -j2
```

The wrapper creates a private temporary local/global Zig cache, prints its
final size after the command, validates the cleanup path, and removes that
exact cache even when the command fails. Installed outputs remain in
`zig-out/`:

- `zig-out/include/glacier/model_contract.h`;
- `zig-out/lib/libglacier_contract.dylib` on macOS;
- `zig-out/lib/libglacier_contract.so` on Linux;
- `zig-out/bin/glacier_contract.dll` plus its import library on Windows;
- a separately named `glacier_contract_static` archive, avoiding a Windows
  import-library name collision.

The wrapper does not impose a live filesystem quota. Keep builds focused and
check free disk space before larger target matrices. It also manages only
compiler caches: model mappings, weight mirrors, request KV, device memory, and
OS page cache are separate runtime resources.

Normal failures and handled `HUP`, `INT`, or `TERM` stop the Zig child before
cleanup. `SIGKILL`, power loss, or a host crash cannot run shell cleanup and may
leave one `glacier-zig-cache.*` directory under the printed temporary parent.

To retain Zig's normal incremental cache instead, run the same build without
the wrapper:

```sh
zig build contract-c -Doptimize=ReleaseSafe -Dmetal=false
```

That direct command is also the native Windows PowerShell/Command Prompt build
path; the ephemeral-cache helper is POSIX-only.

## Verify the boundary

The focused gate compiles the libraries, runs Zig fail-closed tests, links
independent C11 consumers against both the build graph and staged install tree,
checks the C++ header/link path, regenerates the fixtures with the independent
Python oracle, and loads the shared library from a fresh Python process:

```sh
tools/zig-with-ephemeral-cache.sh build contract-interop-test \
  -Doptimize=ReleaseSafe -Dmetal=false -j2
```

It uses three tiny text fixtures under `examples/interop/fixtures/`; no model
download, package installation, provider credential, or language dependency
cache is required.

## Python quick start

Python uses only the standard library:

```sh
python3 examples/interop/python_verify.py
```

Pass explicit locations when running outside the repository root:

```sh
python3 examples/interop/python_verify.py \
  --library /absolute/path/to/libglacier_contract.dylib \
  --fixtures /absolute/path/to/examples/interop/fixtures
```

Use `.so` on Linux or `.dll` on Windows. A successful run prints the
experimental ABI number and the authenticated result root.

## Rust quick start

The Rust example has no crate dependencies or Cargo cache:

```sh
rustc examples/interop/rust_verify.rs \
  -L native=zig-out/lib \
  -o /tmp/glacier-contract-rust
DYLD_LIBRARY_PATH=zig-out/lib /tmp/glacier-contract-rust
```

On Linux, use `LD_LIBRARY_PATH` instead of `DYLD_LIBRARY_PATH`. On Windows,
compile with `-L native=zig-out/lib` and place `zig-out/bin` on `PATH` before
running the executable. These Windows instructions require matching Zig/Rust
target ABIs and remain guidance until a native Windows consumer gate exists.

When `rustc` is on `PATH`, macOS, Linux, and FreeBSD hosts can run the named
native gate:

```sh
tools/zig-with-ephemeral-cache.sh build contract-rust-test \
  -Doptimize=ReleaseSafe -Dmetal=false -j2
```

## C surface

The installed header exports exactly two functions:

```c
uint64_t glacier_contract_abi_v1(void);

uint32_t glacier_model_contract_verify_v1(
    const uint8_t *artifact_wire,
    size_t artifact_wire_size,
    const uint8_t *plan_wire,
    size_t plan_wire_size,
    const uint8_t *result_wire,
    size_t result_wire_size,
    uint8_t out_result_root[32]);
```

The verifier:

- accepts only the exact 320-byte artifact, 768-byte plan, and 768-byte result
  V1 encodings;
- verifies each wire's magic, ABI, reserved bytes, dimensions, semantic
  constraints, and authenticated root;
- verifies every artifact-to-plan and plan-to-result field carried by the
  canonical constructors;
- allocates no memory and retains no input pointer;
- writes the authenticated result root on success;
- zeroes the output root on every failure when the output pointer is present.

Validation finishes before the output write, so the output may point to the
final 32 bytes of the result wire for a zero-copy root check.

Status values are fixed unsigned integers:

| Value | Meaning |
| ---: | --- |
| `0` | valid chain |
| `1` | null argument |
| `2` | wrong wire length |
| `3` | invalid artifact |
| `4` | invalid plan |
| `5` | invalid result |
| `6` | individually valid wires do not bind to one chain |

See
[`include/glacier/model_contract.h`](../include/glacier/model_contract.h) for
the authoritative declarations and
[`tests/model_contract_c_consumer.c`](../tests/model_contract_c_consumer.c) for
a complete C consumer. Windows consumers linking
`glacier_contract_static.lib` must define
`GLACIER_MODEL_CONTRACT_STATIC=1` before including the header.

## Stability and next steps

The header defines `GLACIER_MODEL_CONTRACT_EXPERIMENTAL`. ABI V1 describes this
small verifier surface only; it is not a promise that the wider runtime is
stable. Before promotion, Glacier still needs an API/deprecation policy,
retained symbol and layout checks, native consumer evidence on each claimed OS,
packaging metadata, and migration fixtures.

Model/session handles, token streaming, callbacks, asynchronous execution,
allocator injection, Python wheels, and a safe Rust crate remain later slices.
They should follow the runtime's supported-library boundary instead of exposing
compiler-specific Zig layouts prematurely.
