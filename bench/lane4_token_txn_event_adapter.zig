//! Lossless runner-v6 -> TokenTxn raw-event-v4 adapter.
//!
//! The runner remains responsible for capturing and sealing evidence.  This
//! module only copies already-verified fixed-capacity receipts into the
//! engine-independent wire structs; it performs no allocation and invents no
//! timestamp.

const std = @import("std");
const engine = @import("engine");
const runner = @import("lane4_runner_core");
const observation = @import("lane4_runner_observation");
const wire = @import("lane4_token_txn_event_wire");

comptime {
    std.debug.assert(runner.width == wire.lane_count);
    std.debug.assert(runner.max_tokens_per_lane == wire.wave_count);
    std.debug.assert(runner.b4_token_txn_journal_abi ==
        wire.b4_token_txn_journal_abi);
    std.debug.assert(observation.observation_abi == wire.observation_abi);
    std.debug.assert(engine.decode_lane4.abi == wire.decode_lane4_abi);
    std.debug.assert(engine.token_txn.abi == wire.token_txn_abi);
    std.debug.assert(engine.token_txn.sink_abi == wire.token_txn_sink_abi);
    std.debug.assert(engine.token_txn.prepare_ack_abi ==
        wire.token_txn_prepare_ack_abi);
    std.debug.assert(engine.token_txn.commit_receipt_abi ==
        wire.token_txn_commit_receipt_abi);
    std.debug.assert(engine.resource_bank.abi == wire.resource_bank_abi);
}

pub const Error = runner.B4TokenTxnJournalError || wire.Error;

pub const AdaptedReplay = struct {
    receipt: wire.JournalReceiptV1,
    waves: wire.WaveMatrix,
};

fn adaptClaim(value: engine.resource_bank.Claim) wire.ResourceClaim {
    return .{
        .capsule_bytes = value.capsule_bytes,
        .kv_bytes = value.kv_bytes,
        .activation_bytes = value.activation_bytes,
        .partial_bytes = value.partial_bytes,
        .logits_bytes = value.logits_bytes,
        .output_journal_bytes = value.output_journal_bytes,
        .staging_bytes = value.staging_bytes,
        .device_bytes = value.device_bytes,
        .io_bytes = value.io_bytes,
        .queue_slots = value.queue_slots,
    };
}

fn adaptResourceReceipt(
    value: engine.resource_bank.Receipt,
) wire.ResourceReceipt {
    return .{
        .bank_epoch = value.bank_epoch,
        .slot_index = value.slot_index,
        .generation = value.generation,
        .owner_key = value.owner_key,
        .claim = adaptClaim(value.claim),
        .integrity = value.integrity,
    };
}

fn adaptPrepareAck(value: engine.token_txn.PrepareAckV1) wire.PrepareAckV1 {
    return .{
        .abi_version = value.abi_version,
        .proposal_sha256 = value.proposal_sha256,
        .sink_epoch = value.sink_epoch,
        .reservation_id = value.reservation_id,
    };
}

fn adaptWaveReceipt(
    value: runner.B4TokenTxnWaveReceiptV1,
) wire.WaveReceiptV1 {
    return .{
        .abi_version = value.abi_version,
        .proposal_abi = value.proposal_abi,
        .sink_abi = value.sink_abi,
        .request_epoch = value.request_epoch,
        .transaction_sequence = value.transaction_sequence,
        .resource_permit_generation = value.resource_permit_generation,
        .live_mask = value.live_mask,
        .live_lane_count = value.live_lane_count,
        .kv_transition_mask = value.kv_transition_mask,
        .terminal_mask = value.terminal_mask,
        .lane_step_indices = value.lane_step_indices,
        .token_ids = value.token_ids,
        .resource_receipt_sha256 = value.resource_receipt_sha256,
        .proposal_sha256 = value.proposal_sha256,
        .prepare_ack = adaptPrepareAck(value.prepare_ack),
        .commit_sha256 = value.commit_sha256,
    };
}

fn adaptWave(value: runner.B4TokenTxnWaveV1) wire.WaveV1 {
    return .{
        .abi_version = value.abi_version,
        .token_txn_abi = value.token_txn_abi,
        .token_txn_sink_abi = value.token_txn_sink_abi,
        .previous_sha256 = value.previous_sha256,
        .receipt = adaptWaveReceipt(value.receipt),
        .wave_sha256 = value.wave_sha256,
    };
}

