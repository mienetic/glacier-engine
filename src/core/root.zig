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
pub const Error = pager.Error;

test {
    @import("std").testing.refAllDecls(@This());
}
