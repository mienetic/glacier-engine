//! Glacier core — hardware-independent inference kernel.
//!
//! Everything in this tree must keep hardware-independent boundaries and avoid
//! a required GPU dependency. Named target support is promoted only through
//! the retained compile and native gates in `docs/PLATFORM_PORTABILITY.md`.
//! Hardware access goes through the `pager.Backend` interface, implemented
//! per backend in `src/backends/`.

pub const precision = @import("precision.zig");
pub const pager = @import("pager.zig");
pub const scheduler = @import("scheduler.zig");
pub const depth_router = @import("depth_router.zig");
pub const neuron_predictor = @import("neuron_predictor.zig");
pub const quant = @import("quant.zig");
pub const tensor = @import("tensor.zig");
pub const f16bits = @import("f16bits.zig");
pub const resource_bank = @import("resource_bank.zig");
pub const platform_capabilities = @import("platform_capabilities.zig");
pub const durable_directory_authority =
    @import("durable_directory_sync.zig");
pub const durable_directory_sync = durable_directory_authority;
pub const device_capability_contract =
    @import("device_capability_contract.zig");
pub const device_lifecycle_contract =
    @import("device_lifecycle_contract.zig");
pub const device_loss_retirement =
    @import("device_loss_retirement.zig");
pub const device_loss_dispatch_reconciliation =
    @import("device_loss_dispatch_reconciliation.zig");
pub const device_loss_dispatch_callback_retirement =
    @import("device_loss_dispatch_callback_retirement.zig");
pub const device_allocation_lease =
    @import("device_allocation_lease.zig");
pub const device_allocation_lease_tree =
    @import("device_allocation_lease_tree.zig");
pub const lane_weave_qos = @import("lane_weave_qos.zig");
pub const workload_pressure = @import("workload_pressure.zig");
pub const workload_closed_loop =
    @import("workload_closed_loop.zig");
pub const typed_workload_contract =
    @import("typed_workload_contract.zig");
pub const typed_workload_driver =
    @import("typed_workload_driver.zig");
pub const typed_perception_workload =
    @import("typed_perception_workload.zig");
pub const typed_tool_workload =
    @import("typed_tool_workload.zig");
pub const native_observation_contract =
    @import("native_observation_contract.zig");
pub const native_observation_runner =
    @import("native_observation_runner.zig");
pub const native_workload_report =
    @import("native_workload_report.zig");
pub const native_workload_campaign_manifest =
    @import("native_workload_campaign_manifest.zig");
pub const native_workload_store_fault_report =
    @import("native_workload_store_fault_report.zig");
pub const tool_action_contract =
    @import("tool_action_contract.zig");
pub const tool_action_harness =
    @import("tool_action_harness.zig");
pub const tool_action_outbox_record =
    @import("tool_action_outbox_record.zig");
pub const tool_action_outbox_conformance =
    @import("tool_action_outbox_conformance.zig");
pub const tool_action_outbox_file =
    @import("tool_action_outbox_file.zig");
pub const tool_action_outbox_store_conformance =
    @import("tool_action_outbox_store_conformance.zig");
pub const tool_action_outbox_adapter_contract =
    @import("tool_action_outbox_adapter_contract.zig");
pub const tool_action_outbox_dispatch_driver =
    @import("tool_action_outbox_dispatch_driver.zig");
pub const tool_action_outbox_fake_adapter =
    @import("tool_action_outbox_fake_adapter.zig");
pub const tool_action_outbox_dispatch_conformance =
    @import("tool_action_outbox_dispatch_conformance.zig");
pub const scheduled_media_pressure =
    @import("scheduled_media_pressure.zig");
pub const workload_scenario_corpus =
    @import("workload_scenario_corpus.zig");
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
pub const media_processor_cache =
    @import("media_processor_cache.zig");
pub const model_contract = @import("model_contract.zig");
pub const runtime_support_registry =
    @import("runtime_support_registry.zig");
pub const stateless_model_adapter =
    @import("stateless_model_adapter.zig");
pub const stateless_tensor_result =
    @import("stateless_tensor_result.zig");
pub const stateless_embedding_result =
    @import("stateless_embedding_result.zig");
pub const dense_tensor_reranker =
    @import("dense_tensor_reranker.zig");
pub const dense_tensor_embedding =
    @import("dense_tensor_embedding.zig");
pub const stateful_model_adapter =
    @import("stateful_model_adapter.zig");
pub const stateful_model_continuation =
    @import("stateful_model_continuation.zig");
pub const vision_encoder_adapter =
    @import("vision_encoder_adapter.zig");
pub const audio_window_adapter =
    @import("audio_window_adapter.zig");
pub const audio_transcript_adapter =
    @import("audio_transcript_adapter.zig");
pub const stateful_transcript_adapter =
    @import("stateful_transcript_adapter.zig");
pub const audio_transcript_continuation =
    @import("audio_transcript_continuation.zig");
pub const stateful_video_adapter =
    @import("stateful_video_adapter.zig");
pub const video_model_continuation =
    @import("video_model_continuation.zig");
pub const temporal_video_adapter =
    @import("temporal_video_adapter.zig");
pub const video_segment_adapter =
    @import("video_segment_adapter.zig");
pub const video_segment_timeline =
    @import("video_segment_timeline.zig");
pub const audio_video_result_link =
    @import("audio_video_result_link.zig");
pub const latent_step_adapter =
    @import("latent_step_adapter.zig");
pub const generated_image_publication =
    @import("generated_image_publication.zig");
