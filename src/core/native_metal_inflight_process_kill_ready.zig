//! Canonical ready-frame evidence for one bounded native Metal in-flight
//! process-kill boundary.
//!
//! The frame is pointer-free and allocation-free. It records only the exact
//! pre-signal state observed by the victim process. It does not itself prove
//! that a signal was sent, that a process died, that output was recovered, or
//! that native resources were physically reclaimed.

const std = @import("std");

pub const Digest = [32]u8;
pub const zero_digest: Digest = [_]u8{0} ** 32;

pub const ready_frame_abi: u64 = 0x4757_494b_0000_0001;
pub const ready_frame_encoded_bytes: usize = 512;
pub const ready_frame_rooted_bytes: usize = 480;
pub const allowed_flags: u64 = 0;

pub const submitted_disposition: u64 = 1;
pub const command_buffer_status_committed: u64 = 2;
pub const command_buffer_status_scheduled: u64 = 3;
pub const expected_commit_invoked: u64 = 1;
pub const expected_completion_observed: u64 = 0;
pub const expected_shared_event_signaled_value: u64 = 1;
pub const expected_encoded_signal_value: u64 = 1;
pub const expected_encoded_wait_value: u64 = 2;
pub const expected_live_native_buffer_count: u64 = 4;
pub const expected_live_native_command_count: u64 = 1;
pub const expected_active_allocation_reference_count: u64 = 4;

const scalar_count: usize = 16;
const digest_count: usize = 12;
const rooted_digest_count: usize = digest_count - 1;
const frame_root_domain =
    "glacier-w7b-b4-metal-inflight-ready-frame-v1\x00";

comptime {
    if (@sizeOf(Digest) != 32 or
        scalar_count * @sizeOf(u64) +
            digest_count * @sizeOf(Digest) !=
            ready_frame_encoded_bytes or
        scalar_count * @sizeOf(u64) +
            rooted_digest_count * @sizeOf(Digest) !=
            ready_frame_rooted_bytes)
        @compileError("native Metal in-flight ready-frame layout drift");
}

pub const Error = error{
    BufferTooSmall,
    InvalidAbi,
    InvalidBarrier,
    InvalidCommandStatus,
    InvalidCounts,
    InvalidFlags,
    InvalidGeneration,
    InvalidIdentity,
    InvalidLength,
    InvalidProcess,
    InvalidRoot,
    InvalidSubmissionDisposition,
};

/// Exact 512-byte logical frame. Encoding is explicit little-endian and does
/// not depend on this Zig struct's in-memory representation.
pub const ReadyFrameV1 = struct {
    abi_version: u64 = ready_frame_abi,
    encoded_bytes: u64 = ready_frame_encoded_bytes,
    flags: u64 = allowed_flags,
    pid: u64,
    barrier_generation: u64,
    command_generation: u64,
    submission_disposition: u64 = submitted_disposition,
    command_buffer_status: u64,
    commit_invoked: u64 = expected_commit_invoked,
    completion_observed: u64 = expected_completion_observed,
    shared_event_signaled_value: u64 =
        expected_shared_event_signaled_value,
    encoded_signal_value: u64 = expected_encoded_signal_value,
    encoded_wait_value: u64 = expected_encoded_wait_value,
    live_native_buffer_count: u64 =
        expected_live_native_buffer_count,
    live_native_command_count: u64 =
        expected_live_native_command_count,
    active_allocation_reference_count: u64 =
        expected_active_allocation_reference_count,

    challenge_sha256: Digest,
    victim_sha256: Digest,
    metallib_sha256: Digest,
    build_sha256: Digest,
    machine_sha256: Digest,
    backend_sha256: Digest,
    device_sha256: Digest,
    placement_sha256: Digest,
    ticket_sha256: Digest,
    pin_sha256: Digest,
    submission_sha256: Digest,
    frame_sha256: Digest = zero_digest,
};

/// Canonicalize the fixed envelope, derive the frame root, and validate every
/// retained semantic field. Evidence fields are never silently rewritten.
pub fn makeReadyFrameV1(seed: ReadyFrameV1) Error!ReadyFrameV1 {
    var result = seed;
    result.abi_version = ready_frame_abi;
    result.encoded_bytes = ready_frame_encoded_bytes;
    result.flags = allowed_flags;
    result.frame_sha256 = zero_digest;
    result.frame_sha256 = readyFrameRootV1(result);
    try validateReadyFrameV1(result);
    return result;
}

pub const makeV1 = makeReadyFrameV1;