fn adaptReceipt(
    value: runner.B4TokenTxnJournalReceiptV1,
) wire.JournalReceiptV1 {
    return .{
        .abi_version = value.abi_version,
        .token_txn_abi = value.token_txn_abi,
        .token_txn_sink_abi = value.token_txn_sink_abi,
        .token_txn_prepare_ack_abi = value.token_txn_prepare_ack_abi,
        .token_txn_commit_receipt_abi = value.token_txn_commit_receipt_abi,
        .resource_bank_abi = value.resource_bank_abi,
        .request_epoch = value.request_epoch,
        .expected_transaction_count = value.expected_transaction_count,
        .prepare_count = value.prepare_count,
        .commit_count = value.commit_count,
        .abort_count = value.abort_count,
        .lane_transition_count = value.lane_transition_count,
        .kv_transition_count = value.kv_transition_count,
        .first_sequence = value.first_sequence,
        .last_sequence = value.last_sequence,
        .root_binding = value.root_binding,
        .resource_receipt = adaptResourceReceipt(value.resource_receipt),
        .initial_sha256 = value.initial_sha256,
        .head_sha256 = value.head_sha256,
        .commit_timestamps_available = value.commit_timestamps_available,
    };
}

/// Adapt and independently replay one sealed runner-v6 journal.
///
/// `expectation` is a trust input, not candidate evidence.  The caller must
/// freeze it from a separately validated B4Observation or trusted manifest
/// before admitting `runner_receipt`/`runner_waves`.  This adapter deliberately
/// has no API that derives an expected root, Bank digest, head, or output matrix
/// from the candidate being checked.
pub fn adaptReplay(
    runner_receipt: runner.B4TokenTxnJournalReceiptV1,
    runner_waves: *const runner.B4TokenTxnWaveMatrix,
    expectation: wire.ReplayExpectation,
) Error!AdaptedReplay {
    try runner.verifyB4TokenTxnJournal(runner_waves, runner_receipt);
    var waves: wire.WaveMatrix = undefined;
    for (&waves, runner_waves) |*destination, source|
        destination.* = adaptWave(source);
    const receipt = adaptReceipt(runner_receipt);
    try wire.verifyReplay(receipt, &waves, expectation);
    return .{
        .receipt = receipt,
        .waves = waves,
    };
}

fn testProposal(
    sequence: usize,
    receipt: engine.resource_bank.Receipt,
    request_epoch: u64,
) engine.token_txn.ProposalV1 {
    var proposal: engine.token_txn.ProposalV1 = .{
        .request_epoch = request_epoch,
        .transaction_sequence = @intCast(sequence),
        .resource_permit_generation = @intCast(sequence + 1),
        .live_mask = 0b1111,
        .live_lane_count = wire.lane_count,
        .receipt = receipt,
    };
    for (&proposal.lanes, 0..) |*lane, lane_index| {
        const kv_after: u64 = 7 + @as(u64, @intCast(sequence));
        lane.* = .{
            .lane_index = @intCast(lane_index),
            .step_index = @intCast(sequence),
            .prompt_len = 7,
            .kv_before = if (sequence == 0) kv_after else kv_after - 1,
            .kv_after = kv_after,
            .kv_generation = if (sequence == 0) 0 else @intCast(sequence),
            .has_kv_transition = sequence != 0,
            .output_before = @intCast(sequence),
            .output_after = @intCast(sequence + 1),
            .rng_before = [_]u64{@intCast(lane_index + 1)} ** 4,
            .rng_after = [_]u64{@intCast(lane_index + 1)} ** 4,
            .sampling_calls_before = @intCast(sequence),
            .sampling_calls_after = @intCast(sequence + 1),
            .token_id = @intCast(1000 + lane_index * 100 + sequence),
            .terminal = sequence + 1 == wire.wave_count,
        };
    }
    return proposal;
}

const RunnerTestFixture = struct {
    receipt: runner.B4TokenTxnJournalReceiptV1,
    waves: runner.B4TokenTxnWaveMatrix,
    expectation: wire.ReplayExpectation,
};

