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
pub const lane_weave_qos = core.lane_weave_qos;
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

pub const Precision = core.Precision;
pub const Pager = core.Pager;
pub const PageTable = core.PageTable;
pub const PageEntry = core.PageEntry;
pub const PageId = core.PageId;
pub const Backend = core.Backend;
pub const ResourceBank = core.ResourceBank;
pub const LaneWeaveQoS = core.LaneWeaveQoS;
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

pub const cpu_backend = @import("backends/cpu/backend.zig");
pub const int4_matmul = @import("backends/cpu/int4_matmul.zig");
pub const metal_backend = @import("backends/metal/backend.zig");

pub const CpuBackend = cpu_backend.CpuBackend;
pub const MetalBackend = metal_backend.MetalBackend;

/// Build-time flag from build.zig. When false, the Metal bindings are still
/// compiled (so the API surface stays stable) but tests that need a real
/// Metal device skip themselves.
pub const metal_enabled = blk: {
    if (@hasDecl(@import("config"), "metal_enabled")) {
        break :blk @import("config").metal_enabled;
    }
    break :blk false;
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
pub const decode_lane4 = @import("decode_lane4.zig");
pub const sampling = @import("sampling.zig");
pub const tokenizer = @import("tokenizer.zig");
pub const config = @import("config.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
