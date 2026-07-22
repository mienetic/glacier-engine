//! Crash-recoverable append journal for multi-attempt provider cost evidence.
//!
//! A journal starts with one externally pinned tenant/currency header. Every
//! fixed-size frame embeds one complete ProviderCostWire, links the previous
//! committed root and ends in a separate 48-byte commit footer. Durable writers
//! append and sync the body before appending and syncing the footer. Recovery
//! ignores only a short uncommitted tail; a complete but invalid frame rejects.
//! Replay prevents duplicate/reordered attempts, requires ambiguous attempts to
//! resolve in place and accumulates quote/settled/savings/overrun amounts without
//! double counting the ambiguous observation.

const std = @import("std");
const builtin = @import("builtin");
const gateway = @import("provider_token_gateway.zig");
const cost_wire = @import("provider_cost_wire.zig");
const settlement_wire = @import("provider_settlement_wire.zig");

pub const Digest = gateway.Digest;
pub const KnownU64V1 = cost_wire.KnownU64V1;
pub const header_abi: u64 = 0x4750_4a48_0000_0001;
pub const frame_abi: u64 = 0x4750_4a46_0000_0001;
pub const header_magic = [_]u8{ 'G', 'P', 'C', 'J', 'N', 'L', 'H', '1' };
pub const frame_magic = [_]u8{ 'G', 'P', 'C', 'J', 'N', 'L', 'F', '1' };
pub const commit_magic = [_]u8{ 'G', 'P', 'C', 'J', 'C', 'M', 'T', '1' };
pub const flag_recover_torn_tail: u32 = 1 << 0;
pub const allowed_flags: u32 = flag_recover_torn_tail;
pub const max_supported_frames: usize = 4096;

const header_domain = "glacier-provider-cost-journal-header-v1\x00";
const frame_domain = "glacier-provider-cost-journal-frame-v1\x00";
const digest_bytes = @sizeOf(Digest);

pub const header_bytes: usize =
    header_magic.len + 8 + 8 + 4 + 4 + 8 + 32 + 3 + 5 + 32 + 32;
pub const frame_prefix_bytes: usize =
    frame_magic.len + 8 + 8 + 8 + 8 + 32 + 32 + cost_wire.encoded_bytes;
pub const frame_body_bytes: usize = frame_prefix_bytes + digest_bytes;
pub const commit_footer_bytes: usize = commit_magic.len + 8 + digest_bytes;
pub const frame_bytes: usize = frame_body_bytes + commit_footer_bytes;
pub const max_journal_bytes: usize =
    header_bytes + max_supported_frames * frame_bytes;

pub const Error = error{
    CapacityExceeded,
    InvalidMagic,
    InvalidAbi,
    InvalidLength,
    InvalidFlags,
    InvalidHeader,
    InvalidFrame,
    InvalidCommit,
    InvalidEvidence,
    InvalidLifecycle,
    InvalidCurrency,
    InvalidStorage,
    InvalidPath,
    InvalidState,
    TornTailRequiresRepair,
    ShortRead,
    InjectedFault,
    ArithmeticOverflow,
};

pub const HeaderV1 = struct {
    abi_version: u64 = header_abi,
    flags: u32 = flag_recover_torn_tail,
    journal_epoch: u64 = 0,
    tenant_sha256: Digest = gateway.zero_digest,
    currency_code: [3]u8 = .{ 0, 0, 0 },
    challenge_sha256: Digest = gateway.zero_digest,
    header_sha256: Digest = gateway.zero_digest,
};

pub const RequestPhase = enum(u8) {
    free,
    retryable,
    ambiguous,
    terminal,
};

pub const RequestStateV1 = struct {
    occupied: bool = false,
    request_sha256: Digest = gateway.zero_digest,
    phase: RequestPhase = .free,
    attempt_generation: u64 = 0,
    intent_sha256: Digest = gateway.zero_digest,
    price_sha256: Digest = gateway.zero_digest,
    quote_sha256: Digest = gateway.zero_digest,
};

pub const LedgerV1 = struct {
    committed_frames: u64 = 0,
    physical_attempts: u64 = 0,
    settled_attempts: u64 = 0,
    retryable_no_charge_records: u64 = 0,
    ambiguous_records: u64 = 0,
    resolved_records: u64 = 0,
    retryable_requests: u64 = 0,
    open_ambiguous_requests: u64 = 0,
    terminal_requests: u64 = 0,
    unpriced_settled_attempts: u64 = 0,
    quoted_nanos: KnownU64V1 = .{ .known = true, .value = 0 },
    settled_nanos: KnownU64V1 = .{ .known = true, .value = 0 },
    savings_nanos: KnownU64V1 = .{ .known = true, .value = 0 },
    overrun_nanos: KnownU64V1 = .{ .known = true, .value = 0 },
};

pub const DecodedFrameV1 = struct {
    sequence: u64 = 0,
    cost: cost_wire.DecodedV1 = undefined,
    entry_sha256: Digest = gateway.zero_digest,
};

pub const AppendPlanV1 = struct {
    body: []const u8,
    commit_footer: []const u8,
};

pub const RecoveryStatus = enum(u8) {
    clean,
    torn_tail,
};

pub const RecoveryV1 = struct {
    header: HeaderV1,
    entries: []const DecodedFrameV1,
    status: RecoveryStatus,
    committed_bytes: usize,
    discarded_tail_bytes: usize,
    final_chain_sha256: Digest,
    ledger: LedgerV1,
};

pub const DirectorySyncStatusV1 = enum(u8) {
    not_applicable,
    synced,
    unsupported,
};

pub const StoreStateV1 = enum(u8) {
    ready,
    poisoned,
    closed,
};

pub const OpenOptionsV1 = struct {
    repair_torn_tail: bool = true,
    lock_nonblocking: bool = false,
};

pub const AppendPhaseV1 = enum(u8) {
    after_body_write,
    after_body_sync,
    after_footer_write,
    after_footer_sync,
};

/// A deterministic fault point for crash harnesses. Once an append begins,
/// any returned error poisons the process-local writer. Close it and reopen the
/// pinned journal before attempting another append.
pub const AppendControlV1 = struct {
    fault_after_phase: ?AppendPhaseV1 = null,
};

pub const AppendReceiptV1 = struct {
    sequence: u64,
    committed_bytes: usize,
    final_chain_sha256: Digest,
    ledger: LedgerV1,
    body_sync_exercised: bool,
    footer_sync_exercised: bool,
};

