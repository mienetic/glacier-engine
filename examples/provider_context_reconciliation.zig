//! Full-wire context-token reconciliation and Gateway admission demo.

const std = @import("std");
const core = @import("core");
const context = core.provider_context_pack;
const gateway_api = core.provider_token_gateway;

const wrapper_prefix = "{\"messages\":[";
const wrapper_suffix = "]}";
const system_content = "Follow the signed workspace policy.";
const system_rendered =
    "{\"role\":\"system\",\"content\":\"Follow the signed workspace policy.\"},";
const tool_content = "search(query: string)";
const tool_rendered =
    "{\"role\":\"tool\",\"content\":\"search(query: string)\"},";
const evidence_content = "workspace-policy-sha256:demo";
const evidence_rendered =
    "{\"role\":\"evidence\",\"content\":\"workspace-policy-sha256:demo\"},";
const first_user_content = "Find the relevant source files.";
const first_user_rendered =
    "{\"role\":\"user\",\"content\":\"Find the relevant source files.\"},";
const second_user_content = "Return a concise patch.";
const second_user_rendered =
    "{\"role\":\"user\",\"content\":\"Return a concise patch.\"}";

const raw_wire = wrapper_prefix ++
    system_rendered ++
    tool_rendered ++
    evidence_rendered ++
    first_user_rendered ++
    tool_rendered ++
    evidence_rendered ++
    system_rendered ++
    second_user_rendered ++
    wrapper_suffix;
const packed_wire = wrapper_prefix ++
    system_rendered ++
    tool_rendered ++
    evidence_rendered ++
    first_user_rendered ++
    second_user_rendered ++
    wrapper_suffix;