pub const generated_audio_playback =
    @import("generated_audio_playback.zig");
pub const generated_video_display =
    @import("generated_video_display.zig");
pub const generated_media_checkpoint =
    @import("generated_media_checkpoint.zig");
pub const generated_media_payload_archive =
    @import("generated_media_payload_archive.zig");
pub const generated_media_output_registry =
    @import("generated_media_output_registry.zig");
pub const generated_media_producer_admission =
    @import("generated_media_producer_admission.zig");
pub const generated_media_producer_transition =
    @import("generated_media_producer_transition.zig");
pub const speech_annotation_publication =
    @import("speech_annotation_publication.zig");
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
pub const PlatformCapabilities = platform_capabilities;
pub const DeviceCapabilityContract =
    device_capability_contract;
pub const DeviceLifecycleContract =
    device_lifecycle_contract;
pub const DeviceLossRetirement = device_loss_retirement;
pub const DeviceLossDispatchReconciliation =
    device_loss_dispatch_reconciliation;
pub const DeviceLossDispatchCallbackRetirement =
    device_loss_dispatch_callback_retirement;
pub const DeviceAllocationLease = device_allocation_lease;
pub const DeviceAllocationLeaseTree =
    device_allocation_lease_tree;
pub const LaneWeaveQoS = lane_weave_qos.Scheduler;
pub const WorkloadPressure = workload_pressure;
pub const WorkloadClosedLoop = workload_closed_loop;
pub const TypedWorkloadContract = typed_workload_contract;
pub const TypedWorkloadDriver = typed_workload_driver;
pub const TypedPerceptionWorkload = typed_perception_workload;
pub const TypedToolWorkload = typed_tool_workload;
pub const NativeObservationContract =
    native_observation_contract;
pub const NativeObservationRunner = native_observation_runner;
pub const NativeWorkloadReport = native_workload_report;
pub const NativeWorkloadCampaignManifest =
    native_workload_campaign_manifest;
pub const NativeWorkloadStoreFaultReport =
    native_workload_store_fault_report;
pub const ToolActionContract = tool_action_contract;
pub const ToolActionHarness = tool_action_harness.Harness;
pub const ToolActionOutboxRecord = tool_action_outbox_record;
pub const ToolActionOutboxConformance =
    tool_action_outbox_conformance;
pub const ToolActionOutboxFile = tool_action_outbox_file;
pub const ToolActionOutboxStoreConformance =
    tool_action_outbox_store_conformance;
pub const ToolActionOutboxAdapterContract =
    tool_action_outbox_adapter_contract;
pub const ToolActionOutboxDispatchDriver =
    tool_action_outbox_dispatch_driver;
pub const ToolActionOutboxFakeAdapter =
    tool_action_outbox_fake_adapter;
pub const ToolActionOutboxDispatchConformance =
    tool_action_outbox_dispatch_conformance;
pub const ScheduledMediaPressure = scheduled_media_pressure;
pub const WorkloadScenarioCorpus = workload_scenario_corpus;
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
pub const MediaProcessorCache = media_processor_cache;
pub const ModelContract = model_contract;
pub const RuntimeSupportRegistry = runtime_support_registry;
pub const StatelessModelAdapter = stateless_model_adapter;
pub const StatelessTensorResult = stateless_tensor_result;
pub const StatelessEmbeddingResult = stateless_embedding_result;
pub const DenseTensorReranker = dense_tensor_reranker;
pub const DenseTensorEmbedding = dense_tensor_embedding;
pub const StatefulModelAdapter = stateful_model_adapter;
pub const StatefulModelContinuation =
    stateful_model_continuation;
pub const VisionEncoderAdapter = vision_encoder_adapter;
pub const AudioWindowAdapter = audio_window_adapter;
pub const AudioTranscriptAdapter =
    audio_transcript_adapter;
pub const StatefulTranscriptAdapter =
    stateful_transcript_adapter;
pub const AudioTranscriptContinuation =
    audio_transcript_continuation;
pub const StatefulVideoAdapter =
    stateful_video_adapter;
pub const VideoModelContinuation =
    video_model_continuation;
pub const TemporalVideoAdapter = temporal_video_adapter;
pub const VideoSegmentAdapter = video_segment_adapter;
pub const VideoSegmentTimeline = video_segment_timeline;
pub const AudioVideoResultLink = audio_video_result_link;
pub const LatentStepAdapter = latent_step_adapter;
pub const GeneratedImagePublication =
    generated_image_publication;
pub const GeneratedAudioPlayback =
    generated_audio_playback;
pub const GeneratedVideoDisplay =
    generated_video_display;
pub const GeneratedMediaCheckpoint =
    generated_media_checkpoint;
pub const GeneratedMediaPayloadArchive =
    generated_media_payload_archive;
pub const GeneratedMediaOutputRegistry =
    generated_media_output_registry;
pub const GeneratedMediaProducerAdmission =
    generated_media_producer_admission;
pub const GeneratedMediaProducerTransition =
    generated_media_producer_transition;
pub const SpeechAnnotationPublication =
    speech_annotation_publication;
pub const ContinuationOwnershipManifest = continuation_ownership_manifest;
pub const ContinuationObjectSweep = continuation_object_sweep;
pub const ContinuationObjectSweepRecord = continuation_object_sweep_record;
pub const ContinuationObjectSweepWriter = continuation_object_sweep_writer;
pub const ContinuationObjectSweepFile = continuation_object_sweep_file;
pub const Error = pager.Error;

test {
    @import("std").testing.refAllDecls(@This());
}
