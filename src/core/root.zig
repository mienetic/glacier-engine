//! Glacier core — hardware-independent inference kernel.
//!
//! Everything in this tree must build and test on any platform with no
//! GPU dependency. Hardware access goes through the `pager.Backend`
//! interface, implemented per-backend in `src/backends/`.

pub const precision = @import("precision.zig");
pub const pager = @import("pager.zig");
pub const scheduler = @import("scheduler.zig");
pub const depth_router = @import("depth_router.zig");
pub const neuron_predictor = @import("neuron_predictor.zig");
pub const quant = @import("quant.zig");
pub const tensor = @import("tensor.zig");
pub const f16bits = @import("f16bits.zig");
pub const resource_bank = @import("resource_bank.zig");
pub const lane_weave_qos = @import("lane_weave_qos.zig");
pub const provider_token_gateway = @import("provider_token_gateway.zig");
pub const provider_transport_harness =
    @import("provider_transport_harness.zig");
pub const provider_context_pack = @import("provider_context_pack.zig");
pub const provider_context_adapter =
    @import("provider_context_adapter.zig");
pub const provider_context_wire = @import("provider_context_wire.zig");
pub const provider_settlement_wire =
    @import("provider_settlement_wire.zig");
pub const provider_gateway_event_wire =
    @import("provider_gateway_event_wire.zig");
pub const provider_transport_event_wire =
    @import("provider_transport_event_wire.zig");
pub const provider_cost_wire = @import("provider_cost_wire.zig");
pub const provider_cost_journal = @import("provider_cost_journal.zig");
pub const provider_evidence_join_wire =
    @import("provider_evidence_join_wire.zig");
pub const continuation_capsule = @import("continuation_capsule.zig");
pub const continuation_object_resolver =
    @import("continuation_object_resolver.zig");
pub const continuation_bundle = @import("continuation_bundle.zig");
pub const continuation_object_store =
    @import("continuation_object_store.zig");
pub const continuation_object_payload_store =
    @import("continuation_object_payload_store.zig");
pub const continuation_object_payload_file =
    @import("continuation_object_payload_file.zig");
pub const continuation_checkpoint_file =
    @import("continuation_checkpoint_file.zig");
pub const media_contract = @import("media_contract.zig");
pub const media_decode_plan = @import("media_decode_plan.zig");
pub const media_fixture = @import("media_fixture.zig");
pub const media_transform = @import("media_transform.zig");
pub const media_runtime_txn = @import("media_runtime_txn.zig");
pub const media_runtime_lease = @import("media_runtime_lease.zig");
pub const media_stream_runtime = @import("media_stream_runtime.zig");
pub const media_stream_continuation =
    @import("media_stream_continuation.zig");
pub const media_stream_checkpoint_set =
    @import("media_stream_checkpoint_set.zig");
pub const media_processor_state =
    @import("media_processor_state.zig");
pub const continuation_ownership_manifest =
    @import("continuation_ownership_manifest.zig");
pub const continuation_object_sweep =
    @import("continuation_object_sweep.zig");
pub const continuation_object_sweep_record =
    @import("continuation_object_sweep_record.zig");
pub const continuation_object_sweep_writer =
    @import("continuation_object_sweep_writer.zig");
pub const continuation_object_sweep_file =
    @import("continuation_object_sweep_file.zig");

// Re-export the most commonly used types at the root.
pub const Precision = precision.Precision;
pub const PrecisionProfile = precision.PrecisionProfile;
pub const Pager = pager.Pager;
pub const PageTable = pager.PageTable;
pub const PageEntry = pager.PageEntry;
pub const PageId = pager.PageId;
pub const Backend = pager.Backend;
pub const Scheduler = scheduler.Scheduler;
pub const ResourceBank = resource_bank.Bank;
pub const LaneWeaveQoS = lane_weave_qos.Scheduler;
pub const ProviderTokenGateway = provider_token_gateway.Gateway;
pub const ProviderTransportHarness = provider_transport_harness.Harness;
pub const ProviderContextPack = provider_context_pack;
pub const ProviderContextAdapter = provider_context_adapter;
pub const ProviderContextWire = provider_context_wire;
pub const ProviderSettlementWire = provider_settlement_wire;
pub const ProviderGatewayEventWire = provider_gateway_event_wire;
pub const ProviderTransportEventWire = provider_transport_event_wire;
pub const ProviderCostWire = provider_cost_wire;
pub const ProviderCostJournal = provider_cost_journal;
pub const ProviderEvidenceJoinWire = provider_evidence_join_wire;
pub const ContinuationCapsule = continuation_capsule;
pub const ContinuationObjectResolver = continuation_object_resolver;
pub const ContinuationBundle = continuation_bundle;
pub const ContinuationObjectStore = continuation_object_store;
pub const ContinuationObjectPayloadStore = continuation_object_payload_store;
pub const ContinuationObjectPayloadFile = continuation_object_payload_file;
pub const ContinuationCheckpointFile = continuation_checkpoint_file;
pub const MediaContract = media_contract;
pub const MediaDecodePlan = media_decode_plan;
pub const MediaFixture = media_fixture;
pub const MediaTransform = media_transform;
pub const MediaRuntimeTxn = media_runtime_txn;
pub const MediaRuntimeLease = media_runtime_lease;
pub const MediaStreamRuntime = media_stream_runtime;
pub const MediaStreamContinuation =
    media_stream_continuation;
pub const MediaStreamCheckpointSet =
    media_stream_checkpoint_set;
pub const MediaProcessorState = media_processor_state;
pub const ContinuationOwnershipManifest = continuation_ownership_manifest;
pub const ContinuationObjectSweep = continuation_object_sweep;
pub const ContinuationObjectSweepRecord = continuation_object_sweep_record;
pub const ContinuationObjectSweepWriter = continuation_object_sweep_writer;
pub const ContinuationObjectSweepFile = continuation_object_sweep_file;
pub const Error = pager.Error;

test {
    @import("std").testing.refAllDecls(@This());
}