/// Build candidate evidence and then freeze the verifier input as a distinct
/// value.  Production callers obtain this expectation from their independently
/// validated B4Observation or manifest, never from the candidate adapter.
fn makeRunnerTestFixture() !RunnerTestFixture {
    const request_epoch: u64 = 0x4234_5458_4e54_0001;
    var root_binding = [_]u8{0xa5} ** 32;
    root_binding[0] = 1;
    const bank_receipt: engine.resource_bank.Receipt = .{
        .bank_epoch = 0x4234_4241_4e4b_0001,
        .slot_index = 0,
        .generation = 1,
        .owner_key = 0x1234,
        .claim = .{
            .activation_bytes = 4096,
            .queue_slots = wire.lane_count,
        },
        .integrity = 0x5678,
    };
    var journal = try runner.B4TokenTxnJournal.init(
        request_epoch,
        root_binding,
    );
    const sink = journal.sink();
    var outputs: wire.LaneOutputs = undefined;
    for (0..wire.wave_count) |sequence| {
        const proposal = testProposal(sequence, bank_receipt, request_epoch);
        for (0..wire.lane_count) |lane|
            outputs[lane][sequence] = proposal.lanes[lane].token_id;
        var ack: engine.token_txn.PrepareAckV1 = .{};
        try sink.prepare(sink.context, &proposal, &ack);
        const proposal_sha256 = engine.token_txn.proposalSha256(proposal);
        const commit_receipt: engine.token_txn.CommitReceiptV1 = .{
            .proposal = proposal,
            .proposal_sha256 = proposal_sha256,
            .prepare_ack = ack,
            .commit_sha256 = engine.token_txn.commitSha256(
                proposal_sha256,
                ack,
            ),
        };
        sink.commit(sink.context, &commit_receipt);
    }
    const receipt = try journal.seal();
    var waves: runner.B4TokenTxnWaveMatrix = undefined;
    try journal.copySealedEvents(&waves);
    const resource_receipt = adaptResourceReceipt(receipt.resource_receipt);
    return .{
        .receipt = receipt,
        .waves = waves,
        .expectation = .{
            .root_binding = receipt.root_binding,
            .request_epoch = receipt.request_epoch,
            .resource_receipt_sha256 = wire.resourceReceiptSha256(
                resource_receipt,
            ),
            .head_sha256 = receipt.head_sha256,
            .lane_outputs = outputs,
        },
    };
}

test "runner-v6 adapter pins every TokenTxn and ResourceBank ABI" {
    try std.testing.expectEqual(runner.width, wire.lane_count);
    try std.testing.expectEqual(
        runner.max_tokens_per_lane,
        wire.wave_count,
    );
    const zero_wave: runner.B4TokenTxnWaveV1 = std.mem.zeroes(
        runner.B4TokenTxnWaveV1,
    );
    const mapped = adaptWave(zero_wave);
    try std.testing.expectEqual(zero_wave.abi_version, mapped.abi_version);
    try std.testing.expectEqualSlices(
        u8,
        &zero_wave.wave_sha256,
        &mapped.wave_sha256,
    );

    const zero_receipt: runner.B4TokenTxnJournalReceiptV1 = std.mem.zeroes(
        runner.B4TokenTxnJournalReceiptV1,
    );
    const zero_waves: runner.B4TokenTxnWaveMatrix = std.mem.zeroes(
        runner.B4TokenTxnWaveMatrix,
    );
    const expectation: wire.ReplayExpectation = std.mem.zeroes(
        wire.ReplayExpectation,
    );
    try std.testing.expectError(
        error.ReceiptMismatch,
        adaptReplay(zero_receipt, &zero_waves, expectation),
    );
}

test "runner-v6 sealed journal adapts losslessly and replays outputs" {
    const fixture = try makeRunnerTestFixture();
    const adapted = try adaptReplay(
        fixture.receipt,
        &fixture.waves,
        fixture.expectation,
    );
    try wire.verifyReplay(
        adapted.receipt,
        &adapted.waves,
        fixture.expectation,
    );
    try std.testing.expectEqualSlices(
        u8,
        &fixture.receipt.head_sha256,
        &adapted.receipt.head_sha256,
    );
}

test "runner-v6 adapter rejects a self-consistent opaque proposal substitution" {
    const fixture = try makeRunnerTestFixture();
    var candidate_receipt = fixture.receipt;
    var candidate_waves = fixture.waves;

    // The compact journal intentionally treats proposal_sha256 as opaque.  An
    // attacker can therefore replace one value and recompute every digest that
    // remains inside the candidate without breaking runner self-consistency.
    candidate_waves[0].receipt.proposal_sha256[0] ^= 1;
    candidate_waves[0].receipt.prepare_ack.proposal_sha256 =
        candidate_waves[0].receipt.proposal_sha256;
    candidate_waves[0].receipt.commit_sha256 = engine.token_txn.commitSha256(
        candidate_waves[0].receipt.proposal_sha256,
        candidate_waves[0].receipt.prepare_ack,
    );
    var head = candidate_receipt.initial_sha256;
    for (&candidate_waves) |*wave| {
        wave.previous_sha256 = head;
        head = wire.waveSha256(head, adaptWaveReceipt(wave.receipt));
        wave.wave_sha256 = head;
    }
    candidate_receipt.head_sha256 = head;

    try runner.verifyB4TokenTxnJournal(&candidate_waves, candidate_receipt);
    try std.testing.expectError(
        wire.Error.InvalidDigest,
        adaptReplay(
            candidate_receipt,
            &candidate_waves,
            fixture.expectation,
        ),
    );
}