/// Exclusive, caller-storage filesystem authority for one pinned journal.
///
/// The supplied directory is the capability boundary. `journal_name` must be
/// one path component, which rejects syntactic traversal. The directory itself
/// must be trusted against symlink or rename replacement. Locks are advisory
/// and therefore coordinate only cooperating processes. Creation syncs the
/// file and, where supported, its directory.
pub const StoreV1 = struct {
    file: std.fs.File,
    frame_storage: []u8,
    request_storage: []RequestStateV1,
    header: HeaderV1,
    committed_bytes: usize,
    final_chain_sha256: Digest,
    ledger: LedgerV1,
    recovered_status: RecoveryStatus,
    discarded_tail_bytes: usize,
    directory_sync_status: DirectorySyncStatusV1,
    repair_sync_exercised: bool,
    state: StoreStateV1 = .ready,

    pub fn create(
        directory: std.fs.Dir,
        journal_name: []const u8,
        header: HeaderV1,
        frame_storage: []u8,
        request_storage: []RequestStateV1,
    ) !StoreV1 {
        try validateStoreInputs(
            journal_name,
            frame_storage,
            request_storage,
        );
        if (!headerValidV1(header)) return Error.InvalidHeader;

        const file = try directory.createFile(journal_name, .{
            .read = true,
            .truncate = false,
            .exclusive = true,
            .lock = .exclusive,
            .mode = 0o600,
        });
        errdefer file.close();
        if ((try file.stat()).kind != .file) return Error.InvalidStorage;

        var encoded_header: [header_bytes]u8 = undefined;
        try file.writeAll(try encodeHeaderV1(header, &encoded_header));
        try file.sync();
        const directory_sync_status = try syncDirectoryV1(directory);
        zeroRequests(request_storage);
        return .{
            .file = file,
            .frame_storage = frame_storage,
            .request_storage = request_storage,
            .header = header,
            .committed_bytes = header_bytes,
            .final_chain_sha256 = header.header_sha256,
            .ledger = .{},
            .recovered_status = .clean,
            .discarded_tail_bytes = 0,
            .directory_sync_status = directory_sync_status,
            .repair_sync_exercised = false,
        };
    }

    pub fn open(
        directory: std.fs.Dir,
        journal_name: []const u8,
        expected_header_sha256: Digest,
        options: OpenOptionsV1,
        frame_storage: []u8,
        request_storage: []RequestStateV1,
    ) !StoreV1 {
        try validateStoreInputs(
            journal_name,
            frame_storage,
            request_storage,
        );
        const file = try directory.openFile(journal_name, .{
            .mode = .read_write,
            .lock = .exclusive,
            .lock_nonblocking = options.lock_nonblocking,
        });
        errdefer file.close();
        if ((try file.stat()).kind != .file) return Error.InvalidStorage;

        const file_size_u64 = try file.getEndPos();
        if (file_size_u64 > max_journal_bytes)
            return Error.CapacityExceeded;
        const file_size: usize = @intCast(file_size_u64);
        if (file_size < header_bytes) return Error.InvalidLength;
        var encoded_header: [header_bytes]u8 = undefined;
        if (try file.preadAll(&encoded_header, 0) != header_bytes)
            return Error.ShortRead;
        const header = try decodeHeaderV1(
            &encoded_header,
            expected_header_sha256,
        );
        const payload_bytes = file_size - header_bytes;
        const complete_frames = payload_bytes / frame_bytes;
        const tail_bytes = payload_bytes % frame_bytes;
        if (complete_frames > request_storage.len)
            return Error.CapacityExceeded;
        zeroRequests(request_storage);
        errdefer zeroRequests(request_storage);
        var ledger: LedgerV1 = .{};
        var final_chain_sha256 = header.header_sha256;
        for (0..complete_frames) |index| {
            const offset = header_bytes + index * frame_bytes;
            const encoded_frame = frame_storage[0..frame_bytes];
            if (try file.preadAll(encoded_frame, offset) != frame_bytes)
                return Error.ShortRead;
            const frame = try decodeFrameV1(
                header,
                @as(u64, @intCast(index)) + 1,
                final_chain_sha256,
                encoded_frame,
            );
            try applyFrameV1(frame, request_storage, &ledger);
            final_chain_sha256 = frame.entry_sha256;
        }
        try finalizeRequestCounts(request_storage, &ledger);
        const committed_bytes = header_bytes + complete_frames * frame_bytes;
        const recovered_status: RecoveryStatus =
            if (tail_bytes == 0) .clean else .torn_tail;
        var repair_sync_exercised = false;
        if (recovered_status == .torn_tail) {
            if (!options.repair_torn_tail)
                return Error.TornTailRequiresRepair;
            try file.setEndPos(committed_bytes);
            try file.sync();
            repair_sync_exercised = true;
        }
        return .{
            .file = file,
            .frame_storage = frame_storage,
            .request_storage = request_storage,
            .header = header,
            .committed_bytes = committed_bytes,
            .final_chain_sha256 = final_chain_sha256,
            .ledger = ledger,
            .recovered_status = recovered_status,
            .discarded_tail_bytes = tail_bytes,
            .directory_sync_status = .not_applicable,
            .repair_sync_exercised = repair_sync_exercised,
        };
    }

    pub fn appendFrame(
        self: *StoreV1,
        encoded_frame: []const u8,
        control: AppendControlV1,
    ) !AppendReceiptV1 {
        if (self.state != .ready) return Error.InvalidState;
        if (encoded_frame.len != frame_bytes) return Error.InvalidLength;
        if (self.committed_bytes > max_journal_bytes - frame_bytes)
            return Error.CapacityExceeded;
        const current_frames = (self.committed_bytes - header_bytes) /
            frame_bytes;
        if (current_frames >= max_supported_frames or
            self.request_storage.len <= current_frames)
            return Error.CapacityExceeded;
        const frame = try decodeFrameV1(
            self.header,
            @as(u64, @intCast(current_frames)) + 1,
            self.final_chain_sha256,
            encoded_frame,
        );
        const prospective_ledger = try preflightFrameV1(
            frame,
            self.request_storage,
            self.ledger,
        );
        const plan = try appendPlanV1(encoded_frame);

        try self.file.seekTo(self.committed_bytes);
        self.state = .poisoned;
        try self.file.writeAll(plan.body);
        try injectFaultV1(control, .after_body_write);
        try self.file.sync();
        try injectFaultV1(control, .after_body_sync);
        try self.file.writeAll(plan.commit_footer);
        try injectFaultV1(control, .after_footer_write);
        try self.file.sync();
        try injectFaultV1(control, .after_footer_sync);

        var committed_ledger = self.ledger;
        clearRequestCounts(&committed_ledger);
        try applyFrameV1(frame, self.request_storage, &committed_ledger);
        try finalizeRequestCounts(self.request_storage, &committed_ledger);
        if (!std.meta.eql(committed_ledger, prospective_ledger))
            return Error.InvalidState;
        self.committed_bytes += frame_bytes;
        self.final_chain_sha256 = frame.entry_sha256;
        self.ledger = committed_ledger;
        self.recovered_status = .clean;
        self.discarded_tail_bytes = 0;
        self.repair_sync_exercised = false;
        self.state = .ready;
        return .{
            .sequence = frame.sequence,
            .committed_bytes = self.committed_bytes,
            .final_chain_sha256 = frame.entry_sha256,
            .ledger = committed_ledger,
            .body_sync_exercised = true,
            .footer_sync_exercised = true,
        };
    }

    pub fn close(self: *StoreV1) void {
        if (self.state == .closed) return;
        self.file.close();
        self.state = .closed;
    }
};

fn validateStoreInputs(
    journal_name: []const u8,
    frame_storage: []u8,
    request_storage: []RequestStateV1,
) Error!void {
    if (journal_name.len == 0 or
        std.mem.eql(u8, journal_name, ".") or
        std.mem.eql(u8, journal_name, "..") or
        std.mem.indexOfAny(u8, journal_name, "/\\\x00") != null)
        return Error.InvalidPath;
    if (frame_storage.len < frame_bytes or
        request_storage.len > max_supported_frames)
        return Error.CapacityExceeded;
}

fn syncDirectoryV1(
    directory: std.fs.Dir,
) !DirectorySyncStatusV1 {
    return switch (builtin.os.tag) {
        .linux,
        .macos,
        .ios,
        .freebsd,
        .netbsd,
        .dragonfly,
        .openbsd,
        .solaris,
        .illumos,
        => blk: {
            try std.posix.fsync(directory.fd);
            break :blk .synced;
        },
        else => .unsupported,
    };
}

