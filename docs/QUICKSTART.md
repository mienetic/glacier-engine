# Quickstart

This guide gets a new contributor from clone to a verified Glacier change
without downloading a model or supplying provider credentials.

## 1. Install prerequisites

- Zig 0.15.0 or newer;
- Python 3.10 or newer;
- Git;
- Xcode command-line tools on macOS when using the Metal backend.

Check the toolchain:

```sh
zig version
python3 --version
```

## 2. Build the portable runtime

```sh
git clone https://github.com/mienetic/glacier-engine.git
cd glacier-engine
zig build -Doptimize=ReleaseSafe -Dmetal=false
./zig-out/bin/glacier --version
```

On macOS, Metal is enabled by default. Keep `-Dmetal=false` while learning the
portable core; remove it when working on the accelerator backend.

Running `./zig-out/bin/glacier` without arguments executes a tiny synthetic
paging smoke test.

## 3. Run model-free architecture demos

Each demo is deterministic, credential-free, and included in `zig build test`.

```sh
# Exact admission and deterministic weighted scheduling
zig build lane-weave-demo -Doptimize=ReleaseSafe -Dmetal=false

# Atomic publication of KV, RNG, sampler state, and output
zig build lane-publication-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build lane-contiguous-demo -Doptimize=ReleaseSafe -Dmetal=false

# Bind a committed checkpoint without embedding its external object payloads
zig build continuation-capsule-demo -Doptimize=ReleaseSafe -Dmetal=false

# Resolve exact tenant-scoped capsule objects under explicit byte/scan limits
zig build continuation-resolver-demo -Doptimize=ReleaseSafe -Dmetal=false

# Build a canonical tenant bundle plan without payload embedding or storage I/O
zig build continuation-bundle-demo -Doptimize=ReleaseSafe -Dmetal=false

# Atomically import, lease, quarantine, and repair in a bounded tenant store
zig build continuation-store-demo -Doptimize=ReleaseSafe -Dmetal=false

# Prove exact reachability and emit a dry-run object collection plan
zig build continuation-collection-demo -Doptimize=ReleaseSafe -Dmetal=false

# Regenerate an approved plan and emit functional sweep prepare/abort roots
zig build continuation-sweep-demo -Doptimize=ReleaseSafe -Dmetal=false

# Sync an exact preview before applying/recovering one retired-set commit
zig build continuation-sweep-commit-demo -Doptimize=ReleaseSafe -Dmetal=false

# Verify a sweep record, classify tails, and exercise scoped crash publication
zig build continuation-sweep-record-demo -Doptimize=ReleaseSafe -Dmetal=false

# Exercise descriptor-relative locking, sync, and six real process deaths
zig build continuation-sweep-file-demo -Doptimize=ReleaseSafe -Dmetal=false

# Recover canonical payload bytes across seven plan/promotion process deaths
zig build continuation-payload-file-demo -Doptimize=ReleaseSafe -Dmetal=false

# Resume one exact next token in a fresh process, then exercise atomic
# whole-checkpoint recovery across seven process-death phases
zig build continuation-live-restart-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build continuation-checkpoint-file-demo -Doptimize=ReleaseSafe -Dmetal=false

# Verify shared image/audio/video identity, exact time, and chunk publication
zig build media-contract-demo -Doptimize=ReleaseSafe -Dmetal=false

# Decode bounded RGB, PCM, and intra-frame video fixtures through sealed plans
zig build media-decode-fixture-demo -Doptimize=ReleaseSafe -Dmetal=false

# Transform the fixtures with exact image/audio/video source mappings
zig build media-transform-demo -Doptimize=ReleaseSafe -Dmetal=false

# Admit, execute, validate, commit/abort, receipt, and release all three media kinds
zig build media-runtime-demo -Doptimize=ReleaseSafe -Dmetal=false

# Give every media buffer an exact LeaseTree owner and retire provisional storage
zig build media-runtime-lease-demo -Doptimize=ReleaseSafe -Dmetal=false

# Append two owned chunks per image/audio/video stream and reject target gaps
zig build media-stream-demo -Doptimize=ReleaseSafe -Dmetal=false

# Checkpoint, release, fresh-Bank restore, and append the next media chunks
zig build media-stream-continuation-demo -Doptimize=ReleaseSafe -Dmetal=false

# Repeat that path across distinct source and target OS processes
zig build media-stream-live-restart-demo -Doptimize=ReleaseSafe -Dmetal=false

# Atomically select complete six-object image/audio/video generations across
# seven SIGKILL boundaries, restore output/cache ownership before visibility,
# then create and resume materialized generation three from a fresh process
zig build media-stream-checkpoint-set-demo -Doptimize=ReleaseSafe -Dmetal=false

# Verify image processor, audio feature-window, video temporal-cache, and sync
# state through two lineage-bound generations
zig build media-processor-state-demo -Doptimize=ReleaseSafe -Dmetal=false

# Verify canonical model-family wires and the cache-bound vision adapter
zig test src/core/model_contract.zig -OReleaseSafe
zig test src/core/vision_encoder_adapter.zig -OReleaseSafe
python3 -m unittest bench.tests.test_model_contract

# Verify signed audio windows through the shared stateless adapter lifecycle
zig test src/core/audio_window_adapter.zig -OReleaseSafe
python3 -m unittest bench.tests.test_audio_window_adapter

# Publish only new transcript text when audio context windows overlap
zig test src/core/audio_transcript_adapter.zig -OReleaseSafe
python3 -m unittest bench.tests.test_audio_transcript_adapter

# Verify charged strided video selection and exact target-timeline binding
zig test src/core/temporal_video_adapter.zig -OReleaseSafe
python3 -m unittest bench.tests.test_temporal_video_adapter

# Publish one source-bound typed video segment transactionally
zig test src/core/video_segment_adapter.zig -OReleaseSafe
python3 -m unittest bench.tests.test_video_segment_adapter

# Merge ordered video segments into one canonical visible timeline
zig test src/core/video_segment_timeline.zig -OReleaseSafe
python3 -m unittest bench.tests.test_video_segment_timeline

# Link newly published transcript samples to the verified video timeline
zig test src/core/audio_video_result_link.zig -OReleaseSafe
python3 -m unittest bench.tests.test_audio_video_result_link

# Restore transcript-model state in a fresh process, publish the next exact
# sample range, and advance its video link without duplicated text
zig test src/core/audio_transcript_continuation.zig -OReleaseSafe
python3 -m unittest bench.tests.test_audio_transcript_continuation
zig build audio-transcript-live-restart-demo \
  -Doptimize=ReleaseSafe -Dmetal=false

# Restore exact VFR video-model state, publish the successor after a declared
# gap, and advance the canonical timeline and cross-modal link
zig test src/core/stateful_video_adapter.zig -OReleaseSafe
zig test src/core/video_model_continuation.zig -OReleaseSafe
python3 -m unittest bench.tests.test_video_model_continuation
zig build video-model-live-restart-demo \
  -Doptimize=ReleaseSafe -Dmetal=false

# Verify one atomic retained-state/result transition
zig test src/core/latent_step_adapter.zig -OReleaseSafe
python3 -m unittest bench.tests.test_stateful_model_adapter

# Restore the intermediate latent in another process and publish step two once
zig build stateful-model-live-restart-demo -Doptimize=ReleaseSafe -Dmetal=false
python3 -m unittest bench.tests.test_stateful_model_continuation

# Provider request, settlement, cost, and durable journal evidence
zig build provider-gateway-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build provider-transport-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build provider-cancel-demo -Doptimize=ReleaseSafe -Dmetal=false

# Lossless context mapping and independently observed token counts
zig build provider-context-pack-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build provider-context-reconciliation-demo -Doptimize=ReleaseSafe -Dmetal=false
zig build provider-context-adapter-demo -Doptimize=ReleaseSafe -Dmetal=false
```

