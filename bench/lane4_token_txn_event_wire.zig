//! Canonical TokenTxn raw-event-v4 wire and replay contract.
//!
//! This is deliberately separate from `lane4_event_wire.zig`: raw-event-v3
//! describes the legacy fallible per-lane publication observer, while this
//! profile serializes the timestamp-free strict-B4 TokenTxn journal retained by
//! actual-model runner v6.  One stream is exactly one journal-receipt line
//! followed by 64 wave lines.  The existing TokenTxn journal SHA-256 chain is
//! the stream commitment; no second chain and no invented commit timestamp are
//! introduced here.

const std = @import("std");

pub const schema =
    "glacier.decode-lane4/token-txn-raw-event-evidence-v4";

pub const observation_abi: u64 = 0x474c_344f_0000_0002;
pub const decode_lane4_abi: u64 = 0x4744_4c34_0000_0004;
pub const token_txn_abi: u64 = 0x4754_584e_0000_0001;
pub const token_txn_sink_abi: u64 = 0x4754_5853_0000_0001;
pub const token_txn_prepare_ack_abi: u64 = 0x4754_5841_0000_0001;
pub const token_txn_commit_receipt_abi: u64 = 0x4754_5843_0000_0001;
pub const b4_token_txn_journal_abi: u64 = 0x4742_3454_0000_0001;
pub const resource_bank_abi: u64 = 0x4752_424b_0000_0001;

pub const lane_count: usize = 4;
pub const wave_count: usize = 64;
pub const record_count: usize = wave_count + 1;
pub const total_lane_transitions: usize = lane_count * wave_count;
pub const total_kv_transitions: usize = lane_count * (wave_count - 1);
pub const max_line_bytes: usize = 16 * 1024;

const token_txn_sink_epoch_xor: u64 = 0x4234_5349_4e4b_0001;
const journal_initial_domain =
    "glacier-lane4-runner-b4-token-txn-root-v1\x00";
const journal_wave_domain =
    "glacier-lane4-runner-b4-token-txn-wave-v1\x00";
const resource_receipt_domain =
    "glacier-lane4-runner-resource-receipt-v1\x00";
const token_txn_commit_domain = "glacier-token-txn-commit-v1\x00";
const canonical_replay_domain =
    "glacier-lane4-token-txn-canonical-jsonl-v4\x00";

pub const Digest = [32]u8;
pub const LaneOutputs = [lane_count][wave_count]u32;

pub const Error = error{
    InvalidContract,
    InvalidReceipt,
    InvalidWave,
    InvalidDigest,
    InvalidSequence,
    InvalidOutput,
    TimestampClaimed,
    LineTooLarge,
};

pub const ResourceClaim = struct {
    capsule_bytes: u64 = 0,
    kv_bytes: u64 = 0,
    activation_bytes: u64 = 0,
    partial_bytes: u64 = 0,
    logits_bytes: u64 = 0,
    output_journal_bytes: u64 = 0,
    staging_bytes: u64 = 0,
    device_bytes: u64 = 0,
    io_bytes: u64 = 0,
    queue_slots: u64 = 0,
};

pub const ResourceReceipt = struct {
    bank_epoch: u64,
    slot_index: u32,
    generation: u64,
    owner_key: u64,
    claim: ResourceClaim,
    integrity: u64,
};

pub const PrepareAckV1 = struct {
    abi_version: u64 = token_txn_prepare_ack_abi,
    proposal_sha256: Digest,
    sink_epoch: u64,
    reservation_id: u64,
};

pub const WaveReceiptV1 = struct {
    abi_version: u64 = token_txn_commit_receipt_abi,
    proposal_abi: u64 = token_txn_abi,
    sink_abi: u64 = token_txn_sink_abi,
    request_epoch: u64,
    transaction_sequence: u64,
    resource_permit_generation: u64,
    live_mask: u8,
    live_lane_count: u8,
    kv_transition_mask: u8,
    terminal_mask: u8,
    lane_step_indices: [lane_count]u64,
    token_ids: [lane_count]u32,
    resource_receipt_sha256: Digest,
    proposal_sha256: Digest,
    prepare_ack: PrepareAckV1,
    commit_sha256: Digest,
};

pub const WaveV1 = struct {
    abi_version: u64 = b4_token_txn_journal_abi,
    token_txn_abi: u64 = token_txn_abi,
    token_txn_sink_abi: u64 = token_txn_sink_abi,
    previous_sha256: Digest,
    receipt: WaveReceiptV1,
    wave_sha256: Digest,
};

pub const WaveMatrix = [wave_count]WaveV1;

pub const JournalReceiptV1 = struct {
    abi_version: u64 = b4_token_txn_journal_abi,
    token_txn_abi: u64 = token_txn_abi,
    token_txn_sink_abi: u64 = token_txn_sink_abi,
    token_txn_prepare_ack_abi: u64 = token_txn_prepare_ack_abi,
    token_txn_commit_receipt_abi: u64 = token_txn_commit_receipt_abi,
    resource_bank_abi: u64 = resource_bank_abi,
    request_epoch: u64,
    expected_transaction_count: u32 = wave_count,
    prepare_count: u32,
    commit_count: u32,
    abort_count: u32,
    lane_transition_count: u32,
    kv_transition_count: u32,
    first_sequence: u64,
    last_sequence: u64,
    root_binding: Digest,
    resource_receipt: ResourceReceipt,
    initial_sha256: Digest,
    head_sha256: Digest,
    commit_timestamps_available: bool = false,
};