fn injectFaultV1(
    control: AppendControlV1,
    phase: AppendPhaseV1,
) Error!void {
    if (control.fault_after_phase == phase) return Error.InjectedFault;
}

fn preflightFrameV1(
    frame: DecodedFrameV1,
    states: []RequestStateV1,
    current_ledger: LedgerV1,
) Error!LedgerV1 {
    const request_sha256 =
        frame.cost.provider_settlement.request.request_sha256;
    var free_index: ?usize = null;
    const state_index = for (states, 0..) |state, index| {
        if (state.occupied and std.mem.eql(
            u8,
            &state.request_sha256,
            &request_sha256,
        )) break index;
        if (!state.occupied and free_index == null) free_index = index;
    } else free_index orelse return Error.CapacityExceeded;

    const saved_state = states[state_index];
    defer states[state_index] = saved_state;
    var prospective_ledger = current_ledger;
    clearRequestCounts(&prospective_ledger);
    try applyFrameV1(frame, states, &prospective_ledger);
    try finalizeRequestCounts(states, &prospective_ledger);
    return prospective_ledger;
}

fn clearRequestCounts(ledger: *LedgerV1) void {
    ledger.retryable_requests = 0;
    ledger.open_ambiguous_requests = 0;
    ledger.terminal_requests = 0;
}

pub fn makeHeaderV1(
    journal_epoch: u64,
    tenant_sha256: Digest,
    currency_code: [3]u8,
    challenge_sha256: Digest,
) Error!HeaderV1 {
    var value: HeaderV1 = .{
        .journal_epoch = journal_epoch,
        .tenant_sha256 = tenant_sha256,
        .currency_code = currency_code,
        .challenge_sha256 = challenge_sha256,
    };
    value.header_sha256 = headerSha256(value);
    if (!headerValidV1(value)) return Error.InvalidHeader;
    return value;
}

pub fn headerSha256(value: HeaderV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(header_domain);
    hashU64(&hash, value.abi_version);
    hashU32(&hash, value.flags);
    hashU64(&hash, value.journal_epoch);
    hash.update(&value.tenant_sha256);
    hash.update(&value.currency_code);
    hash.update(&value.challenge_sha256);
    return finish(&hash);
}

pub fn headerValidV1(value: HeaderV1) bool {
    return value.abi_version == header_abi and
        value.flags == flag_recover_torn_tail and
        value.journal_epoch != 0 and
        !isZero(value.tenant_sha256) and
        currencyValid(value.currency_code) and
        !isZero(value.challenge_sha256) and
        std.mem.eql(u8, &value.header_sha256, &headerSha256(value));
}

pub fn encodeHeaderV1(
    value: HeaderV1,
    destination: []u8,
) Error![]const u8 {
    if (!headerValidV1(value)) return Error.InvalidHeader;
    if (destination.len < header_bytes) return Error.CapacityExceeded;
    const output = destination[0..header_bytes];
    @memset(output, 0);
    errdefer @memset(output, 0);
    var writer: Writer = .{ .bytes = output };
    try writer.writeBytes(&header_magic);
    try writer.writeU64(value.abi_version);
    try writer.writeU64(header_bytes);
    try writer.writeU32(value.flags);
    try writer.writeU32(0);
    try writer.writeU64(value.journal_epoch);
    try writer.writeDigest(value.tenant_sha256);
    try writer.writeBytes(&value.currency_code);
    try writer.writeBytes(&[_]u8{0} ** 5);
    try writer.writeDigest(value.challenge_sha256);
    try writer.writeDigest(value.header_sha256);
    if (writer.position != output.len) return Error.InvalidLength;
    return output;
}

pub fn decodeHeaderV1(
    encoded: []const u8,
    expected_header_sha256: Digest,
) Error!HeaderV1 {
    if (encoded.len != header_bytes) return Error.InvalidLength;
    var reader: Reader = .{ .bytes = encoded };
    if (!std.mem.eql(u8, try reader.readBytes(header_magic.len), &header_magic))
        return Error.InvalidMagic;
    const abi_version = try reader.readU64();
    if (abi_version != header_abi) return Error.InvalidAbi;
    if (try reader.readU64() != header_bytes) return Error.InvalidLength;
    const flags = try reader.readU32();
    if (flags != flag_recover_torn_tail or try reader.readU32() != 0)
        return Error.InvalidFlags;
    const journal_epoch = try reader.readU64();
    const tenant_sha256 = try reader.readDigest();
    var currency_code: [3]u8 = undefined;
    @memcpy(&currency_code, try reader.readBytes(3));
    for (try reader.readBytes(5)) |byte|
        if (byte != 0) return Error.InvalidHeader;
    const challenge_sha256 = try reader.readDigest();
    const header_sha256 = try reader.readDigest();
    if (reader.position != encoded.len or
        !std.mem.eql(u8, &header_sha256, &expected_header_sha256))
        return Error.InvalidHeader;
    const value: HeaderV1 = .{
        .abi_version = abi_version,
        .flags = flags,
        .journal_epoch = journal_epoch,
        .tenant_sha256 = tenant_sha256,
        .currency_code = currency_code,
        .challenge_sha256 = challenge_sha256,
        .header_sha256 = header_sha256,
    };
    if (!headerValidV1(value)) return Error.InvalidHeader;
    return value;
}

pub fn encodeFrameV1(
    header: HeaderV1,
    sequence: u64,
    previous_chain_sha256: Digest,
    encoded_cost: []const u8,
    destination: []u8,
) Error![]const u8 {
    if (!headerValidV1(header) or sequence == 0 or
        isZero(previous_chain_sha256)) return Error.InvalidFrame;
    if (encoded_cost.len != cost_wire.encoded_bytes)
        return Error.InvalidLength;
    const cost = cost_wire.decodeAndVerifyV1(encoded_cost) catch
        return Error.InvalidEvidence;
    if (!std.mem.eql(
        u8,
        &cost.price.currency_code,
        &header.currency_code,
    )) return Error.InvalidCurrency;
    if (destination.len < frame_bytes) return Error.CapacityExceeded;
    const output = destination[0..frame_bytes];
    if (overlap(u8, encoded_cost, u8, output)) return Error.InvalidStorage;
    @memset(output, 0);
    errdefer @memset(output, 0);
    var writer: Writer = .{ .bytes = output };
    try writer.writeBytes(&frame_magic);
    try writer.writeU64(frame_abi);
    try writer.writeU64(frame_bytes);
    try writer.writeU64(header.journal_epoch);
    try writer.writeU64(sequence);
    try writer.writeDigest(header.tenant_sha256);
    try writer.writeDigest(previous_chain_sha256);
    try writer.writeBytes(encoded_cost);
    if (writer.position != frame_prefix_bytes) return Error.InvalidLength;
    const entry_sha256 = frameSha256(
        header.header_sha256,
        output[0..frame_prefix_bytes],
    );
    try writer.writeDigest(entry_sha256);
    if (writer.position != frame_body_bytes) return Error.InvalidLength;
    try writer.writeBytes(&commit_magic);
    try writer.writeU64(sequence);
    try writer.writeDigest(entry_sha256);
    if (writer.position != output.len) return Error.InvalidLength;
    return output;
}

