//! Canonical JSON evidence for the download-free dense-tensor family.

const std = @import("std");
const core = @import("core");
const embedding_demo = @import("dense_tensor_embedding_demo.zig");
const reranker = core.dense_tensor_reranker;
const classifier = core.dense_tensor_classifier;
const retrieval = core.dense_tensor_retrieval;
const tensor_result = core.stateless_tensor_result;
const embedding_result = core.stateless_embedding_result;
const retrieval_result = core.stateless_retrieval_result;
const resource_bank = core.resource_bank;
const model = core.model_contract;

fn writeHex(writer: anytype, bytes: []const u8) !void {
    for (bytes) |byte|
        try writer.print("{x:0>2}", .{byte});
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arguments = try std.process.argsAlloc(arena.allocator());
    if (arguments.len == 1) return runReranker();
    if (arguments.len == 2) {
        if (std.mem.eql(u8, arguments[1], "rerank"))
            return runReranker();
        if (std.mem.eql(u8, arguments[1], "classify"))
            return runClassifier();
        if (std.mem.eql(u8, arguments[1], "embed"))
            return embedding_demo.runEmbedding();
        if (std.mem.eql(u8, arguments[1], "retrieve"))
            return runRetrieval();
    }
    return error.UnexpectedArgument;
}

fn runReranker() !void {
    var fixture = try reranker.ReferenceFixtureV1.init();
    const batch_map = try fixture.batchMap();
    const policy = try fixture.scorePolicy();
    var context = fixture.referenceContext();
    const adapter = try reranker.referenceAdapterV1(
        fixture.manifest,
        &context,
    );
    var slots = [_]resource_bank.Slot{.{}} ** 2;
    var bank = try resource_bank.Bank.init(
        &slots,
        .{},
        0x4445_4d4f_5252,
    );
    var session: reranker.Session = .{};
    try session.initV1(
        &bank,
        0x4445_4d4f_4f57,
        &fixture.publication_state,
        fixture.manifest,
        fixture.plan,
        adapter,
    );
    var candidate: [
        reranker.reference_item_ids.len *
            tensor_result.ranked_element_bytes
    ]u8 = undefined;
    var output: [candidate.len]u8 = undefined;
    _ = try session.prepareV1(
        fixture.binding,
        batch_map,
        policy,
        &fixture.query_weights,
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
    )) return error.EvidenceMismatch;
    const ranked = try tensor_result.decodeAndVerifyRankedResultV1(
        &output,
        batch_map.encoded,
        policy.encoded,
    );

    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_writer =
        std.fs.File.stdout().writer(&stdout_buffer);
    const writer = &stdout_writer.interface;
    try writer.writeAll(
        "{\"schema\":\"glacier.dense-tensor-reranker/v1\"," ++
            "\"weights_hex\":\"",
    );
    try writeHex(writer, &fixture.query_weights);
    try writer.writeAll("\",\"tensor_hex\":\"");
    try writeHex(writer, &fixture.dense_tensor);
    try writer.print(
        "\",\"input_features\":{d},\"batch_map_hex\":\"",
        .{fixture.plan.input_features},
    );
    try writeHex(writer, batch_map.encoded);
    try writer.writeAll("\",\"score_policy_hex\":\"");
    try writeHex(writer, policy.encoded);
    try writer.writeAll("\",\"ranked_result_hex\":\"");
    try writeHex(writer, &output);
    try writer.writeAll("\",\"output_sha256\":\"");
    try writeHex(writer, &result.output_sha256);
    try writer.writeAll("\",\"source_mapping_sha256\":\"");
    try writeHex(writer, &result.source_mapping_sha256);
    try writer.writeAll("\",\"result_sha256\":\"");
    try writeHex(writer, &result.result_sha256);
    try writer.writeAll("\",\"items\":[");
    for (0..ranked.item_count) |index| {
        if (index != 0) try writer.writeByte(',');
        const item = try ranked.item(index);
        try writer.print(
            "{{\"rank\":{d},\"item_id\":{d}," ++
                "\"input_ordinal\":{d},\"score\":{d}}}",
            .{
                item.rank,
                item.item_id,
                item.input_ordinal,
                item.score,
            },
        );
    }
    try writer.writeAll("],\"verified\":true}\n");
    try writer.flush();
}