fn sha256(bytes: []const u8) context.Digest {
    var digest: context.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn span(
    sequence: u32,
    kind: context.SpanKind,
    reuse_mode: context.ReuseMode,
    retention: context.Retention,
    content: []const u8,
    rendered: []const u8,
    provenance: []const u8,
    tokens: u64,
) !context.SpanV1 {
    return context.makeSpanV1(
        sequence,
        kind,
        reuse_mode,
        retention,
        sha256(content),
        sha256(rendered),
        sha256(provenance),
        tokens,
    );
}

fn request(
    request_key: u64,
    observation: context.TokenObservationV1,
    reconciliation: context.ReconciliationV1,
    domain: context.DomainV1,
) !gateway_api.RequestV1 {
    if (!context.reconciliationValidV1(reconciliation))
        return error.InvalidReconciliation;
    const expected_observation_sha256 = switch (observation.arm) {
        .raw => reconciliation.raw_observation_sha256,
        .packed_context => reconciliation.packed_observation_sha256,
    };
    const reconciled_input_tokens = switch (observation.arm) {
        .raw => reconciliation.raw_wire_tokens,
        .packed_context => reconciliation.packed_wire_tokens,
    };
    if (!std.mem.eql(
        u8,
        &observation.observation_sha256,
        &expected_observation_sha256,
    )) return error.InvalidReconciliation;
    return gateway_api.makeRequestV1(
        domain.adapter_abi,
        domain.isolation_key,
        request_key,
        1,
        domain.model_sha256,
        observation.wire_sha256,
        sha256("demo-tool-schema-v1"),
        reconciliation.reconciliation_sha256,
        sha256("demo-deterministic-sampling-v1"),
        reconciled_input_tokens,
        50,
        .in_flight,
    );
}

pub fn main() !void {
    const domain = try context.makeDomainV1(
        0x4445_4d4f_4354_5849,
        0x4445_4d4f_4354_5841,
        sha256("demo-provider-namespace-v1"),
        sha256("demo-provider-model-v1"),
        sha256("demo-tokenizer-v1"),
        sha256("demo-message-render-policy-v1"),
    );
    const policy = try context.makePolicyV1(8, 300, 10);
    const spans = [_]context.SpanV1{
        try span(
            0,
            .system,
            .idempotent_exact,
            .required,
            system_content,
            system_rendered,
            "workspace-policy:source-a",
            60,
        ),
        try span(
            1,
            .tool,
            .idempotent_exact,
            .required,
            tool_content,
            tool_rendered,
            "tool-registry:source-a",
            80,
        ),
        try span(
            2,
            .evidence,
            .idempotent_exact,
            .required,
            evidence_content,
            evidence_rendered,
            "evidence-store:source-a",
            50,
        ),
        try span(
            3,
            .user,
            .unique,
            .required,
            first_user_content,
            first_user_rendered,
            "conversation:turn-1",
            30,
        ),
        try span(
            4,
            .tool,
            .idempotent_exact,
            .required,
            tool_content,
            tool_rendered,
            "tool-registry:source-b",
            80,
        ),
        try span(
            5,
            .evidence,
            .idempotent_exact,
            .required,
            evidence_content,
            evidence_rendered,
            "evidence-store:source-b",
            50,
        ),
        try span(
            6,
            .system,
            .idempotent_exact,
            .required,
            system_content,
            system_rendered,
            "workspace-policy:source-b",
            60,
        ),
        try span(
            7,
            .user,
            .unique,
            .preserved,
            second_user_content,
            second_user_rendered,
            "conversation:turn-2",
            20,
        ),
    };
    var decisions: [spans.len]context.DecisionV1 =
        [_]context.DecisionV1{.{}} ** spans.len;
    const receipt = try context.packV1(
        domain,
        policy,
        &spans,
        &decisions,
    );
    if (!context.verifyPackV1(
        domain,
        policy,
        &spans,
        &decisions,
        receipt,
    )) return error.InvalidPack;

    // This identity binds both observations to the same deterministic
    // tokenizer execution. It is fixture provenance, not provider attestation.
    const tokenizer_execution = sha256(
        "glacier-demo-tokenizer-execution-v1",
    );
    const raw_observation = try context.makeTokenObservationV1(
        domain,
        receipt,
        .raw,
        sha256(raw_wire),
        tokenizer_execution,
        440,
    );
    const packed_observation = try context.makeTokenObservationV1(
        domain,
        receipt,
        .packed_context,
        sha256(packed_wire),
        tokenizer_execution,
        250,
    );
    const reconciliation = try context.makeReconciliationV1(
        domain,
        policy,
        receipt,
        raw_observation,
        packed_observation,
    );
    if (!context.verifyReconciliationV1(
        domain,
        policy,
        receipt,
        raw_observation,
        packed_observation,
        reconciliation,
    )) return error.InvalidReconciliation;

    const gateway_config: gateway_api.ConfigV1 = .{
        .gateway_epoch = 0x4445_4d4f_4354_5802,
        .challenge = sha256("demo-gateway-challenge-v2"),
        .limits = .{
            .max_reserved_tokens = 1_000,
            .max_reserved_tokens_per_isolation = 800,
            .max_request_tokens = 400,
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

    const raw_reservation = reconciliation.raw_wire_tokens + 50;
    if (gateway.admit(try request(
        1,
        raw_observation,
        reconciliation,
        domain,
    ))) |_| {
        return error.UnexpectedRawAdmission;
    } else |err| if (err != gateway_api.Error.BudgetExceeded) return err;

    // Gateway input is the independently reconciled full-wire count, never
    // the packer's component sum on its own.
    const packed_reservation = reconciliation.packed_wire_tokens + 50;
    const admission = try gateway.admit(try request(
        2,
        packed_observation,
        reconciliation,
        domain,
    ));
    try verifier.apply(admission.event.?);
    const admitted = try gateway.snapshot();
    if (raw_reservation != 490 or packed_reservation != 300 or
        reconciliation.wire_deduplicated_tokens != 190 or
        reconciliation.packed_budget_headroom != 50 or
        admitted.ledger.reserved_tokens != packed_reservation)
        return error.UnexpectedReservation;
    try verifier.apply(try gateway.cancel(admission.handle));
    const gateway_final = try gateway.close();
    try verifier.requireFinal(
        2,
        gateway_final.ledger,
        gateway_final.event_chain_sha256,
    );

    const raw_hex = std.fmt.bytesToHex(
        raw_observation.observation_sha256,
        .lower,
    );
    const packed_hex = std.fmt.bytesToHex(
        packed_observation.observation_sha256,
        .lower,
    );
    const reconciliation_hex = std.fmt.bytesToHex(
        reconciliation.reconciliation_sha256,
        .lower,
    );
    const gateway_hex = std.fmt.bytesToHex(
        gateway_final.event_chain_sha256,
        .lower,
    );
    if (!std.mem.eql(
        u8,
        &raw_hex,
        "f83b3298e9a6cd0927ce7965e301e5a6f395c5f5aeeef797b4c6145c825f8ba6",
    ) or !std.mem.eql(
        u8,
        &packed_hex,
        "ea81f157e43842147dbdcb02510c43788c2d92b7731b9cfbba38f86408428bc5",
    ) or !std.mem.eql(
        u8,
        &reconciliation_hex,
        "8cc50858ee45fb0618917a2c2cfd1a638d1a498b1313cf4f287aa9b003815c99",
    ) or !std.mem.eql(
        u8,
        &gateway_hex,
        "76d8996b817151d8fcbccdcbce9356d186ba5b8c92b54772d909a88fa12364a0",
    )) return error.UnexpectedGoldenEvidence;

    const stdout = std.fs.File.stdout();
    var buffer: [2048]u8 = undefined;
    var writer = std.fs.File.Writer.init(stdout, &buffer);
    try writer.interface.print(
        "{{\"schema\":\"glacier.provider-context-reconciliation/demo-v1\"," ++
            "\"logical_spans\":{d},\"emitted_spans\":{d}," ++
            "\"raw_wire_tokens\":{d},\"packed_wire_tokens\":{d}," ++
            "\"wire_deduplicated_tokens\":{d}," ++
            "\"packed_budget_headroom\":{d}," ++
            "\"raw_reservation\":{d},\"packed_reservation\":{d}," ++
            "\"raw_admitted\":false,\"packed_admitted\":true," ++
            "\"token_count_source\":\"deterministic_full_wire_fixture\"," ++
            "\"tokenizer_identity_is_attestation\":false," ++
            "\"provider_network_io\":false,\"verified\":true," ++
            "\"raw_observation_sha256\":\"{s}\"," ++
            "\"packed_observation_sha256\":\"{s}\"," ++
            "\"reconciliation_sha256\":\"{s}\"," ++
            "\"gateway_chain_sha256\":\"{s}\"}}\n",
        .{
            receipt.input_spans,
            receipt.emitted_spans,
            reconciliation.raw_wire_tokens,
            reconciliation.packed_wire_tokens,
            reconciliation.wire_deduplicated_tokens,
            reconciliation.packed_budget_headroom,
            raw_reservation,
            packed_reservation,
            &raw_hex,
            &packed_hex,
            &reconciliation_hex,
            &gateway_hex,
        },
    );
    try writer.interface.flush();
}