/// Splits one encoded frame into the two durability writes. Persist and sync
/// `body` before appending and syncing `commit_footer`.
pub fn appendPlanV1(encoded_frame: []const u8) Error!AppendPlanV1 {
    if (encoded_frame.len != frame_bytes) return Error.InvalidLength;
    if (!std.mem.eql(u8, encoded_frame[0..frame_magic.len], &frame_magic) or
        !std.mem.eql(
            u8,
            encoded_frame[frame_body_bytes .. frame_body_bytes + commit_magic.len],
            &commit_magic,
        )) return Error.InvalidFrame;
    return .{
        .body = encoded_frame[0..frame_body_bytes],
        .commit_footer = encoded_frame[frame_body_bytes..frame_bytes],
    };
}

/// Verifies one standalone frame against an already pinned header, sequence
/// and previous committed root. This is the composition boundary for external
/// manifests; it grants no append or recovery authority.
pub fn decodeFrameAndVerifyV1(
    header: HeaderV1,
    expected_sequence: u64,
    expected_previous: Digest,
    encoded_frame: []const u8,
) Error!DecodedFrameV1 {
    return decodeFrameV1(
        header,
        expected_sequence,
        expected_previous,
        encoded_frame,
    );
}

pub fn recoverV1(
    encoded: []const u8,
    expected_header_sha256: Digest,
    entry_storage: []DecodedFrameV1,
    request_storage: []RequestStateV1,
) Error!RecoveryV1 {
    if (encoded.len < header_bytes) return Error.InvalidLength;
    const header = try decodeHeaderV1(
        encoded[0..header_bytes],
        expected_header_sha256,
    );
    const payload_len = encoded.len - header_bytes;
    const complete_frames = payload_len / frame_bytes;
    const tail_bytes = payload_len % frame_bytes;
    if (complete_frames > max_supported_frames) return Error.CapacityExceeded;
    if (entry_storage.len < complete_frames or
        request_storage.len < complete_frames) return Error.CapacityExceeded;
    zeroEntries(entry_storage);
    zeroRequests(request_storage);
    errdefer {
        zeroEntries(entry_storage);
        zeroRequests(request_storage);
    }
    var ledger: LedgerV1 = .{};
    var previous_chain = header.header_sha256;
    for (0..complete_frames) |index| {
        const start = header_bytes + index * frame_bytes;
        const frame = try decodeFrameV1(
            header,
            @as(u64, @intCast(index)) + 1,
            previous_chain,
            encoded[start .. start + frame_bytes],
        );
        try applyFrameV1(frame, request_storage, &ledger);
        entry_storage[index] = frame;
        previous_chain = frame.entry_sha256;
    }
    finalizeRequestCounts(request_storage, &ledger) catch
        return Error.ArithmeticOverflow;
    const committed_bytes = header_bytes + complete_frames * frame_bytes;
    return .{
        .header = header,
        .entries = entry_storage[0..complete_frames],
        .status = if (tail_bytes == 0) .clean else .torn_tail,
        .committed_bytes = committed_bytes,
        .discarded_tail_bytes = tail_bytes,
        .final_chain_sha256 = previous_chain,
        .ledger = ledger,
    };
}

pub fn verifyClosedV1(
    encoded: []const u8,
    expected_header_sha256: Digest,
    expected_final_chain_sha256: Digest,
    entry_storage: []DecodedFrameV1,
    request_storage: []RequestStateV1,
) Error!RecoveryV1 {
    const recovered = try recoverV1(
        encoded,
        expected_header_sha256,
        entry_storage,
        request_storage,
    );
    if (recovered.status != .clean or isZero(expected_final_chain_sha256) or
        !std.mem.eql(
            u8,
            &recovered.final_chain_sha256,
            &expected_final_chain_sha256,
        )) return Error.InvalidCommit;
    return recovered;
}

fn decodeFrameV1(
    header: HeaderV1,
    expected_sequence: u64,
    expected_previous: Digest,
    encoded: []const u8,
) Error!DecodedFrameV1 {
    if (encoded.len != frame_bytes) return Error.InvalidLength;
    var reader: Reader = .{ .bytes = encoded };
    if (!std.mem.eql(u8, try reader.readBytes(frame_magic.len), &frame_magic))
        return Error.InvalidMagic;
    if (try reader.readU64() != frame_abi) return Error.InvalidAbi;
    if (try reader.readU64() != frame_bytes) return Error.InvalidLength;
    if (try reader.readU64() != header.journal_epoch)
        return Error.InvalidFrame;
    const sequence = try reader.readU64();
    if (sequence != expected_sequence) return Error.InvalidFrame;
    const tenant_sha256 = try reader.readDigest();
    if (!std.mem.eql(u8, &tenant_sha256, &header.tenant_sha256))
        return Error.InvalidFrame;
    const previous_chain_sha256 = try reader.readDigest();
    if (!std.mem.eql(u8, &previous_chain_sha256, &expected_previous))
        return Error.InvalidFrame;
    const encoded_cost = try reader.readBytes(cost_wire.encoded_bytes);
    if (reader.position != frame_prefix_bytes) return Error.InvalidLength;
    const expected_entry = frameSha256(
        header.header_sha256,
        encoded[0..frame_prefix_bytes],
    );
    const entry_sha256 = try reader.readDigest();
    if (!std.mem.eql(u8, &entry_sha256, &expected_entry))
        return Error.InvalidFrame;
    if (reader.position != frame_body_bytes) return Error.InvalidLength;
    if (!std.mem.eql(u8, try reader.readBytes(commit_magic.len), &commit_magic))
        return Error.InvalidCommit;
    if (try reader.readU64() != sequence) return Error.InvalidCommit;
    const committed_root = try reader.readDigest();
    if (reader.position != encoded.len or
        !std.mem.eql(u8, &committed_root, &entry_sha256))
        return Error.InvalidCommit;
    const cost = cost_wire.decodeAndVerifyV1(encoded_cost) catch
        return Error.InvalidEvidence;
    if (!std.mem.eql(
        u8,
        &cost.price.currency_code,
        &header.currency_code,
    )) return Error.InvalidCurrency;
    return .{
        .sequence = sequence,
        .cost = cost,
        .entry_sha256 = entry_sha256,
    };
}

fn applyFrameV1(
    frame: DecodedFrameV1,
    states: []RequestStateV1,
    ledger: *LedgerV1,
) Error!void {
    const provider = frame.cost.provider_settlement;
    const receipt = provider.receipt;
    const request_sha256 = provider.request.request_sha256;
    const attempt_generation = receipt.intent.attempt_generation;
    var state = findRequest(states, request_sha256);
    var new_attempt = false;
    if (state == null) {
        if (receipt.outcome == .resolved_success or
            receipt.outcome == .resolved_failure)
            return Error.InvalidLifecycle;
        state = try allocateRequest(states, request_sha256);
        new_attempt = true;
    } else {
        switch (state.?.phase) {
            .free => return Error.InvalidLifecycle,
            .terminal => return Error.InvalidLifecycle,
            .retryable => {
                const expected = std.math.add(
                    u64,
                    state.?.attempt_generation,
                    1,
                ) catch return Error.ArithmeticOverflow;
                if (attempt_generation != expected or
                    receipt.outcome == .resolved_success or
                    receipt.outcome == .resolved_failure)
                    return Error.InvalidLifecycle;
                new_attempt = true;
            },
            .ambiguous => {
                if ((receipt.outcome != .resolved_success and
                    receipt.outcome != .resolved_failure) or
                    attempt_generation != state.?.attempt_generation or
                    !std.mem.eql(
                        u8,
                        &receipt.intent.intent_sha256,
                        &state.?.intent_sha256,
                    ) or !std.mem.eql(
                    u8,
                    &frame.cost.price.price_sha256,
                    &state.?.price_sha256,
                ) or !std.mem.eql(
                    u8,
                    &frame.cost.quote.quote_sha256,
                    &state.?.quote_sha256,
                )) return Error.InvalidLifecycle;
            },
        }
    }

    if (new_attempt) {
        state.?.attempt_generation = attempt_generation;
        state.?.intent_sha256 = receipt.intent.intent_sha256;
        state.?.price_sha256 = frame.cost.price.price_sha256;
        state.?.quote_sha256 = frame.cost.quote.quote_sha256;
        ledger.physical_attempts = try addU64(ledger.physical_attempts, 1);
        ledger.quoted_nanos = try addKnown(
            ledger.quoted_nanos,
            frame.cost.quote.breakdown.total_nanos,
        );
    }

    switch (receipt.outcome) {
        .retryable_no_charge => {
            state.?.phase = .retryable;
            ledger.retryable_no_charge_records = try addU64(
                ledger.retryable_no_charge_records,
                1,
            );
            try accumulateSettlement(frame.cost, ledger);
        },
        .ambiguous => {
            state.?.phase = .ambiguous;
            ledger.ambiguous_records = try addU64(
                ledger.ambiguous_records,
                1,
            );
        },
        .succeeded, .failed => {
            state.?.phase = .terminal;
            try accumulateSettlement(frame.cost, ledger);
        },
        .resolved_success, .resolved_failure => {
            state.?.phase = .terminal;
            ledger.resolved_records = try addU64(
                ledger.resolved_records,
                1,
            );
            try accumulateSettlement(frame.cost, ledger);
        },
    }
    ledger.committed_frames = try addU64(ledger.committed_frames, 1);
}

