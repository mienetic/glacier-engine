//! Credential-free ExternalTokenGateway conformance demo.

const std = @import("std");
const core = @import("core");
const gateway_api = core.provider_token_gateway;
const settlement_wire = core.provider_settlement_wire;
const event_wire = core.provider_gateway_event_wire;
const transport = core.provider_transport_harness;
const transport_wire = core.provider_transport_event_wire;
const cost_wire = core.provider_cost_wire;
const cost_journal = core.provider_cost_journal;
const join_wire = core.provider_evidence_join_wire;

fn digest(seed: u8) gateway_api.Digest {
    var value: gateway_api.Digest = undefined;
    @memset(&value, seed);
    return value;
}

fn request(request_key: u64) !gateway_api.RequestV1 {
    return gateway_api.makeRequestV1(
        0x4445_4d4f_4144_5054,
        0x4445_4d4f_4953_4f4c,
        request_key,
        1,
        digest(0x11),
        digest(0x22),
        digest(0x33),
        digest(0x44),
        digest(0x55),
        100,
        50,
        .in_flight,
    );
}

pub fn main() !void {
    const config: gateway_api.ConfigV1 = .{
        .gateway_epoch = 0x4445_4d4f_4757_0001,
        .challenge = digest(0xa5),
        .limits = .{
            .max_reserved_tokens = 1_000,
            .max_reserved_tokens_per_isolation = 800,
            .max_request_tokens = 500,
            .max_followers_per_owner = 4,
        },
    };
    var owner_slots: [2]gateway_api.OwnerSlot =
        [_]gateway_api.OwnerSlot{.{}} ** 2;
    var follower_slots: [4]gateway_api.FollowerSlot =
        [_]gateway_api.FollowerSlot{.{}} ** 4;
    var gateway: gateway_api.Gateway = .{};
    try gateway.init(&owner_slots, &follower_slots, config);
    var verifier = try gateway_api.VerifierV2.init(
        config,
        owner_slots.len,
        follower_slots.len,
    );
    var events: [8]gateway_api.EventV2 = undefined;
    var event_count: usize = 0;

    const owner_request = try request(1);
    const owner = try gateway.admit(owner_request);
    if (owner.kind != .owner) return error.UnexpectedAdmission;
    events[event_count] = owner.event.?;
    event_count += 1;
    try verifier.apply(events[event_count - 1]);
    const follower = try gateway.admit(try request(2));
    if (follower.kind != .coalesced) return error.UnexpectedAdmission;
    events[event_count] = follower.event.?;
    event_count += 1;
    try verifier.apply(events[event_count - 1]);
    const cancelled_follower = try gateway.admit(try request(3));
    if (cancelled_follower.kind != .coalesced)
        return error.UnexpectedAdmission;
    events[event_count] = cancelled_follower.event.?;
    event_count += 1;
    try verifier.apply(events[event_count - 1]);
    events[event_count] = try gateway.cancel(cancelled_follower.handle);
    event_count += 1;
    try verifier.apply(events[event_count - 1]);
    if (gateway.poll(cancelled_follower.handle)) |_| {
        return error.CancelledFollowerRemainedVisible;
    } else |err| {
        if (err != gateway_api.Error.InvalidHandle) return err;
    }

    const dispatch = try gateway.beginDispatch(owner.handle);
    events[event_count] = dispatch.event;
    event_count += 1;
    try verifier.apply(events[event_count - 1]);
    const before_settlement = try gateway.snapshot();
    const transport_descriptor = try transport.makeDescriptorV1(
        owner_request.provider_adapter_abi,
        digest(0x91),
        transport.required_capabilities,
    );
    const transport_config: transport.ConfigV1 = .{
        .harness_epoch = 0x4a4f_494e_5452_0001,
        .challenge = digest(0xa6),
        .max_chunks_per_attempt = 8,
        .descriptor = transport_descriptor,
    };
    var attempt_slots: [1]transport.AttemptSlot = .{.{}};
    var transport_harness: transport.Harness = .{};
    try transport_harness.init(&attempt_slots, transport_config);
    const transport_script = try transport.makeScriptV1(
        transport_descriptor,
        dispatch.intent,
        digest(0x61),
        3,
        .succeeded,
        try gateway_api.makeUsageV1(100, 20, 40, 8, 0, 80),
        digest(0x77),
    );
    const transport_started = try transport_harness.start(
        dispatch.permit,
        transport_script,
    );
    var transport_events: [4]transport_wire.EventV1 = undefined;
    for (0..transport_script.chunk_count) |index| {
        const chunk = switch (try transport_harness.step(transport_started.handle)) {
            .chunk => |value| value,
            .outcome => return error.UnexpectedTransportOutcome,
        };
        if (chunk.chunk_index != index) return error.InvalidTransportChunk;
        transport_events[index] = .{ .chunk = chunk };
    }
    const transport_outcome = switch (try transport_harness.step(
        transport_started.handle,
    )) {
        .chunk => return error.UnexpectedTransportChunk,
        .outcome => |value| value,
    };
    transport_events[transport_script.chunk_count] = .{
        .outcome = transport_outcome,
    };
    const settlement = try transport.applyOutcome(
        &gateway,
        dispatch.permit,
        transport_descriptor,
        transport_script,
        transport_outcome,
    );
    events[event_count] = settlement.event;
    event_count += 1;
    try verifier.apply(events[event_count - 1]);
    const transport_cancel_snapshot = try transport_harness.cancelSnapshot();
    try transport_harness.acknowledge(transport_started.handle);
    const transport_final = try transport_harness.close();

    const owner_receipt = switch (try gateway.poll(owner.handle)) {
        .succeeded => |receipt| receipt,
        else => return error.UnexpectedStatus,
    };
    const follower_receipt = switch (try gateway.poll(follower.handle)) {
        .succeeded => |receipt| receipt,
        else => return error.UnexpectedStatus,
    };
    if (!std.meta.eql(owner_receipt, follower_receipt) or
        !gateway_api.attemptReceiptValidV1(owner_receipt) or
        owner_receipt.request_set_count != 3)
        return error.UnverifiedSharedReceipt;
    var settlement_storage: [settlement_wire.encoded_bytes]u8 = undefined;
    const settlement_evidence = try settlement_wire.encodeV1(
        owner_request,
        owner_receipt,
        &settlement_storage,
    );
    const decoded_settlement = try settlement_wire.decodeAndVerifyV1(
        settlement_evidence,
    );
    if (!std.meta.eql(decoded_settlement.request, owner_request) or
        !std.meta.eql(decoded_settlement.receipt, owner_receipt))
        return error.UnverifiedSettlementWire;
    var transport_wire_storage: [4096]u8 = undefined;
    const transport_evidence = try transport_wire.encodeV1(
        transport_wire.flag_require_closed,
        transport_config,
        attempt_slots.len,
        dispatch.intent,
        transport_script,
        &transport_events,
        settlement_evidence,
        transport_final,
        transport_cancel_snapshot,
        &transport_wire_storage,
    );
    var decoded_transport_events: [transport_events.len]transport_wire.EventV1 =
        undefined;
    const decoded_transport = try transport_wire.decodeAndVerifyV1(
        transport_evidence,
        &decoded_transport_events,
    );
    if (!std.meta.eql(decoded_transport.settlement, decoded_settlement) or
        decoded_transport.events.len != transport_events.len)
        return error.UnverifiedTransportWire;
    const price = try cost_wire.makePriceTableV1(
        owner_request.provider_adapter_abi,
        digest(0xa1),
        owner_request.model_sha256,
        17,
        1_700_000_000,
        1_700_001_000,
        .{ 'U', 'S', 'D' },
        .per_component_ceiling,
        .within_output,
        .included,
        .{
            .uncached_input = .{ .known = true, .value = 2_000_000_000 },
            .cached_input = .{ .known = true, .value = 500_000_000 },
            .visible_output = .{ .known = true, .value = 8_000_000_000 },
            .reasoning = .{ .known = true, .value = 10_000_000_000 },
            .retry = .{ .known = true, .value = 0 },
        },
    );
    const quote = try cost_wire.makeQuoteV1(
        price,
        owner_request,
        1_700_000_100,
    );
    const cost_settlement = try cost_wire.makeCostSettlementV1(
        price,
        quote,
        decoded_settlement,
        1_700_000_200,
    );
    var cost_storage: [cost_wire.encoded_bytes]u8 = undefined;
    const cost_evidence = try cost_wire.encodeV1(
        cost_wire.flag_require_known_quote,
        price,
        quote,
        settlement_evidence,
        cost_settlement,
        &cost_storage,
    );
    const decoded_cost = try cost_wire.decodeAndVerifyV1(cost_evidence);
    if (!std.meta.eql(decoded_cost.price, price) or
        !std.meta.eql(decoded_cost.quote, quote) or
        !std.meta.eql(decoded_cost.cost_settlement, cost_settlement))
        return error.UnverifiedCostWire;
    const journal_header = try cost_journal.makeHeaderV1(
        0x4a4f_5552_4e41_4c01,
        digest(0xb1),
        decoded_cost.price.currency_code,
        digest(0xc1),
    );
    var journal_frame_storage: [cost_journal.frame_bytes]u8 = undefined;
    const journal_frame = try cost_journal.encodeFrameV1(
        journal_header,
        1,
        journal_header.header_sha256,
        cost_evidence,
        &journal_frame_storage,
    );
    var journal_requests: [1]cost_journal.RequestStateV1 = undefined;
    var journal_tmp = std.testing.tmpDir(.{});
    defer journal_tmp.cleanup();
    var journal_store = try cost_journal.StoreV1.create(
        journal_tmp.dir,
        "cost.journal",
        journal_header,
        &journal_frame_storage,
        &journal_requests,
    );
    const journal_directory_sync = journal_store.directory_sync_status;
    const journal_append = try journal_store.appendFrame(journal_frame, .{});
    journal_store.close();
    var reopened_journal = try cost_journal.StoreV1.open(
        journal_tmp.dir,
        "cost.journal",
        journal_header.header_sha256,
        .{},
        &journal_frame_storage,
        &journal_requests,
    );
    defer reopened_journal.close();
    const journal_final_root = reopened_journal.final_chain_sha256;
    if (reopened_journal.ledger.committed_frames != 1 or
        reopened_journal.ledger.physical_attempts != 1 or
        reopened_journal.ledger.settled_nanos.value != 316_000 or
        reopened_journal.recovered_status != .clean or
        reopened_journal.repair_sync_exercised or
        !journal_append.body_sync_exercised or
        !journal_append.footer_sync_exercised or
        try reopened_journal.file.getEndPos() !=
            cost_journal.header_bytes + cost_journal.frame_bytes)
        return error.UnverifiedCostJournal;

    events[event_count] = try gateway.acknowledge(follower.handle);
    event_count += 1;
    try verifier.apply(events[event_count - 1]);
    events[event_count] = try gateway.acknowledge(owner.handle);
    event_count += 1;
    try verifier.apply(events[event_count - 1]);
    if (event_count != events.len) return error.UnexpectedEventCount;
    const final_snapshot = try gateway.close();
    try verifier.requireFinal(
        8,
        final_snapshot.ledger,
        final_snapshot.event_chain_sha256,
    );
    const attachments = [_]event_wire.AttachmentV1{.{
        .event_index = 5,
        .encoded_settlement = settlement_evidence,
    }};
    var replay_owners: [2]event_wire.ReplayOwnerV1 = undefined;
    var replay_consumers: [6]event_wire.ReplayConsumerV1 = undefined;
    var settlement_bindings: [1]event_wire.SettlementBindingV1 = undefined;
    var event_stream_storage: [5984]u8 = undefined;
    const event_stream = try event_wire.encodeV1(
        event_wire.flag_require_closed,
        config,
        owner_slots.len,
        follower_slots.len,
        &events,
        &attachments,
        final_snapshot,
        &replay_owners,
        &replay_consumers,
        &settlement_bindings,
        &event_stream_storage,
    );
    var decoded_events: [8]gateway_api.EventV2 = undefined;
    const decoded_stream = try event_wire.decodeAndVerifyV1(
        event_stream,
        &decoded_events,
        &replay_owners,
        &replay_consumers,
        &settlement_bindings,
    );
    if (!std.meta.eql(decoded_stream.final_snapshot, final_snapshot) or
        decoded_stream.events.len != events.len or
        decoded_stream.settlements.len != 1)
        return error.UnverifiedGatewayEventWire;
    const join_scratch: join_wire.ScratchV1 = .{
        .gateway_events = &decoded_events,
        .gateway_owners = &replay_owners,
        .gateway_consumers = &replay_consumers,
        .gateway_bindings = &settlement_bindings,
        .transport_events = &decoded_transport_events,
    };
    var join_storage: [join_wire.encoded_bytes]u8 = undefined;
    const joined_evidence = try join_wire.encodeV1(
        journal_header,
        1,
        journal_header.header_sha256,
        journal_frame,
        5,
        event_stream,
        transport_evidence,
        join_scratch,
        &join_storage,
    );
    const decoded_join = try join_wire.decodeAndVerifyV1(
        joined_evidence,
        journal_header,
        journal_frame,
        event_stream,
        transport_evidence,
        join_scratch,
    );
    if (decoded_join.gateway_event_index != 5 or
        decoded_join.transport_event_count != transport_events.len or
        !std.mem.eql(
            u8,
            &decoded_join.journal_entry_sha256,
            &journal_final_root,
        )) return error.UnverifiedEvidenceJoin;
    const chain_hex = std.fmt.bytesToHex(
        final_snapshot.event_chain_sha256,
        .lower,
    );
    const settlement_hex = std.fmt.bytesToHex(
        decoded_settlement.envelope_sha256,
        .lower,
    );
    const event_stream_hex = std.fmt.bytesToHex(
        decoded_stream.envelope_sha256,
        .lower,
    );
    const transport_wire_hex = std.fmt.bytesToHex(
        decoded_transport.envelope_sha256,
        .lower,
    );
    const join_hex = std.fmt.bytesToHex(
        decoded_join.envelope_sha256,
        .lower,
    );
    const cost_hex = std.fmt.bytesToHex(
        decoded_cost.envelope_sha256,
        .lower,
    );
    const journal_header_hex = std.fmt.bytesToHex(
        journal_header.header_sha256,
        .lower,
    );
    const journal_final_hex = std.fmt.bytesToHex(
        journal_final_root,
        .lower,
    );
    if (!std.mem.eql(
        u8,
        &chain_hex,
        "802acbd0995333738ab67192f0ac417cd080e1baa637de4beccc80262819c1bd",
    )) return error.UnexpectedChainHead;
    if (!std.mem.eql(
        u8,
        &settlement_hex,
        "39794959d4febdfebcad2ef9824163ac53c714849b9dc0e56ce57c9ecc22d21f",
    )) return error.UnexpectedSettlementRoot;
    if (!std.mem.eql(
        u8,
        &cost_hex,
        "834486543213e6c6ae5cc0726a0f61d805fbd080fe3db323ac9c72eebf562731",
    )) return error.UnexpectedCostRoot;
    if (!std.mem.eql(
        u8,
        &journal_header_hex,
        "f778fb16cab3df661e58f8f10fe94e2d49686da594c45c6824ddfddffeab93ef",
    )) return error.UnexpectedCostJournalHeaderRoot;
    if (!std.mem.eql(
        u8,
        &journal_final_hex,
        "2bbd2e767663fdb30810adc3c246ec0494e6857fb87c7ef003f0f3b63a653187",
    )) return error.UnexpectedCostJournalFinalRoot;
    if (!std.mem.eql(
        u8,
        &event_stream_hex,
        "a7e56cb9e4127f9ced08455424d009a27b0b541ea14f36999ef726d7afaed827",
    )) return error.UnexpectedEventStreamRoot;
    if (!std.mem.eql(
        u8,
        &transport_wire_hex,
        "6f58a4ac93d819771985856fc6579ea0566e1e6d220a01e7b72af7e82a0be3bd",
    )) return error.UnexpectedTransportWireRoot;
    if (!std.mem.eql(
        u8,
        &join_hex,
        "2fada5a5836deb0d5a8d2acdad08bd09f4eb3b759dcf5b8ee69a4e38d6ee5274",
    )) return error.UnexpectedEvidenceJoinRoot;
    const stdout = std.fs.File.stdout();
    var buffer: [2048]u8 = undefined;
    var writer = std.fs.File.Writer.init(stdout, &buffer);
    try writer.interface.print(
        "{{\"schema\":\"glacier.external-token-gateway/demo-v5\"," ++
            "\"logical_requests\":3,\"result_consumers\":2," ++
            "\"physical_dispatches\":{d}," ++
            "\"coalesced_requests\":{d}," ++
            "\"followers_without_dispatch_permit\":2," ++
            "\"cancelled_followers\":{d}," ++
            "\"reserved_before_settlement\":{d}," ++
            "\"reserved_after_acknowledgement\":{d}," ++
            "\"settled_billable_tokens\":{d}," ++
            "\"settlement_wire_bytes\":{d}," ++
            "\"settlement_wire_sha256\":\"{s}\"," ++
            "\"cost_wire_bytes\":{d}," ++
            "\"cost_wire_sha256\":\"{s}\"," ++
            "\"cost_currency\":\"{s}\"," ++
            "\"quoted_cost_nanos\":{d}," ++
            "\"settled_cost_nanos\":{d}," ++
            "\"quote_savings_nanos\":{d}," ++
            "\"quote_overrun_nanos\":{d}," ++
            "\"cost_journal_bytes\":{d}," ++
            "\"cost_journal_header_sha256\":\"{s}\"," ++
            "\"cost_journal_final_sha256\":\"{s}\"," ++
            "\"cost_journal_committed_frames\":{d}," ++
            "\"cost_journal_frame_body_bytes\":{d}," ++
            "\"cost_journal_commit_footer_bytes\":{d}," ++
            "\"cost_journal_wire_scratch_bytes\":{d}," ++
            "\"cost_journal_file_io\":true," ++
            "\"cost_journal_body_sync_exercised\":true," ++
            "\"cost_journal_footer_sync_exercised\":true," ++
            "\"cost_journal_directory_sync\":\"{s}\"," ++
            "\"cost_journal_reopen_verified\":true,",
        .{
            final_snapshot.ledger.physical_dispatches,
            final_snapshot.ledger.coalesced_requests,
            final_snapshot.ledger.cancelled_followers,
            before_settlement.ledger.reserved_tokens,
            final_snapshot.ledger.reserved_tokens,
            final_snapshot.ledger.settled_billable_tokens,
            settlement_evidence.len,
            &settlement_hex,
            cost_evidence.len,
            &cost_hex,
            &decoded_cost.price.currency_code,
            decoded_cost.quote.breakdown.total_nanos.value,
            decoded_cost.cost_settlement.breakdown.total_nanos.value,
            decoded_cost.cost_settlement.savings_nanos.value,
            decoded_cost.cost_settlement.overrun_nanos.value,
            cost_journal.header_bytes + cost_journal.frame_bytes,
            &journal_header_hex,
            &journal_final_hex,
            reopened_journal.ledger.committed_frames,
            cost_journal.frame_body_bytes,
            cost_journal.commit_footer_bytes,
            cost_journal.frame_bytes,
            @tagName(journal_directory_sync),
        },
    );
    try writer.interface.print(
        "\"transport_wire_bytes\":{d}," ++
            "\"transport_wire_sha256\":\"{s}\"," ++
            "\"transport_wire_events\":{d}," ++
            "\"event_stream_wire_bytes\":{d}," ++
            "\"event_stream_wire_sha256\":\"{s}\"," ++
            "\"event_stream_events\":{d}," ++
            "\"event_stream_settlements\":{d}," ++
            "\"event_stream_closed\":true," ++
            "\"evidence_join_wire_bytes\":{d}," ++
            "\"evidence_join_wire_sha256\":\"{s}\"," ++
            "\"evidence_join_bound_roots\":19," ++
            "\"evidence_join_gateway_event_index\":{d}," ++
            "\"usage_source\":\"deterministic_fixture\"," ++
            "\"provider_network_io\":false,\"verified\":true," ++
            "\"chain_head_sha256\":\"{s}\"}}\n",
        .{
            transport_evidence.len,
            &transport_wire_hex,
            decoded_transport.events.len,
            event_stream.len,
            &event_stream_hex,
            decoded_stream.events.len,
            decoded_stream.settlements.len,
            joined_evidence.len,
            &join_hex,
            decoded_join.gateway_event_index,
            &chain_hex,
        },
    );
    try writer.interface.flush();
}
