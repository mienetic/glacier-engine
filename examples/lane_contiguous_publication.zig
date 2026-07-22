//! Model-free proof that portable receipts bind actual contiguous AI state.

const std = @import("std");
const engine = @import("engine");
const core = engine.core;
const lane = core.lane_weave_qos;
const resource_bank = core.resource_bank;
const kv = engine.kv_cache;
const publication = engine.lane_publication_txn;
const contiguous = engine.lane_contiguous_publication;

const DemoSink = struct {
    prepare_calls: u64 = 0,
    commit_calls: u64 = 0,

    fn interface(self: *DemoSink) publication.SinkV1 {
        return .{
            .context = self,
            .prepare = prepare,
            .commit = commit,
            .abort = abort,
        };
    }

    fn prepare(
        context: *anyopaque,
        proposal: *const publication.ProposalV1,
        ack: *publication.PrepareAckV1,
    ) publication.SinkPrepareError!void {
        const self: *DemoSink = @ptrCast(@alignCast(context));
        self.prepare_calls += 1;
        ack.* = .{
            .proposal_sha256 = publication.proposalSha256(proposal.*),
            .sink_epoch = 0x434f_4445,
            .reservation_id = self.prepare_calls,
        };
    }

    fn commit(
        context: *anyopaque,
        _: *const publication.CommitReceiptV1,
    ) void {
        const self: *DemoSink = @ptrCast(@alignCast(context));
        self.commit_calls += 1;
    }

    fn abort(
        _: *anyopaque,
        _: *const publication.ProposalV1,
        _: *const publication.PrepareAckV1,
    ) void {}
};

pub fn main() !void {
    var cache = try kv.KVCache.init(std.heap.page_allocator, 2, 2, 4);
    defer cache.deinit();
    _ = try cache.appendRow(0, &.{ 1, 2 }, &.{ 3, 4 });
    _ = try cache.appendRow(1, &.{ 5, 6 }, &.{ 7, 8 });
    cache.commit();

    var output: [2]u32 = undefined;
    var output_len: usize = 0;
    var rng: contiguous.RngState = .{ 11, 12, 13, 14 };
    var sampling_calls: u64 = 0;
    const claim: resource_bank.Claim = .{
        .kv_bytes = @intCast(cache.logicalLedger().allocation_payload_bytes),
        .output_journal_bytes = @sizeOf(@TypeOf(output)),
        .queue_slots = 1,
    };

    var bank_slots: [1]resource_bank.Slot = undefined;
    var lane_slots: [1]lane.Slot = undefined;
    var projection: [1]lane.ProjectionSlot = undefined;
    var bank = try resource_bank.Bank.init(
        &bank_slots,
        .{
            .host_bytes = 1 << 20,
            .kv_bytes = 1 << 20,
            .output_journal_bytes = 1 << 20,
            .queue_slots = 1,
        },
        0x434f_4445_4241,
    );
    var scheduler = try lane.Scheduler.init(
        &bank,
        .{ .slots = &lane_slots, .projection = &projection },
        .{
            .scheduler_epoch = 0x434f_4445_5343,
            .challenge = [_]u8{0xc7} ** 32,
            .max_weight = 4,
        },
    );
    const admission = switch (try scheduler.admit(.{
        .tenant_key = 101,
        .request_key = 202,
        .request_generation = 1,
        .resource_owner_key = 303,
        .weight = 1,
        .work_quanta = 2,
        .claim = claim,
    })) {
        .admitted => |value| value,
        .rejected => return error.UnexpectedAdmissionRejection,
    };

    var session: contiguous.Session = .{};
    try session.init(
        &scheduler,
        &bank,
        admission,
        0x434f_4445_5251,
        .{
            .cache = &cache,
            .rng_state = &rng,
            .sampling_calls = &sampling_calls,
            .output = &output,
            .output_len = &output_len,
        },
    );
    const initial = try session.snapshotVerified();
    var verifier = try publication.TranscriptVerifierV1.init(
        admission.event.resource_receipt,
        0x434f_4445_5251,
        contiguous.abi,
        initial.state,
    );
    var sink: DemoSink = .{};

    const first = try session.publish(
        try scheduler.prepareService(),
        .{
            .rng_after = rng,
            .sampling_calls_after = 0,
            .token_id = 901,
        },
        sink.interface(),
    );
    try verifier.apply(first);

    const row = try cache.beginRows(1);
    _ = try cache.appendRowTxn(row, 0, &.{ 21, 22 }, &.{ 23, 24 });
    _ = try cache.appendRowTxn(row, 1, &.{ 25, 26 }, &.{ 27, 28 });
    const second = try session.publish(
        try scheduler.prepareService(),
        .{
            .kv_mark = row,
            .rng_after = .{ 31, 32, 33, 34 },
            .sampling_calls_after = 1,
            .token_id = 902,
            .terminal = true,
        },
        sink.interface(),
    );
    try verifier.apply(second);
    const verified = try session.snapshotVerified();
    try verifier.requireFinal(
        2,
        true,
        verified.state,
        verified.transcript_sha256,
    );
    const physical_kv = contiguous.logicalKvPrefixSha256(&cache, cache.len);
    if (std.mem.eql(
        u8,
        &physical_kv,
        &initial.state.kv_state_sha256,
    ) or output_len != 2 or output[0] != 901 or output[1] != 902 or
        sampling_calls != 1 or sink.commit_calls != 2)
        return error.ConcreteStateMismatch;

    var expected_transcript: publication.Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_transcript,
        "44f382f45f16624ed07b80bf59e90d94f6ff030eaf41c2772f2f0ee2c06b7e71",
    );
    if (!std.mem.eql(
        u8,
        &verified.transcript_sha256,
        &expected_transcript,
    )) return error.GoldenTranscriptMismatch;

    try session.close();
    _ = try scheduler.retire(admission.handle);
    const bank_snapshot = try bank.snapshot();
    const final_host_bytes = try bank_snapshot.used.hostBytes();
    _ = try scheduler.close();

    const transcript_hex = std.fmt.bytesToHex(
        verified.transcript_sha256,
        .lower,
    );
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"component\":\"lane-contiguous-publication\"," ++
            "\"commits\":{d},\"first_token_kv_rows\":0," ++
            "\"sampled_tokens\":{d},\"final_kv_positions\":{d}," ++
            "\"output_tokens\":[{d},{d}],\"verified\":true," ++
            "\"final_bank_host_bytes\":{d},\"session_bytes\":{d}," ++
            "\"transcript_sha256\":\"{s}\"}}\n",
        .{
            sink.commit_calls,
            sampling_calls,
            cache.len,
            output[0],
            output[1],
            final_host_bytes,
            @sizeOf(contiguous.Session),
            &transcript_hex,
        },
    );
    try stdout.flush();
}