fn accumulateSettlement(
    cost: cost_wire.DecodedV1,
    ledger: *LedgerV1,
) Error!void {
    ledger.settled_attempts = try addU64(ledger.settled_attempts, 1);
    if (!cost.cost_settlement.breakdown.total_nanos.known)
        ledger.unpriced_settled_attempts = try addU64(
            ledger.unpriced_settled_attempts,
            1,
        );
    ledger.settled_nanos = try addKnown(
        ledger.settled_nanos,
        cost.cost_settlement.breakdown.total_nanos,
    );
    ledger.savings_nanos = try addKnown(
        ledger.savings_nanos,
        cost.cost_settlement.savings_nanos,
    );
    ledger.overrun_nanos = try addKnown(
        ledger.overrun_nanos,
        cost.cost_settlement.overrun_nanos,
    );
}

fn findRequest(
    states: []RequestStateV1,
    request_sha256: Digest,
) ?*RequestStateV1 {
    for (states) |*state|
        if (state.occupied and std.mem.eql(
            u8,
            &state.request_sha256,
            &request_sha256,
        )) return state;
    return null;
}

fn allocateRequest(
    states: []RequestStateV1,
    request_sha256: Digest,
) Error!*RequestStateV1 {
    for (states) |*state| {
        if (!state.occupied) {
            state.* = .{
                .occupied = true,
                .request_sha256 = request_sha256,
            };
            return state;
        }
    }
    return Error.CapacityExceeded;
}

fn finalizeRequestCounts(
    states: []const RequestStateV1,
    ledger: *LedgerV1,
) Error!void {
    for (states) |state| {
        if (!state.occupied) continue;
        switch (state.phase) {
            .free => return Error.InvalidLifecycle,
            .retryable => ledger.retryable_requests = try addU64(
                ledger.retryable_requests,
                1,
            ),
            .ambiguous => ledger.open_ambiguous_requests = try addU64(
                ledger.open_ambiguous_requests,
                1,
            ),
            .terminal => ledger.terminal_requests = try addU64(
                ledger.terminal_requests,
                1,
            ),
        }
    }
}

fn addKnown(left: KnownU64V1, right: KnownU64V1) Error!KnownU64V1 {
    if (!left.known or !right.known) return .{};
    return .{
        .known = true,
        .value = try addU64(left.value, right.value),
    };
}

fn addU64(left: u64, right: u64) Error!u64 {
    return std.math.add(u64, left, right) catch Error.ArithmeticOverflow;
}

fn frameSha256(header_sha256: Digest, prefix: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(frame_domain);
    hash.update(&header_sha256);
    hash.update(prefix);
    return finish(&hash);
}

fn currencyValid(value: [3]u8) bool {
    for (value) |byte| if (byte < 'A' or byte > 'Z') return false;
    return true;
}

fn isZero(value: Digest) bool {
    return std.mem.eql(u8, &value, &gateway.zero_digest);
}

fn zeroEntries(values: []DecodedFrameV1) void {
    for (values) |*value| value.* = undefined;
}

fn zeroRequests(values: []RequestStateV1) void {
    for (values) |*value| value.* = .{};
}

fn overlap(
    comptime Left: type,
    left: []const Left,
    comptime Right: type,
    right: []const Right,
) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_size = std.math.mul(usize, left.len, @sizeOf(Left)) catch
        return true;
    const right_size = std.math.mul(usize, right.len, @sizeOf(Right)) catch
        return true;
    const left_end = std.math.add(usize, left_start, left_size) catch
        return true;
    const right_end = std.math.add(usize, right_start, right_size) catch
        return true;
    return left_start < right_end and right_start < left_end;
}

const Writer = struct {
    bytes: []u8,
    position: usize = 0,

    fn writeBytes(self: *Writer, value: []const u8) Error!void {
        const end = std.math.add(usize, self.position, value.len) catch
            return Error.InvalidLength;
        if (end > self.bytes.len) return Error.CapacityExceeded;
        @memcpy(self.bytes[self.position..end], value);
        self.position = end;
    }

    fn writeU32(self: *Writer, value: u32) Error!void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        try self.writeBytes(&bytes);
    }

    fn writeU64(self: *Writer, value: u64) Error!void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        try self.writeBytes(&bytes);
    }

    fn writeDigest(self: *Writer, value: Digest) Error!void {
        try self.writeBytes(&value);
    }
};

const Reader = struct {
    bytes: []const u8,
    position: usize = 0,

    fn readBytes(self: *Reader, length: usize) Error![]const u8 {
        const end = std.math.add(usize, self.position, length) catch
            return Error.InvalidLength;
        if (end > self.bytes.len) return Error.InvalidLength;
        const value = self.bytes[self.position..end];
        self.position = end;
        return value;
    }

    fn readU32(self: *Reader) Error!u32 {
        return std.mem.readInt(u32, (try self.readBytes(4))[0..4], .little);
    }

    fn readU64(self: *Reader) Error!u64 {
        return std.mem.readInt(u64, (try self.readBytes(8))[0..8], .little);
    }

    fn readDigest(self: *Reader) Error!Digest {
        var value: Digest = undefined;
        @memcpy(&value, try self.readBytes(digest_bytes));
        return value;
    }
};

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

fn finish(hash: *std.crypto.hash.sha2.Sha256) Digest {
    var value: Digest = undefined;
    hash.final(&value);
    return value;
}

fn testDigest(seed: u8) Digest {
    var value: Digest = undefined;
    @memset(&value, seed);
    return value;
}

const TestCostEnvelope = struct {
    bytes: [cost_wire.encoded_bytes]u8,
};

