//! Model-free demonstration of verified one-token AI publication.

const std = @import("std");
const engine = @import("engine");
const core = engine.core;
const lane = core.lane_weave_qos;
const resource_bank = core.resource_bank;
const publication = engine.lane_publication_txn;

const execution_abi: u64 = 0x4445_4d4f_4558_0001;
const rng_abi: u64 = 0x4445_4d4f_524e_0001;

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
            .sink_epoch = 0x4445_4d4f,
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
        0x4445_4d4f_4241,
    );
    var scheduler = try lane.Scheduler.init(
        &bank,
        .{ .slots = &lane_slots, .projection = &projection },
        .{
            .scheduler_epoch = 0x4445_4d4f_5343,
            .challenge = filledDigest(0xa7),
            .max_weight = 4,
        },
    );
    const admission = switch (try scheduler.admit(.{
        .tenant_key = 101,
        .request_key = 202,
        .request_generation = 1,
        .resource_owner_key = 303,
        .weight = 1,
        .work_quanta = 3,
        .claim = .{
            .kv_bytes = 4096,
            .output_journal_bytes = 1024,
            .queue_slots = 1,
        },
    })) {
        .admitted => |value| value,
        .rejected => return error.UnexpectedAdmissionRejection,
    };

    const initial_state = publication.makeStateCommitmentV1(
        execution_abi,
        32,
        filledDigest(0x11),
        rng_abi,
        filledDigest(0x22),
        0,
        0,
        filledDigest(0x33),
    );
    var session: publication.Session = .{};
    try session.init(
        &scheduler,
        &bank,
        admission,
        0x4445_4d4f_5251,
        execution_abi,
        initial_state,
    );
    var verifier = try publication.TranscriptVerifierV1.init(
        admission.event.resource_receipt,
        0x4445_4d4f_5251,
        execution_abi,
        initial_state,
    );
    var sink: DemoSink = .{};
    var state = initial_state;
    for ([_]u32{ 901, 902, 903 }, 0..) |token_id, index| {
        const transition = try publication.makeTokenTransitionV1(
            state,
            filledDigest(@truncate(0x40 + index)),
            filledDigest(@truncate(0x70 + index)),
            token_id,
            index == 2,
        );
        const receipt = try session.publish(
            try scheduler.prepareService(),
            transition,
            sink.interface(),
        );
        try verifier.apply(receipt);
        state = transition.after;
    }
    const verified = verifier.snapshot();
    _ = try session.retire();
    const bank_snapshot = try bank.snapshot();
    const final_host_bytes = try bank_snapshot.used.hostBytes();
    _ = try scheduler.close();

    const transcript_hex = std.fmt.bytesToHex(
        verified.transcript_sha256,
        .lower,
    );
    var expected_transcript: publication.Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_transcript,
        "5525a18aa56ecf745a30aeea1e59e7b83d2543e3cedc18e9ed4178c8b1f576b2",
    );
    if (!std.mem.eql(
        u8,
        &verified.transcript_sha256,
        &expected_transcript,
    )) return error.GoldenTranscriptMismatch;
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"component\":\"lane-publication-txn\",\"commits\":{d}," ++
            "\"queue_slots\":1,\"verified\":true," ++
            "\"final_bank_host_bytes\":{d}," ++
            "\"session_bytes\":{d},\"proposal_bytes\":{d}," ++
            "\"receipt_bytes\":{d}," ++
            "\"transcript_sha256\":\"{s}\"}}\n",
        .{
            sink.commit_calls,
            final_host_bytes,
            @sizeOf(publication.Session),
            @sizeOf(publication.ProposalV1),
            @sizeOf(publication.CommitReceiptV1),
            &transcript_hex,
        },
    );
    try stdout.flush();
}

fn filledDigest(byte: u8) publication.Digest {
    return [_]u8{byte} ** 32;
}