## 4. Run the verification suites

```sh
zig build test -Doptimize=Debug -Dmetal=false
zig build test -Doptimize=ReleaseSafe -Dmetal=false
python3 -m unittest discover -s bench/tests
```

Before submitting a runtime change, also run:

```sh
zig build test -Doptimize=ReleaseFast -Dmetal=false
zig build test -Doptimize=ReleaseSafe -Dmetal=false -Dsanitize-thread=true
zig build test-compile -Dtarget=x86_64-linux-gnu -Dmetal=false -Doptimize=ReleaseSafe
zig build test-compile -Dtarget=aarch64-linux-gnu -Dmetal=false -Doptimize=ReleaseSafe
```

ThreadSanitizer support depends on the host Zig/Clang toolchain. If the toolchain
cannot run it, record that limitation rather than reporting it as passed.

## 5. Try the CLI with a fixture

Generate a small synthetic Safetensors file and convert it to the draft Glacier
model format:

```sh
./zig-out/bin/glacier gen-fixture /tmp/glacier-fixture.safetensors
./zig-out/bin/glacier convert /tmp/glacier-fixture.safetensors /tmp/glacier-fixture.glacier
./zig-out/bin/glacier info /tmp/glacier-fixture.glacier
```

For an INT4 fixture:

```sh
./zig-out/bin/glacier convert --int4 --group-size 64 \
  /tmp/glacier-fixture.safetensors /tmp/glacier-fixture-int4.glacier
```

The synthetic fixture exercises parsing and conversion. It is not a useful
language model and does not establish generation quality.

## 6. Prepare a native runtime image

The `.glacier` file is the portable draft source format. `.glrt` is a derived,
execution-layout-bound runtime image:

```sh
./zig-out/bin/glacier prepare \
  /tmp/glacier-fixture-int4.glacier /tmp/glacier-fixture.glrt
```

Read [Native runtime image](RUNTIME_IMAGE.md) before changing its ABI.

## 7. Make a first contribution

Pick one item from [Contributor projects](PROJECTS.md). Add or update a rejection
test before changing the contract, run the smallest relevant suite, and open a
draft pull request early. The [Contributing guide](CONTRIBUTING.md) explains the
full verification matrix.

## Troubleshooting

### Metal build fails

Retry with `-Dmetal=false`. If the portable build succeeds, include the macOS,
Xcode, and device versions in a Metal-specific issue.

### Build cache behaves unexpectedly

Remove only the repository-local `.zig-cache` and `zig-out` directories, then
rebuild. Do not delete shared toolchain or model directories.

### A benchmark number looks surprising

Do not compare isolated point estimates. Retain the raw artifact, machine
envelope, paired order, correctness result, and thermal/power limitations. See
[Benchmark and evidence guide](BENCHMARKS.md).