fn testCostEnvelope(
    outcome: gateway.AttemptOutcome,
    attempt_generation: u64,
) !TestCostEnvelope {
    const request = try gateway.makeRequestV1(
        0x434f_5354_4144_5054,
        0x434f_5354_4953_4f4c,
        71,
        3,
        testDigest(0x11),
        testDigest(0x22),
        testDigest(0x33),
        testDigest(0x44),
        testDigest(0x55),
        100,
        50,
        .in_flight,
    );
    var intent: gateway.DispatchIntentV1 = .{
        .gateway_epoch = 0x434f_5354_4757_0001,
        .owner_slot_index = 2,
        .owner_generation = 9,
        .attempt_generation = attempt_generation,
        .request_sha256 = request.request_sha256,
        .dispatch_key_sha256 = gateway.dispatchKeySha256(request),
        .reserved_tokens = 150,
        .previous_event_chain_sha256 = testDigest(0x66),
    };
    intent.intent_sha256 = gateway.dispatchIntentSha256(intent);
    const usage = switch (outcome) {
        .retryable_no_charge => try gateway.makeUsageV1(
            null,
            null,
            null,
            null,
            null,
            0,
        ),
        .ambiguous => try gateway.makeUsageV1(100, null, 40, null, 3, null),
        .succeeded, .resolved_success => try gateway.makeUsageV1(
            100,
            20,
            40,
            8,
            0,
            80,
        ),
        .failed, .resolved_failure => try gateway.makeUsageV1(
            100,
            0,
            40,
            0,
            0,
            60,
        ),
    };
    var receipt: gateway.AttemptReceiptV1 = .{
        .outcome = outcome,
        .intent = intent,
        .usage = usage,
        .result_sha256 = switch (outcome) {
            .succeeded, .resolved_success => testDigest(0x77),
            else => gateway.zero_digest,
        },
        .request_set_count = 3,
        .request_set_sha256 = testDigest(0x88),
        .event_sha256 = testDigest(0x99),
    };
    receipt.receipt_sha256 = gateway.attemptReceiptSha256(receipt);
    var settlement_bytes: [settlement_wire.encoded_bytes]u8 = undefined;
    const settlement = try settlement_wire.encodeV1(
        request,
        receipt,
        &settlement_bytes,
    );
    const decoded_settlement = try settlement_wire.decodeAndVerifyV1(
        settlement,
    );
    const price = try cost_wire.makePriceTableV1(
        request.provider_adapter_abi,
        testDigest(0xa1),
        request.model_sha256,
        17,
        1_700_000_000,
        1_700_001_000,
        .{ 'U', 'S', 'D' },
        .per_component_ceiling,
        .within_output,
        .included,
        .{
            .uncached_input = .{ .known = true, .value = 2_000_000_000 },
            .cached_input = .{ .known = true, .value = 500_000_000 },
            .visible_output = .{ .known = true, .value = 8_000_000_000 },
            .reasoning = .{ .known = true, .value = 10_000_000_000 },
            .retry = .{ .known = true, .value = 0 },
        },
    );
    const quote = try cost_wire.makeQuoteV1(price, request, 1_700_000_100);
    const cost = try cost_wire.makeCostSettlementV1(
        price,
        quote,
        decoded_settlement,
        1_700_000_200,
    );
    var bytes: [cost_wire.encoded_bytes]u8 = undefined;
    _ = try cost_wire.encodeV1(
        cost_wire.flag_require_known_quote,
        price,
        quote,
        settlement,
        cost,
        &bytes,
    );
    return .{ .bytes = bytes };
}

const test_frame_count = 3;
const test_journal_bytes = header_bytes + test_frame_count * frame_bytes;

const TestJournal = struct {
    header: HeaderV1,
    bytes: [test_journal_bytes]u8,
    final_chain_sha256: Digest,
};

fn frameRoot(encoded: []const u8) Digest {
    var value: Digest = undefined;
    @memcpy(
        &value,
        encoded[frame_prefix_bytes .. frame_prefix_bytes + digest_bytes],
    );
    return value;
}

fn testJournal() !TestJournal {
    const header = try makeHeaderV1(
        0x4a4f_5552_4e41_4c01,
        testDigest(0xb1),
        .{ 'U', 'S', 'D' },
        testDigest(0xc1),
    );
    const costs = [_]TestCostEnvelope{
        try testCostEnvelope(.retryable_no_charge, 4),
        try testCostEnvelope(.ambiguous, 5),
        try testCostEnvelope(.resolved_success, 5),
    };
    var bytes: [test_journal_bytes]u8 = undefined;
    _ = try encodeHeaderV1(header, bytes[0..header_bytes]);
    var previous = header.header_sha256;
    for (costs, 0..) |cost, index| {
        const start = header_bytes + index * frame_bytes;
        const encoded_frame = try encodeFrameV1(
            header,
            @as(u64, @intCast(index)) + 1,
            previous,
            &cost.bytes,
            bytes[start .. start + frame_bytes],
        );
        previous = frameRoot(encoded_frame);
    }
    return .{
        .header = header,
        .bytes = bytes,
        .final_chain_sha256 = previous,
    };
}

fn resealHeaderForTest(encoded: []u8) void {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(header_domain);
    hash.update(encoded[8..16]);
    hash.update(encoded[24..28]);
    hash.update(encoded[32..40]);
    hash.update(encoded[40..72]);
    hash.update(encoded[72..75]);
    hash.update(encoded[80..112]);
    var root: Digest = undefined;
    hash.final(&root);
    @memcpy(encoded[112..144], &root);
}

fn resealFrameForTest(header_sha256: Digest, encoded: []u8) void {
    const root = frameSha256(header_sha256, encoded[0..frame_prefix_bytes]);
    @memcpy(
        encoded[frame_prefix_bytes .. frame_prefix_bytes + digest_bytes],
        &root,
    );
    @memcpy(
        encoded[frame_body_bytes + commit_magic.len + 8 .. frame_bytes],
        &root,
    );
}

test "multi-attempt journal resolves ambiguity without double counting" {
    const fixture = try testJournal();
    const header_hex = std.fmt.bytesToHex(
        fixture.header.header_sha256,
        .lower,
    );
    const final_hex = std.fmt.bytesToHex(
        fixture.final_chain_sha256,
        .lower,
    );
    try std.testing.expectEqualStrings(
        "f778fb16cab3df661e58f8f10fe94e2d49686da594c45c6824ddfddffeab93ef",
        &header_hex,
    );
    try std.testing.expectEqualStrings(
        "b8eeb5f018c5be473bdf1e12634a2b2605b39c3bfde96696f05659b009998edc",
        &final_hex,
    );
    var entries: [test_frame_count]DecodedFrameV1 = undefined;
    var requests: [test_frame_count]RequestStateV1 = undefined;
    const recovered = try verifyClosedV1(
        &fixture.bytes,
        fixture.header.header_sha256,
        fixture.final_chain_sha256,
        &entries,
        &requests,
    );
    try std.testing.expectEqual(RecoveryStatus.clean, recovered.status);
    try std.testing.expectEqual(@as(usize, test_journal_bytes), recovered.committed_bytes);
    try std.testing.expectEqual(@as(usize, 0), recovered.discarded_tail_bytes);
    try std.testing.expectEqual(@as(u64, 3), recovered.ledger.committed_frames);
    try std.testing.expectEqual(@as(u64, 2), recovered.ledger.physical_attempts);
    try std.testing.expectEqual(@as(u64, 2), recovered.ledger.settled_attempts);
    try std.testing.expectEqual(@as(u64, 1), recovered.ledger.retryable_no_charge_records);
    try std.testing.expectEqual(@as(u64, 1), recovered.ledger.ambiguous_records);
    try std.testing.expectEqual(@as(u64, 1), recovered.ledger.resolved_records);
    try std.testing.expectEqual(@as(u64, 1), recovered.ledger.terminal_requests);
    try std.testing.expectEqual(@as(u64, 0), recovered.ledger.open_ambiguous_requests);
    try std.testing.expectEqual(@as(u64, 1_400_000), recovered.ledger.quoted_nanos.value);
    try std.testing.expectEqual(@as(u64, 316_000), recovered.ledger.settled_nanos.value);
    try std.testing.expectEqual(@as(u64, 1_084_000), recovered.ledger.savings_nanos.value);
    try std.testing.expectEqual(@as(u64, 0), recovered.ledger.overrun_nanos.value);
}

