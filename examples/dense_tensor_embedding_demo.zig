//! Canonical JSON evidence for the download-free dense-tensor embedding.

const std = @import("std");
const core = @import("core");
const embedding = core.dense_tensor_embedding;
const embedding_result = core.stateless_embedding_result;
const resource_bank = core.resource_bank;
const model = core.model_contract;

fn writeHex(writer: anytype, bytes: []const u8) !void {
    for (bytes) |byte|
        try writer.print("{x:0>2}", .{byte});
}

pub fn main() !void {
    return runEmbedding();
}

pub fn runEmbedding() !void {
    var fixture = try embedding.ReferenceFixtureV1.init();
    const batch_map = try fixture.batchMap();
    const policy = try fixture.embeddingPolicy();
    var context = fixture.referenceContext();
    const adapter = try embedding.referenceAdapterV1(
        fixture.manifest,
        &context,
    );
    var slots = [_]resource_bank.Slot{.{}} ** 2;
    var bank = try resource_bank.Bank.init(
        &slots,
        .{},
        0x4445_4d4f_454d,
    );
    var session: embedding.Session = .{};
    try session.initV1(
        &bank,
        0x4445_4d4f_4f57,
        &fixture.publication_state,
        fixture.manifest,
        fixture.plan,
        adapter,
    );
    var candidate: [embedding.reference_output_bytes]u8 =
        undefined;
    var output: [candidate.len]u8 = undefined;
    _ = try session.prepareV1(
        fixture.binding,
        batch_map,
        policy,
        &fixture.projection_weights,
        &fixture.dense_tensor,
        &candidate,
        &output,
    );
    const result = try session.commitV1();
    try session.closeAndRelease();
    if (!(try bank.snapshot()).used.isZero())
        return error.OwnershipLeak;
    if (!std.mem.eql(
        u8,
        &result.output_sha256,
        &model.sha256(&output),
    ))
        return error.EvidenceMismatch;
    const matrix =
        try embedding_result.decodeAndValidateNormalizedEmbeddingV1(
            &output,
            batch_map.batch_map_sha256,
            policy.encoded,
            embedding.reference_item_ids.len,
            embedding.reference_output_dimensions,
        );

    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_writer =
        std.fs.File.stdout().writer(&stdout_buffer);
    const writer = &stdout_writer.interface;
    try writer.writeAll(
        "{\"schema\":\"glacier.dense-tensor-embedding/v1\"," ++
            "\"batch_map_hex\":\"",
    );
    try writeHex(writer, batch_map.encoded);
    try writer.writeAll("\",\"embedding_policy_hex\":\"");
    try writeHex(writer, policy.encoded);
    try writer.writeAll("\",\"embedding_hex\":\"");
    try writeHex(writer, &output);
    try writer.writeAll("\",\"weights_hex\":\"");
    try writeHex(writer, &fixture.projection_weights);
    try writer.writeAll("\",\"tensor_hex\":\"");
    try writeHex(writer, &fixture.dense_tensor);
    try writer.print(
        "\",\"input_features\":{d},\"output_dimensions\":{d}," ++
            "\"source_mapping_sha256\":\"",
        .{
            fixture.plan.input_features,
            fixture.plan.output_dimensions,
        },
    );
    try writeHex(writer, &result.source_mapping_sha256);
    try writer.writeAll("\",\"result_sha256\":\"");
    try writeHex(writer, &result.result_sha256);
    try writer.writeAll("\",\"output_sha256\":\"");
    try writeHex(writer, &result.output_sha256);
    try writer.writeAll("\",\"embedding_sha256\":\"");
    try writeHex(writer, &matrix.embedding_matrix_sha256);
    try writer.writeAll("\",\"rows\":[");
    for (0..matrix.item_count) |item_index| {
        if (item_index != 0) try writer.writeByte(',');
        try writer.print(
            "{{\"item_id\":{d},\"input_ordinal\":{d}," ++
                "\"components\":[",
            .{
                try batch_map.itemId(item_index),
                item_index,
            },
        );
        for (0..matrix.dimensions) |dimension_index| {
            if (dimension_index != 0)
                try writer.writeByte(',');
            try writer.print("{d}", .{
                try matrix.component(item_index, dimension_index),
            });
        }
        try writer.writeAll("]}");
    }
    try writer.writeAll("],\"verified\":true}\n");
    try writer.flush();
}