/// SHA-256(domain || canonical bytes[0..480]).
pub fn readyFrameRootV1(value: ReadyFrameV1) Digest {
    var rooted: [ready_frame_rooted_bytes]u8 = undefined;
    encodeRootedBytesV1(value, &rooted);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(frame_root_domain);
    hash.update(&rooted);
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

pub const rootV1 = readyFrameRootV1;

pub fn validateReadyFrameV1(value: ReadyFrameV1) Error!void {
    if (value.abi_version != ready_frame_abi)
        return Error.InvalidAbi;
    if (value.encoded_bytes != ready_frame_encoded_bytes)
        return Error.InvalidLength;
    if (value.flags != allowed_flags)
        return Error.InvalidFlags;
    if (!positiveGeneration(value.pid))
        return Error.InvalidProcess;
    if (!positiveGeneration(value.barrier_generation) or
        !positiveGeneration(value.command_generation))
        return Error.InvalidGeneration;
    if (value.submission_disposition != submitted_disposition)
        return Error.InvalidSubmissionDisposition;
    if (value.command_buffer_status !=
        command_buffer_status_committed and
        value.command_buffer_status !=
            command_buffer_status_scheduled)
        return Error.InvalidCommandStatus;
    if (value.commit_invoked != expected_commit_invoked or
        value.completion_observed != expected_completion_observed or
        value.shared_event_signaled_value !=
            expected_shared_event_signaled_value or
        value.encoded_signal_value !=
            expected_encoded_signal_value or
        value.encoded_wait_value != expected_encoded_wait_value)
        return Error.InvalidBarrier;
    if (value.live_native_buffer_count !=
        expected_live_native_buffer_count or
        value.live_native_command_count !=
            expected_live_native_command_count or
        value.active_allocation_reference_count !=
            expected_active_allocation_reference_count)
        return Error.InvalidCounts;

    for (identityDigestsV1(value)) |identity| {
        if (digestIsZero(identity))
            return Error.InvalidIdentity;
    }
    if (digestIsZero(value.frame_sha256))
        return Error.InvalidIdentity;
    if (!digestEqual(
        value.frame_sha256,
        readyFrameRootV1(value),
    ))
        return Error.InvalidRoot;
}

pub const validateV1 = validateReadyFrameV1;

/// Encode into exactly 512 caller-owned bytes.
pub fn encodeReadyFrameV1(
    value: ReadyFrameV1,
    output: []u8,
) Error![]const u8 {
    if (output.len < ready_frame_encoded_bytes)
        return Error.BufferTooSmall;
    if (output.len != ready_frame_encoded_bytes)
        return Error.InvalidLength;
    try validateReadyFrameV1(value);
    encodeUncheckedV1(
        value,
        output[0..ready_frame_encoded_bytes],
    );
    return output;
}

pub const encodeV1 = encodeReadyFrameV1;

/// Decode only an exact 512-byte canonical wire.
pub fn decodeReadyFrameV1(encoded: []const u8) Error!ReadyFrameV1 {
    if (encoded.len != ready_frame_encoded_bytes)
        return Error.InvalidLength;
    var reader: Reader = .{ .bytes = encoded };
    var scalars: [scalar_count]u64 = undefined;
    for (&scalars) |*scalar|
        scalar.* = reader.readU64();
    var digests: [digest_count]Digest = undefined;
    for (&digests) |*digest|
        digest.* = reader.readDigest();
    if (reader.position != ready_frame_encoded_bytes)
        return Error.InvalidLength;

    const result: ReadyFrameV1 = .{
        .abi_version = scalars[0],
        .encoded_bytes = scalars[1],
        .flags = scalars[2],
        .pid = scalars[3],
        .barrier_generation = scalars[4],
        .command_generation = scalars[5],
        .submission_disposition = scalars[6],
        .command_buffer_status = scalars[7],
        .commit_invoked = scalars[8],
        .completion_observed = scalars[9],
        .shared_event_signaled_value = scalars[10],
        .encoded_signal_value = scalars[11],
        .encoded_wait_value = scalars[12],
        .live_native_buffer_count = scalars[13],
        .live_native_command_count = scalars[14],
        .active_allocation_reference_count = scalars[15],
        .challenge_sha256 = digests[0],
        .victim_sha256 = digests[1],
        .metallib_sha256 = digests[2],
        .build_sha256 = digests[3],
        .machine_sha256 = digests[4],
        .backend_sha256 = digests[5],
        .device_sha256 = digests[6],
        .placement_sha256 = digests[7],
        .ticket_sha256 = digests[8],
        .pin_sha256 = digests[9],
        .submission_sha256 = digests[10],
        .frame_sha256 = digests[11],
    };
    try validateReadyFrameV1(result);
    return result;
}

pub const decodeV1 = decodeReadyFrameV1;

fn positiveGeneration(value: u64) bool {
    return value != 0 and value != std.math.maxInt(u64);
}

fn identityDigestsV1(
    value: ReadyFrameV1,
) [rooted_digest_count]Digest {
    return .{
        value.challenge_sha256,
        value.victim_sha256,
        value.metallib_sha256,
        value.build_sha256,
        value.machine_sha256,
        value.backend_sha256,
        value.device_sha256,
        value.placement_sha256,
        value.ticket_sha256,
        value.pin_sha256,
        value.submission_sha256,
    };
}

fn scalarValuesV1(value: ReadyFrameV1) [scalar_count]u64 {
    return .{
        value.abi_version,
        value.encoded_bytes,
        value.flags,
        value.pid,
        value.barrier_generation,
        value.command_generation,
        value.submission_disposition,
        value.command_buffer_status,
        value.commit_invoked,
        value.completion_observed,
        value.shared_event_signaled_value,
        value.encoded_signal_value,
        value.encoded_wait_value,
        value.live_native_buffer_count,
        value.live_native_command_count,
        value.active_allocation_reference_count,
    };
}

fn encodeRootedBytesV1(
    value: ReadyFrameV1,
    output: *[ready_frame_rooted_bytes]u8,
) void {
    var writer: Writer = .{ .bytes = output };
    for (scalarValuesV1(value)) |scalar|
        writer.writeU64(scalar);
    for (identityDigestsV1(value)) |identity|
        writer.writeDigest(identity);
    std.debug.assert(writer.position == ready_frame_rooted_bytes);
}

fn encodeUncheckedV1(
    value: ReadyFrameV1,
    output: []u8,
) void {
    std.debug.assert(output.len == ready_frame_encoded_bytes);
    var writer: Writer = .{ .bytes = output };
    for (scalarValuesV1(value)) |scalar|
        writer.writeU64(scalar);
    for (identityDigestsV1(value)) |identity|
        writer.writeDigest(identity);
    writer.writeDigest(value.frame_sha256);
    std.debug.assert(writer.position == ready_frame_encoded_bytes);
}

fn digestIsZero(value: Digest) bool {
    return digestEqual(value, zero_digest);
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

const Writer = struct {
    bytes: []u8,
    position: usize = 0,

    fn writeU64(self: *Writer, value: u64) void {
        const end = self.position + @sizeOf(u64);
        std.mem.writeInt(
            u64,
            self.bytes[self.position..end][0..8],
            value,
            .little,
        );
        self.position = end;
    }

    fn writeDigest(self: *Writer, value: Digest) void {
        const end = self.position + @sizeOf(Digest);
        @memcpy(self.bytes[self.position..end], &value);
        self.position = end;
    }
};

const Reader = struct {
    bytes: []const u8,
    position: usize = 0,

    fn readU64(self: *Reader) u64 {
        const end = self.position + @sizeOf(u64);
        const result = std.mem.readInt(
            u64,
            self.bytes[self.position..end][0..8],
            .little,
        );
        self.position = end;
        return result;
    }

    fn readDigest(self: *Reader) Digest {
        const end = self.position + @sizeOf(Digest);
        var result: Digest = undefined;
        @memcpy(&result, self.bytes[self.position..end]);
        self.position = end;
        return result;
    }
};

fn testDigest(bytes: []const u8) Digest {
    var result: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

fn testFrame() Error!ReadyFrameV1 {
    return makeReadyFrameV1(.{
        .pid = 41_337,
        .barrier_generation = 7,
        .command_generation = 11,
        .command_buffer_status = command_buffer_status_scheduled,
        .challenge_sha256 = testDigest("challenge"),
        .victim_sha256 = testDigest("victim"),
        .metallib_sha256 = testDigest("metallib"),
        .build_sha256 = testDigest("build"),
        .machine_sha256 = testDigest("machine"),
        .backend_sha256 = testDigest("backend"),
        .device_sha256 = testDigest("device"),
        .placement_sha256 = testDigest("placement"),
        .ticket_sha256 = testDigest("ticket"),
        .pin_sha256 = testDigest("pin"),
        .submission_sha256 = testDigest("submission"),
    });
}

fn expectDecodeFailure(encoded: []const u8) !void {
    if (decodeReadyFrameV1(encoded)) |_| {
        return error.TestExpectedDecodeFailure;
    } else |_| {}
}

fn expectRerootedFailure(
    value_seed: ReadyFrameV1,
    expected_error: Error,
) !void {
    var value = value_seed;
    value.frame_sha256 = readyFrameRootV1(value);
    var wire: [ready_frame_encoded_bytes]u8 = undefined;
    encodeUncheckedV1(value, &wire);
    try std.testing.expectError(
        expected_error,
        decodeReadyFrameV1(&wire),
    );
}

test "ready frame round trips through exact canonical wire" {
    const frame = try testFrame();
    try validateReadyFrameV1(frame);
    try std.testing.expectEqual(
        readyFrameRootV1(frame),
        frame.frame_sha256,
    );

    var wire: [ready_frame_encoded_bytes]u8 = undefined;
    const encoded = try encodeReadyFrameV1(frame, &wire);
    try std.testing.expectEqual(
        @as(usize, ready_frame_encoded_bytes),
        encoded.len,
    );
    try std.testing.expectEqualDeep(
        frame,
        try decodeReadyFrameV1(encoded),
    );
}

test "ready frame rejects every one-bit mutation" {
    const frame = try testFrame();
    var wire: [ready_frame_encoded_bytes]u8 = undefined;
    _ = try encodeReadyFrameV1(frame, &wire);

    for (0..ready_frame_encoded_bytes) |byte_index| {
        for (0..8) |bit_index| {
            var mutated = wire;
            mutated[byte_index] ^=
                @as(u8, 1) << @intCast(bit_index);
            try expectDecodeFailure(&mutated);
        }
    }
}

test "ready frame rejects every truncation and extension" {
    const frame = try testFrame();
    var wire: [ready_frame_encoded_bytes]u8 = undefined;
    _ = try encodeReadyFrameV1(frame, &wire);

    for (0..ready_frame_encoded_bytes) |length|
        try std.testing.expectError(
            Error.InvalidLength,
            decodeReadyFrameV1(wire[0..length]),
        );

    var extended: [ready_frame_encoded_bytes + 1]u8 = undefined;
    @memcpy(
        extended[0..ready_frame_encoded_bytes],
        &wire,
    );
    extended[ready_frame_encoded_bytes] = 0;
    try std.testing.expectError(
        Error.InvalidLength,
        decodeReadyFrameV1(&extended),
    );
}

test "ready frame rejects coherently rerooted semantic drift" {
    const frame = try testFrame();

    var drift = frame;
    drift.abi_version +%= 1;
    try expectRerootedFailure(drift, Error.InvalidAbi);

    drift = frame;
    drift.encoded_bytes -= 1;
    try expectRerootedFailure(drift, Error.InvalidLength);

    drift = frame;
    drift.flags = 1;
    try expectRerootedFailure(drift, Error.InvalidFlags);

    drift = frame;
    drift.pid = 0;
    try expectRerootedFailure(drift, Error.InvalidProcess);
    drift.pid = std.math.maxInt(u64);
    try expectRerootedFailure(drift, Error.InvalidProcess);

    drift = frame;
    drift.barrier_generation = 0;
    try expectRerootedFailure(drift, Error.InvalidGeneration);
    drift.barrier_generation = std.math.maxInt(u64);
    try expectRerootedFailure(drift, Error.InvalidGeneration);
    drift = frame;
    drift.command_generation = 0;
    try expectRerootedFailure(drift, Error.InvalidGeneration);
    drift.command_generation = std.math.maxInt(u64);
    try expectRerootedFailure(drift, Error.InvalidGeneration);

    drift = frame;
    drift.submission_disposition = 2;
    try expectRerootedFailure(
        drift,
        Error.InvalidSubmissionDisposition,
    );

    drift = frame;
    drift.command_buffer_status = 4;
    try expectRerootedFailure(
        drift,
        Error.InvalidCommandStatus,
    );

    inline for (.{
        "commit_invoked",
        "completion_observed",
        "shared_event_signaled_value",
        "encoded_signal_value",
        "encoded_wait_value",
    }) |field_name| {
        drift = frame;
        @field(drift, field_name) +%= 1;
        try expectRerootedFailure(drift, Error.InvalidBarrier);
    }

    inline for (.{
        "live_native_buffer_count",
        "live_native_command_count",
        "active_allocation_reference_count",
    }) |field_name| {
        drift = frame;
        @field(drift, field_name) +%= 1;
        try expectRerootedFailure(drift, Error.InvalidCounts);
    }

    inline for (.{
        "challenge_sha256",
        "victim_sha256",
        "metallib_sha256",
        "build_sha256",
        "machine_sha256",
        "backend_sha256",
        "device_sha256",
        "placement_sha256",
        "ticket_sha256",
        "pin_sha256",
        "submission_sha256",
    }) |field_name| {
        drift = frame;
        @field(drift, field_name) = zero_digest;
        try expectRerootedFailure(drift, Error.InvalidIdentity);
    }
}