test "every append crash boundary recovers only committed footer prefixes" {
    const fixture = try testJournal();
    var entries: [test_frame_count]DecodedFrameV1 = undefined;
    var requests: [test_frame_count]RequestStateV1 = undefined;
    for (header_bytes..fixture.bytes.len + 1) |length| {
        const recovered = try recoverV1(
            fixture.bytes[0..length],
            fixture.header.header_sha256,
            &entries,
            &requests,
        );
        const payload = length - header_bytes;
        const expected_frames = payload / frame_bytes;
        const expected_tail = payload % frame_bytes;
        try std.testing.expectEqual(
            @as(u64, @intCast(expected_frames)),
            recovered.ledger.committed_frames,
        );
        try std.testing.expectEqual(expected_tail, recovered.discarded_tail_bytes);
        try std.testing.expectEqual(
            if (expected_tail == 0) RecoveryStatus.clean else RecoveryStatus.torn_tail,
            recovered.status,
        );
    }
}

test "closed verification rejects suffix loss and corrupt committed footer" {
    const fixture = try testJournal();
    var entries: [test_frame_count]DecodedFrameV1 = undefined;
    var requests: [test_frame_count]RequestStateV1 = undefined;
    try std.testing.expectError(
        Error.InvalidCommit,
        verifyClosedV1(
            fixture.bytes[0 .. fixture.bytes.len - frame_bytes],
            fixture.header.header_sha256,
            fixture.final_chain_sha256,
            &entries,
            &requests,
        ),
    );
    const torn = try recoverV1(
        fixture.bytes[0 .. fixture.bytes.len - 1],
        fixture.header.header_sha256,
        &entries,
        &requests,
    );
    try std.testing.expectEqual(RecoveryStatus.torn_tail, torn.status);
    try std.testing.expectEqual(@as(u64, 2), torn.ledger.committed_frames);

    var corrupt = fixture.bytes;
    corrupt[fixture.bytes.len - commit_footer_bytes] ^= 1;
    try std.testing.expectError(
        Error.InvalidCommit,
        recoverV1(
            &corrupt,
            fixture.header.header_sha256,
            &entries,
            &requests,
        ),
    );
}

test "duplicate attempts and resolution without ambiguity reject" {
    const fixture = try testJournal();
    const duplicate_cost = try testCostEnvelope(.retryable_no_charge, 4);
    var duplicate: [header_bytes + frame_bytes * 2]u8 = undefined;
    @memcpy(duplicate[0 .. header_bytes + frame_bytes], fixture.bytes[0 .. header_bytes + frame_bytes]);
    const first_root = frameRoot(duplicate[header_bytes .. header_bytes + frame_bytes]);
    _ = try encodeFrameV1(
        fixture.header,
        2,
        first_root,
        &duplicate_cost.bytes,
        duplicate[header_bytes + frame_bytes ..],
    );
    var entries: [2]DecodedFrameV1 = undefined;
    var requests: [2]RequestStateV1 = undefined;
    try std.testing.expectError(
        Error.InvalidLifecycle,
        recoverV1(
            &duplicate,
            fixture.header.header_sha256,
            &entries,
            &requests,
        ),
    );

    const resolution = try testCostEnvelope(.resolved_success, 4);
    var invalid: [header_bytes + frame_bytes]u8 = undefined;
    _ = try encodeHeaderV1(fixture.header, invalid[0..header_bytes]);
    _ = try encodeFrameV1(
        fixture.header,
        1,
        fixture.header.header_sha256,
        &resolution.bytes,
        invalid[header_bytes..],
    );
    var one_entry: [1]DecodedFrameV1 = undefined;
    var one_request: [1]RequestStateV1 = undefined;
    try std.testing.expectError(
        Error.InvalidLifecycle,
        recoverV1(
            &invalid,
            fixture.header.header_sha256,
            &one_entry,
            &one_request,
        ),
    );
}

test "every serialized byte mutation rejects under pinned closed roots" {
    const fixture = try testJournal();
    var mutated: [test_journal_bytes]u8 = undefined;
    var entries: [test_frame_count]DecodedFrameV1 = undefined;
    var requests: [test_frame_count]RequestStateV1 = undefined;
    for (0..fixture.bytes.len) |offset| {
        @memcpy(&mutated, &fixture.bytes);
        mutated[offset] ^= 1;
        if (offset < 112) {
            resealHeaderForTest(mutated[0..header_bytes]);
        } else if (offset >= header_bytes) {
            const frame_index = (offset - header_bytes) / frame_bytes;
            const frame_offset = (offset - header_bytes) % frame_bytes;
            if (frame_offset < frame_prefix_bytes) {
                const start = header_bytes + frame_index * frame_bytes;
                resealFrameForTest(
                    fixture.header.header_sha256,
                    mutated[start .. start + frame_bytes],
                );
            }
        }
        if (verifyClosedV1(
            &mutated,
            fixture.header.header_sha256,
            fixture.final_chain_sha256,
            &entries,
            &requests,
        )) |_| {
            return error.AcceptedMutation;
        } else |_| {}
    }
}

test "journal layout keeps body and commit footer independently appendable" {
    const fixture = try testJournal();
    const plan = try appendPlanV1(
        fixture.bytes[header_bytes .. header_bytes + frame_bytes],
    );
    try std.testing.expectEqual(@as(usize, 144), header_bytes);
    try std.testing.expectEqual(@as(usize, 1565), frame_prefix_bytes);
    try std.testing.expectEqual(@as(usize, 1597), frame_body_bytes);
    try std.testing.expectEqual(@as(usize, 48), commit_footer_bytes);
    try std.testing.expectEqual(@as(usize, 1645), frame_bytes);
    try std.testing.expectEqual(@as(usize, 5079), test_journal_bytes);
    try std.testing.expectEqual(frame_body_bytes, plan.body.len);
    try std.testing.expectEqual(commit_footer_bytes, plan.commit_footer.len);
}

