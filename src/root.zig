//! Glacier engine — public root module.
//!
//! Composes the hardware-independent core with the chosen backend. For
//! the MVP we wire in the CPU backend by default; the Metal backend is
//! selected at runtime on Apple Silicon once it is implemented.

const std = @import("std");
pub const core = @import("core");

pub const precision = core.precision;
pub const pager = core.pager;
pub const scheduler = core.scheduler;
pub const resource_bank = core.resource_bank;
pub const platform_capabilities = core.platform_capabilities;
pub const device_capability_contract =
    core.device_capability_contract;
pub const device_lifecycle_contract =
    core.device_lifecycle_contract;
pub const device_loss_retirement =
    core.device_loss_retirement;
pub const device_loss_dispatch_reconciliation =
    core.device_loss_dispatch_reconciliation;
pub const device_loss_dispatch_callback_retirement =
    core.device_loss_dispatch_callback_retirement;
pub const device_allocation_lease =
    core.device_allocation_lease;
pub const device_allocation_lease_tree =
    core.device_allocation_lease_tree;
pub const lane_weave_qos = core.lane_weave_qos;
pub const workload_pressure = core.workload_pressure;
pub const workload_closed_loop = core.workload_closed_loop;
pub const typed_workload_contract = core.typed_workload_contract;
pub const typed_workload_driver = core.typed_workload_driver;
pub const typed_perception_workload = core.typed_perception_workload;
pub const typed_tool_workload = core.typed_tool_workload;
pub const native_observation_contract =
    core.native_observation_contract;
pub const native_observation_runner =
    core.native_observation_runner;
pub const native_workload_report =
    core.native_workload_report;
pub const native_workload_campaign_manifest =
    core.native_workload_campaign_manifest;
pub const native_workload_store_fault_report =
    core.native_workload_store_fault_report;
pub const tool_action_contract = core.tool_action_contract;
pub const tool_action_harness = core.tool_action_harness;
pub const tool_action_outbox_record =
    core.tool_action_outbox_record;
pub const tool_action_outbox_conformance =
    core.tool_action_outbox_conformance;
pub const tool_action_outbox_file =
    core.tool_action_outbox_file;
pub const tool_action_outbox_store_conformance =
    core.tool_action_outbox_store_conformance;
pub const tool_action_outbox_adapter_contract =
    core.tool_action_outbox_adapter_contract;
pub const tool_action_outbox_dispatch_driver =
    core.tool_action_outbox_dispatch_driver;
pub const tool_action_outbox_fake_adapter =
    core.tool_action_outbox_fake_adapter;
pub const tool_action_outbox_dispatch_conformance =
    core.tool_action_outbox_dispatch_conformance;
pub const scheduled_media_pressure =
    core.scheduled_media_pressure;
pub const workload_scenario_corpus =
    core.workload_scenario_corpus;
pub const provider_token_gateway = core.provider_token_gateway;
pub const provider_transport_harness = core.provider_transport_harness;
pub const provider_context_pack = core.provider_context_pack;
pub const provider_context_adapter = core.provider_context_adapter;
pub const provider_context_wire = core.provider_context_wire;
pub const provider_settlement_wire = core.provider_settlement_wire;
pub const provider_gateway_event_wire = core.provider_gateway_event_wire;
pub const provider_transport_event_wire = core.provider_transport_event_wire;
pub const provider_cost_wire = core.provider_cost_wire;
pub const provider_cost_journal = core.provider_cost_journal;
pub const provider_evidence_join_wire = core.provider_evidence_join_wire;
pub const continuation_capsule = core.continuation_capsule;
pub const continuation_object_resolver = core.continuation_object_resolver;
pub const continuation_bundle = core.continuation_bundle;
pub const continuation_object_store = core.continuation_object_store;
pub const continuation_object_payload_store =
    core.continuation_object_payload_store;
pub const continuation_object_payload_file =
    core.continuation_object_payload_file;
pub const continuation_ownership_manifest =
    core.continuation_ownership_manifest;
pub const continuation_object_sweep = core.continuation_object_sweep;
pub const continuation_object_sweep_record =
    core.continuation_object_sweep_record;
pub const continuation_object_sweep_writer =
    core.continuation_object_sweep_writer;
pub const continuation_object_sweep_file =
    core.continuation_object_sweep_file;

pub const Precision = core.Precision;
pub const Pager = core.Pager;
pub const PageTable = core.PageTable;
pub const PageEntry = core.PageEntry;
pub const PageId = core.PageId;
pub const Backend = core.Backend;
pub const ResourceBank = core.ResourceBank;
pub const PlatformCapabilities = core.PlatformCapabilities;
pub const DeviceCapabilityContract =
    core.DeviceCapabilityContract;
