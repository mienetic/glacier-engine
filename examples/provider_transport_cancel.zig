//! Credential-free active provider cancellation conformance demo.

const std = @import("std");
const core = @import("core");
const gateway_api = core.provider_token_gateway;
const transport = core.provider_transport_harness;
const settlement_wire = core.provider_settlement_wire;
const transport_wire = core.provider_transport_event_wire;

fn digest(seed: u8) gateway_api.Digest {
    var value: gateway_api.Digest = undefined;
    @memset(&value, seed);
    return value;
}

fn request() !gateway_api.RequestV1 {
    return gateway_api.makeRequestV1(
        0x4445_4d4f_4341_4e43,
        0x4445_4d4f_4341_4e49,
        1,
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
    const gateway_config: gateway_api.ConfigV1 = .{
        .gateway_epoch = 0x4445_4d4f_4347_0001,
        .challenge = digest(0xa7),
        .limits = .{
            .max_reserved_tokens = 1_000,
            .max_reserved_tokens_per_isolation = 800,
            .max_request_tokens = 500,
            .max_followers_per_owner = 1,
        },
    };
    var owner_slots: [1]gateway_api.OwnerSlot = .{.{}};
    var follower_slots: [1]gateway_api.FollowerSlot = .{.{}};
    var gateway: gateway_api.Gateway = .{};
    try gateway.init(&owner_slots, &follower_slots, gateway_config);
    var verifier = try gateway_api.VerifierV2.init(
        gateway_config,
        owner_slots.len,
        follower_slots.len,
    );
    const owner_request = try request();
    const admission = try gateway.admit(owner_request);
    try verifier.apply(admission.event.?);
    const dispatch = try gateway.beginDispatch(admission.handle);
    try verifier.apply(dispatch.event);
    const reserved_before_cancel = (try gateway.snapshot()).ledger.reserved_tokens;

    const descriptor = try transport.makeDescriptorV1(
        0x4445_4d4f_4341_4e43,
        digest(0x93),
        transport.required_capabilities |
            transport.capability_active_cancellation,
    );
    var attempt_slots: [1]transport.AttemptSlot = .{.{}};
    var harness: transport.Harness = .{};
    try harness.init(&attempt_slots, .{
        .harness_epoch = 0x4445_4d4f_4348_0001,
        .challenge = digest(0xa8),
        .max_chunks_per_attempt = 8,
        .descriptor = descriptor,
    });
    const script = try transport.makeScriptV1(
        descriptor,
        dispatch.intent,
        digest(0x62),
        5,
        .succeeded,
        try gateway_api.makeUsageV1(100, 50, 0, 0, 0, 150),
        digest(0x72),
    );
    const started = try harness.start(dispatch.permit, script);
    var transport_events: [5]transport_wire.EventV1 = undefined;
    var transport_event_count: usize = 0;
    const emitted_before_cancel: u32 = 2;
    for (0..emitted_before_cancel) |index| {
        const chunk = switch (try harness.step(started.handle)) {
            .chunk => |value| value,
            .outcome => return error.UnexpectedOutcome,
        };
        if (!transport.chunkMatchesScriptV1(
            chunk,
            dispatch.intent,
            script,
        ) or chunk.chunk_index != index) return error.InvalidChunk;
        transport_events[transport_event_count] = .{ .chunk = chunk };
        transport_event_count += 1;
    }

    const cancellation = try harness.requestCancel(
        started.handle,
        .deadline_expired,
    );
    transport_events[transport_event_count] = .{
        .cancel_request = cancellation.request,
    };
    transport_event_count += 1;
    const ack = try transport.makeCancelAckV1(
        cancellation.request,
        .confirmed,
        try gateway_api.makeUsageV1(100, 5, 81, 0, 0, 24),
        transport.zero_digest,
    );
    transport_events[transport_event_count] = .{ .cancel_ack = ack };
    transport_event_count += 1;
    const outcome = switch (try harness.applyCancelAck(
        started.handle,
        ack,
    )) {
        .resumed => return error.UnexpectedResume,
        .terminal => |value| value,
    };
    transport_events[transport_event_count] = .{
        .cancel_outcome = outcome,
    };
    transport_event_count += 1;
    if (!transport.cancelOutcomeMatchesAttemptV1(
        outcome,
        descriptor,
        dispatch.intent,
        script,
        cancellation.request,
        ack,
    )) return error.InvalidCancelOutcome;
    const settlement = try transport.applyCancelOutcome(
        &gateway,
        dispatch.permit,
        descriptor,
        script,
        cancellation.request,
        ack,
        outcome,
    );
    try verifier.apply(settlement.event);
    const reserved_after_settlement =
        (try gateway.snapshot()).ledger.reserved_tokens;
    const cancel_snapshot = try harness.cancelSnapshot();
    try harness.acknowledge(started.handle);

    const receipt = switch (try gateway.poll(admission.handle)) {
        .failed => |value| value,
        else => return error.UnexpectedStatus,
    };
    if (receipt.usage.billable_tokens.value != 24)
        return error.UnexpectedUsage;
    try verifier.apply(try gateway.acknowledge(admission.handle));
    const harness_final = try harness.close();
    var settlement_storage: [settlement_wire.encoded_bytes]u8 = undefined;
    const encoded_settlement = try settlement_wire.encodeV1(
        owner_request,
        settlement.receipt,
        &settlement_storage,
    );
    var transport_wire_storage: [4096]u8 = undefined;
    const encoded_transport = try transport_wire.encodeV1(
        transport_wire.flag_require_closed,
        .{
            .harness_epoch = 0x4445_4d4f_4348_0001,
            .challenge = digest(0xa8),
            .max_chunks_per_attempt = 8,
            .descriptor = descriptor,
        },
        attempt_slots.len,
        dispatch.intent,
        script,
        transport_events[0..transport_event_count],
        encoded_settlement,
        harness_final,
        cancel_snapshot,
        &transport_wire_storage,
    );
    var decoded_event_storage: [5]transport_wire.EventV1 = undefined;
    const decoded_transport = try transport_wire.decodeAndVerifyV1(
        encoded_transport,
        &decoded_event_storage,
    );
    if (decoded_transport.events.len != transport_event_count or
        decoded_transport.final_snapshot.ledger.emitted_chunks !=
            emitted_before_cancel)
        return error.InvalidTransportWire;
    const gateway_final = try gateway.close();
    try verifier.requireFinal(
        4,
        gateway_final.ledger,
        gateway_final.event_chain_sha256,
    );
    if (reserved_before_cancel != 150 or reserved_after_settlement != 0 or
        harness_final.ledger.emitted_chunks != emitted_before_cancel or
        cancel_snapshot.ledger.confirmed_cancellations != 1 or
        cancel_snapshot.ledger.known_post_cancel_billable_tokens != 24 or
        gateway_final.ledger.failed_dispatches != 1 or
        gateway_final.ledger.settled_billable_tokens != 24)
        return error.UnexpectedLedger;

    const request_hex = std.fmt.bytesToHex(
        cancellation.request.request_sha256,
        .lower,
    );
    const ack_hex = std.fmt.bytesToHex(ack.ack_sha256, .lower);
    const outcome_hex = std.fmt.bytesToHex(outcome.outcome_sha256, .lower);
    const transport_wire_hex = std.fmt.bytesToHex(
        decoded_transport.envelope_sha256,
        .lower,
    );
    const gateway_chain_hex = std.fmt.bytesToHex(
        gateway_final.event_chain_sha256,
        .lower,
    );
    if (!std.mem.eql(
        u8,
        &request_hex,
        "0ba2d506fd570f7b2128cac9d226e559c9c79b4a12b96f49c358fe9a1aa98c83",
    ) or !std.mem.eql(
        u8,
        &ack_hex,
        "547d97e80c61afc3350f49961cf95d5e9346292e571d7cc9ea4a3783df9590c5",
    ) or !std.mem.eql(
        u8,
        &outcome_hex,
        "787c8ce57720db4d08a7b440b4ec75854f292185f0b8fac4c0e6d4191aba5fc1",
    ) or !std.mem.eql(
        u8,
        &gateway_chain_hex,
        "06f0210728ed5919f9f3624f7f801074beb7dde19105884b0b6c958958f508b3",
    ) or !std.mem.eql(
        u8,
        &transport_wire_hex,
        "078a462b4e422ed40cda3ea1f72cdda18cebbf8815dce902d41c0ebfaa12a443",
    )) return error.UnexpectedGoldenEvidence;

    const stdout = std.fs.File.stdout();
    var buffer: [2048]u8 = undefined;
    var writer = std.fs.File.Writer.init(stdout, &buffer);
    try writer.interface.print(
        "{{\"schema\":\"glacier.provider-cancel/demo-v1\"," ++
            "\"reserved_before_cancel\":{d}," ++
            "\"reserved_after_settlement\":{d}," ++
            "\"planned_chunks\":{d},\"emitted_chunks\":{d}," ++
            "\"confirmed_cancellations\":{d}," ++
            "\"post_cancel_billable_tokens\":{d}," ++
            "\"transport_wire_bytes\":{d}," ++
            "\"transport_wire_events\":{d}," ++
            "\"transport_wire_sha256\":\"{s}\"," ++
            "\"provider_network_io\":false,\"verified\":true," ++
            "\"cancel_request_sha256\":\"{s}\"," ++
            "\"cancel_ack_sha256\":\"{s}\"," ++
            "\"cancel_outcome_sha256\":\"{s}\"," ++
            "\"gateway_chain_sha256\":\"{s}\"}}\n",
        .{
            reserved_before_cancel,
            reserved_after_settlement,
            script.chunk_count,
            harness_final.ledger.emitted_chunks,
            cancel_snapshot.ledger.confirmed_cancellations,
            cancel_snapshot.ledger.known_post_cancel_billable_tokens,
            encoded_transport.len,
            decoded_transport.events.len,
            &transport_wire_hex,
            &request_hex,
            &ack_hex,
            &outcome_hex,
            &gateway_chain_hex,
        },
    );
    try writer.interface.flush();
}