fn runClassifier() !void {
    var fixture = try classifier.ReferenceFixtureV1.init();
    const batch_map = try fixture.batchMap();
    const class_map = try fixture.classMap();
    const policy = try fixture.classScorePolicy();
    var context = fixture.referenceContext();
    const adapter = try classifier.referenceAdapterV1(
        fixture.manifest,
        &context,
    );
    var slots = [_]resource_bank.Slot{.{}} ** 2;
    var bank = try resource_bank.Bank.init(
        &slots,
        .{},
        0x4445_4d4f_434c,
    );
    var session: classifier.Session = .{};
    try session.initV1(
        &bank,
        0x4445_4d4f_434f,
        &fixture.publication_state,
        fixture.manifest,
        fixture.plan,
        adapter,
    );
    var candidate: [classifier.reference_output_bytes]u8 = undefined;
    var output: [candidate.len]u8 = undefined;
    _ = try session.prepareV1(
        fixture.binding,
        batch_map,
        class_map,
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
    )) return error.EvidenceMismatch;
    const matrix =
        try tensor_result.decodeAndVerifyClassScoreMatrixV1(
            &output,
            batch_map.encoded,
            class_map.encoded,
            policy.encoded,
        );

    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_writer =
        std.fs.File.stdout().writer(&stdout_buffer);
    const writer = &stdout_writer.interface;
    try writer.writeAll(
        "{\"schema\":\"glacier.dense-tensor-classifier/v1\"," ++
            "\"weights_hex\":\"",
    );
    try writeHex(writer, &fixture.projection_weights);
    try writer.writeAll("\",\"tensor_hex\":\"");
    try writeHex(writer, &fixture.dense_tensor);
    try writer.print(
        "\",\"input_features\":{d},\"batch_map_hex\":\"",
        .{fixture.plan.input_features},
    );
    try writeHex(writer, batch_map.encoded);
    try writer.writeAll("\",\"class_map_hex\":\"");
    try writeHex(writer, class_map.encoded);
    try writer.writeAll("\",\"class_score_policy_hex\":\"");
    try writeHex(writer, policy.encoded);
    try writer.writeAll("\",\"class_score_matrix_hex\":\"");
    try writeHex(writer, &output);
    try writer.writeAll("\",\"class_score_matrix_sha256\":\"");
    try writeHex(writer, &matrix.class_score_matrix_sha256);
    try writer.writeAll("\",\"output_sha256\":\"");
    try writeHex(writer, &result.output_sha256);
    try writer.writeAll("\",\"source_mapping_sha256\":\"");
    try writeHex(writer, &result.source_mapping_sha256);
    try writer.writeAll("\",\"result_sha256\":\"");
    try writeHex(writer, &result.result_sha256);
    try writer.writeAll("\",\"rows\":[");
    for (0..matrix.item_count) |item_index| {
        if (item_index != 0) try writer.writeByte(',');
        try writer.print(
            "{{\"item_id\":{d},\"input_ordinal\":{d},\"scores\":[",
            .{ try batch_map.itemId(item_index), item_index },
        );
        for (0..matrix.class_count) |class_index| {
            if (class_index != 0) try writer.writeByte(',');
            try writer.print(
                "{d}",
                .{try matrix.score(item_index, class_index)},
            );
        }
        const winner = try matrix.winner(class_map, item_index);
        try writer.print(
            "],\"winner\":{{\"class_id\":{d}," ++
                "\"class_ordinal\":{d},\"score\":{d}}}}}",
            .{
                winner.class_id,
                winner.class_ordinal,
                winner.score,
            },
        );
    }
    try writer.writeAll("],\"verified\":true}\n");
    try writer.flush();
}