pub const DeviceLifecycleContract =
    core.DeviceLifecycleContract;
pub const DeviceLossRetirement = core.DeviceLossRetirement;
pub const DeviceLossDispatchReconciliation =
    core.DeviceLossDispatchReconciliation;
pub const DeviceAllocationLease =
    core.DeviceAllocationLease;
pub const DeviceAllocationLeaseTree =
    core.DeviceAllocationLeaseTree;
pub const LaneWeaveQoS = core.LaneWeaveQoS;
pub const WorkloadPressure = core.WorkloadPressure;
pub const WorkloadClosedLoop = core.WorkloadClosedLoop;
pub const TypedWorkloadContract = core.TypedWorkloadContract;
pub const TypedWorkloadDriver = core.TypedWorkloadDriver;
pub const TypedPerceptionWorkload = core.TypedPerceptionWorkload;
pub const TypedToolWorkload = core.TypedToolWorkload;
pub const NativeObservationContract =
    core.NativeObservationContract;
pub const NativeObservationRunner = core.NativeObservationRunner;
pub const NativeWorkloadReport = core.NativeWorkloadReport;
pub const NativeWorkloadCampaignManifest =
    core.NativeWorkloadCampaignManifest;
pub const ToolActionContract = core.ToolActionContract;
pub const ToolActionHarness = core.ToolActionHarness;
pub const ToolActionOutboxRecord = core.ToolActionOutboxRecord;
pub const ToolActionOutboxConformance =
    core.ToolActionOutboxConformance;
pub const ToolActionOutboxFile =
    core.ToolActionOutboxFile;
pub const ToolActionOutboxStoreConformance =
    core.ToolActionOutboxStoreConformance;
pub const ToolActionOutboxAdapterContract =
    core.ToolActionOutboxAdapterContract;
pub const ToolActionOutboxDispatchDriver =
    core.ToolActionOutboxDispatchDriver;
pub const ToolActionOutboxFakeAdapter =
    core.ToolActionOutboxFakeAdapter;
pub const ToolActionOutboxDispatchConformance =
    core.ToolActionOutboxDispatchConformance;
pub const ScheduledMediaPressure = core.ScheduledMediaPressure;
pub const WorkloadScenarioCorpus = core.WorkloadScenarioCorpus;
pub const ProviderTokenGateway = core.ProviderTokenGateway;
pub const ProviderTransportHarness = core.ProviderTransportHarness;
pub const ProviderContextPack = core.ProviderContextPack;
pub const ProviderContextAdapter = core.ProviderContextAdapter;
pub const ProviderContextWire = core.ProviderContextWire;
pub const ProviderSettlementWire = core.ProviderSettlementWire;
pub const ProviderGatewayEventWire = core.ProviderGatewayEventWire;
pub const ProviderTransportEventWire = core.ProviderTransportEventWire;
pub const ProviderCostWire = core.ProviderCostWire;
pub const ProviderCostJournal = core.ProviderCostJournal;
pub const ProviderEvidenceJoinWire = core.ProviderEvidenceJoinWire;
pub const ContinuationCapsule = core.ContinuationCapsule;
pub const ContinuationObjectResolver = core.ContinuationObjectResolver;
pub const ContinuationBundle = core.ContinuationBundle;
pub const ContinuationObjectStore = core.ContinuationObjectStore;
pub const ContinuationObjectPayloadStore =
    core.ContinuationObjectPayloadStore;
pub const ContinuationObjectPayloadFile =
    core.ContinuationObjectPayloadFile;
pub const ContinuationOwnershipManifest =
    core.ContinuationOwnershipManifest;
pub const ContinuationObjectSweep = core.ContinuationObjectSweep;
pub const ContinuationObjectSweepRecord =
    core.ContinuationObjectSweepRecord;
pub const ContinuationObjectSweepWriter =
    core.ContinuationObjectSweepWriter;
pub const ContinuationObjectSweepFile =
    core.ContinuationObjectSweepFile;

pub const cpu_backend = @import("backends/cpu/backend.zig");
pub const int4_matmul = @import("backends/cpu/int4_matmul.zig");
pub const metal_backend = @import("backends/metal/backend.zig");
pub const metal_allocation_adapter =
    @import("backends/metal/allocation_adapter.zig");
pub const metal_device_lifecycle_adapter =
    @import("backends/metal/device_lifecycle_adapter.zig");
