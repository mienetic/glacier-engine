//! Credential-free provider transport conformance demo.

const std = @import("std");
const core = @import("core");
const gateway_api = core.provider_token_gateway;
const transport = core.provider_transport_harness;

fn digest(seed: u8) gateway_api.Digest {
    var value: gateway_api.Digest = undefined;
    @memset(&value, seed);
    return value;
}

fn request(request_key: u64) !gateway_api.RequestV1 {
    return gateway_api.makeRequestV1(
        0x4445_4d4f_5452_4e53,
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
    const gateway_config: gateway_api.ConfigV1 = .{
        .gateway_epoch = 0x4445_4d4f_4757_0002,
        .challenge = digest(0xa5),
        .limits = .{
            .max_reserved_tokens = 1_000,
            .max_reserved_tokens_per_isolation = 800,
            .max_request_tokens = 500,
            .max_followers_per_owner = 2,
        },
    };
    var owner_slots: [1]gateway_api.OwnerSlot = .{.{}};
    var follower_slots: [2]gateway_api.FollowerSlot =
        [_]gateway_api.FollowerSlot{.{}} ** 2;
    var gateway: gateway_api.Gateway = .{};
    try gateway.init(&owner_slots, &follower_slots, gateway_config);
    var verifier = try gateway_api.VerifierV2.init(
        gateway_config,
        owner_slots.len,
        follower_slots.len,
    );
    const owner = try gateway.admit(try request(1));
    try verifier.apply(owner.event.?);
    const follower = try gateway.admit(try request(2));
    try verifier.apply(follower.event.?);
    const dispatch = try gateway.beginDispatch(owner.handle);
    try verifier.apply(dispatch.event);

    const descriptor = try transport.makeDescriptorV1(
        0x4445_4d4f_5452_4e53,
        digest(0x91),
        transport.required_capabilities,
    );
    var attempt_slots: [1]transport.AttemptSlot = .{.{}};
    var harness: transport.Harness = .{};
    try harness.init(&attempt_slots, .{
        .harness_epoch = 0x4445_4d4f_4852_0001,
        .challenge = digest(0xa6),
        .max_chunks_per_attempt = 8,
        .descriptor = descriptor,
    });
    const script = try transport.makeScriptV1(
        descriptor,
        dispatch.intent,
        digest(0x61),
        3,
        .succeeded,
        try gateway_api.makeUsageV1(100, 20, 40, 8, 0, 80),
        digest(0x71),
    );
    const started = try harness.start(dispatch.permit, script);
    var chunk_count: u32 = 0;
    while (chunk_count < script.chunk_count) : (chunk_count += 1) {
        const chunk = switch (try harness.step(started.handle)) {
            .chunk => |value| value,
            .outcome => return error.UnexpectedOutcome,
        };
        if (!transport.chunkMatchesScriptV1(
            chunk,
            dispatch.intent,
            script,
        ) or
            chunk.chunk_index != chunk_count)
            return error.InvalidChunk;
    }
    const outcome = switch (try harness.step(started.handle)) {
        .chunk => return error.UnexpectedChunk,
        .outcome => |value| value,
    };
    if (!transport.outcomeMatchesScriptV1(outcome, descriptor, script))
        return error.InvalidOutcome;
    const settlement = try transport.applyOutcome(
        &gateway,
        dispatch.permit,
        descriptor,
        script,
        outcome,
    );
    try verifier.apply(settlement.event);
    try harness.acknowledge(started.handle);

    const owner_receipt = switch (try gateway.poll(owner.handle)) {
        .succeeded => |receipt| receipt,
        else => return error.UnexpectedStatus,
    };
    const follower_receipt = switch (try gateway.poll(follower.handle)) {
        .succeeded => |receipt| receipt,
        else => return error.UnexpectedStatus,
    };
    if (!std.meta.eql(owner_receipt, follower_receipt))
        return error.SplitVisibleResult;
    try verifier.apply(try gateway.acknowledge(follower.handle));
    try verifier.apply(try gateway.acknowledge(owner.handle));
    const harness_final = try harness.close();
    const gateway_final = try gateway.close();
    try verifier.requireFinal(
        6,
        gateway_final.ledger,
        gateway_final.event_chain_sha256,
    );

    const provider_request_hex = std.fmt.bytesToHex(
        outcome.provider_request_sha256,
        .lower,
    );
    const response_chain_hex = std.fmt.bytesToHex(
        outcome.response_chain_sha256,
        .lower,
    );
    const outcome_hex = std.fmt.bytesToHex(outcome.outcome_sha256, .lower);
    const gateway_chain_hex = std.fmt.bytesToHex(
        gateway_final.event_chain_sha256,
        .lower,
    );
    if (!std.mem.eql(
        u8,
        &provider_request_hex,
        "097f723cb618933737f8e7552e16625e26241eadb9d4e5d24cdcfa31a41224a7",
    ) or !std.mem.eql(
        u8,
        &response_chain_hex,
        "0630767b119ca7de039ccb4ce09673133b8160318683960586f68ff89b0b5262",
    ) or !std.mem.eql(
        u8,
        &outcome_hex,
        "f448a98d633d7240546dcceafbba2405e149898d06aeaa6097f19fc5ed3fc880",
    ) or !std.mem.eql(
        u8,
        &gateway_chain_hex,
        "7c9cce5ff1486cf1a441d81cfa01dfd2709c29d70cdbcbb6d879b50944769433",
    )) return error.UnexpectedGoldenEvidence;

    const stdout = std.fs.File.stdout();
    var buffer: [2048]u8 = undefined;
    var writer = std.fs.File.Writer.init(stdout, &buffer);
    try writer.interface.print(
        "{{\"schema\":\"glacier.provider-transport/demo-v1\"," ++
            "\"logical_requests\":2,\"physical_dispatches\":{d}," ++
            "\"transport_attempts\":{d},\"stream_chunks\":{d}," ++
            "\"settled_billable_tokens\":{d}," ++
            "\"provider_network_io\":false,\"verified\":true," ++
            "\"provider_request_sha256\":\"{s}\"," ++
            "\"response_chain_sha256\":\"{s}\"," ++
            "\"outcome_sha256\":\"{s}\"," ++
            "\"gateway_chain_sha256\":\"{s}\"}}\n",
        .{
            gateway_final.ledger.physical_dispatches,
            harness_final.ledger.started_attempts,
            harness_final.ledger.emitted_chunks,
            gateway_final.ledger.settled_billable_tokens,
            &provider_request_hex,
            &response_chain_hex,
            &outcome_hex,
            &gateway_chain_hex,
        },
    );
    try writer.interface.flush();
}
