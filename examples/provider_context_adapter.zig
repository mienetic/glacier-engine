//! Allocation-free renderer/token-counter adapter and Gateway demo.

const std = @import("std");
const core = @import("core");
const adapter_api = core.provider_context_adapter;
const context = core.provider_context_pack;
const evidence_wire_api = core.provider_context_wire;
const gateway_api = core.provider_token_gateway;

const fragments = [_][]const u8{ "AA", "BBB", "BBB", "C" };

fn sha256(bytes: []const u8) context.Digest {
    var digest: context.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn append(
    destination: []u8,
    cursor: *usize,
    bytes: []const u8,
) adapter_api.CallbackError!void {
    const end = std.math.add(usize, cursor.*, bytes.len) catch
        return adapter_api.CallbackError.WireCapacityExceeded;
    if (end > destination.len)
        return adapter_api.CallbackError.WireCapacityExceeded;
    @memcpy(destination[cursor.*..end], bytes);
    cursor.* = end;
}

const ByteAdapter = struct {
    render_execution_sha256: context.Digest,
    tokenizer_execution_sha256: context.Digest,

    fn runtime(
        self: *ByteAdapter,
        descriptor: adapter_api.DescriptorV1,
    ) adapter_api.AdapterV1 {
        return .{
            .adapter_context = self,
            .descriptor = descriptor,
            .renderFn = render,
            .countFn = count,
        };
    }

    fn render(
        adapter_context: *anyopaque,
        arm: context.ContextArm,
        spans: []const context.SpanV1,
        decisions: []const context.DecisionV1,
        destination: []u8,
    ) adapter_api.CallbackError!adapter_api.RenderResult {
        const self: *ByteAdapter = @ptrCast(@alignCast(adapter_context));
        if (spans.len != fragments.len or decisions.len != spans.len)
            return adapter_api.CallbackError.RenderRejected;
        var cursor: usize = 0;
        try append(destination, &cursor, "[");
        for (spans, decisions, fragments) |span, decision, fragment| {
            if (!std.mem.eql(
                u8,
                &span.rendered_sha256,
                &sha256(fragment),
            )) return adapter_api.CallbackError.RenderRejected;
            const emit = switch (arm) {
                .raw => true,
                .packed_context => decision.action == .emit,
            };
            if (emit) try append(destination, &cursor, fragment);
        }
        try append(destination, &cursor, "]");
        return .{
            .written = cursor,
            .render_execution_sha256 = self.render_execution_sha256,
        };
    }

    fn count(
        adapter_context: *anyopaque,
        wire: []const u8,
    ) adapter_api.CallbackError!adapter_api.TokenCountResult {
        const self: *ByteAdapter = @ptrCast(@alignCast(adapter_context));
        return .{
            .tokens = @intCast(wire.len),
            .tokenizer_execution_sha256 = self.tokenizer_execution_sha256,
        };
    }
};

fn makeSpan(
    sequence: u32,
    kind: context.SpanKind,
    reuse_mode: context.ReuseMode,
    retention: context.Retention,
    fragment: []const u8,
    provenance: []const u8,
) !context.SpanV1 {
    return context.makeSpanV1(
        sequence,
        kind,
        reuse_mode,
        retention,
        sha256(fragment),
        sha256(fragment),
        sha256(provenance),
        fragment.len,
    );
}

fn request(
    request_key: u64,
    observation: context.TokenObservationV1,
    execution: adapter_api.ExecutionV1,
    domain: context.DomainV1,
) !gateway_api.RequestV1 {
    if (!adapter_api.executionValidV1(execution))
        return error.InvalidExecution;
    const expected_observation_sha256 = switch (observation.arm) {
        .raw => execution.reconciliation.raw_observation_sha256,
        .packed_context => execution.reconciliation.packed_observation_sha256,
    };
    const reconciled_tokens = switch (observation.arm) {
        .raw => execution.reconciliation.raw_wire_tokens,
        .packed_context => execution.reconciliation.packed_wire_tokens,
    };
    if (!std.mem.eql(
        u8,
        &observation.observation_sha256,
        &expected_observation_sha256,
    )) return error.InvalidExecution;
    return gateway_api.makeRequestV1(
        domain.adapter_abi,
        domain.isolation_key,
        request_key,
        1,
        domain.model_sha256,
        observation.wire_sha256,
        sha256("demo-adapter-tool-schema-v1"),
        execution.execution_sha256,
        sha256("demo-adapter-sampling-v1"),
        reconciled_tokens,
        3,
        .in_flight,
    );
}

pub fn main() !void {
    const adapter_abi: u64 = 0x4445_4d4f_4144_5001;
    const provider_namespace = sha256("demo-adapter-provider-v1");
    const tokenizer = sha256("demo-byte-tokenizer-v1");
    const render_policy = sha256("demo-framed-render-policy-v1");
    const domain = try context.makeDomainV1(
        0x4445_4d4f_4354_5849,
        adapter_abi,
        provider_namespace,
        sha256("demo-adapter-model-v1"),
        tokenizer,
        render_policy,
    );
    const policy = try context.makePolicyV1(4, 10, 2);
    const spans = [_]context.SpanV1{
        try makeSpan(0, .system, .unique, .required, fragments[0], "policy"),
        try makeSpan(
            1,
            .tool,
            .idempotent_exact,
            .required,
            fragments[1],
            "tool-a",
        ),
        try makeSpan(
            2,
            .tool,
            .idempotent_exact,
            .required,
            fragments[2],
            "tool-b",
        ),
        try makeSpan(3, .user, .unique, .preserved, fragments[3], "turn-1"),
    };
    var decisions: [spans.len]context.DecisionV1 =
        [_]context.DecisionV1{.{}} ** spans.len;
    const receipt = try context.packV1(
        domain,
        policy,
        &spans,
        &decisions,
    );
    const descriptor = try adapter_api.makeDescriptorV1(
        adapter_abi,
        provider_namespace,
        tokenizer,
        render_policy,
        adapter_api.required_capabilities,
        64,
    );
    var byte_adapter: ByteAdapter = .{
        .render_execution_sha256 = sha256("demo-byte-render-execution-v1"),
        .tokenizer_execution_sha256 = sha256(
            "demo-byte-tokenizer-execution-v1",
        ),
    };
    var wire_scratch: [64]u8 = undefined;
    const execution = try adapter_api.executeReusedScratchV1(
        byte_adapter.runtime(descriptor),
        domain,
        policy,
        &spans,
        &decisions,
        receipt,
        &wire_scratch,
    );
    const packed_len: usize = @intCast(execution.packed_wire_bytes);
    const packed_wire = wire_scratch[0..packed_len];
    if (execution.raw_wire_bytes != 11 or
        !std.mem.eql(u8, packed_wire, "[AABBBC]"))
        return error.UnexpectedWire;

    var replay_adapter = byte_adapter;
    var replay_scratch: [64]u8 = undefined;
    if (!adapter_api.replayReusedScratchV1(
        replay_adapter.runtime(descriptor),
        domain,
        policy,
        &spans,
        &decisions,
        receipt,
        packed_wire,
        execution,
        &replay_scratch,
    )) return error.ReplayFailed;

    var evidence_wire_storage: [4096]u8 = undefined;
    const evidence_wire = try evidence_wire_api.encodeV1(
        descriptor,
        domain,
        policy,
        &spans,
        &decisions,
        receipt,
        execution,
        packed_wire,
        &evidence_wire_storage,
    );
    var decoded_spans: [spans.len]context.SpanV1 = undefined;
    var decoded_decisions: [spans.len]context.DecisionV1 = undefined;
    const decoded_evidence = try evidence_wire_api.decodeAndVerifyV1(
        evidence_wire,
        &decoded_spans,
        &decoded_decisions,
    );
    if (!std.meta.eql(decoded_evidence.descriptor, descriptor) or
        !std.meta.eql(decoded_evidence.domain, domain) or
        !std.meta.eql(decoded_evidence.policy, policy) or
        !std.meta.eql(decoded_evidence.receipt, receipt) or
        !std.meta.eql(decoded_evidence.execution, execution) or
        !std.mem.eql(u8, decoded_evidence.packed_wire, packed_wire))
        return error.EvidenceWireMismatch;

    const gateway_config: gateway_api.ConfigV1 = .{
        .gateway_epoch = 0x4445_4d4f_4144_5002,
        .challenge = sha256("demo-adapter-gateway-challenge-v1"),
        .limits = .{
            .max_reserved_tokens = 64,
            .max_reserved_tokens_per_isolation = 32,
            .max_request_tokens = 12,
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

    const raw_reservation = execution.reconciliation.raw_wire_tokens + 3;
    if (gateway.admit(try request(
        1,
        execution.raw_observation,
        execution,
        domain,
    ))) |_| {
        return error.UnexpectedRawAdmission;
    } else |err| if (err != gateway_api.Error.BudgetExceeded) return err;
    const packed_reservation =
        execution.reconciliation.packed_wire_tokens + 3;
    const admission = try gateway.admit(try request(
        2,
        execution.packed_observation,
        execution,
        domain,
    ));
    try verifier.apply(admission.event.?);
    const admitted = try gateway.snapshot();
    if (raw_reservation != 14 or packed_reservation != 11 or
        admitted.ledger.reserved_tokens != packed_reservation)
        return error.UnexpectedReservation;
    try verifier.apply(try gateway.cancel(admission.handle));
    const gateway_final = try gateway.close();
    try verifier.requireFinal(
        2,
        gateway_final.ledger,
        gateway_final.event_chain_sha256,
    );

    const descriptor_hex = std.fmt.bytesToHex(
        descriptor.descriptor_sha256,
        .lower,
    );
    const execution_hex = std.fmt.bytesToHex(
        execution.execution_sha256,
        .lower,
    );
    const reconciliation_hex = std.fmt.bytesToHex(
        execution.reconciliation.reconciliation_sha256,
        .lower,
    );
    const gateway_hex = std.fmt.bytesToHex(
        gateway_final.event_chain_sha256,
        .lower,
    );
    const evidence_wire_hex = std.fmt.bytesToHex(
        decoded_evidence.envelope_sha256,
        .lower,
    );
    if (!std.mem.eql(
        u8,
        &descriptor_hex,
        "d85a42b9ad16255d122ac883ca63d5136eca00d82f2c3689f809a10ee975cafa",
    ) or !std.mem.eql(
        u8,
        &execution_hex,
        "3114bae74248905c516aa677ffeea560a9dae09dc0d32b893cf0dac17734cbaf",
    ) or !std.mem.eql(
        u8,
        &reconciliation_hex,
        "2d49c7305baabb1f728599585757e2f2a9e68938b1bf4c6b1ab657df6157c15c",
    ) or !std.mem.eql(
        u8,
        &evidence_wire_hex,
        "24836b276a8918ebcff9d3c9ff6b38d66e301602d96ddffda4de963fbf87e545",
    ) or !std.mem.eql(
        u8,
        &gateway_hex,
        "30fdf2be28e769126d18527c67da9c623a7c35a9c4de105473c40add24c868fb",
    )) return error.UnexpectedGoldenEvidence;

    const stdout = std.fs.File.stdout();
    var buffer: [2048]u8 = undefined;
    var writer = std.fs.File.Writer.init(stdout, &buffer);
    try writer.interface.print(
        "{{\"schema\":\"glacier.provider-context-adapter/demo-v1\"," ++
            "\"logical_spans\":{d},\"emitted_spans\":{d}," ++
            "\"raw_wire_bytes\":{d},\"packed_wire_bytes\":{d}," ++
            "\"raw_wire_tokens\":{d},\"packed_wire_tokens\":{d}," ++
            "\"deduplicated_tokens\":{d}," ++
            "\"raw_reservation\":{d},\"packed_reservation\":{d}," ++
            "\"raw_admitted\":false,\"packed_admitted\":true," ++
            "\"scratch_allocation\":\"caller_owned\"," ++
            "\"execution_mode\":\"reused_single_scratch\"," ++
            "\"execution_wire_scratch_capacity_bytes\":{d}," ++
            "\"equivalent_dual_execution_capacity_bytes\":{d}," ++
            "\"execution_wire_scratch_capacity_reduction_x\":2," ++
            "\"raw_wire_retained\":false," ++
            "\"packed_wire_retained\":true," ++
            "\"portable_evidence_wire\":true," ++
            "\"evidence_wire_encoding\":\"canonical_little_endian\"," ++
            "\"evidence_wire_bytes\":{d}," ++
            "\"decoded_logical_spans\":{d}," ++
            "\"full_pack_semantic_verification\":true," ++
            "\"token_count_source\":\"adapter_full_wire_byte_execution\"," ++
            "\"provider_tokenizer\":false,\"provider_network_io\":false," ++
            "\"deterministic_replay\":true,\"verified\":true," ++
            "\"descriptor_sha256\":\"{s}\"," ++
            "\"execution_sha256\":\"{s}\"," ++
            "\"reconciliation_sha256\":\"{s}\"," ++
            "\"evidence_wire_sha256\":\"{s}\"," ++
            "\"gateway_chain_sha256\":\"{s}\"}}\n",
        .{
            receipt.input_spans,
            receipt.emitted_spans,
            execution.raw_wire_bytes,
            execution.packed_wire_bytes,
            execution.reconciliation.raw_wire_tokens,
            execution.reconciliation.packed_wire_tokens,
            execution.reconciliation.wire_deduplicated_tokens,
            raw_reservation,
            packed_reservation,
            wire_scratch.len,
            wire_scratch.len * 2,
            evidence_wire.len,
            decoded_evidence.spans.len,
            &descriptor_hex,
            &execution_hex,
            &reconciliation_hex,
            &evidence_wire_hex,
            &gateway_hex,
        },
    );
    try writer.interface.flush();
}