pub const metal_native_observer =
    @import("backends/metal/native_observer.zig");
pub const metal_native_workload_report =
    @import("backends/metal/native_workload_report.zig");

pub const CpuBackend = cpu_backend.CpuBackend;
pub const MetalBackend = metal_backend.MetalBackend;
pub const MetalAllocationAdapter = metal_allocation_adapter;
pub const MetalDeviceLifecycleAdapter =
    metal_device_lifecycle_adapter;
pub const MetalNativeObserver = metal_native_observer;
pub const MetalNativeWorkloadReport =
    metal_native_workload_report;

/// Build-time flag from build.zig. When false, the Metal bindings are still
/// compiled (so the API surface stays stable) but tests that need a real
/// Metal device skip themselves.
pub const metal_enabled = blk: {
    if (@hasDecl(@import("config"), "metal_enabled")) {
        break :blk @import("config").metal_enabled;
    }
    break :blk false;
};
pub const metal_library_path: [*:0]const u8 = blk: {
    if (@hasDecl(@import("config"), "metal_library_path")) {
        break :blk @import("config").metal_library_path.ptr;
    }
    break :blk "zig-out/metal/shaders.metallib";
};

pub const model = @import("model/format.zig");
pub const safetensors = @import("model/safetensors.zig");
pub const converter = @import("model/converter.zig");
pub const qio = @import("model/qio.zig");
pub const forward = @import("forward.zig");
pub const loader = @import("loader.zig");
pub const runtime_image = @import("model/runtime_image.zig");
pub const perplexity = @import("perplexity.zig");
pub const fixture_gen = @import("fixture_gen.zig");
pub const kv_cache = @import("kv_cache.zig");
pub const paged_kv_cache = @import("paged_kv_cache.zig");
pub const leased_paged_kv_cache = @import("leased_paged_kv_cache.zig");
pub const continuation_paged_kv_restore =
    @import("continuation_paged_kv_restore.zig");
pub const continuation_live_restart =
    @import("continuation_live_restart.zig");
pub const paged_lease_token_txn = @import("paged_lease_token_txn.zig");
pub const paged_attention = @import("paged_attention.zig");
pub const paged_elastic_token_txn = @import("paged_elastic_token_txn.zig");
pub const paged_token_txn = @import("paged_token_txn.zig");
pub const token_txn = @import("token_txn.zig");
pub const lane_publication_txn = @import("lane_publication_txn.zig");
pub const lane_contiguous_publication =
    @import("lane_contiguous_publication.zig");
pub const int4_weights = @import("int4_weights.zig");
pub const int4_executor = @import("int4_executor.zig");
pub const progressive_int4 = @import("progressive_int4.zig");
pub const generate = @import("generate.zig");
pub const prepared_text_checkpoint =
    @import("prepared_text_checkpoint.zig");
pub const prepared_text_session = @import("prepared_text_session.zig");
pub const prepared_text_source_lease =
    @import("prepared_text_source_lease.zig");
pub const prepared_text_successor =
    @import("prepared_text_successor.zig");
pub const prepared_text_handoff_archive =
    @import("prepared_text_handoff_archive.zig");
pub const prepared_text_durable_handoff =
    @import("prepared_text_durable_handoff.zig");
pub const prepared_text_result_sink =
    @import("prepared_text_result_sink.zig");
pub const prepared_text_result_sink_file =
    @import("prepared_text_result_sink_file.zig");
pub const prepared_text_acknowledged_progress =
    @import("prepared_text_acknowledged_progress.zig");
pub const prepared_text_acknowledged_restore =
    @import("prepared_text_acknowledged_restore.zig");
pub const prepared_text_acknowledged_delivery =
    @import("prepared_text_acknowledged_delivery.zig");
pub const prepared_text_restart_manifest =
    @import("prepared_text_restart_manifest.zig");
pub const prepared_text_restore_admission =
    @import("prepared_text_restore_admission.zig");
pub const prepared_text_terminal_equivalence =
    @import("prepared_text_terminal_equivalence.zig");
pub const decode_lane4 = @import("decode_lane4.zig");
pub const sampling = @import("sampling.zig");
pub const tokenizer = @import("tokenizer.zig");
pub const media_png_apng_v1 = @import("media/png_apng_v1.zig");
pub const media_wave_pcm_v1 = @import("media/wave_pcm_v1.zig");
pub const generated_media_format_conformance =
    @import("media/generated_media_format_conformance.zig");
pub const config = @import("config.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