test "locked store creates appends and reopens the exact journal" {
    const fixture = try testJournal();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    var frame_storage: [frame_bytes]u8 = undefined;
    var requests: [test_frame_count]RequestStateV1 = undefined;
    var store = try StoreV1.create(
        temporary.dir,
        "cost.journal",
        fixture.header,
        &frame_storage,
        &requests,
    );
    defer store.close();
    try std.testing.expectEqual(
        switch (builtin.os.tag) {
            .linux,
            .macos,
            .ios,
            .freebsd,
            .netbsd,
            .dragonfly,
            .openbsd,
            .solaris,
            .illumos,
            => DirectorySyncStatusV1.synced,
            else => DirectorySyncStatusV1.unsupported,
        },
        store.directory_sync_status,
    );

    var locked_frame_storage: [frame_bytes]u8 = undefined;
    var locked_requests: [test_frame_count]RequestStateV1 = undefined;
    try std.testing.expectError(
        error.WouldBlock,
        StoreV1.open(
            temporary.dir,
            "cost.journal",
            fixture.header.header_sha256,
            .{ .lock_nonblocking = true },
            &locked_frame_storage,
            &locked_requests,
        ),
    );

    for (0..test_frame_count) |index| {
        const start = header_bytes + index * frame_bytes;
        @memcpy(
            store.frame_storage[0..frame_bytes],
            fixture.bytes[start .. start + frame_bytes],
        );
        const receipt = try store.appendFrame(
            store.frame_storage[0..frame_bytes],
            .{},
        );
        try std.testing.expectEqual(
            @as(u64, @intCast(index)) + 1,
            receipt.sequence,
        );
        try std.testing.expect(receipt.body_sync_exercised);
        try std.testing.expect(receipt.footer_sync_exercised);
    }
    var actual_bytes: [test_journal_bytes]u8 = undefined;
    try std.testing.expectEqual(
        @as(usize, test_journal_bytes),
        try store.file.preadAll(&actual_bytes, 0),
    );
    try std.testing.expectEqualSlices(u8, &fixture.bytes, &actual_bytes);
    store.close();

    var reopened_frame_storage: [frame_bytes]u8 = undefined;
    var reopened_requests: [test_frame_count]RequestStateV1 = undefined;
    var reopened = try StoreV1.open(
        temporary.dir,
        "cost.journal",
        fixture.header.header_sha256,
        .{},
        &reopened_frame_storage,
        &reopened_requests,
    );
    defer reopened.close();
    try std.testing.expectEqual(RecoveryStatus.clean, reopened.recovered_status);
    try std.testing.expectEqual(@as(usize, 0), reopened.discarded_tail_bytes);
    try std.testing.expect(!reopened.repair_sync_exercised);
    try std.testing.expectEqual(
        @as(u64, test_frame_count),
        reopened.ledger.committed_frames,
    );
    try std.testing.expectEqualSlices(
        u8,
        &fixture.final_chain_sha256,
        &reopened.final_chain_sha256,
    );
}

test "filesystem append fault phases require reopen and exact recovery" {
    const fixture = try testJournal();
    const phases = [_]AppendPhaseV1{
        .after_body_write,
        .after_body_sync,
        .after_footer_write,
        .after_footer_sync,
    };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    for (phases, 0..) |phase, phase_index| {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(
            &name_buffer,
            "fault-{d}.journal",
            .{phase_index},
        );
        var frame_storage: [frame_bytes]u8 = undefined;
        var requests: [test_frame_count]RequestStateV1 = undefined;
        var store = try StoreV1.create(
            temporary.dir,
            name,
            fixture.header,
            &frame_storage,
            &requests,
        );
        const first = fixture.bytes[header_bytes .. header_bytes + frame_bytes];
        _ = try store.appendFrame(first, .{});
        const second_start = header_bytes + frame_bytes;
        const second = fixture.bytes[second_start .. second_start + frame_bytes];
        try std.testing.expectError(
            Error.InjectedFault,
            store.appendFrame(
                second,
                .{ .fault_after_phase = phase },
            ),
        );
        try std.testing.expectEqual(StoreStateV1.poisoned, store.state);
        try std.testing.expectError(
            Error.InvalidState,
            store.appendFrame(second, .{}),
        );
        store.close();

        const body_phase = phase == .after_body_write or
            phase == .after_body_sync;
        if (body_phase) {
            var reject_frame_storage: [frame_bytes]u8 = undefined;
            var reject_requests: [test_frame_count]RequestStateV1 = undefined;
            try std.testing.expectError(
                Error.TornTailRequiresRepair,
                StoreV1.open(
                    temporary.dir,
                    name,
                    fixture.header.header_sha256,
                    .{ .repair_torn_tail = false },
                    &reject_frame_storage,
                    &reject_requests,
                ),
            );
        }

        var recovered_frame_storage: [frame_bytes]u8 = undefined;
        var recovered_requests: [test_frame_count]RequestStateV1 = undefined;
        var recovered = try StoreV1.open(
            temporary.dir,
            name,
            fixture.header.header_sha256,
            .{},
            &recovered_frame_storage,
            &recovered_requests,
        );
        defer recovered.close();
        if (body_phase) {
            try std.testing.expectEqual(
                RecoveryStatus.torn_tail,
                recovered.recovered_status,
            );
            try std.testing.expectEqual(
                @as(usize, frame_body_bytes),
                recovered.discarded_tail_bytes,
            );
            try std.testing.expect(recovered.repair_sync_exercised);
            try std.testing.expectEqual(
                @as(u64, 1),
                recovered.ledger.committed_frames,
            );
            try std.testing.expectEqual(
                @as(u64, header_bytes + frame_bytes),
                try recovered.file.getEndPos(),
            );
        } else {
            try std.testing.expectEqual(
                RecoveryStatus.clean,
                recovered.recovered_status,
            );
            try std.testing.expect(!recovered.repair_sync_exercised);
            try std.testing.expectEqual(
                @as(u64, 2),
                recovered.ledger.committed_frames,
            );
            try std.testing.expectEqual(
                @as(u64, header_bytes + frame_bytes * 2),
                try recovered.file.getEndPos(),
            );
        }
    }
}

test "filesystem store rejects corrupt commits and path escape" {
    const fixture = try testJournal();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    var short_storage: [frame_bytes]u8 = undefined;
    var no_requests: [0]RequestStateV1 = .{};
    try std.testing.expectError(
        Error.InvalidPath,
        StoreV1.create(
            temporary.dir,
            "../escape.journal",
            fixture.header,
            &short_storage,
            &no_requests,
        ),
    );
    var invalid_header = fixture.header;
    invalid_header.journal_epoch = 0;
    try std.testing.expectError(
        Error.InvalidHeader,
        StoreV1.create(
            temporary.dir,
            "invalid.journal",
            invalid_header,
            &short_storage,
            &no_requests,
        ),
    );
    try std.testing.expectError(
        error.FileNotFound,
        temporary.dir.statFile("invalid.journal"),
    );

    var frame_storage: [frame_bytes]u8 = undefined;
    var requests: [test_frame_count]RequestStateV1 = undefined;
    var store = try StoreV1.create(
        temporary.dir,
        "corrupt.journal",
        fixture.header,
        &frame_storage,
        &requests,
    );
    for (0..test_frame_count) |index| {
        const start = header_bytes + index * frame_bytes;
        _ = try store.appendFrame(
            fixture.bytes[start .. start + frame_bytes],
            .{},
        );
    }
    store.close();

    var corrupt_file = try temporary.dir.openFile(
        "corrupt.journal",
        .{ .mode = .read_write, .lock = .exclusive },
    );
    const corrupt_offset = test_journal_bytes - commit_footer_bytes;
    try corrupt_file.seekTo(corrupt_offset);
    var corrupt_byte: [1]u8 = undefined;
    if (try corrupt_file.readAll(&corrupt_byte) != 1) return Error.ShortRead;
    corrupt_byte[0] ^= 1;
    try corrupt_file.seekTo(corrupt_offset);
    try corrupt_file.writeAll(&corrupt_byte);
    try corrupt_file.sync();
    corrupt_file.close();

    var rejected_frame_storage: [frame_bytes]u8 = undefined;
    var rejected_requests: [test_frame_count]RequestStateV1 = undefined;
    try std.testing.expectError(
        Error.InvalidCommit,
        StoreV1.open(
            temporary.dir,
            "corrupt.journal",
            fixture.header.header_sha256,
            .{},
            &rejected_frame_storage,
            &rejected_requests,
        ),
    );
    const stat = try temporary.dir.statFile("corrupt.journal");
    try std.testing.expectEqual(@as(u64, test_journal_bytes), stat.size);
}
