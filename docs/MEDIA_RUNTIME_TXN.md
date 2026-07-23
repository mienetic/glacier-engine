# Media Runtime Transaction

Glacier's first complete model-free media runtime vertical joins deterministic
image, audio, and video transforms to exact `ResourceBank` admission and atomic
media publication. It turns the earlier contracts into one lifecycle:

```text
inspect sealed plan
        │
        ▼
derive exact Claim ──reserve/commit──> bind publication session
        │
        ▼
execute transform into caller-owned provisional buffers
        │
        ├─ fail/abort ──> abort permit + scrub provisional bytes
        │
        ▼
reverify output + every mapping + transform receipt
        │
        ▼
prepare timeline/output/resource publication
        │
        ▼
revalidate Bank permit + candidate + prior media state
        │
        ▼
commit media state + Bank publication fence
        │
        ▼
close session + release exact Claim to zero
```

This is an AI Runtime integration prototype, not a media-model implementation.
The retained executors still operate only on tiny canonical fixtures.

## Exact admission

`claimForExecutionV1` derives one closed resource claim from the sealed
transform plan and exact fixture length:

| Claim field | Derivation |
| --- | --- |
| Capsule bytes | 416-byte decode plan + 512-byte transform plan |
| Activation bytes | Exact decoded source bytes |
| Output journal bytes | Exact transformed output bytes |
| Staging bytes | 128 bytes per exact output mapping + declared scratch |
| I/O bytes | Exact encoded fixture length |
| Queue slots | One |
| KV, partial, logits, device | Zero for this model-free slice |

The claim is admitted before transform execution. A hard-cap rejection does not
leave a reservation, publication session, output mutation, or accounting delta.
The current three fixtures retain these claims:

| Kind | Activation | Output | Staging | I/O | Host-byte total |
| --- | ---: | ---: | ---: | ---: | ---: |
| Image | 12 | 12 | 512 | 364 | 1,464 |
| Audio | 32 | 4 | 256 | 384 | 1,220 |
| Video | 8 | 4 | 128 | 360 | 1,068 |

`ResourceBank.hostBytes` excludes the separately accounted I/O and queue-slot
fields. The demo therefore reports 3,752 total admitted host bytes, not total
process memory. No RSS or physical-residency claim follows from these logical
counters.

## Session and transaction invariants

One `Session` owns one admitted transform-plan/fixture pair and one
`ResourceBank` receipt. The Bank binds the session's address, request epoch, and
zero-based resource publication sequence. The media state retains its existing
one-based sequence. The fixed runtime receipt records both values explicitly.

`prepare` rejects before execution when the fixture, plan root, exact claim,
media object, request epoch, timeline base, or caller capacity differs from the
admitted values. After execution, the public transform verifier reconstructs:

- the exact output bytes;
- every source/output unit, byte range, and timeline mapping;
- the mapping chain;
- the output digest; and
- the transform receipt root.

`commit` verifies the Bank permit again, verifies the candidate again, applies
the prepared media publication to a copy of the prior state, and constructs the
runtime receipt before entering a bounded infallible single-owner mutation
suffix. The session then advances both publication sequences exactly once.

`abort` leaves the prior media state and Bank sequence unchanged, clears decoded
source, provisional output, and mapping storage, and permits an exact retry.
Candidate mutation between prepare and commit follows the same rollback path.
Copied transaction descriptors cannot commit or abort after the owning
generation has completed.

`closeAndRelease` closes the publication session at its exact next sequence and
releases the complete admitted claim. The retained image, audio, and video
fixtures all finish with zero Bank usage.

## Fixed runtime receipt

`ExecutionReceiptV1` is a 640-byte little-endian wire:

| Offset | Bytes | Field |
| ---: | ---: | --- |
| 0 | 8 | Magic `GMRTXN1\0` |
| 8 | 8 | Receipt ABI |
| 16 | 8 | Exact wire bytes |
| 24 | 8 | Flags; currently zero |
| 32 | 16 | Transform operation and media kind |
| 48 | 48 | Request epoch, resource/media sequences, units, output bytes, mapping count |
| 96 | 80 | Ten exact `ResourceBank.Claim` fields |
| 176 | 40 | Bank epoch, slot, generation, owner, and receipt integrity |
| 216 | 32 | Fixture root |
| 248 | 32 | Transform-plan root |
| 280 | 32 | Transform-receipt root |
| 312 | 32 | Resource-commitment root |
| 344 | 32 | Timeline-event root |
| 376 | 32 | Media-publication commit root |
| 408 | 32 | Output root |
| 440 | 32 | Mapping-chain root |
| 472 | 136 | Reserved zero |
| 608 | 32 | Domain-separated receipt root |

The resource commitment includes the runtime ABI, request epoch, complete Bank
receipt and claim, fixture root, and transform-plan root. The media publication
then binds that commitment beside the output, timeline event, prior state, and
prior commit. Independent verification therefore requires the previous media
state, exact fixture/plan, transform receipt, output, mappings, and runtime
receipt. Those are the inputs needed to reconstruct the transition rather than
an ambient assertion that it occurred.

## Evidence

Run the native vertical:

```sh
zig build media-runtime-demo -Doptimize=ReleaseSafe -Dmetal=false
```

Run the independent Python verifier:

```sh
python3 -m unittest bench.tests.test_media_runtime_txn
```

Both implementations retain the same runtime receipt roots:

| Kind | Runtime receipt root |
| --- | --- |
| Image | `4fd2368c0b7a34db2e69b378ca43fb87354a0363e27f0b58a63e1eda49b3b711` |
| Audio | `a636e11e16f55a6fa1bf9ee6bfc1b7e5add14bf077b0afd913e11bd01dfb6025` |
| Video | `7b9f97e839e9b0f85bb361d634c695f73eb3b0d49316668ecea81c050d33eebb` |

The native tests cover successful lifecycle and exact release for all three
modalities, explicit abort/retry, candidate mutation, copied transaction replay,
capacity rejection, plan substitution, short output, and all 640 serialized
receipt-byte mutations. The Python model independently reconstructs resource
receipt integrity, exact claims, timeline/publication roots, complete transform
evidence, wire roots, and re-rooted semantic contradictions.

## Claim boundary and next integration

The session is request-local and single-owner. It does not claim concurrent
access to one session, durable output bytes, process-restart continuation,
external codecs, capture/playback, accelerator residency, streaming chunks,
model embeddings, vision/speech/video inference, or generated media.

The next runtime slices are:

1. subdivide the admitted claim through `LeaseTree` nodes for decoded source,
   mappings, output, and scratch;
2. retire provisional source/staging ownership after publication while retaining
   output ownership;
3. add multi-chunk audio/video sessions with exact gap/overlap and cancellation
   policy;
4. bind the committed media receipt into continuation/checkpoint state; and
5. place the first vision or speech family adapter above this media vertical.

See the [Glacier AI Runtime Roadmap](AI_RUNTIME_ROADMAP.md),
[Multimodal Roadmap](MULTIMODAL_ROADMAP.md), and
[Deterministic Media Transforms](MEDIA_TRANSFORMS.md).