/// Values retained outside the JSONL stream by runner v6.  In particular the
/// expected head must be pinned externally: root/request/outputs alone would
/// permit a party to replace opaque proposal digests and recompute a new chain.
/// The 64 wave records already serialize all 4 x 64 token IDs, so replay checks
/// those IDs directly against this independently pinned output matrix.  A
/// duplicate output record or output-only digest would add no evidence.
pub const ReplayExpectation = struct {
    root_binding: Digest,
    request_epoch: u64,
    resource_receipt_sha256: Digest,
    head_sha256: Digest,
    lane_outputs: LaneOutputs,
};

fn isZeroDigest(value: Digest) bool {
    return std.mem.allEqual(u8, &value, 0);
}

fn hashU8(hash: *std.crypto.hash.sha2.Sha256, value: u8) void {
    hash.update(&.{value});
}

fn hashU32(hash: *std.crypto.hash.sha2.Sha256, value: u32) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    hash.update(&bytes);
}

fn hashU64(hash: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

pub fn resourceReceiptSha256(receipt: ResourceReceipt) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(resource_receipt_domain);
    hashU64(&hash, resource_bank_abi);
    hashU64(&hash, receipt.bank_epoch);
    hashU32(&hash, receipt.slot_index);
    hashU64(&hash, receipt.generation);
    hashU64(&hash, receipt.owner_key);
    inline for (std.meta.fields(ResourceClaim)) |field|
        hashU64(&hash, @field(receipt.claim, field.name));
    hashU64(&hash, receipt.integrity);
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

pub fn initialJournalSha256(
    root_binding: Digest,
    request_epoch: u64,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(journal_initial_domain);
    hashU64(&hash, b4_token_txn_journal_abi);
    hashU64(&hash, token_txn_abi);
    hashU64(&hash, token_txn_sink_abi);
    hashU64(&hash, token_txn_prepare_ack_abi);
    hashU64(&hash, token_txn_commit_receipt_abi);
    hashU64(&hash, resource_bank_abi);
    hashU32(&hash, lane_count);
    hashU32(&hash, wave_count);
    hashU64(&hash, request_epoch);
    hash.update(&root_binding);
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

pub fn commitSha256(
    proposal_sha256: Digest,
    ack: PrepareAckV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(token_txn_commit_domain);
    hashU64(&hash, token_txn_commit_receipt_abi);
    hash.update(&proposal_sha256);
    hashU64(&hash, ack.abi_version);
    hash.update(&ack.proposal_sha256);
    hashU64(&hash, ack.sink_epoch);
    hashU64(&hash, ack.reservation_id);
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

pub fn waveSha256(
    previous_sha256: Digest,
    receipt: WaveReceiptV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(journal_wave_domain);
    hashU64(&hash, b4_token_txn_journal_abi);
    hashU64(&hash, token_txn_abi);
    hashU64(&hash, token_txn_sink_abi);
    hash.update(&previous_sha256);
    hash.update(&receipt.resource_receipt_sha256);
    hash.update(&receipt.proposal_sha256);
    hash.update(&receipt.commit_sha256);
    hashU64(&hash, receipt.request_epoch);
    hashU64(&hash, receipt.transaction_sequence);
    hashU64(&hash, receipt.resource_permit_generation);
    hashU8(&hash, receipt.live_mask);
    hashU8(&hash, receipt.live_lane_count);
    hashU8(&hash, receipt.kv_transition_mask);
    hashU8(&hash, receipt.terminal_mask);
    for (receipt.lane_step_indices, receipt.token_ids) |step, token_id| {
        hashU64(&hash, step);
        hashU32(&hash, token_id);
    }
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn validateResourceReceipt(receipt: ResourceReceipt) Error!void {
    if (receipt.bank_epoch == 0 or receipt.slot_index != 0 or
        receipt.generation == 0 or receipt.owner_key == 0 or
        receipt.integrity == 0 or receipt.claim.queue_slots != lane_count)
        return Error.InvalidReceipt;
    // queue_slots is admission concurrency, not a byte-backed resource claim.
    // A receipt charging four queue positions but zero bytes in every resource
    // class is not valid runner-v6 actual-model evidence.
    if (receipt.claim.capsule_bytes == 0 and
        receipt.claim.kv_bytes == 0 and
        receipt.claim.activation_bytes == 0 and
        receipt.claim.partial_bytes == 0 and
        receipt.claim.logits_bytes == 0 and
        receipt.claim.output_journal_bytes == 0 and
        receipt.claim.staging_bytes == 0 and
        receipt.claim.device_bytes == 0 and
        receipt.claim.io_bytes == 0)
        return Error.InvalidReceipt;
}

fn validateJournalReceipt(
    receipt: JournalReceiptV1,
    expectation: ReplayExpectation,
) Error!Digest {
    if (receipt.abi_version != b4_token_txn_journal_abi or
        receipt.token_txn_abi != token_txn_abi or
        receipt.token_txn_sink_abi != token_txn_sink_abi or
        receipt.token_txn_prepare_ack_abi != token_txn_prepare_ack_abi or
        receipt.token_txn_commit_receipt_abi !=
            token_txn_commit_receipt_abi or
        receipt.resource_bank_abi != resource_bank_abi or
        receipt.request_epoch == 0 or
        receipt.request_epoch ^ token_txn_sink_epoch_xor == 0 or
        receipt.request_epoch != expectation.request_epoch or
        receipt.expected_transaction_count != wave_count or
        receipt.prepare_count != wave_count or
        receipt.commit_count != wave_count or receipt.abort_count != 0 or
        receipt.lane_transition_count != total_lane_transitions or
        receipt.kv_transition_count != total_kv_transitions or
        receipt.first_sequence != 0 or
        receipt.last_sequence != wave_count - 1)
        return Error.InvalidReceipt;
    if (receipt.commit_timestamps_available) return Error.TimestampClaimed;
    if (isZeroDigest(receipt.root_binding) or
        !std.mem.eql(u8, &receipt.root_binding, &expectation.root_binding) or
        !std.mem.eql(u8, &receipt.head_sha256, &expectation.head_sha256))
        return Error.InvalidDigest;
    try validateResourceReceipt(receipt.resource_receipt);
    const resource_digest = resourceReceiptSha256(receipt.resource_receipt);
    if (!std.mem.eql(
        u8,
        &resource_digest,
        &expectation.resource_receipt_sha256,
    )) return Error.InvalidDigest;
    const initial = initialJournalSha256(
        receipt.root_binding,
        receipt.request_epoch,
    );
    if (!std.mem.eql(u8, &initial, &receipt.initial_sha256))
        return Error.InvalidDigest;
    return resource_digest;
}

fn validateWave(
    wave: WaveV1,
    sequence: usize,
    request_epoch: u64,
    resource_digest: Digest,
    previous: Digest,
    outputs: LaneOutputs,
) Error!Digest {
    const receipt = wave.receipt;
    const expected_kv_mask: u8 = if (sequence == 0) 0 else 0b1111;
    const expected_terminal_mask: u8 = if (sequence + 1 == wave_count)
        0b1111
    else
        0;
    if (wave.abi_version != b4_token_txn_journal_abi or
        wave.token_txn_abi != token_txn_abi or
        wave.token_txn_sink_abi != token_txn_sink_abi or
        !std.mem.eql(u8, &wave.previous_sha256, &previous) or
        receipt.abi_version != token_txn_commit_receipt_abi or
        receipt.proposal_abi != token_txn_abi or
        receipt.sink_abi != token_txn_sink_abi or
        receipt.request_epoch != request_epoch or
        receipt.transaction_sequence != sequence or
        // A fresh runner-v6 ResourceBank publication session increments this
        // generation exactly once for every zero-abort committed wave.
        receipt.resource_permit_generation != sequence + 1 or
        receipt.live_mask != 0b1111 or
        receipt.live_lane_count != lane_count or
        receipt.kv_transition_mask != expected_kv_mask or
        receipt.terminal_mask != expected_terminal_mask or
        receipt.prepare_ack.abi_version != token_txn_prepare_ack_abi or
        receipt.prepare_ack.sink_epoch !=
            (request_epoch ^ token_txn_sink_epoch_xor) or
        receipt.prepare_ack.reservation_id != sequence + 1)
        return Error.InvalidWave;
    if (isZeroDigest(receipt.proposal_sha256) or
        !std.mem.eql(
            u8,
            &receipt.resource_receipt_sha256,
            &resource_digest,
        ) or
        !std.mem.eql(
            u8,
            &receipt.prepare_ack.proposal_sha256,
            &receipt.proposal_sha256,
        )) return Error.InvalidDigest;
    const commit_digest = commitSha256(
        receipt.proposal_sha256,
        receipt.prepare_ack,
    );
    if (!std.mem.eql(u8, &commit_digest, &receipt.commit_sha256))
        return Error.InvalidDigest;
    for (0..lane_count) |lane| {
        if (receipt.lane_step_indices[lane] != sequence or
            receipt.token_ids[lane] != outputs[lane][sequence])
            return Error.InvalidOutput;
    }
    const digest = waveSha256(previous, receipt);
    if (!std.mem.eql(u8, &digest, &wave.wave_sha256))
        return Error.InvalidDigest;
    return digest;
}

/// Verify one decoded v4 stream.  A decoder must already have rejected unknown,
/// missing, duplicate, or non-canonical JSON fields; the Python implementation
/// provides that byte-level gate.  This function owns the semantic replay gate.
pub fn verifyReplay(
    receipt: JournalReceiptV1,
    waves: *const WaveMatrix,
    expectation: ReplayExpectation,
) Error!void {
    if (expectation.request_epoch == 0 or
        expectation.request_epoch ^ token_txn_sink_epoch_xor == 0 or
        isZeroDigest(expectation.root_binding) or
        isZeroDigest(expectation.resource_receipt_sha256) or
        isZeroDigest(expectation.head_sha256))
        return Error.InvalidContract;
    const resource_digest = try validateJournalReceipt(receipt, expectation);
    var head = receipt.initial_sha256;
    for (waves, 0..) |wave, sequence| {
        head = try validateWave(
            wave,
            sequence,
            receipt.request_epoch,
            resource_digest,
            head,
            expectation.lane_outputs,
        );
    }
    if (!std.mem.eql(u8, &head, &receipt.head_sha256) or
        !std.mem.eql(u8, &head, &expectation.head_sha256))
        return Error.InvalidDigest;
}

fn writeU8(writer: *std.Io.Writer, value: u8) !void {
    try writer.print("\"{x:0>2}\"", .{value});
}

fn writeU32(writer: *std.Io.Writer, value: u32) !void {
    try writer.print("\"{x:0>8}\"", .{value});
}

fn writeU64(writer: *std.Io.Writer, value: u64) !void {
    try writer.print("\"{x:0>16}\"", .{value});
}

fn writeDigest(writer: *std.Io.Writer, value: Digest) !void {
    const text = std.fmt.bytesToHex(value, .lower);
    try writer.print("\"{s}\"", .{&text});
}

fn writeClaim(writer: *std.Io.Writer, claim: ResourceClaim) !void {
    try writer.writeAll("{\"capsule_bytes\":");
    try writeU64(writer, claim.capsule_bytes);
    try writer.writeAll(",\"kv_bytes\":");
    try writeU64(writer, claim.kv_bytes);
    try writer.writeAll(",\"activation_bytes\":");
    try writeU64(writer, claim.activation_bytes);
    try writer.writeAll(",\"partial_bytes\":");
    try writeU64(writer, claim.partial_bytes);
    try writer.writeAll(",\"logits_bytes\":");
    try writeU64(writer, claim.logits_bytes);
    try writer.writeAll(",\"output_journal_bytes\":");
    try writeU64(writer, claim.output_journal_bytes);
    try writer.writeAll(",\"staging_bytes\":");
    try writeU64(writer, claim.staging_bytes);
    try writer.writeAll(",\"device_bytes\":");
    try writeU64(writer, claim.device_bytes);
    try writer.writeAll(",\"io_bytes\":");
    try writeU64(writer, claim.io_bytes);
    try writer.writeAll(",\"queue_slots\":");
    try writeU64(writer, claim.queue_slots);
    try writer.writeAll("}");
}

fn writeResourceReceipt(
    writer: *std.Io.Writer,
    receipt: ResourceReceipt,
) !void {
    try writer.writeAll("{\"bank_epoch\":");
    try writeU64(writer, receipt.bank_epoch);
    try writer.writeAll(",\"slot_index\":");
    try writeU32(writer, receipt.slot_index);
    try writer.writeAll(",\"generation\":");
    try writeU64(writer, receipt.generation);
    try writer.writeAll(",\"owner_key\":");
    try writeU64(writer, receipt.owner_key);
    try writer.writeAll(",\"claim\":");
    try writeClaim(writer, receipt.claim);
    try writer.writeAll(",\"integrity\":");
    try writeU64(writer, receipt.integrity);
    try writer.writeAll("}");
}

fn writePrepareAck(writer: *std.Io.Writer, ack: PrepareAckV1) !void {
    try writer.writeAll("{\"abi_version\":");
    try writeU64(writer, ack.abi_version);
    try writer.writeAll(",\"proposal_sha256\":");
    try writeDigest(writer, ack.proposal_sha256);
    try writer.writeAll(",\"sink_epoch\":");
    try writeU64(writer, ack.sink_epoch);
    try writer.writeAll(",\"reservation_id\":");
    try writeU64(writer, ack.reservation_id);
    try writer.writeAll("}");
}

fn writeWaveReceipt(writer: *std.Io.Writer, receipt: WaveReceiptV1) !void {
    try writer.writeAll("{\"abi_version\":");
    try writeU64(writer, receipt.abi_version);
    try writer.writeAll(",\"proposal_abi\":");
    try writeU64(writer, receipt.proposal_abi);
    try writer.writeAll(",\"sink_abi\":");
    try writeU64(writer, receipt.sink_abi);
    try writer.writeAll(",\"request_epoch\":");
    try writeU64(writer, receipt.request_epoch);
    try writer.writeAll(",\"transaction_sequence\":");
    try writeU64(writer, receipt.transaction_sequence);
    try writer.writeAll(",\"resource_permit_generation\":");
    try writeU64(writer, receipt.resource_permit_generation);
    try writer.writeAll(",\"live_mask\":");
    try writeU8(writer, receipt.live_mask);
    try writer.writeAll(",\"live_lane_count\":");
    try writeU8(writer, receipt.live_lane_count);
    try writer.writeAll(",\"kv_transition_mask\":");
    try writeU8(writer, receipt.kv_transition_mask);
    try writer.writeAll(",\"terminal_mask\":");
    try writeU8(writer, receipt.terminal_mask);
    try writer.writeAll(",\"lane_step_indices\":[");
    for (receipt.lane_step_indices, 0..) |step, lane| {
        if (lane != 0) try writer.writeAll(",");
        try writeU64(writer, step);
    }
    try writer.writeAll("],\"token_ids\":[");
    for (receipt.token_ids, 0..) |token, lane| {
        if (lane != 0) try writer.writeAll(",");
        try writeU32(writer, token);
    }
    try writer.writeAll("],\"resource_receipt_sha256\":");
    try writeDigest(writer, receipt.resource_receipt_sha256);
    try writer.writeAll(",\"proposal_sha256\":");
    try writeDigest(writer, receipt.proposal_sha256);
    try writer.writeAll(",\"prepare_ack\":");
    try writePrepareAck(writer, receipt.prepare_ack);
    try writer.writeAll(",\"commit_sha256\":");
    try writeDigest(writer, receipt.commit_sha256);
    try writer.writeAll("}");
}

/// Canonical receipt line.  Key order is normative and intentionally mirrors
/// the in-memory runner receipt rather than lexicographic JSON ordering.
pub fn writeJournalReceiptLine(
    writer: *std.Io.Writer,
    receipt: JournalReceiptV1,
) !void {
    try writer.print("{{\"schema\":\"{s}\",\"kind\":\"journal_receipt\",\"observation_abi\":", .{schema});
    try writeU64(writer, observation_abi);
    try writer.writeAll(",\"decode_lane4_abi\":");
    try writeU64(writer, decode_lane4_abi);
    try writer.writeAll(",\"journal_receipt\":{\"abi_version\":");
    try writeU64(writer, receipt.abi_version);
    try writer.writeAll(",\"token_txn_abi\":");
    try writeU64(writer, receipt.token_txn_abi);
    try writer.writeAll(",\"token_txn_sink_abi\":");
    try writeU64(writer, receipt.token_txn_sink_abi);
    try writer.writeAll(",\"token_txn_prepare_ack_abi\":");
    try writeU64(writer, receipt.token_txn_prepare_ack_abi);
    try writer.writeAll(",\"token_txn_commit_receipt_abi\":");
    try writeU64(writer, receipt.token_txn_commit_receipt_abi);
    try writer.writeAll(",\"resource_bank_abi\":");
    try writeU64(writer, receipt.resource_bank_abi);
    try writer.writeAll(",\"request_epoch\":");
    try writeU64(writer, receipt.request_epoch);
    try writer.writeAll(",\"expected_transaction_count\":");
    try writeU32(writer, receipt.expected_transaction_count);
    try writer.writeAll(",\"prepare_count\":");
    try writeU32(writer, receipt.prepare_count);
    try writer.writeAll(",\"commit_count\":");
    try writeU32(writer, receipt.commit_count);
    try writer.writeAll(",\"abort_count\":");
    try writeU32(writer, receipt.abort_count);
    try writer.writeAll(",\"lane_transition_count\":");
    try writeU32(writer, receipt.lane_transition_count);
    try writer.writeAll(",\"kv_transition_count\":");
    try writeU32(writer, receipt.kv_transition_count);
    try writer.writeAll(",\"first_sequence\":");
    try writeU64(writer, receipt.first_sequence);
    try writer.writeAll(",\"last_sequence\":");
    try writeU64(writer, receipt.last_sequence);
    try writer.writeAll(",\"root_binding_sha256\":");
    try writeDigest(writer, receipt.root_binding);
    try writer.writeAll(",\"resource_receipt\":");
    try writeResourceReceipt(writer, receipt.resource_receipt);
    try writer.writeAll(",\"initial_sha256\":");
    try writeDigest(writer, receipt.initial_sha256);
    try writer.writeAll(",\"head_sha256\":");
    try writeDigest(writer, receipt.head_sha256);
    try writer.print(",\"commit_timestamps_available\":{s}}}}}\n", .{
        if (receipt.commit_timestamps_available) "true" else "false",
    });
}

pub fn writeWaveLine(
    writer: *std.Io.Writer,
    record_sequence: u64,
    wave: WaveV1,
) !void {
    if (record_sequence >= wave_count or
        wave.receipt.transaction_sequence != record_sequence)
        return Error.InvalidSequence;
    try writer.print("{{\"schema\":\"{s}\",\"kind\":\"token_txn_wave\",\"record_sequence\":", .{schema});
    try writeU64(writer, record_sequence);
    try writer.writeAll(",\"wave\":{\"abi_version\":");
    try writeU64(writer, wave.abi_version);
    try writer.writeAll(",\"token_txn_abi\":");
    try writeU64(writer, wave.token_txn_abi);
    try writer.writeAll(",\"token_txn_sink_abi\":");
    try writeU64(writer, wave.token_txn_sink_abi);
    try writer.writeAll(",\"previous_sha256\":");
    try writeDigest(writer, wave.previous_sha256);
    try writer.writeAll(",\"receipt\":");
    try writeWaveReceipt(writer, wave.receipt);
    try writer.writeAll(",\"wave_sha256\":");
    try writeDigest(writer, wave.wave_sha256);
    try writer.writeAll("}}\n");
}

pub fn writeReplay(
    writer: *std.Io.Writer,
    receipt: JournalReceiptV1,
    waves: *const WaveMatrix,
    expectation: ReplayExpectation,
) !void {
    try verifyReplay(receipt, waves, expectation);
    try writeJournalReceiptLine(writer, receipt);
    for (waves, 0..) |wave, sequence|
        try writeWaveLine(writer, @intCast(sequence), wave);
}

/// Digest the exact 65 canonical JSONL records without allocating one large
/// transcript.  This digest is a cross-language golden, not a replacement for
/// the externally pinned TokenTxn journal head.
pub fn canonicalReplaySha256(
    receipt: JournalReceiptV1,
    waves: *const WaveMatrix,
    expectation: ReplayExpectation,
) !Digest {
    try verifyReplay(receipt, waves, expectation);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(canonical_replay_domain);
    hashU32(&hash, record_count);

    var storage: [max_line_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    writeJournalReceiptLine(&writer, receipt) catch return Error.LineTooLarge;
    const receipt_line = writer.buffered();
    hashU64(&hash, receipt_line.len);
    hash.update(receipt_line);

    for (waves, 0..) |wave, sequence| {
        writer = std.Io.Writer.fixed(&storage);
        writeWaveLine(&writer, @intCast(sequence), wave) catch
            return Error.LineTooLarge;
        const line = writer.buffered();
        hashU64(&hash, line.len);
        hash.update(line);
    }
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

const TestFixture = struct {
    receipt: JournalReceiptV1,
    waves: WaveMatrix,
    expectation: ReplayExpectation,
};

fn testDigest(label: []const u8, sequence: usize) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-lane4-token-txn-v4-test-fixture\x00");
    hashU64(&hash, label.len);
    hash.update(label);
    hashU64(&hash, sequence);
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn makeTestFixture() TestFixture {
    const root_binding = testDigest("root-binding", 0);
    const request_epoch: u64 = 0x166c_0c70_0c7f_0081;
    const bank_receipt: ResourceReceipt = .{
        .bank_epoch = 0x4234_4241_4e4b_0080,
        .slot_index = 0,
        .generation = 1,
        .owner_key = 0xc7ec_8fbc_6eaa_ed23,
        .claim = .{
            .capsule_bytes = 0x101,
            .kv_bytes = 0x202,
            .activation_bytes = 0x303,
            .partial_bytes = 0x404,
            .logits_bytes = 0x505,
            .output_journal_bytes = 0x606,
            .staging_bytes = 0x707,
            .device_bytes = 0x808,
            .io_bytes = 0x909,
            .queue_slots = lane_count,
        },
        .integrity = 0xe295_a727_52c3_77d5,
    };
    const resource_digest = resourceReceiptSha256(bank_receipt);
    const initial = initialJournalSha256(root_binding, request_epoch);
    var waves: WaveMatrix = undefined;
    var outputs: LaneOutputs = undefined;
    var head = initial;
    for (&waves, 0..) |*wave, sequence| {
        var token_ids: [lane_count]u32 = undefined;
        for (0..lane_count) |lane| {
            const token: u32 = @intCast(1 + lane * 10_000 + sequence);
            token_ids[lane] = token;
            outputs[lane][sequence] = token;
        }
        const proposal_digest = testDigest("proposal", sequence);
        const ack: PrepareAckV1 = .{
            .proposal_sha256 = proposal_digest,
            .sink_epoch = request_epoch ^ token_txn_sink_epoch_xor,
            .reservation_id = sequence + 1,
        };
        const compact_receipt: WaveReceiptV1 = .{
            .request_epoch = request_epoch,
            .transaction_sequence = sequence,
            .resource_permit_generation = sequence + 1,
            .live_mask = 0b1111,
            .live_lane_count = lane_count,
            .kv_transition_mask = if (sequence == 0) 0 else 0b1111,
            .terminal_mask = if (sequence + 1 == wave_count)
                0b1111
            else
                0,
            .lane_step_indices = [_]u64{@intCast(sequence)} ** lane_count,
            .token_ids = token_ids,
            .resource_receipt_sha256 = resource_digest,
            .proposal_sha256 = proposal_digest,
            .prepare_ack = ack,
            .commit_sha256 = commitSha256(proposal_digest, ack),
        };
        const wave_digest = waveSha256(head, compact_receipt);
        wave.* = .{
            .previous_sha256 = head,
            .receipt = compact_receipt,
            .wave_sha256 = wave_digest,
        };
        head = wave_digest;
    }
    const receipt: JournalReceiptV1 = .{
        .request_epoch = request_epoch,
        .prepare_count = wave_count,
        .commit_count = wave_count,
        .abort_count = 0,
        .lane_transition_count = total_lane_transitions,
        .kv_transition_count = total_kv_transitions,
        .first_sequence = 0,
        .last_sequence = wave_count - 1,
        .root_binding = root_binding,
        .resource_receipt = bank_receipt,
        .initial_sha256 = initial,
        .head_sha256 = head,
    };
    return .{
        .receipt = receipt,
        .waves = waves,
        .expectation = .{
            .root_binding = root_binding,
            .request_epoch = request_epoch,
            .resource_receipt_sha256 = resource_digest,
            .head_sha256 = head,
            .lane_outputs = outputs,
        },
    };
}

fn rehashTestFixtureResource(fixture: *TestFixture) void {
    const resource_digest = resourceReceiptSha256(
        fixture.receipt.resource_receipt,
    );
    fixture.expectation.resource_receipt_sha256 = resource_digest;
    var head = fixture.receipt.initial_sha256;
    for (&fixture.waves) |*wave| {
        wave.previous_sha256 = head;
        wave.receipt.resource_receipt_sha256 = resource_digest;
        wave.wave_sha256 = waveSha256(head, wave.receipt);
        head = wave.wave_sha256;
    }
    fixture.receipt.head_sha256 = head;
    fixture.expectation.head_sha256 = head;
}

const Mutation = enum {
    receipt_abi_version,
    receipt_token_txn_abi,
    receipt_token_txn_sink_abi,
    receipt_prepare_ack_abi,
    receipt_commit_receipt_abi,
    receipt_resource_bank_abi,
    receipt_request_epoch,
    receipt_expected_transaction_count,
    receipt_prepare_count,
    receipt_commit_count,
    receipt_abort_count,
    receipt_lane_transition_count,
    receipt_kv_transition_count,
    receipt_first_sequence,
    receipt_last_sequence,
    receipt_root_binding,
    bank_epoch,
    bank_slot_index,
    bank_generation,
    bank_owner_key,
    claim_capsule_bytes,
    claim_kv_bytes,
    claim_activation_bytes,
    claim_partial_bytes,
    claim_logits_bytes,
    claim_output_journal_bytes,
    claim_staging_bytes,
    claim_device_bytes,
    claim_io_bytes,
    claim_queue_slots,
    bank_integrity,
    receipt_initial_sha256,
    receipt_head_sha256,
    receipt_commit_timestamps_available,
    wave_abi_version,
    wave_token_txn_abi,
    wave_token_txn_sink_abi,
    wave_previous_sha256,
    wave_receipt_abi_version,
    wave_proposal_abi,
    wave_sink_abi,
    wave_request_epoch,
    wave_transaction_sequence,
    wave_resource_permit_generation,
    wave_live_mask,
    wave_live_lane_count,
    wave_kv_transition_mask,
    wave_terminal_mask,
    wave_lane_step_indices,
    wave_token_ids,
    wave_resource_receipt_sha256,
    wave_proposal_sha256,
    ack_abi_version,
    ack_proposal_sha256,
    ack_sink_epoch,
    ack_reservation_id,
    wave_commit_sha256,
    wave_sha256,
    expected_output_token,
};

fn mutateFixture(fixture: *TestFixture, mutation: Mutation) void {
    const middle = 7;
    switch (mutation) {
        .receipt_abi_version => fixture.receipt.abi_version +%= 1,
        .receipt_token_txn_abi => fixture.receipt.token_txn_abi +%= 1,
        .receipt_token_txn_sink_abi => fixture.receipt.token_txn_sink_abi +%= 1,
        .receipt_prepare_ack_abi => fixture.receipt.token_txn_prepare_ack_abi +%= 1,
        .receipt_commit_receipt_abi => fixture.receipt.token_txn_commit_receipt_abi +%= 1,
        .receipt_resource_bank_abi => fixture.receipt.resource_bank_abi +%= 1,
        .receipt_request_epoch => fixture.receipt.request_epoch +%= 1,
        .receipt_expected_transaction_count => fixture.receipt.expected_transaction_count -%= 1,
        .receipt_prepare_count => fixture.receipt.prepare_count -%= 1,
        .receipt_commit_count => fixture.receipt.commit_count -%= 1,
        .receipt_abort_count => fixture.receipt.abort_count +%= 1,
        .receipt_lane_transition_count => fixture.receipt.lane_transition_count -%= 1,
        .receipt_kv_transition_count => fixture.receipt.kv_transition_count -%= 1,
        .receipt_first_sequence => fixture.receipt.first_sequence +%= 1,
        .receipt_last_sequence => fixture.receipt.last_sequence -%= 1,
        .receipt_root_binding => fixture.receipt.root_binding[0] ^= 1,
        .bank_epoch => fixture.receipt.resource_receipt.bank_epoch +%= 1,
        .bank_slot_index => fixture.receipt.resource_receipt.slot_index +%= 1,
        .bank_generation => fixture.receipt.resource_receipt.generation +%= 1,
        .bank_owner_key => fixture.receipt.resource_receipt.owner_key +%= 1,
        .claim_capsule_bytes => fixture.receipt.resource_receipt.claim.capsule_bytes +%= 1,
        .claim_kv_bytes => fixture.receipt.resource_receipt.claim.kv_bytes +%= 1,
        .claim_activation_bytes => fixture.receipt.resource_receipt.claim.activation_bytes +%= 1,
        .claim_partial_bytes => fixture.receipt.resource_receipt.claim.partial_bytes +%= 1,
        .claim_logits_bytes => fixture.receipt.resource_receipt.claim.logits_bytes +%= 1,
        .claim_output_journal_bytes => fixture.receipt.resource_receipt.claim.output_journal_bytes +%= 1,
        .claim_staging_bytes => fixture.receipt.resource_receipt.claim.staging_bytes +%= 1,
        .claim_device_bytes => fixture.receipt.resource_receipt.claim.device_bytes +%= 1,
        .claim_io_bytes => fixture.receipt.resource_receipt.claim.io_bytes +%= 1,
        .claim_queue_slots => fixture.receipt.resource_receipt.claim.queue_slots +%= 1,
        .bank_integrity => fixture.receipt.resource_receipt.integrity +%= 1,
        .receipt_initial_sha256 => fixture.receipt.initial_sha256[0] ^= 1,
        .receipt_head_sha256 => fixture.receipt.head_sha256[0] ^= 1,
        .receipt_commit_timestamps_available => fixture.receipt.commit_timestamps_available = true,
        .wave_abi_version => fixture.waves[middle].abi_version +%= 1,
        .wave_token_txn_abi => fixture.waves[middle].token_txn_abi +%= 1,
        .wave_token_txn_sink_abi => fixture.waves[middle].token_txn_sink_abi +%= 1,
        .wave_previous_sha256 => fixture.waves[middle].previous_sha256[0] ^= 1,
        .wave_receipt_abi_version => fixture.waves[middle].receipt.abi_version +%= 1,
        .wave_proposal_abi => fixture.waves[middle].receipt.proposal_abi +%= 1,
        .wave_sink_abi => fixture.waves[middle].receipt.sink_abi +%= 1,
        .wave_request_epoch => fixture.waves[middle].receipt.request_epoch +%= 1,
        .wave_transaction_sequence => fixture.waves[middle].receipt.transaction_sequence +%= 1,
        .wave_resource_permit_generation => fixture.waves[middle].receipt.resource_permit_generation +%= 1,
        .wave_live_mask => fixture.waves[middle].receipt.live_mask ^= 1,
        .wave_live_lane_count => fixture.waves[middle].receipt.live_lane_count -%= 1,
        .wave_kv_transition_mask => fixture.waves[middle].receipt.kv_transition_mask ^= 1,
        .wave_terminal_mask => fixture.waves[middle].receipt.terminal_mask ^= 1,
        .wave_lane_step_indices => fixture.waves[middle].receipt.lane_step_indices[2] +%= 1,
        .wave_token_ids => fixture.waves[middle].receipt.token_ids[2] +%= 1,
        .wave_resource_receipt_sha256 => fixture.waves[middle].receipt.resource_receipt_sha256[0] ^= 1,
        .wave_proposal_sha256 => fixture.waves[middle].receipt.proposal_sha256[0] ^= 1,
        .ack_abi_version => fixture.waves[middle].receipt.prepare_ack.abi_version +%= 1,
        .ack_proposal_sha256 => fixture.waves[middle].receipt.prepare_ack.proposal_sha256[0] ^= 1,
        .ack_sink_epoch => fixture.waves[middle].receipt.prepare_ack.sink_epoch +%= 1,
        .ack_reservation_id => fixture.waves[middle].receipt.prepare_ack.reservation_id +%= 1,
        .wave_commit_sha256 => fixture.waves[middle].receipt.commit_sha256[0] ^= 1,
        .wave_sha256 => fixture.waves[middle].wave_sha256[0] ^= 1,
        .expected_output_token => fixture.expectation.lane_outputs[2][middle] +%= 1,
    }
}

fn expectReplayRejected(fixture: TestFixture) !void {
    if (verifyReplay(
        fixture.receipt,
        &fixture.waves,
        fixture.expectation,
    )) |_| {
        return error.TestExpectedError;
    } else |_| {}
}

test "TokenTxn raw-event-v4 replays one exact timestamp-free 64-wave ledger" {
    const fixture = makeTestFixture();
    try verifyReplay(
        fixture.receipt,
        &fixture.waves,
        fixture.expectation,
    );
    try std.testing.expect(!fixture.receipt.commit_timestamps_available);
    try std.testing.expectEqual(
        wave_count + 1,
        record_count,
    );

    var storage: [max_line_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try writeJournalReceiptLine(&writer, fixture.receipt);
    try std.testing.expect(std.mem.indexOf(
        u8,
        writer.buffered(),
        "monotonic_ns",
    ) == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        writer.buffered(),
        "commit_timestamp_ns",
    ) == null);
}

test "TokenTxn raw-event-v4 rejects every serialized semantic field mutation" {
    inline for (std.meta.tags(Mutation)) |mutation| {
        var fixture = makeTestFixture();
        mutateFixture(&fixture, mutation);
        try expectReplayRejected(fixture);
    }
}

test "TokenTxn raw-event-v4 rejects queue-only ResourceBank claims after rehash" {
    var fixture = makeTestFixture();
    fixture.receipt.resource_receipt.claim = .{
        .queue_slots = lane_count,
    };
    rehashTestFixtureResource(&fixture);
    try std.testing.expectError(
        Error.InvalidReceipt,
        verifyReplay(
            fixture.receipt,
            &fixture.waves,
            fixture.expectation,
        ),
    );
}

test "TokenTxn raw-event-v4 canonical replay cross-language golden" {
    const fixture = makeTestFixture();
    const actual = try canonicalReplaySha256(
        fixture.receipt,
        &fixture.waves,
        fixture.expectation,
    );
    // Filled from the Zig implementation first and independently asserted by
    // the Python codec.  Changing canonical key order or integer width is an
    // explicit v4 wire break.
    const expected = Digest{
        0x38, 0x12, 0x40, 0xf7, 0x83, 0xf4, 0x30, 0x54,
        0xf1, 0x6c, 0x98, 0xc6, 0xcd, 0x70, 0xe1, 0x68,
        0x8e, 0x4a, 0xc5, 0xf2, 0x3a, 0x0f, 0x0f, 0xbf,
        0xe8, 0x8c, 0xad, 0xab, 0xf8, 0x4c, 0x3e, 0xaa,
    };
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}
