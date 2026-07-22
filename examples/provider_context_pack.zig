//! Lossless exact context packing and Gateway admission demo.

const std = @import("std");
const core = @import("core");
const context = core.provider_context_pack;
const gateway_api = core.provider_token_gateway;

fn digest(seed: u8) context.Digest {
    var value: context.Digest = undefined;
    @memset(&value, seed);
    return value;
}

fn span(
    sequence: u32,
    kind: context.SpanKind,
    reuse_mode: context.ReuseMode,
    retention: context.Retention,
    content: u8,
    rendered: u8,
    provenance: u8,
    tokens: u64,
) !context.SpanV1 {
    return context.makeSpanV1(
        sequence,
        kind,
        reuse_mode,
        retention,
        digest(content),
        digest(rendered),
        digest(provenance),
        tokens,
    );
}

fn request(
    request_key: u64,
    input_tokens: u64,
    prompt_sha256: context.Digest,
    receipt: context.ReceiptV1,
    domain: context.DomainV1,
) !gateway_api.RequestV1 {
    return gateway_api.makeRequestV1(
        domain.adapter_abi,
        domain.isolation_key,
        request_key,
        1,
        domain.model_sha256,
        domain.tokenizer_sha256,
        prompt_sha256,
        receipt.mapping_chain_sha256,
        digest(0x91),
        input_tokens,
        50,
        .in_flight,
    );
}

pub fn main() !void {
    const domain = try context.makeDomainV1(
        0x4445_4d4f_4354_5849,
        0x4445_4d4f_4354_5841,
        digest(0x81),
        digest(0x82),
        digest(0x83),
        digest(0x84),
    );
    const policy = try context.makePolicyV1(8, 300, 10);
    const spans = [_]context.SpanV1{
        try span(0, .system, .idempotent_exact, .required, 1, 11, 21, 60),
        try span(1, .tool, .idempotent_exact, .required, 2, 12, 22, 80),
        try span(2, .evidence, .idempotent_exact, .required, 3, 13, 23, 50),
        try span(3, .user, .unique, .required, 4, 14, 24, 30),
        try span(4, .tool, .idempotent_exact, .required, 2, 12, 25, 80),
        try span(5, .evidence, .idempotent_exact, .required, 3, 13, 26, 50),
        try span(6, .system, .idempotent_exact, .required, 1, 11, 27, 60),
        try span(7, .user, .unique, .preserved, 5, 15, 28, 20),
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
    if (receipt.logical_tokens != 440 or receipt.emitted_tokens != 250 or
        receipt.deduplicated_tokens != 190 or receipt.emitted_spans != 5 or
        receipt.aliased_spans != 3 or receipt.required_spans != 7)
        return error.UnexpectedPackLedger;

    const gateway_config: gateway_api.ConfigV1 = .{
        .gateway_epoch = 0x4445_4d4f_4354_5801,
        .challenge = digest(0xa9),
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
    const raw_reservation = receipt.logical_tokens + 50;
    if (gateway.admit(try request(
        1,
        receipt.logical_tokens,
        receipt.mapping_chain_sha256,
        receipt,
        domain,
    ))) |_| {
        return error.UnexpectedRawAdmission;
    } else |err| if (err != gateway_api.Error.BudgetExceeded) return err;

    const packed_reservation = receipt.emitted_tokens + 50;
    const admission = try gateway.admit(try request(
        2,
        receipt.emitted_tokens,
        receipt.emitted_chain_sha256,
        receipt,
        domain,
    ));
    try verifier.apply(admission.event.?);
    const admitted = try gateway.snapshot();
    if (raw_reservation != 490 or packed_reservation != 300 or
        admitted.ledger.reserved_tokens != packed_reservation)
        return error.UnexpectedReservation;
    try verifier.apply(try gateway.cancel(admission.handle));
    const gateway_final = try gateway.close();
    try verifier.requireFinal(
        2,
        gateway_final.ledger,
        gateway_final.event_chain_sha256,
    );

    const receipt_hex = std.fmt.bytesToHex(receipt.receipt_sha256, .lower);
    const mapping_hex = std.fmt.bytesToHex(
        receipt.mapping_chain_sha256,
        .lower,
    );
    const emitted_hex = std.fmt.bytesToHex(
        receipt.emitted_chain_sha256,
        .lower,
    );
    const gateway_hex = std.fmt.bytesToHex(
        gateway_final.event_chain_sha256,
        .lower,
    );
    if (!std.mem.eql(
        u8,
        &receipt_hex,
        "034ad51e021153a4ca784a228314299f663492a645d1768c7dee821006d99300",
    ) or !std.mem.eql(
        u8,
        &mapping_hex,
        "d0234acda2a848ab9d19b400063bb15de23085f03c98d222b190da6bc3435b92",
    ) or !std.mem.eql(
        u8,
        &emitted_hex,
        "27a307a0903c72fc08972a83e5ba50d22f8e976d1be749277563b8219ab2b310",
    ) or !std.mem.eql(
        u8,
        &gateway_hex,
        "32f7378dd55d93dc447ae60470bfd99049b5fda6a893f37f26620f694102d281",
    )) return error.UnexpectedGoldenEvidence;

    const stdout = std.fs.File.stdout();
    var buffer: [2048]u8 = undefined;
    var writer = std.fs.File.Writer.init(stdout, &buffer);
    try writer.interface.print(
        "{{\"schema\":\"glacier.provider-context-pack/demo-v1\"," ++
            "\"logical_spans\":{d},\"emitted_spans\":{d}," ++
            "\"aliased_spans\":{d},\"required_spans\":{d}," ++
            "\"logical_tokens\":{d},\"emitted_tokens\":{d}," ++
            "\"deduplicated_tokens\":{d}," ++
            "\"raw_reservation\":{d},\"packed_reservation\":{d}," ++
            "\"raw_admitted\":false,\"packed_admitted\":true," ++
            "\"token_count_source\":\"deterministic_fixture\"," ++
            "\"provider_network_io\":false,\"verified\":true," ++
            "\"receipt_sha256\":\"{s}\"," ++
            "\"mapping_chain_sha256\":\"{s}\"," ++
            "\"emitted_chain_sha256\":\"{s}\"," ++
            "\"gateway_chain_sha256\":\"{s}\"}}\n",
        .{
            receipt.input_spans,
            receipt.emitted_spans,
            receipt.aliased_spans,
            receipt.required_spans,
            receipt.logical_tokens,
            receipt.emitted_tokens,
            receipt.deduplicated_tokens,
            raw_reservation,
            packed_reservation,
            &receipt_hex,
            &mapping_hex,
            &emitted_hex,
            &gateway_hex,
        },
    );
    try writer.interface.flush();
}