fn runRetrieval() !void {
    var fixture = try retrieval.ReferenceFixtureV1.init();
    const corpus_map = try fixture.corpusMap();
    const query_map = try fixture.queryMap();
    const embedding_policy = try fixture.embeddingPolicy();
    const retrieval_policy = try fixture.retrievalPolicy();
    const visibility = try fixture.visibility();
    const index = try fixture.index();
    const query_binding = try fixture.queryBinding();
    var context = fixture.referenceContext();
    const adapter = try retrieval.referenceAdapterV1(
        fixture.manifest,
        &context,
    );
    var slots = [_]resource_bank.Slot{.{}} ** 2;
    var bank = try resource_bank.Bank.init(
        &slots,
        .{},
        0x4445_4d4f_5254,
    );
    var session: retrieval.Session = .{};
    try session.initV1(
        &bank,
        0x4445_4d4f_5257,
        &fixture.publication_state,
        fixture.manifest,
        fixture.plan,
        adapter,
    );
    var candidate: [retrieval.reference_output_bytes]u8 =
        undefined;
    var output: [candidate.len]u8 = undefined;
    _ = try session.prepareV1(
        fixture.binding,
        index,
        corpus_map,
        query_map,
        embedding_policy,
        retrieval_policy,
        visibility,
        query_binding,
        &fixture.packed_weights,
        &fixture.query_embedding,
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
    )) return error.EvidenceMismatch;

    const corpus_embedding =
        try embedding_result.decodeAndValidateNormalizedEmbeddingV1(
            fixture.packed_weights[retrieval_result.retrieval_index_bytes..],
            corpus_map.batch_map_sha256,
            embedding_policy.encoded,
            retrieval.reference_corpus_item_ids.len,
            retrieval.reference_dimensions,
        );
    const query_embedding =
        try embedding_result.decodeAndValidateNormalizedEmbeddingV1(
            &fixture.query_embedding,
            query_map.batch_map_sha256,
            embedding_policy.encoded,
            1,
            retrieval.reference_dimensions,
        );
    const retrieved = try retrieval_result.decodeRetrievalResultV1(
        &output,
        corpus_map,
        visibility,
        embedding_policy,
        corpus_embedding,
        index,
        query_map,
        query_embedding,
        retrieval_policy,
        query_binding,
    );

    var stdout_buffer: [32 * 1024]u8 = undefined;
    var stdout_writer =
        std.fs.File.stdout().writer(&stdout_buffer);
    const writer = &stdout_writer.interface;
    try writer.writeAll(
        "{\"schema\":\"glacier.dense-tensor-retrieval/v1\"," ++
            "\"corpus_map_hex\":\"",
    );
    try writeHex(writer, corpus_map.encoded);
    try writer.writeAll("\",\"query_map_hex\":\"");
    try writeHex(writer, query_map.encoded);
    try writer.writeAll("\",\"embedding_policy_hex\":\"");
    try writeHex(writer, embedding_policy.encoded);
    try writer.writeAll("\",\"retrieval_policy_hex\":\"");
    try writeHex(writer, retrieval_policy.encoded);
    try writer.writeAll("\",\"visibility_hex\":\"");
    try writeHex(writer, visibility.encoded);
    try writer.writeAll("\",\"index_hex\":\"");
    try writeHex(writer, index.encoded);
    try writer.writeAll("\",\"query_binding_hex\":\"");
    try writeHex(writer, query_binding.encoded);
    try writer.writeAll("\",\"packed_weights_hex\":\"");
    try writeHex(writer, &fixture.packed_weights);
    try writer.writeAll("\",\"query_embedding_hex\":\"");
    try writeHex(writer, &fixture.query_embedding);
    try writer.writeAll("\",\"retrieval_result_hex\":\"");
    try writeHex(writer, &output);
    try writer.writeAll("\",\"output_sha256\":\"");
    try writeHex(writer, &result.output_sha256);
    try writer.writeAll("\",\"source_mapping_sha256\":\"");
    try writeHex(writer, &result.source_mapping_sha256);
    try writer.writeAll("\",\"result_sha256\":\"");
    try writeHex(writer, &result.result_sha256);
    try writer.writeAll("\",\"retrieval_result_sha256\":\"");
    try writeHex(writer, &retrieved.retrieval_result_sha256);
    try writer.writeAll("\",\"hits\":[");
    for (0..retrieved.hit_count) |hit_index| {
        if (hit_index != 0) try writer.writeByte(',');
        const hit = try retrieved.hit(hit_index);
        try writer.print(
            "{{\"rank\":{d},\"item_id\":{d}," ++
                "\"corpus_ordinal\":{d},\"score_q30\":{d}}}",
            .{
                hit.rank,
                hit.item_id,
                hit.corpus_ordinal,
                hit.score,
            },
        );
    }
    try writer.writeAll("],\"verified\":true}\n");
    try writer.flush();
}
