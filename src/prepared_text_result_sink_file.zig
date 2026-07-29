//! Descriptor-relative durable adapter for prepared-text result delivery.
//!
//! Each successful application publishes a complete immutable acknowledgement
//! ledger, then atomically replaces one fixed selector. The adapter never runs
//! inside `lane_publication_txn.SinkV1.commit`: callers pass the receipt to the
//! portable result sink after `SessionV3.step` returns.
//!
//! Ordered `fsync` calls and process-death tests establish the declared POSIX
//! host protocol. They do not claim physical power-loss durability.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const result_sink = @import("prepared_text_result_sink.zig");

extern "c" fn renameatx_np(
    old_directory: std.posix.fd_t,
    old_name: [*:0]const u8,
    new_directory: std.posix.fd_t,
    new_name: [*:0]const u8,
    flags: c_uint,
) c_int;

const platform_capabilities = core.platform_capabilities;
const sweep_file = core.continuation_object_sweep_file;

pub const Digest = result_sink.Digest;
pub const zero_digest = result_sink.zero_digest;

pub const ledger_abi: u64 = 0x4750_524c_0000_0001;
pub const selector_abi: u64 = 0x4750_524c_0000_0002;
pub const ledger_magic =
    [_]u8{ 'G', 'P', 'R', 'S', 'L', 'E', 'D', '1' };
pub const selector_magic =
    [_]u8{ 'G', 'P', 'R', 'S', 'S', 'E', 'L', '1' };
pub const ledger_header_bytes: usize = 256;
pub const ledger_footer_bytes: usize = 32;
pub const selector_bytes: usize = 272;
pub const selector_body_bytes: usize = selector_bytes - 32;
pub const allowed_flags: u64 = 0;

pub const lock_name =
    ".glacier-prepared-text-result-sink-lock-v1";
pub const active_selector_name =
    ".glacier-prepared-text-result-sink-active-v1";
const lease_capacity_bytes =
    core.continuation_object_sweep_record.encoded_bytes;

fn initialRecoveryOsAvailableV1(os_tag: std.Target.Os.Tag) bool {
    return switch (os_tag) {
        .linux, .macos, .ios => true,
        else => false,
    };
}

/// Recoverable first publication additionally requires an atomic no-replace
/// rename. Unsupported kernels fail closed instead of falling back to a
/// check-then-replace sequence.
pub const initial_recovery_available_v1 =
    platform_capabilities.current_adapter_availability_v1
        .posix_durable_file_adapter and
    initialRecoveryOsAvailableV1(builtin.os.tag);

const ledger_domain =
    "glacier-prepared-text-result-sink-ledger-v1\x00";
const selector_domain =
    "glacier-prepared-text-result-sink-selector-v1\x00";
const max_generated_name_bytes: usize = 192;

pub const Error = result_sink.Error || sweep_file.Error || error{
    InjectedFault,
    InvalidLedger,
    InvalidSelector,
    InvalidState,
    InvalidStorage,
    MultipleLinks,
    PublicationMismatch,
    SelectionChanged,
    StorageContentChanged,
    StorageIdentityChanged,
    StorageIo,
    UnsafePermissions,
    UnsupportedPlatform,
};

pub const IoPhaseV1 = enum(u8) {
    ledger_body_write,
    ledger_body_sync,
    ledger_footer_write,
    ledger_file_sync,
    ledger_immutable_rename,
    ledger_directory_sync,
    selector_temp_write,
    selector_temp_sync,
    selector_replace,
    selector_directory_sync,
};

/// Called after the named OS operation returns and before its postcondition is
/// accepted. Tests use this boundary for injected failure and process death.
pub const PhaseObserverV1 = struct {
    context: *anyopaque,
    after_phase_fn: *const fn (
        context: *anyopaque,
        phase: IoPhaseV1,
    ) Error!void,

    fn after(self: PhaseObserverV1, phase: IoPhaseV1) Error!void {
        try self.after_phase_fn(self.context, phase);
    }
};

pub const PreparedLedgerV1 = struct {
    bytes: []const u8,
    ledger_sha256: Digest,
};

pub const DecodedLedgerV1 = struct {
    encoded: []const u8,
    acknowledgement_count: usize,
    initial_sequence: u64,
    next_sequence: u64,
    request_epoch: u64,
    request_sha256: Digest,
    sink_implementation_sha256: Digest,
    sink_instance_sha256: Digest,
    last_acknowledgement_sha256: Digest,
    result_sink_prefix_sha256: Digest,
    ledger_sha256: Digest,

    pub fn acknowledgement(
        self: DecodedLedgerV1,
        index: usize,
    ) Error!result_sink.ResultAcknowledgementV1 {
        if (index >= self.acknowledgement_count)
            return Error.InvalidLedger;
        const offset = ledger_header_bytes +
            index * result_sink.acknowledgement_bytes;
        return result_sink.decodeAcknowledgementV1(
            self.encoded[offset .. offset + result_sink.acknowledgement_bytes],
        );
    }
};

pub const PreparedSelectorV1 = struct {
    bytes: [selector_bytes]u8,
    selector_sha256: Digest,
};

pub const DecodedSelectorV1 = struct {
    generation: u64,
    acknowledgement_count: usize,
    initial_sequence: u64,
    next_sequence: u64,
    request_epoch: u64,
    ledger_bytes: usize,
    request_sha256: Digest,
    sink_implementation_sha256: Digest,
    sink_instance_sha256: Digest,
    previous_selector_sha256: Digest,
    ledger_sha256: Digest,
    selector_sha256: Digest,
};

/// One validated selector/immutable-ledger pair. `ledger.encoded` borrows the
/// caller-provided ledger storage until that storage is reused.
pub const SelectedSnapshotV1 = struct {
    selector: DecodedSelectorV1,
    ledger: DecodedLedgerV1,
};

pub const StoreStateV1 = enum(u8) {
    ready,
    publishing,
    poisoned,
    closed,
};

pub const ApplyDispositionV1 = enum(u8) {
    applied,
    replayed,
};

pub const EmptyInitializationDispositionV1 = enum(u8) {
    created,
    recovered,
    already_selected,
};

pub const DurableApplyReceiptV1 = struct {
    disposition: ApplyDispositionV1,
    acknowledgement: result_sink.ResultAcknowledgementV1,
    ledger_sha256: Digest,
    selector_sha256: Digest,
};

pub const runtime_result_sink_max_capacity_v1: usize = 63;
/// The result-sink lease stream is canonically empty. One byte is retained so
/// an unexpected non-empty lock file can still be inspected and rejected.
pub const runtime_result_sink_lock_bytes_v1: usize = 1;

/// Address-stable caller storage borrowed by `RuntimeResultSinkFileV1`.
///
/// Every region must remain exclusively owned and at the same address until
/// the returned store is closed. The four backing regions must be pairwise
/// disjoint, including the bytes occupied by `semantic_state` itself.
pub const RuntimeResultSinkFileStorageV1 = struct {
    semantic_state: *result_sink.RuntimeResultSinkStateV1,
    lock: []u8,
    acknowledgements: []result_sink.ResultAcknowledgementV1,
    ledger: []u8,
};

/// Pure semantic decision plus its exact retained durable candidate.
///
/// `ledger`, when present, borrows the runtime store's retained ledger
/// storage. Callers must keep exclusive access to the store and must not
/// mutate that storage before passing this value to `applyPrepared`.
pub const RuntimePreparedApplyV1 = struct {
    input: result_sink.DeliveryInputV1,
    semantic: result_sink.PreparedApplyV1,
    acknowledgement_count: usize,
    ledger_sha256: Digest,
    selector_sha256: Digest,
    ledger: ?PreparedLedgerV1,
    selector: ?PreparedSelectorV1,

    fn receipt(
        self: RuntimePreparedApplyV1,
    ) DurableApplyReceiptV1 {
        return .{
            .disposition = switch (self.semantic.disposition) {
                .applied => .applied,
                .replayed => .replayed,
            },
            .acknowledgement = self.semantic.acknowledgement,
            .ledger_sha256 = self.ledger_sha256,
            .selector_sha256 = self.selector_sha256,
        };
    }
};

pub fn ledgerBytesForCountV1(count: usize) Error!usize {
    const acknowledgements = std.math.mul(
        usize,
        count,
        result_sink.acknowledgement_bytes,
    ) catch return Error.ArithmeticOverflow;
    const body = std.math.add(
        usize,
        ledger_header_bytes,
        acknowledgements,
    ) catch return Error.ArithmeticOverflow;
    return std.math.add(
        usize,
        body,
        ledger_footer_bytes,
    ) catch return Error.ArithmeticOverflow;
}

pub fn encodeLedgerV1(
    request_sha256: Digest,
    request_epoch: u64,
    initial_sequence: u64,
    sink_implementation_sha256: Digest,
    sink_instance_sha256: Digest,
    acknowledgements: []const result_sink.ResultAcknowledgementV1,
    destination: []u8,
) Error!PreparedLedgerV1 {
    return encodeLedgerPartsV1(
        request_sha256,
        request_epoch,
        initial_sequence,
        sink_implementation_sha256,
        sink_instance_sha256,
        acknowledgements,
        null,
        destination,
    );
}

/// Encodes an existing acknowledgement prefix and at most one prepared tail
/// without first mutating the live semantic ledger. The resulting bytes are
/// identical to `encodeLedgerV1` over the contiguous combined sequence.
pub fn encodeLedgerPartsV1(
    request_sha256: Digest,
    request_epoch: u64,
    initial_sequence: u64,
    sink_implementation_sha256: Digest,
    sink_instance_sha256: Digest,
    acknowledgement_prefix: []const result_sink.ResultAcknowledgementV1,
    appended_acknowledgement: ?result_sink.ResultAcknowledgementV1,
    destination: []u8,
) Error!PreparedLedgerV1 {
    if (isZero(request_sha256) or request_epoch == 0 or
        isZero(sink_implementation_sha256) or
        isZero(sink_instance_sha256))
        return Error.InvalidLedger;
    const acknowledgement_count = std.math.add(
        usize,
        acknowledgement_prefix.len,
        if (appended_acknowledgement == null) 0 else 1,
    ) catch return Error.ArithmeticOverflow;
    const encoded_bytes = try ledgerBytesForCountV1(
        acknowledgement_count,
    );
    if (destination.len < encoded_bytes)
        return Error.BufferTooSmall;
    const encoded = destination[0..encoded_bytes];
    if (slicesOverlapV1(
        std.mem.sliceAsBytes(acknowledgement_prefix),
        encoded,
    ))
        return Error.InvalidStorage;
    const acknowledgement_count_u64 = std.math.cast(
        u64,
        acknowledgement_count,
    ) orelse return Error.ArithmeticOverflow;
    const next_sequence = std.math.add(
        u64,
        initial_sequence,
        acknowledgement_count_u64,
    ) catch return Error.ArithmeticOverflow;
    const last_acknowledgement = if (appended_acknowledgement) |appended|
        appended
    else if (acknowledgement_prefix.len == 0)
        null
    else
        acknowledgement_prefix[acknowledgement_prefix.len - 1];
    const last_ack = if (last_acknowledgement) |acknowledgement|
        acknowledgement.acknowledgement_sha256
    else
        zero_digest;
    const result_prefix = if (last_acknowledgement) |acknowledgement|
        acknowledgement.result_sink_prefix_sha256
    else
        zero_digest;

    @memset(encoded, 0);
    @memcpy(encoded[0..8], &ledger_magic);
    writeU64(encoded, 8, ledger_abi);
    writeU64(encoded, 16, ledger_header_bytes);
    writeU64(
        encoded,
        24,
        result_sink.acknowledgement_bytes,
    );
    writeU64(encoded, 32, encoded_bytes);
    writeU64(encoded, 40, acknowledgement_count);
    writeU64(encoded, 48, initial_sequence);
    writeU64(encoded, 56, next_sequence);
    writeU64(encoded, 64, request_epoch);
    writeU64(encoded, 72, allowed_flags);
    @memcpy(encoded[80..112], &request_sha256);
    @memcpy(encoded[112..144], &sink_implementation_sha256);
    @memcpy(encoded[144..176], &sink_instance_sha256);
    @memcpy(encoded[176..208], &last_ack);
    @memcpy(encoded[208..240], &result_prefix);

    for (acknowledgement_prefix, 0..) |acknowledgement, index| {
        const offset = ledger_header_bytes +
            index * result_sink.acknowledgement_bytes;
        _ = try result_sink.encodeAcknowledgementV1(
            acknowledgement,
            encoded[offset .. offset + result_sink.acknowledgement_bytes],
        );
    }
    if (appended_acknowledgement) |acknowledgement| {
        const offset = ledger_header_bytes +
            acknowledgement_prefix.len *
                result_sink.acknowledgement_bytes;
        _ = try result_sink.encodeAcknowledgementV1(
            acknowledgement,
            encoded[offset .. offset + result_sink.acknowledgement_bytes],
        );
    }
    const footer_offset = encoded_bytes - ledger_footer_bytes;
    const root = ledgerRootV1(encoded[0..footer_offset]);
    @memcpy(encoded[footer_offset..], &root);
    const decoded = try decodeLedgerV1(encoded);
    if (!digestEqual(decoded.ledger_sha256, root))
        return Error.InvalidLedger;
    return .{ .bytes = encoded, .ledger_sha256 = root };
}

pub fn decodeLedgerV1(encoded: []const u8) Error!DecodedLedgerV1 {
    if (encoded.len < ledger_header_bytes + ledger_footer_bytes or
        !std.mem.eql(u8, encoded[0..8], &ledger_magic) or
        readU64(encoded, 8) != ledger_abi or
        readU64(encoded, 16) != ledger_header_bytes or
        readU64(encoded, 24) !=
            result_sink.acknowledgement_bytes or
        readU64(encoded, 32) != encoded.len or
        readU64(encoded, 72) != allowed_flags or
        !std.mem.allEqual(u8, encoded[240..256], 0))
        return Error.InvalidLedger;
    const count = std.math.cast(
        usize,
        readU64(encoded, 40),
    ) orelse return Error.InvalidLedger;
    if (try ledgerBytesForCountV1(count) != encoded.len)
        return Error.InvalidLedger;
    const initial_sequence = readU64(encoded, 48);
    const next_sequence = readU64(encoded, 56);
    const request_epoch = readU64(encoded, 64);
    const expected_next = std.math.add(
        u64,
        initial_sequence,
        @as(u64, @intCast(count)),
    ) catch return Error.InvalidLedger;
    const request_sha256 = encoded[80..112].*;
    const sink_implementation_sha256 = encoded[112..144].*;
    const sink_instance_sha256 = encoded[144..176].*;
    const last_acknowledgement_sha256 = encoded[176..208].*;
    const result_sink_prefix_sha256 = encoded[208..240].*;
    const footer_offset = encoded.len - ledger_footer_bytes;
    var ledger_sha256: Digest = undefined;
    @memcpy(
        &ledger_sha256,
        encoded[footer_offset .. footer_offset + ledger_footer_bytes],
    );
    if (request_epoch == 0 or next_sequence != expected_next or
        isZero(request_sha256) or
        isZero(sink_implementation_sha256) or
        isZero(sink_instance_sha256) or
        !digestEqual(
            ledger_sha256,
            ledgerRootV1(encoded[0..footer_offset]),
        ) or
        (count == 0 and
            (!isZero(last_acknowledgement_sha256) or
                !isZero(result_sink_prefix_sha256))) or
        (count > 0 and
            (isZero(last_acknowledgement_sha256) or
                isZero(result_sink_prefix_sha256))))
        return Error.InvalidLedger;

    const result: DecodedLedgerV1 = .{
        .encoded = encoded,
        .acknowledgement_count = count,
        .initial_sequence = initial_sequence,
        .next_sequence = next_sequence,
        .request_epoch = request_epoch,
        .request_sha256 = request_sha256,
        .sink_implementation_sha256 = sink_implementation_sha256,
        .sink_instance_sha256 = sink_instance_sha256,
        .last_acknowledgement_sha256 = last_acknowledgement_sha256,
        .result_sink_prefix_sha256 = result_sink_prefix_sha256,
        .ledger_sha256 = ledger_sha256,
    };
    var previous_ack = zero_digest;
    var previous_prefix = zero_digest;
    for (0..count) |index| {
        const acknowledgement = try result.acknowledgement(index);
        const sequence = std.math.add(
            u64,
            initial_sequence,
            @as(u64, @intCast(index)),
        ) catch return Error.InvalidLedger;
        if (acknowledgement.application_ordinal != index + 1 or
            acknowledgement.application_count != 1 or
            acknowledgement.request_epoch != request_epoch or
            acknowledgement.transaction_sequence != sequence or
            !digestEqual(
                acknowledgement.request_sha256,
                request_sha256,
            ) or !digestEqual(
            acknowledgement.sink_implementation_sha256,
            sink_implementation_sha256,
        ) or !digestEqual(
            acknowledgement.sink_instance_sha256,
            sink_instance_sha256,
        ) or !digestEqual(
            acknowledgement.predecessor_acknowledgement_sha256,
            previous_ack,
        ) or !digestEqual(
            acknowledgement.predecessor_sink_prefix_sha256,
            previous_prefix,
        ))
            return Error.InvalidLedger;
        previous_ack = acknowledgement.acknowledgement_sha256;
        previous_prefix = acknowledgement.result_sink_prefix_sha256;
    }
    if (!digestEqual(previous_ack, last_acknowledgement_sha256) or
        !digestEqual(previous_prefix, result_sink_prefix_sha256))
        return Error.InvalidLedger;
    return result;
}

pub fn prepareInitialSelectorV1(
    ledger: PreparedLedgerV1,
) Error!PreparedSelectorV1 {
    const decoded = try decodeLedgerV1(ledger.bytes);
    if (decoded.acknowledgement_count != 0)
        return Error.InvalidSelector;
    return encodeSelectorV1(1, zero_digest, decoded);
}

pub fn prepareSuccessorSelectorV1(
    previous: DecodedSelectorV1,
    ledger: PreparedLedgerV1,
) Error!PreparedSelectorV1 {
    const decoded = try decodeLedgerV1(ledger.bytes);
    const generation = std.math.add(
        u64,
        previous.generation,
        1,
    ) catch return Error.ArithmeticOverflow;
    const expected_count = std.math.add(
        usize,
        previous.acknowledgement_count,
        1,
    ) catch return Error.ArithmeticOverflow;
    const expected_next = std.math.add(
        u64,
        previous.next_sequence,
        1,
    ) catch return Error.ArithmeticOverflow;
    if (decoded.acknowledgement_count !=
        expected_count or
        decoded.initial_sequence != previous.initial_sequence or
        decoded.next_sequence != expected_next or
        decoded.request_epoch != previous.request_epoch or
        !digestEqual(decoded.request_sha256, previous.request_sha256) or
        !digestEqual(
            decoded.sink_implementation_sha256,
            previous.sink_implementation_sha256,
        ) or !digestEqual(
        decoded.sink_instance_sha256,
        previous.sink_instance_sha256,
    ))
        return Error.InvalidSelector;
    return encodeSelectorV1(
        generation,
        previous.selector_sha256,
        decoded,
    );
}

pub fn decodeSelectorV1(
    encoded: []const u8,
) Error!DecodedSelectorV1 {
    if (encoded.len != selector_bytes or
        !std.mem.eql(u8, encoded[0..8], &selector_magic) or
        readU64(encoded, 8) != selector_abi or
        readU64(encoded, 16) != selector_bytes or
        readU64(encoded, 24) != allowed_flags)
        return Error.InvalidSelector;
    const generation = readU64(encoded, 32);
    const count = std.math.cast(
        usize,
        readU64(encoded, 40),
    ) orelse return Error.InvalidSelector;
    const initial_sequence = readU64(encoded, 48);
    const next_sequence = readU64(encoded, 56);
    const request_epoch = readU64(encoded, 64);
    const ledger_bytes = std.math.cast(
        usize,
        readU64(encoded, 72),
    ) orelse return Error.InvalidSelector;
    const request_sha256 = encoded[80..112].*;
    const sink_implementation_sha256 = encoded[112..144].*;
    const sink_instance_sha256 = encoded[144..176].*;
    const previous_selector_sha256 = encoded[176..208].*;
    const ledger_sha256 = encoded[208..240].*;
    const selector_sha256 = encoded[240..272].*;
    const expected_generation = std.math.add(
        u64,
        @as(u64, @intCast(count)),
        1,
    ) catch return Error.InvalidSelector;
    const expected_next = std.math.add(
        u64,
        initial_sequence,
        @as(u64, @intCast(count)),
    ) catch return Error.InvalidSelector;
    if (generation == 0 or generation != expected_generation or
        request_epoch == 0 or next_sequence != expected_next or
        ledger_bytes != try ledgerBytesForCountV1(count) or
        isZero(request_sha256) or
        isZero(sink_implementation_sha256) or
        isZero(sink_instance_sha256) or isZero(ledger_sha256) or
        isZero(selector_sha256) or
        (generation == 1 and !isZero(previous_selector_sha256)) or
        (generation > 1 and isZero(previous_selector_sha256)) or
        !digestEqual(
            selector_sha256,
            selectorRootV1(encoded[0..selector_body_bytes]),
        ))
        return Error.InvalidSelector;
    return .{
        .generation = generation,
        .acknowledgement_count = count,
        .initial_sequence = initial_sequence,
        .next_sequence = next_sequence,
        .request_epoch = request_epoch,
        .ledger_bytes = ledger_bytes,
        .request_sha256 = request_sha256,
        .sink_implementation_sha256 = sink_implementation_sha256,
        .sink_instance_sha256 = sink_instance_sha256,
        .previous_selector_sha256 = previous_selector_sha256,
        .ledger_sha256 = ledger_sha256,
        .selector_sha256 = selector_sha256,
    };
}

pub fn ledgerRootV1(body: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(ledger_domain);
    hash.update(body);
    return finish(&hash);
}

pub fn selectorRootV1(body: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(selector_domain);
    hash.update(body);
    return finish(&hash);
}

/// Purely validates that one decoded active selector names and describes the
/// exact decoded immutable ledger supplied with it.
pub fn validateSelectedPairV1(
    selector: DecodedSelectorV1,
    ledger: DecodedLedgerV1,
) error{PublicationMismatch}!void {
    if (selector.acknowledgement_count !=
        ledger.acknowledgement_count or
        selector.initial_sequence != ledger.initial_sequence or
        selector.next_sequence != ledger.next_sequence or
        selector.request_epoch != ledger.request_epoch or
        selector.ledger_bytes != ledger.encoded.len or
        !digestEqual(selector.request_sha256, ledger.request_sha256) or
        !digestEqual(
            selector.sink_implementation_sha256,
            ledger.sink_implementation_sha256,
        ) or !digestEqual(
        selector.sink_instance_sha256,
        ledger.sink_instance_sha256,
    ) or !digestEqual(selector.ledger_sha256, ledger.ledger_sha256))
        return Error.PublicationMismatch;
}

/// Reads and validates the active selector without taking the writer lease.
/// The selected path is opened read-only without following a final symlink,
/// and must remain the same exact private single-link regular file throughout
/// the read.
pub fn readActiveSelectorReadOnlyV1(
    directory: std.fs.Dir,
    storage: *[selector_bytes]u8,
) !DecodedSelectorV1 {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1
        .posix_durable_file_adapter)
        return Error.UnsupportedPlatform;
    const encoded = try readStableExactReadOnlyFileV1(
        directory,
        active_selector_name,
        storage,
        selector_bytes,
    );
    return decodeSelectorV1(encoded);
}

/// Reads one allocation-free, read-only snapshot of the selected immutable
/// acknowledgement ledger. Only the active selector and its hash-derived
/// ledger name are consulted; locks, candidates, and unrelated artifacts are
/// neither opened nor recovered.
///
/// The selector is re-opened after ledger validation. A different or no
/// longer valid final selector is reported as `SelectionChanged`, so callers
/// can retry without accepting a mixed publication. The two storage regions
/// must not overlap.
pub fn readSelectedSnapshotReadOnlyV1(
    directory: std.fs.Dir,
    selector_storage: *[selector_bytes]u8,
    ledger_storage: []u8,
    maximum_acknowledgements: usize,
) !SelectedSnapshotV1 {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1
        .posix_durable_file_adapter)
        return Error.UnsupportedPlatform;
    return readSelectedSnapshotObservedV1(
        directory,
        selector_storage,
        ledger_storage,
        maximum_acknowledgements,
        null,
    );
}

/// Compatibility alias for `readSelectedSnapshotReadOnlyV1`.
pub fn readSelectedSnapshotV1(
    directory: std.fs.Dir,
    selector_storage: *[selector_bytes]u8,
    ledger_storage: []u8,
    maximum_acknowledgements: usize,
) !SelectedSnapshotV1 {
    return readSelectedSnapshotReadOnlyV1(
        directory,
        selector_storage,
        ledger_storage,
        maximum_acknowledgements,
    );
}

const StoreIoViewV1 = struct {
    directory: std.fs.Dir,
    lock: *sweep_file.FileLeaseV1,
    observer: ?PhaseObserverV1,

    fn publishFreshSelectionV1(
        self: StoreIoViewV1,
        ledger: PreparedLedgerV1,
        selector: PreparedSelectorV1,
    ) !void {
        var ledger_name_storage: [max_generated_name_bytes]u8 =
            undefined;
        const ledger_name = try ledgerNameV1(
            ledger.ledger_sha256,
            &ledger_name_storage,
        );
        try writeNewExactFileV1(
            self.directory,
            ledger_name,
            ledger.bytes,
        );
        try self.lock.commitDirectory();
        try writeNewExactFileV1(
            self.directory,
            active_selector_name,
            &selector.bytes,
        );
        try self.lock.commitDirectory();
    }

    fn publishLedgerV1(
        self: StoreIoViewV1,
        ledger: PreparedLedgerV1,
    ) !void {
        var immutable_name_storage: [
            max_generated_name_bytes
        ]u8 = undefined;
        const immutable_name = try ledgerNameV1(
            ledger.ledger_sha256,
            &immutable_name_storage,
        );
        if (try exactFileExistsV1(
            self.directory,
            immutable_name,
            ledger.bytes,
        )) return;

        var candidate_name_storage: [
            max_generated_name_bytes
        ]u8 = undefined;
        const candidate_name = try ledgerCandidateNameV1(
            ledger.ledger_sha256,
            &candidate_name_storage,
        );
        {
            const file = try createFreshSafeFileV1(
                self.directory,
                candidate_name,
            );
            defer file.close();
            const footer_offset =
                ledger.bytes.len - ledger_footer_bytes;
            try file.setEndPos(0);
            try file.pwriteAll(ledger.bytes[0..footer_offset], 0);
            try file.setEndPos(footer_offset);
            try self.observe(.ledger_body_write);
            try file.sync();
            try self.observe(.ledger_body_sync);
            try file.pwriteAll(
                ledger.bytes[footer_offset..],
                footer_offset,
            );
            try file.setEndPos(ledger.bytes.len);
            try self.observe(.ledger_footer_write);
            try file.sync();
            try self.observe(.ledger_file_sync);
            try verifyExactOpenFileV1(
                file,
                self.directory,
                candidate_name,
                ledger.bytes,
            );
        }
        try self.directory.rename(candidate_name, immutable_name);
        try self.observe(.ledger_immutable_rename);
        try self.lock.commitDirectory();
        try self.observe(.ledger_directory_sync);
        if (!try exactFileExistsV1(
            self.directory,
            immutable_name,
            ledger.bytes,
        ))
            return Error.StorageContentChanged;
    }

    /// Initial publication differs from successor publication in one
    /// crucial respect: neither the immutable ledger name nor the active
    /// selector may replace authority that raced the namespace audit.
    fn publishInitialLedgerV1(
        self: StoreIoViewV1,
        ledger: PreparedLedgerV1,
        namespace: EmptyInitializationNamespaceV1,
    ) !void {
        if (try exactFileExistsV1(
            self.directory,
            namespace.ledger_name,
            ledger.bytes,
        )) return;

        const file = openSafeFileV1(
            self.directory,
            namespace.ledger_candidate_name,
            .create,
        ) catch |err| switch (err) {
            error.PathAlreadyExists => try openSafeFileV1(
                self.directory,
                namespace.ledger_candidate_name,
                .existing,
            ),
            else => return err,
        };
        defer file.close();
        const initial_view = try inspectFileV1(
            file,
            self.directory,
            namespace.ledger_candidate_name,
        );
        try verifyPinnedRepairableFileV1(
            file,
            self.directory,
            namespace.ledger_candidate_name,
            ledger.bytes,
            initial_view,
        );
        const footer_offset =
            ledger.bytes.len - ledger_footer_bytes;

        try file.setEndPos(0);
        try file.pwriteAll(ledger.bytes[0..footer_offset], 0);
        try file.setEndPos(footer_offset);
        try self.observe(.ledger_body_write);
        try verifyPinnedExactFileV1(
            file,
            self.directory,
            namespace.ledger_candidate_name,
            ledger.bytes[0..footer_offset],
            initial_view,
        );
        try auditEmptyInitializationPhaseV1(
            self.directory,
            namespace,
            .{
                .active_selected = false,
                .immutable_ledger = false,
                .ledger_candidate = ledger.bytes[0..footer_offset],
            },
        );

        try file.sync();
        try self.observe(.ledger_body_sync);
        try verifyPinnedExactFileV1(
            file,
            self.directory,
            namespace.ledger_candidate_name,
            ledger.bytes[0..footer_offset],
            initial_view,
        );
        try auditEmptyInitializationPhaseV1(
            self.directory,
            namespace,
            .{
                .active_selected = false,
                .immutable_ledger = false,
                .ledger_candidate = ledger.bytes[0..footer_offset],
            },
        );

        try file.pwriteAll(
            ledger.bytes[footer_offset..],
            footer_offset,
        );
        try file.setEndPos(ledger.bytes.len);
        try self.observe(.ledger_footer_write);
        try verifyPinnedExactFileV1(
            file,
            self.directory,
            namespace.ledger_candidate_name,
            ledger.bytes,
            initial_view,
        );
        try auditEmptyInitializationPhaseV1(
            self.directory,
            namespace,
            .{
                .active_selected = false,
                .immutable_ledger = false,
                .ledger_candidate = ledger.bytes,
            },
        );

        try file.sync();
        try self.observe(.ledger_file_sync);
        try verifyPinnedExactFileV1(
            file,
            self.directory,
            namespace.ledger_candidate_name,
            ledger.bytes,
            initial_view,
        );
        try auditEmptyInitializationPhaseV1(
            self.directory,
            namespace,
            .{
                .active_selected = false,
                .immutable_ledger = false,
                .ledger_candidate = ledger.bytes,
            },
        );

        try renameNoReplaceV1(
            self.directory,
            namespace.ledger_candidate_name,
            namespace.ledger_name,
        );
        try self.observe(.ledger_immutable_rename);
        try verifyPinnedExactFileV1(
            file,
            self.directory,
            namespace.ledger_name,
            ledger.bytes,
            initial_view,
        );
        try auditEmptyInitializationPhaseV1(
            self.directory,
            namespace,
            .{
                .active_selected = false,
                .immutable_ledger = true,
            },
        );

        try self.lock.commitDirectory();
        try self.observe(.ledger_directory_sync);
        try verifyPinnedExactFileV1(
            file,
            self.directory,
            namespace.ledger_name,
            ledger.bytes,
            initial_view,
        );
        try auditEmptyInitializationPhaseV1(
            self.directory,
            namespace,
            .{
                .active_selected = false,
                .immutable_ledger = true,
            },
        );
    }

    fn publishSelectorV1(
        self: StoreIoViewV1,
        selector: PreparedSelectorV1,
    ) !void {
        var candidate_name_storage: [
            max_generated_name_bytes
        ]u8 = undefined;
        const candidate_name = try selectorCandidateNameV1(
            selector.selector_sha256,
            &candidate_name_storage,
        );
        {
            const file = try createFreshSafeFileV1(
                self.directory,
                candidate_name,
            );
            defer file.close();
            try file.setEndPos(0);
            try file.pwriteAll(&selector.bytes, 0);
            try file.setEndPos(selector.bytes.len);
            try self.observe(.selector_temp_write);
            try file.sync();
            try self.observe(.selector_temp_sync);
            try verifyExactOpenFileV1(
                file,
                self.directory,
                candidate_name,
                &selector.bytes,
            );
        }
        try self.directory.rename(
            candidate_name,
            active_selector_name,
        );
        try self.observe(.selector_replace);
        try self.lock.commitDirectory();
        try self.observe(.selector_directory_sync);
    }

    fn publishInitialSelectorV1(
        self: StoreIoViewV1,
        selector: PreparedSelectorV1,
        namespace: EmptyInitializationNamespaceV1,
    ) !void {
        const file = openSafeFileV1(
            self.directory,
            namespace.selector_candidate_name,
            .create,
        ) catch |err| switch (err) {
            error.PathAlreadyExists => try openSafeFileV1(
                self.directory,
                namespace.selector_candidate_name,
                .existing,
            ),
            else => return err,
        };
        defer file.close();
        const initial_view = try inspectFileV1(
            file,
            self.directory,
            namespace.selector_candidate_name,
        );
        try verifyPinnedRepairableFileV1(
            file,
            self.directory,
            namespace.selector_candidate_name,
            &selector.bytes,
            initial_view,
        );

        try file.setEndPos(0);
        try file.pwriteAll(&selector.bytes, 0);
        try file.setEndPos(selector.bytes.len);
        try self.observe(.selector_temp_write);
        try verifyPinnedExactFileV1(
            file,
            self.directory,
            namespace.selector_candidate_name,
            &selector.bytes,
            initial_view,
        );
        try auditEmptyInitializationPhaseV1(
            self.directory,
            namespace,
            .{
                .active_selected = false,
                .immutable_ledger = true,
                .selector_candidate = &selector.bytes,
            },
        );

        try file.sync();
        try self.observe(.selector_temp_sync);
        try verifyPinnedExactFileV1(
            file,
            self.directory,
            namespace.selector_candidate_name,
            &selector.bytes,
            initial_view,
        );
        // This full namespace audit is the last operation before the
        // selector's no-replace linearization point.
        try auditEmptyInitializationPhaseV1(
            self.directory,
            namespace,
            .{
                .active_selected = false,
                .immutable_ledger = true,
                .selector_candidate = &selector.bytes,
            },
        );

        try renameNoReplaceV1(
            self.directory,
            namespace.selector_candidate_name,
            active_selector_name,
        );
        try self.observe(.selector_replace);
        try verifyPinnedExactFileV1(
            file,
            self.directory,
            active_selector_name,
            &selector.bytes,
            initial_view,
        );
        try auditEmptyInitializationPhaseV1(
            self.directory,
            namespace,
            .{
                .active_selected = true,
                .immutable_ledger = true,
            },
        );

        try self.lock.commitDirectory();
        try self.observe(.selector_directory_sync);
        try verifyPinnedExactFileV1(
            file,
            self.directory,
            active_selector_name,
            &selector.bytes,
            initial_view,
        );
        try auditEmptyInitializationPhaseV1(
            self.directory,
            namespace,
            .{
                .active_selected = true,
                .immutable_ledger = true,
            },
        );
    }

    fn observe(self: StoreIoViewV1, phase: IoPhaseV1) Error!void {
        if (self.observer) |observer| try observer.after(phase);
    }
};

pub fn ResultSinkFileV1(comptime capacity: usize) type {
    if (capacity == 0)
        @compileError("durable result sink capacity must be nonzero");
    return struct {
        const Self = @This();
        const SemanticSink = result_sink.ResultSinkV1(capacity);

        pub const EmptyInitializationResultV1 = struct {
            store: Self,
            disposition: EmptyInitializationDispositionV1,
        };

        /// Borrowed from `lock`'s owned durable-directory authority. Never
        /// close this alias directly or retain it after `close`.
        directory: std.fs.Dir,
        lock: sweep_file.FileLeaseV1,
        sink: SemanticSink,
        selector: DecodedSelectorV1,
        observer: ?PhaseObserverV1,
        state: StoreStateV1 = .ready,

        pub fn create(
            directory: std.fs.Dir,
            storage_epoch: u64,
            request_sha256: Digest,
            request_epoch: u64,
            initial_sequence: u64,
            sink_implementation_sha256: Digest,
            sink_instance_sha256: Digest,
            lock_storage: []u8,
            observer: ?PhaseObserverV1,
        ) !Self {
            if (comptime !platform_capabilities
                .current_adapter_availability_v1
                .posix_durable_file_adapter)
                return Error.UnsupportedPlatform;
            var lock = try sweep_file.FileLeaseV1.create(
                directory,
                lock_name,
                .{
                    .storage_epoch = storage_epoch,
                    .max_bytes = lease_capacity_bytes,
                },
                lock_storage,
            );
            errdefer lock.close();
            const durable_directory = lock.directory;
            const sink = try SemanticSink.init(
                request_sha256,
                request_epoch,
                initial_sequence,
                sink_implementation_sha256,
                sink_instance_sha256,
            );
            var ledger_storage: [
                ledger_header_bytes + ledger_footer_bytes
            ]u8 = undefined;
            const ledger = try encodeLedgerV1(
                request_sha256,
                request_epoch,
                initial_sequence,
                sink_implementation_sha256,
                sink_instance_sha256,
                &.{},
                &ledger_storage,
            );
            const selector = try prepareInitialSelectorV1(ledger);
            try (StoreIoViewV1{
                .directory = durable_directory,
                .lock = &lock,
                .observer = observer,
            }).publishFreshSelectionV1(ledger, selector);
            return .{
                .directory = durable_directory,
                .lock = lock,
                .sink = sink,
                .selector = try decodeSelectorV1(&selector.bytes),
                .observer = observer,
            };
        }

        /// Creates the canonical empty acknowledgement ledger and selects it,
        /// or completes that exact initialization after process death. An
        /// already-selected empty sink is accepted without rewriting it.
        /// Every other selected state is refused so this operation can never
        /// reset durable acknowledgements.
        pub fn createOrRecoverEmpty(
            directory: std.fs.Dir,
            storage_epoch: u64,
            request_sha256: Digest,
            request_epoch: u64,
            initial_sequence: u64,
            sink_implementation_sha256: Digest,
            sink_instance_sha256: Digest,
            lock_storage: []u8,
            observer: ?PhaseObserverV1,
        ) !EmptyInitializationResultV1 {
            if (comptime !initial_recovery_available_v1)
                return Error.UnsupportedPlatform;
            const semantic_sink = try SemanticSink.init(
                request_sha256,
                request_epoch,
                initial_sequence,
                sink_implementation_sha256,
                sink_instance_sha256,
            );
            var ledger_storage: [
                ledger_header_bytes + ledger_footer_bytes
            ]u8 = undefined;
            const ledger = try encodeLedgerV1(
                request_sha256,
                request_epoch,
                initial_sequence,
                sink_implementation_sha256,
                sink_instance_sha256,
                &.{},
                &ledger_storage,
            );
            const prepared_selector =
                try prepareInitialSelectorV1(ledger);
            const decoded_selector =
                try decodeSelectorV1(&prepared_selector.bytes);

            var ledger_name_storage: [
                max_generated_name_bytes
            ]u8 = undefined;
            const ledger_name = try ledgerNameV1(
                ledger.ledger_sha256,
                &ledger_name_storage,
            );
            var ledger_candidate_name_storage: [
                max_generated_name_bytes
            ]u8 = undefined;
            const ledger_candidate_name =
                try ledgerCandidateNameV1(
                    ledger.ledger_sha256,
                    &ledger_candidate_name_storage,
                );
            var selector_candidate_name_storage: [
                max_generated_name_bytes
            ]u8 = undefined;
            const selector_candidate_name =
                try selectorCandidateNameV1(
                    prepared_selector.selector_sha256,
                    &selector_candidate_name_storage,
                );
            const namespace: EmptyInitializationNamespaceV1 = .{
                .ledger_name = ledger_name,
                .ledger_candidate_name = ledger_candidate_name,
                .selector_candidate_name = selector_candidate_name,
                .ledger = ledger.bytes,
                .selector = &prepared_selector.bytes,
            };

            const acquired = try acquireEmptyLockV1(
                directory,
                storage_epoch,
                lock_storage,
            );
            const durable_directory = acquired.lock.directory;
            var store: Self = .{
                .directory = durable_directory,
                .lock = acquired.lock,
                .sink = semantic_sink,
                .selector = decoded_selector,
                .observer = observer,
            };
            errdefer store.close();

            if (try exactFileExistsV1(
                durable_directory,
                active_selector_name,
                &prepared_selector.bytes,
            )) {
                try verifySelectedEmptyV1(
                    durable_directory,
                    ledger,
                    prepared_selector,
                );
                _ = try inspectEmptyInitializationNamespaceV1(
                    durable_directory,
                    true,
                    namespace,
                );
                return .{
                    .store = store,
                    .disposition = .already_selected,
                };
            }

            const evidence =
                try inspectEmptyInitializationNamespaceV1(
                    durable_directory,
                    false,
                    namespace,
                );

            try store.ioView().publishInitialLedgerV1(
                ledger,
                namespace,
            );
            const ledger_boundary =
                try inspectEmptyInitializationNamespaceV1(
                    durable_directory,
                    false,
                    namespace,
                );
            if (!ledger_boundary.immutable_ledger or
                ledger_boundary.ledger_candidate or
                ledger_boundary.selector_candidate !=
                    evidence.selector_candidate)
                return Error.StorageIdentityChanged;
            try store.ioView().publishInitialSelectorV1(
                prepared_selector,
                namespace,
            );
            try verifySelectedEmptyV1(
                durable_directory,
                ledger,
                prepared_selector,
            );
            try auditEmptyInitializationPhaseV1(
                durable_directory,
                namespace,
                .{
                    .active_selected = true,
                    .immutable_ledger = true,
                },
            );
            return .{
                .store = store,
                .disposition = if (acquired.created and
                    !evidence.any())
                    .created
                else
                    .recovered,
            };
        }

        pub fn open(
            directory: std.fs.Dir,
            storage_epoch: u64,
            request_sha256: Digest,
            request_epoch: u64,
            initial_sequence: u64,
            sink_implementation_sha256: Digest,
            sink_instance_sha256: Digest,
            lock_storage: []u8,
            ledger_storage: []u8,
            observer: ?PhaseObserverV1,
        ) !Self {
            if (comptime !platform_capabilities
                .current_adapter_availability_v1
                .posix_durable_file_adapter)
                return Error.UnsupportedPlatform;
            const maximum_ledger_bytes =
                try ledgerBytesForCountV1(capacity);
            if (ledger_storage.len < maximum_ledger_bytes)
                return Error.BufferTooSmall;
            var lock = try sweep_file.FileLeaseV1.open(
                directory,
                lock_name,
                .{
                    .storage_epoch = storage_epoch,
                    .max_bytes = lease_capacity_bytes,
                },
                lock_storage,
            );
            errdefer lock.close();
            if (lock.stream().len != 0)
                return Error.StorageContentChanged;
            const durable_directory = lock.directory;
            const loaded = try loadActiveV1(
                durable_directory,
                ledger_storage,
                maximum_ledger_bytes,
            );
            try validateExpectedIdentityV1(
                loaded.selector,
                request_sha256,
                request_epoch,
                initial_sequence,
                sink_implementation_sha256,
                sink_instance_sha256,
            );
            if (loaded.ledger.acknowledgement_count > capacity)
                return Error.CapacityExceeded;
            var sink = try SemanticSink.init(
                request_sha256,
                request_epoch,
                initial_sequence,
                sink_implementation_sha256,
                sink_instance_sha256,
            );
            for (0..loaded.ledger.acknowledgement_count) |index| {
                const acknowledgement =
                    try loaded.ledger.acknowledgement(index);
                const replayed = try sink.apply(.{
                    .request_sha256 = acknowledgement.request_sha256,
                    .request_epoch = acknowledgement.request_epoch,
                    .transaction_sequence = acknowledgement.transaction_sequence,
                    .token_id = acknowledgement.token_id,
                    .proposal_sha256 = acknowledgement.proposal_sha256,
                    .transition_sha256 = acknowledgement.transition_sha256,
                    .commit_receipt_sha256 = acknowledgement.commit_receipt_sha256,
                });
                if (replayed.disposition != .applied or
                    !std.meta.eql(
                        replayed.acknowledgement,
                        acknowledgement,
                    ))
                    return Error.InvalidLedger;
            }
            return .{
                .directory = durable_directory,
                .lock = lock,
                .sink = sink,
                .selector = loaded.selector,
                .observer = observer,
            };
        }

        pub fn apply(
            self: *Self,
            input: result_sink.DeliveryInputV1,
            ledger_storage: []u8,
        ) !DurableApplyReceiptV1 {
            if (self.state != .ready)
                return Error.InvalidState;
            var candidate_sink = self.sink;
            const semantic_result = try candidate_sink.apply(input);
            if (semantic_result.disposition == .replayed) {
                return .{
                    .disposition = .replayed,
                    .acknowledgement = semantic_result.acknowledgement,
                    .ledger_sha256 = self.selector.ledger_sha256,
                    .selector_sha256 = self.selector.selector_sha256,
                };
            }

            const ledger = try encodeLedgerV1(
                candidate_sink.request_sha256,
                candidate_sink.request_epoch,
                candidate_sink.initial_sequence,
                candidate_sink.sink_implementation_sha256,
                candidate_sink.sink_instance_sha256,
                candidate_sink.acknowledgementSlice(),
                ledger_storage,
            );
            const prepared_selector =
                try prepareSuccessorSelectorV1(
                    self.selector,
                    ledger,
                );
            self.state = .publishing;
            errdefer self.state = .poisoned;
            try self.ioView().publishLedgerV1(ledger);
            try self.ioView().publishSelectorV1(prepared_selector);

            const loaded = try loadActiveV1(
                self.directory,
                ledger_storage,
                try ledgerBytesForCountV1(capacity),
            );
            if (!digestEqual(
                loaded.selector.selector_sha256,
                prepared_selector.selector_sha256,
            ) or !digestEqual(
                loaded.ledger.ledger_sha256,
                ledger.ledger_sha256,
            ))
                return Error.PublicationMismatch;
            self.sink = candidate_sink;
            self.selector = loaded.selector;
            self.state = .ready;
            return .{
                .disposition = .applied,
                .acknowledgement = semantic_result.acknowledgement,
                .ledger_sha256 = ledger.ledger_sha256,
                .selector_sha256 = prepared_selector.selector_sha256,
            };
        }

        pub fn applyCommitReceipt(
            self: *Self,
            request_sha256: Digest,
            receipt: @import("lane_publication_txn.zig").CommitReceiptV1,
            ledger_storage: []u8,
        ) !DurableApplyReceiptV1 {
            return self.apply(
                try result_sink.deliveryInputFromCommitReceiptV1(
                    request_sha256,
                    receipt,
                ),
                ledger_storage,
            );
        }

        pub fn close(self: *Self) void {
            if (self.state == .closed) return;
            if (self.state == .publishing)
                @panic("cannot close result sink during publication");
            self.state = .closed;
            self.lock.close();
        }

        fn ioView(self: *Self) StoreIoViewV1 {
            return .{
                .directory = self.directory,
                .lock = &self.lock,
                .observer = self.observer,
            };
        }
    };
}

const ValidatedRuntimePublicationV1 = struct {
    ledger: PreparedLedgerV1,
    selector: PreparedSelectorV1,
};

const RuntimeStorageIdentityV1 = struct {
    semantic_state_address: usize,
    lock_address: usize,
    lock_length: usize,
    acknowledgement_address: usize,
    acknowledgement_capacity: usize,
    ledger_address: usize,
    ledger_length: usize,
};

/// Durable result sink whose acknowledgement capacity is selected by caller
/// storage at runtime. The capacity may be zero and is capped at 63.
pub const RuntimeResultSinkFileV1 = struct {
    const Self = @This();

    pub const EmptyInitializationResultV1 = struct {
        store: Self,
        disposition: EmptyInitializationDispositionV1,
    };

    /// Borrowed from `lock`'s owned durable-directory authority. Never close
    /// this alias directly or retain it after `close`.
    directory: std.fs.Dir,
    lock: sweep_file.FileLeaseV1,
    sink: result_sink.RuntimeResultSinkV1,
    selector: DecodedSelectorV1,
    ledger_storage: []u8,
    storage_identity: RuntimeStorageIdentityV1,
    observer: ?PhaseObserverV1,
    state: StoreStateV1 = .ready,

    pub fn create(
        directory: std.fs.Dir,
        storage_epoch: u64,
        request_sha256: Digest,
        request_epoch: u64,
        initial_sequence: u64,
        sink_implementation_sha256: Digest,
        sink_instance_sha256: Digest,
        storage: RuntimeResultSinkFileStorageV1,
        observer: ?PhaseObserverV1,
    ) !Self {
        if (comptime !platform_capabilities
            .current_adapter_availability_v1
            .posix_durable_file_adapter)
            return Error.UnsupportedPlatform;
        _ = try validateRuntimeStorageV1(storage);
        const initial_state = try makeRuntimeInitialStateV1(
            storage,
            request_sha256,
            request_epoch,
            initial_sequence,
            sink_implementation_sha256,
            sink_instance_sha256,
        );
        const ledger = try encodeLedgerV1(
            request_sha256,
            request_epoch,
            initial_sequence,
            sink_implementation_sha256,
            sink_instance_sha256,
            &.{},
            storage.ledger,
        );
        const selector = try prepareInitialSelectorV1(ledger);
        const decoded_selector =
            try decodeSelectorV1(&selector.bytes);

        var lock = try sweep_file.FileLeaseV1.create(
            directory,
            lock_name,
            .{
                .storage_epoch = storage_epoch,
                .max_bytes = lease_capacity_bytes,
            },
            storage.lock,
        );
        errdefer lock.close();
        const durable_directory = lock.directory;
        try (StoreIoViewV1{
            .directory = durable_directory,
            .lock = &lock,
            .observer = observer,
        }).publishFreshSelectionV1(ledger, selector);

        storage.semantic_state.* = initial_state;
        return .{
            .directory = durable_directory,
            .lock = lock,
            .sink = .{ .state = storage.semantic_state },
            .selector = decoded_selector,
            .ledger_storage = storage.ledger,
            .storage_identity = runtimeStorageIdentityV1(storage),
            .observer = observer,
        };
    }

    /// Creates or completes the exact canonical empty selection without
    /// replacing a raced namespace authority.
    pub fn createOrRecoverEmpty(
        directory: std.fs.Dir,
        storage_epoch: u64,
        request_sha256: Digest,
        request_epoch: u64,
        initial_sequence: u64,
        sink_implementation_sha256: Digest,
        sink_instance_sha256: Digest,
        storage: RuntimeResultSinkFileStorageV1,
        observer: ?PhaseObserverV1,
    ) !EmptyInitializationResultV1 {
        if (comptime !initial_recovery_available_v1)
            return Error.UnsupportedPlatform;
        _ = try validateRuntimeStorageV1(storage);
        const initial_state = try makeRuntimeInitialStateV1(
            storage,
            request_sha256,
            request_epoch,
            initial_sequence,
            sink_implementation_sha256,
            sink_instance_sha256,
        );
        const ledger = try encodeLedgerV1(
            request_sha256,
            request_epoch,
            initial_sequence,
            sink_implementation_sha256,
            sink_instance_sha256,
            &.{},
            storage.ledger,
        );
        const prepared_selector =
            try prepareInitialSelectorV1(ledger);
        const decoded_selector =
            try decodeSelectorV1(&prepared_selector.bytes);

        var ledger_name_storage: [
            max_generated_name_bytes
        ]u8 = undefined;
        const ledger_name = try ledgerNameV1(
            ledger.ledger_sha256,
            &ledger_name_storage,
        );
        var ledger_candidate_name_storage: [
            max_generated_name_bytes
        ]u8 = undefined;
        const ledger_candidate_name =
            try ledgerCandidateNameV1(
                ledger.ledger_sha256,
                &ledger_candidate_name_storage,
            );
        var selector_candidate_name_storage: [
            max_generated_name_bytes
        ]u8 = undefined;
        const selector_candidate_name =
            try selectorCandidateNameV1(
                prepared_selector.selector_sha256,
                &selector_candidate_name_storage,
            );
        const namespace: EmptyInitializationNamespaceV1 = .{
            .ledger_name = ledger_name,
            .ledger_candidate_name = ledger_candidate_name,
            .selector_candidate_name = selector_candidate_name,
            .ledger = ledger.bytes,
            .selector = &prepared_selector.bytes,
        };

        const acquired = try acquireEmptyLockV1(
            directory,
            storage_epoch,
            storage.lock,
        );
        var lock = acquired.lock;
        errdefer lock.close();
        const durable_directory = lock.directory;
        const io: StoreIoViewV1 = .{
            .directory = durable_directory,
            .lock = &lock,
            .observer = observer,
        };

        if (try exactFileExistsV1(
            durable_directory,
            active_selector_name,
            &prepared_selector.bytes,
        )) {
            try verifySelectedEmptyV1(
                durable_directory,
                ledger,
                prepared_selector,
            );
            _ = try inspectEmptyInitializationNamespaceV1(
                durable_directory,
                true,
                namespace,
            );
            storage.semantic_state.* = initial_state;
            return .{
                .store = .{
                    .directory = durable_directory,
                    .lock = lock,
                    .sink = .{ .state = storage.semantic_state },
                    .selector = decoded_selector,
                    .ledger_storage = storage.ledger,
                    .storage_identity = runtimeStorageIdentityV1(storage),
                    .observer = observer,
                },
                .disposition = .already_selected,
            };
        }

        const evidence =
            try inspectEmptyInitializationNamespaceV1(
                durable_directory,
                false,
                namespace,
            );
        try io.publishInitialLedgerV1(ledger, namespace);
        const ledger_boundary =
            try inspectEmptyInitializationNamespaceV1(
                durable_directory,
                false,
                namespace,
            );
        if (!ledger_boundary.immutable_ledger or
            ledger_boundary.ledger_candidate or
            ledger_boundary.selector_candidate !=
                evidence.selector_candidate)
            return Error.StorageIdentityChanged;
        try io.publishInitialSelectorV1(
            prepared_selector,
            namespace,
        );
        try verifySelectedEmptyV1(
            durable_directory,
            ledger,
            prepared_selector,
        );
        try auditEmptyInitializationPhaseV1(
            durable_directory,
            namespace,
            .{
                .active_selected = true,
                .immutable_ledger = true,
            },
        );

        storage.semantic_state.* = initial_state;
        return .{
            .store = .{
                .directory = durable_directory,
                .lock = lock,
                .sink = .{ .state = storage.semantic_state },
                .selector = decoded_selector,
                .ledger_storage = storage.ledger,
                .storage_identity = runtimeStorageIdentityV1(storage),
                .observer = observer,
            },
            .disposition = if (acquired.created and
                !evidence.any())
                .created
            else
                .recovered,
        };
    }

    /// Opens and fully validates the selected ledger before writing any
    /// acknowledgement or semantic-state storage.
    pub fn open(
        directory: std.fs.Dir,
        storage_epoch: u64,
        request_sha256: Digest,
        request_epoch: u64,
        initial_sequence: u64,
        sink_implementation_sha256: Digest,
        sink_instance_sha256: Digest,
        storage: RuntimeResultSinkFileStorageV1,
        observer: ?PhaseObserverV1,
    ) !Self {
        if (comptime !platform_capabilities
            .current_adapter_availability_v1
            .posix_durable_file_adapter)
            return Error.UnsupportedPlatform;
        const maximum_ledger_bytes =
            try validateRuntimeStorageV1(storage);

        var lock = try sweep_file.FileLeaseV1.open(
            directory,
            lock_name,
            .{
                .storage_epoch = storage_epoch,
                .max_bytes = lease_capacity_bytes,
            },
            storage.lock,
        );
        errdefer lock.close();
        if (lock.stream().len != 0)
            return Error.StorageContentChanged;
        const durable_directory = lock.directory;
        const loaded = try loadActiveV1(
            durable_directory,
            storage.ledger,
            maximum_ledger_bytes,
        );
        try validateExpectedIdentityV1(
            loaded.selector,
            request_sha256,
            request_epoch,
            initial_sequence,
            sink_implementation_sha256,
            sink_instance_sha256,
        );
        if (loaded.ledger.acknowledgement_count >
            storage.acknowledgements.len)
            return Error.CapacityExceeded;

        installValidatedRuntimeLedgerV1(storage, loaded.ledger);
        return .{
            .directory = durable_directory,
            .lock = lock,
            .sink = .{ .state = storage.semantic_state },
            .selector = loaded.selector,
            .ledger_storage = storage.ledger,
            .storage_identity = runtimeStorageIdentityV1(storage),
            .observer = observer,
        };
    }

    /// Prepares the exact semantic result and durable candidate without I/O
    /// or live acknowledgement mutation.
    pub fn prepareApply(
        self: *Self,
        input: result_sink.DeliveryInputV1,
    ) !RuntimePreparedApplyV1 {
        if (self.state != .ready)
            return Error.InvalidState;
        _ = try validateRetainedRuntimeStorageV1(self);
        const semantic = try self.sink.prepareApply(input);
        if (semantic.disposition == .replayed) {
            return .{
                .input = input,
                .semantic = semantic,
                .acknowledgement_count = self.selector.acknowledgement_count,
                .ledger_sha256 = self.selector.ledger_sha256,
                .selector_sha256 = self.selector.selector_sha256,
                .ledger = null,
                .selector = null,
            };
        }

        const semantic_state = self.sink.state;
        const acknowledgement_count = std.math.add(
            usize,
            self.selector.acknowledgement_count,
            1,
        ) catch return Error.ArithmeticOverflow;
        const ledger = try encodeLedgerPartsV1(
            semantic_state.request_sha256,
            semantic_state.request_epoch,
            semantic_state.initial_sequence,
            semantic_state.sink_implementation_sha256,
            semantic_state.sink_instance_sha256,
            self.sink.acknowledgementSlice(),
            semantic.acknowledgement,
            self.ledger_storage,
        );
        const selector = try prepareSuccessorSelectorV1(
            self.selector,
            ledger,
        );
        return .{
            .input = input,
            .semantic = semantic,
            .acknowledgement_count = acknowledgement_count,
            .ledger_sha256 = ledger.ledger_sha256,
            .selector_sha256 = selector.selector_sha256,
            .ledger = ledger,
            .selector = selector,
        };
    }

    /// Revalidates and publishes one exact value returned by `prepareApply`.
    /// Stale or mutated preparations fail before any durable I/O and leave
    /// the live semantic state ready and unchanged.
    pub fn applyPrepared(
        self: *Self,
        prepared: RuntimePreparedApplyV1,
    ) !DurableApplyReceiptV1 {
        if (self.state != .ready)
            return Error.InvalidState;
        _ = try validateRetainedRuntimeStorageV1(self);
        const publication =
            try self.validatePreparedApply(prepared);
        if (publication == null) {
            try self.sink.commitPrepared(prepared.semantic);
            return prepared.receipt();
        }
        const candidate = publication.?;
        const maximum_ledger_bytes =
            try ledgerBytesForCountV1(
                self.sink.state.acknowledgements.len,
            );

        self.state = .publishing;
        errdefer self.state = .poisoned;
        try self.ioView().publishLedgerV1(candidate.ledger);
        try self.ioView().publishSelectorV1(candidate.selector);
        const loaded = try loadActiveV1(
            self.directory,
            self.ledger_storage,
            maximum_ledger_bytes,
        );
        if (!digestEqual(
            loaded.selector.selector_sha256,
            candidate.selector.selector_sha256,
        ) or !digestEqual(
            loaded.ledger.ledger_sha256,
            candidate.ledger.ledger_sha256,
        ))
            return Error.PublicationMismatch;

        self.sink.commitPreparedAssumeValid(prepared.semantic);
        self.selector = loaded.selector;
        self.state = .ready;
        return prepared.receipt();
    }

    pub fn apply(
        self: *Self,
        input: result_sink.DeliveryInputV1,
    ) !DurableApplyReceiptV1 {
        return self.applyPrepared(
            try self.prepareApply(input),
        );
    }

    pub fn applyCommitReceipt(
        self: *Self,
        request_sha256: Digest,
        receipt: @import("lane_publication_txn.zig").CommitReceiptV1,
    ) !DurableApplyReceiptV1 {
        return self.apply(
            try result_sink.deliveryInputFromCommitReceiptV1(
                request_sha256,
                receipt,
            ),
        );
    }

    pub fn close(self: *Self) void {
        if (self.state == .closed) return;
        if (self.state == .publishing)
            @panic("cannot close result sink during publication");
        self.state = .closed;
        self.lock.close();
    }

    fn validatePreparedApply(
        self: *const Self,
        prepared: RuntimePreparedApplyV1,
    ) !?ValidatedRuntimePublicationV1 {
        const current = self.sink.prepareApply(
            prepared.input,
        ) catch return Error.StalePreparation;
        if (!std.meta.eql(current, prepared.semantic))
            return Error.StalePreparation;

        if (current.disposition == .replayed) {
            if (prepared.ledger != null or
                prepared.selector != null or
                prepared.acknowledgement_count !=
                    self.selector.acknowledgement_count or
                !digestEqual(
                    prepared.ledger_sha256,
                    self.selector.ledger_sha256,
                ) or !digestEqual(
                prepared.selector_sha256,
                self.selector.selector_sha256,
            ))
                return Error.StalePreparation;
            return null;
        }

        const candidate_ledger =
            prepared.ledger orelse
            return Error.StalePreparation;
        const expected_count = std.math.add(
            usize,
            self.sink.appliedCount(),
            1,
        ) catch return Error.StalePreparation;
        const expected_next_sequence = std.math.add(
            u64,
            self.sink.state.next_sequence,
            1,
        ) catch return Error.StalePreparation;
        const retained_bytes = try ledgerBytesForCountV1(
            expected_count,
        );
        if (@intFromPtr(candidate_ledger.bytes.ptr) !=
            @intFromPtr(self.ledger_storage.ptr) or
            candidate_ledger.bytes.len != retained_bytes)
            return Error.StalePreparation;
        const decoded = decodeLedgerV1(
            candidate_ledger.bytes,
        ) catch return Error.StalePreparation;
        const semantic_state = self.sink.state;
        if (decoded.acknowledgement_count !=
            expected_count or
            decoded.initial_sequence !=
                semantic_state.initial_sequence or
            decoded.next_sequence !=
                expected_next_sequence or
            decoded.request_epoch !=
                semantic_state.request_epoch or
            !digestEqual(
                decoded.request_sha256,
                semantic_state.request_sha256,
            ) or !digestEqual(
            decoded.sink_implementation_sha256,
            semantic_state.sink_implementation_sha256,
        ) or !digestEqual(
            decoded.sink_instance_sha256,
            semantic_state.sink_instance_sha256,
        ) or !digestEqual(
            decoded.ledger_sha256,
            candidate_ledger.ledger_sha256,
        ))
            return Error.StalePreparation;
        for (
            self.sink.acknowledgementSlice(),
            0..,
        ) |acknowledgement, index| {
            const decoded_acknowledgement =
                decoded.acknowledgement(index) catch
                    return Error.StalePreparation;
            if (!std.meta.eql(
                acknowledgement,
                decoded_acknowledgement,
            ))
                return Error.StalePreparation;
        }
        const decoded_tail = decoded.acknowledgement(
            self.sink.appliedCount(),
        ) catch return Error.StalePreparation;
        if (!std.meta.eql(
            decoded_tail,
            current.acknowledgement,
        ))
            return Error.StalePreparation;

        const recomputed_selector =
            prepareSuccessorSelectorV1(
                self.selector,
                candidate_ledger,
            ) catch return Error.StalePreparation;
        const candidate_selector =
            prepared.selector orelse
            return Error.StalePreparation;
        if (!std.meta.eql(
            recomputed_selector,
            candidate_selector,
        ) or prepared.acknowledgement_count !=
            decoded.acknowledgement_count or
            !digestEqual(
                prepared.ledger_sha256,
                candidate_ledger.ledger_sha256,
            ) or !digestEqual(
            prepared.selector_sha256,
            recomputed_selector.selector_sha256,
        ))
            return Error.StalePreparation;
        return .{
            .ledger = candidate_ledger,
            .selector = recomputed_selector,
        };
    }

    fn ioView(self: *Self) StoreIoViewV1 {
        return .{
            .directory = self.directory,
            .lock = &self.lock,
            .observer = self.observer,
        };
    }
};

fn runtimeStorageIdentityV1(
    storage: RuntimeResultSinkFileStorageV1,
) RuntimeStorageIdentityV1 {
    return .{
        .semantic_state_address = @intFromPtr(storage.semantic_state),
        .lock_address = @intFromPtr(storage.lock.ptr),
        .lock_length = storage.lock.len,
        .acknowledgement_address = @intFromPtr(storage.acknowledgements.ptr),
        .acknowledgement_capacity = storage.acknowledgements.len,
        .ledger_address = @intFromPtr(storage.ledger.ptr),
        .ledger_length = storage.ledger.len,
    };
}

fn validateRetainedRuntimeStorageV1(
    store: *const RuntimeResultSinkFileV1,
) Error!usize {
    const storage: RuntimeResultSinkFileStorageV1 = .{
        .semantic_state = store.sink.state,
        .lock = store.lock.stream_storage,
        .acknowledgements = store.sink.state.acknowledgements,
        .ledger = store.ledger_storage,
    };
    if (!std.meta.eql(
        runtimeStorageIdentityV1(storage),
        store.storage_identity,
    ))
        return Error.StorageIdentityChanged;
    if (store.lock.stream().len != 0)
        return Error.StorageContentChanged;
    return validateRuntimeStorageV1(storage);
}

fn validateRuntimeStorageV1(
    storage: RuntimeResultSinkFileStorageV1,
) Error!usize {
    if (storage.acknowledgements.len >
        runtime_result_sink_max_capacity_v1)
        return Error.CapacityExceeded;
    const maximum_ledger_bytes = try ledgerBytesForCountV1(
        storage.acknowledgements.len,
    );
    if (storage.lock.len <
        runtime_result_sink_lock_bytes_v1 or
        storage.ledger.len < maximum_ledger_bytes)
        return Error.BufferTooSmall;

    const regions = [_][]const u8{
        std.mem.asBytes(storage.semantic_state),
        storage.lock,
        std.mem.sliceAsBytes(storage.acknowledgements),
        storage.ledger,
    };
    for (regions, 0..) |left, index| {
        for (regions[index + 1 ..]) |right| {
            if (slicesOverlapV1(left, right))
                return Error.InvalidStorage;
        }
    }
    return maximum_ledger_bytes;
}

fn makeRuntimeInitialStateV1(
    storage: RuntimeResultSinkFileStorageV1,
    request_sha256: Digest,
    request_epoch: u64,
    initial_sequence: u64,
    sink_implementation_sha256: Digest,
    sink_instance_sha256: Digest,
) result_sink.Error!result_sink.RuntimeResultSinkStateV1 {
    var initial_state: result_sink.RuntimeResultSinkStateV1 =
        undefined;
    _ = try result_sink.RuntimeResultSinkV1.init(
        &initial_state,
        request_sha256,
        request_epoch,
        initial_sequence,
        sink_implementation_sha256,
        sink_instance_sha256,
        storage.acknowledgements,
    );
    return initial_state;
}

/// `decodeLedgerV1` has already validated every acknowledgement, so this
/// installation has no remaining failure path after its first caller write.
fn installValidatedRuntimeLedgerV1(
    storage: RuntimeResultSinkFileStorageV1,
    ledger: DecodedLedgerV1,
) void {
    for (0..ledger.acknowledgement_count) |index| {
        storage.acknowledgements[index] =
            ledger.acknowledgement(index) catch unreachable;
    }
    storage.semantic_state.* = .{
        .request_sha256 = ledger.request_sha256,
        .request_epoch = ledger.request_epoch,
        .initial_sequence = ledger.initial_sequence,
        .next_sequence = ledger.next_sequence,
        .sink_implementation_sha256 = ledger.sink_implementation_sha256,
        .sink_instance_sha256 = ledger.sink_instance_sha256,
        .acknowledgements = storage.acknowledgements,
        .applied_count = ledger.acknowledgement_count,
    };
}

const SnapshotReadObserverV1 = struct {
    context: *anyopaque,
    before_selector_recheck_fn: *const fn (
        context: *anyopaque,
    ) Error!void,

    fn beforeSelectorRecheck(
        self: SnapshotReadObserverV1,
    ) Error!void {
        try self.before_selector_recheck_fn(self.context);
    }
};

fn readSelectedSnapshotObservedV1(
    directory: std.fs.Dir,
    selector_storage: *[selector_bytes]u8,
    ledger_storage: []u8,
    maximum_acknowledgements: usize,
    observer: ?SnapshotReadObserverV1,
) !SelectedSnapshotV1 {
    if (slicesOverlapV1(selector_storage, ledger_storage))
        return Error.InvalidStorage;
    const selector = try readActiveSelectorReadOnlyV1(
        directory,
        selector_storage,
    );
    if (selector.acknowledgement_count >
        maximum_acknowledgements)
        return Error.CapacityExceeded;
    if (ledger_storage.len < selector.ledger_bytes)
        return Error.BufferTooSmall;

    var ledger_name_storage: [max_generated_name_bytes]u8 =
        undefined;
    const ledger_name = try ledgerNameV1(
        selector.ledger_sha256,
        &ledger_name_storage,
    );
    const ledger_wire = try readStableExactReadOnlyFileV1(
        directory,
        ledger_name,
        ledger_storage,
        selector.ledger_bytes,
    );
    const ledger = try decodeLedgerV1(ledger_wire);
    try validateSelectedPairV1(selector, ledger);

    if (observer) |active| try active.beforeSelectorRecheck();
    var recheck_storage: [selector_bytes]u8 = undefined;
    _ = readActiveSelectorReadOnlyV1(
        directory,
        &recheck_storage,
    ) catch return Error.SelectionChanged;
    if (!std.mem.eql(
        u8,
        selector_storage,
        &recheck_storage,
    ))
        return Error.SelectionChanged;
    return .{ .selector = selector, .ledger = ledger };
}

const LoadedActiveV1 = struct {
    ledger: DecodedLedgerV1,
    selector: DecodedSelectorV1,
};

fn loadActiveV1(
    directory: std.fs.Dir,
    ledger_storage: []u8,
    maximum_ledger_bytes: usize,
) !LoadedActiveV1 {
    var selector_storage: [selector_bytes]u8 = undefined;
    const selector_wire = try readExactFileV1(
        directory,
        active_selector_name,
        &selector_storage,
        selector_bytes,
    );
    const selector = try decodeSelectorV1(selector_wire);
    if (selector.ledger_bytes > maximum_ledger_bytes)
        return Error.CapacityExceeded;
    var ledger_name_storage: [max_generated_name_bytes]u8 = undefined;
    const ledger_name = try ledgerNameV1(
        selector.ledger_sha256,
        &ledger_name_storage,
    );
    const ledger_wire = try readExactFileV1(
        directory,
        ledger_name,
        ledger_storage,
        maximum_ledger_bytes,
    );
    const ledger = try decodeLedgerV1(ledger_wire);
    try validateSelectedPairV1(selector, ledger);
    return .{ .ledger = ledger, .selector = selector };
}

fn validateExpectedIdentityV1(
    selector: DecodedSelectorV1,
    request_sha256: Digest,
    request_epoch: u64,
    initial_sequence: u64,
    sink_implementation_sha256: Digest,
    sink_instance_sha256: Digest,
) Error!void {
    if (selector.request_epoch != request_epoch or
        selector.initial_sequence != initial_sequence or
        !digestEqual(selector.request_sha256, request_sha256) or
        !digestEqual(
            selector.sink_implementation_sha256,
            sink_implementation_sha256,
        ) or !digestEqual(
        selector.sink_instance_sha256,
        sink_instance_sha256,
    ))
        return Error.PublicationMismatch;
}

fn encodeSelectorV1(
    generation: u64,
    previous_selector_sha256: Digest,
    ledger: DecodedLedgerV1,
) Error!PreparedSelectorV1 {
    const expected_generation = std.math.add(
        u64,
        @as(u64, @intCast(ledger.acknowledgement_count)),
        1,
    ) catch return Error.ArithmeticOverflow;
    if (generation == 0 or
        generation != expected_generation or
        (generation == 1 and !isZero(previous_selector_sha256)) or
        (generation > 1 and isZero(previous_selector_sha256)))
        return Error.InvalidSelector;
    var output = [_]u8{0} ** selector_bytes;
    @memcpy(output[0..8], &selector_magic);
    writeU64(&output, 8, selector_abi);
    writeU64(&output, 16, selector_bytes);
    writeU64(&output, 24, allowed_flags);
    writeU64(&output, 32, generation);
    writeU64(
        &output,
        40,
        ledger.acknowledgement_count,
    );
    writeU64(&output, 48, ledger.initial_sequence);
    writeU64(&output, 56, ledger.next_sequence);
    writeU64(&output, 64, ledger.request_epoch);
    writeU64(&output, 72, ledger.encoded.len);
    @memcpy(output[80..112], &ledger.request_sha256);
    @memcpy(
        output[112..144],
        &ledger.sink_implementation_sha256,
    );
    @memcpy(output[144..176], &ledger.sink_instance_sha256);
    @memcpy(output[176..208], &previous_selector_sha256);
    @memcpy(output[208..240], &ledger.ledger_sha256);
    const root = selectorRootV1(output[0..selector_body_bytes]);
    @memcpy(output[selector_body_bytes..], &root);
    _ = try decodeSelectorV1(&output);
    return .{ .bytes = output, .selector_sha256 = root };
}

fn ledgerNameV1(
    ledger_sha256: Digest,
    storage: []u8,
) ![]const u8 {
    const hex = std.fmt.bytesToHex(ledger_sha256, .lower);
    return std.fmt.bufPrint(
        storage,
        "prepared-text-result-ledger-{s}.bin",
        .{&hex},
    );
}

fn ledgerCandidateNameV1(
    ledger_sha256: Digest,
    storage: []u8,
) ![]const u8 {
    const hex = std.fmt.bytesToHex(ledger_sha256, .lower);
    return std.fmt.bufPrint(
        storage,
        ".prepared-text-result-ledger-{s}.tmp",
        .{&hex},
    );
}

fn selectorCandidateNameV1(
    selector_sha256: Digest,
    storage: []u8,
) ![]const u8 {
    const hex = std.fmt.bytesToHex(selector_sha256, .lower);
    return std.fmt.bufPrint(
        storage,
        ".prepared-text-result-selector-{s}.tmp",
        .{&hex},
    );
}

const AcquiredEmptyLockV1 = struct {
    lock: sweep_file.FileLeaseV1,
    created: bool,
};

fn acquireEmptyLockV1(
    directory: std.fs.Dir,
    storage_epoch: u64,
    lock_storage: []u8,
) !AcquiredEmptyLockV1 {
    var created = true;
    var lock = sweep_file.FileLeaseV1.create(
        directory,
        lock_name,
        .{
            .storage_epoch = storage_epoch,
            .max_bytes = lease_capacity_bytes,
        },
        lock_storage,
    ) catch |err| switch (err) {
        error.PathAlreadyExists => existing: {
            created = false;
            break :existing try sweep_file.FileLeaseV1.open(
                directory,
                lock_name,
                .{
                    .storage_epoch = storage_epoch,
                    .max_bytes = lease_capacity_bytes,
                },
                lock_storage,
            );
        },
        else => return err,
    };
    errdefer lock.close();
    if (lock.stream().len != 0)
        return Error.StorageContentChanged;
    return .{ .lock = lock, .created = created };
}

const EmptyInitializationEvidenceV1 = struct {
    immutable_ledger: bool,
    ledger_candidate: bool,
    selector_candidate: bool,

    fn any(self: EmptyInitializationEvidenceV1) bool {
        return self.immutable_ledger or
            self.ledger_candidate or
            self.selector_candidate;
    }
};

const EmptyInitializationNamespaceV1 = struct {
    ledger_name: []const u8,
    ledger_candidate_name: []const u8,
    selector_candidate_name: []const u8,
    ledger: []const u8,
    selector: []const u8,
};

const EmptyInitializationPhaseV1 = struct {
    active_selected: bool,
    immutable_ledger: bool,
    ledger_candidate: ?[]const u8 = null,
    selector_candidate: ?[]const u8 = null,
};

fn inspectEmptyInitializationNamespaceV1(
    directory: std.fs.Dir,
    active_selected: bool,
    namespace: EmptyInitializationNamespaceV1,
) !EmptyInitializationEvidenceV1 {
    var saw_ledger = false;
    var saw_ledger_candidate = false;
    var saw_selector_candidate = false;
    var saw_active = false;
    var scan_directory = try directory.openDir(".", .{
        .iterate = true,
        .no_follow = true,
    });
    defer scan_directory.close();
    var iterator = scan_directory.iterate();
    while (try iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.name, lock_name))
            continue;
        if (std.mem.eql(
            u8,
            entry.name,
            active_selector_name,
        )) {
            if (!active_selected)
                return Error.StorageIdentityChanged;
            saw_active = true;
            continue;
        }
        if (std.mem.eql(
            u8,
            entry.name,
            namespace.ledger_name,
        )) {
            saw_ledger = true;
            continue;
        }
        if (std.mem.eql(
            u8,
            entry.name,
            namespace.ledger_candidate_name,
        )) {
            saw_ledger_candidate = true;
            continue;
        }
        if (std.mem.eql(
            u8,
            entry.name,
            namespace.selector_candidate_name,
        )) {
            saw_selector_candidate = true;
            continue;
        }
        if (isReservedResultSinkArtifactNameV1(entry.name))
            return Error.InvalidStorage;
    }

    const immutable_ledger = try exactFileExistsV1(
        directory,
        namespace.ledger_name,
        namespace.ledger,
    );
    const ledger_candidate =
        try recoverableCandidateExistsV1(
            directory,
            namespace.ledger_candidate_name,
            namespace.ledger,
        );
    const selector_candidate =
        try recoverableCandidateExistsV1(
            directory,
            namespace.selector_candidate_name,
            namespace.selector,
        );
    const active_exists = try exactFileExistsV1(
        directory,
        active_selector_name,
        namespace.selector,
    );
    if (saw_active != active_exists or
        active_selected != active_exists or
        saw_ledger != immutable_ledger or
        saw_ledger_candidate != ledger_candidate or
        saw_selector_candidate != selector_candidate)
        return Error.StorageIdentityChanged;
    if ((active_selected and
        (!immutable_ledger or
            ledger_candidate or
            selector_candidate)) or
        (!active_selected and
            ledger_candidate and
            (immutable_ledger or selector_candidate)) or
        (!active_selected and
            selector_candidate and
            !immutable_ledger))
        return Error.InvalidStorage;
    return .{
        .immutable_ledger = immutable_ledger,
        .ledger_candidate = ledger_candidate,
        .selector_candidate = selector_candidate,
    };
}

fn auditEmptyInitializationPhaseV1(
    directory: std.fs.Dir,
    namespace: EmptyInitializationNamespaceV1,
    expected: EmptyInitializationPhaseV1,
) !void {
    const evidence = try inspectEmptyInitializationNamespaceV1(
        directory,
        expected.active_selected,
        namespace,
    );
    const expects_ledger_candidate =
        expected.ledger_candidate != null;
    const expects_selector_candidate =
        expected.selector_candidate != null;
    if (evidence.immutable_ledger != expected.immutable_ledger or
        evidence.ledger_candidate != expects_ledger_candidate or
        evidence.selector_candidate != expects_selector_candidate)
        return Error.StorageIdentityChanged;
    if (expected.ledger_candidate) |bytes| {
        if (!try exactFileExistsV1(
            directory,
            namespace.ledger_candidate_name,
            bytes,
        ))
            return Error.StorageIdentityChanged;
    }
    if (expected.selector_candidate) |bytes| {
        if (!try exactFileExistsV1(
            directory,
            namespace.selector_candidate_name,
            bytes,
        ))
            return Error.StorageIdentityChanged;
    }
}

fn isReservedResultSinkArtifactNameV1(name: []const u8) bool {
    return std.mem.startsWith(
        u8,
        name,
        "prepared-text-result-ledger-",
    ) or std.mem.startsWith(
        u8,
        name,
        ".prepared-text-result-ledger-",
    ) or std.mem.startsWith(
        u8,
        name,
        ".prepared-text-result-selector-",
    );
}

fn recoverableCandidateExistsV1(
    directory: std.fs.Dir,
    name: []const u8,
    expected: []const u8,
) !bool {
    const file = openSafeFileV1(
        directory,
        name,
        .existing,
    ) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close();
    const before = try inspectFileV1(file, directory, name);
    if (before.size > expected.len or
        !try fileContentsEqualV1(
            file,
            expected[0..before.size],
        ))
        return Error.StorageContentChanged;
    const after = try inspectFileV1(file, directory, name);
    if (!std.meta.eql(before, after))
        return Error.StorageIdentityChanged;
    return true;
}

fn verifySelectedEmptyV1(
    directory: std.fs.Dir,
    expected_ledger: PreparedLedgerV1,
    expected_selector: PreparedSelectorV1,
) !void {
    var ledger_storage: [
        ledger_header_bytes + ledger_footer_bytes
    ]u8 = undefined;
    const loaded = try loadActiveV1(
        directory,
        &ledger_storage,
        ledger_storage.len,
    );
    if (loaded.ledger.acknowledgement_count != 0 or
        loaded.selector.generation != 1 or
        !digestEqual(
            loaded.ledger.ledger_sha256,
            expected_ledger.ledger_sha256,
        ) or !digestEqual(
        loaded.selector.selector_sha256,
        expected_selector.selector_sha256,
    ))
        return Error.PublicationMismatch;
}

const OpenKind = enum {
    create,
    existing,
};

fn openSafeFileV1(
    directory: std.fs.Dir,
    name: []const u8,
    kind: OpenKind,
) !std.fs.File {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1
        .posix_durable_file_adapter)
        return Error.UnsupportedPlatform;
    if (!@hasField(std.posix.O, "CLOEXEC") or
        !@hasField(std.posix.O, "NOFOLLOW"))
        return Error.UnsupportedPlatform;
    var flags: std.posix.O = .{ .ACCMODE = .RDWR };
    flags.CLOEXEC = true;
    flags.NOFOLLOW = true;
    if (@hasField(std.posix.O, "NOCTTY")) flags.NOCTTY = true;
    if (kind == .create) {
        flags.CREAT = true;
        flags.EXCL = true;
    }
    const fd = try std.posix.openat(
        directory.fd,
        name,
        flags,
        if (kind == .create) 0o600 else 0,
    );
    return .{ .handle = fd };
}

fn openSafeReadOnlyFileV1(
    directory: std.fs.Dir,
    name: []const u8,
) !std.fs.File {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1
        .posix_durable_file_adapter)
        return Error.UnsupportedPlatform;
    if (!@hasField(std.posix.O, "CLOEXEC") or
        !@hasField(std.posix.O, "NOFOLLOW") or
        !@hasField(std.posix.O, "NONBLOCK"))
        return Error.UnsupportedPlatform;
    var flags: std.posix.O = .{ .ACCMODE = .RDONLY };
    flags.CLOEXEC = true;
    flags.NOFOLLOW = true;
    flags.NONBLOCK = true;
    if (@hasField(std.posix.O, "NOCTTY")) flags.NOCTTY = true;
    const fd = try std.posix.openat(
        directory.fd,
        name,
        flags,
        0,
    );
    return .{ .handle = fd };
}

fn readStableExactReadOnlyFileV1(
    directory: std.fs.Dir,
    name: []const u8,
    storage: []u8,
    expected_bytes: usize,
) ![]const u8 {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1
        .posix_durable_file_adapter)
        return Error.UnsupportedPlatform;
    if (storage.len < expected_bytes)
        return Error.BufferTooSmall;
    const file = try openSafeReadOnlyFileV1(directory, name);
    defer file.close();
    const before = try inspectFileV1(file, directory, name);
    if (before.size != expected_bytes)
        return Error.StorageContentChanged;
    const encoded = storage[0..expected_bytes];
    if (try file.preadAll(encoded, 0) != encoded.len)
        return Error.StorageIo;
    const after = try inspectFileV1(file, directory, name);
    if (!std.meta.eql(before, after))
        return Error.StorageIdentityChanged;
    return encoded;
}

fn slicesOverlapV1(
    left: []const u8,
    right: []const u8,
) bool {
    if (left.len == 0 or right.len == 0)
        return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_end = std.math.add(
        usize,
        left_start,
        left.len,
    ) catch return true;
    const right_end = std.math.add(
        usize,
        right_start,
        right.len,
    ) catch return true;
    return left_start < right_end and
        right_start < left_end;
}

fn createFreshSafeFileV1(
    directory: std.fs.Dir,
    name: []const u8,
) !std.fs.File {
    var collisions: usize = 0;
    while (true) {
        return openSafeFileV1(
            directory,
            name,
            .create,
        ) catch |err| switch (err) {
            error.PathAlreadyExists => {
                if (collisions == 3)
                    return Error.StorageIdentityChanged;
                collisions += 1;
                directory.deleteFile(name) catch |delete_error| switch (delete_error) {
                    error.FileNotFound => {},
                    else => return delete_error,
                };
                continue;
            },
            else => return err,
        };
    }
}

fn writeNewExactFileV1(
    directory: std.fs.Dir,
    name: []const u8,
    bytes: []const u8,
) !void {
    const file = try openSafeFileV1(directory, name, .create);
    defer file.close();
    try file.writeAll(bytes);
    try file.setEndPos(bytes.len);
    try file.sync();
    try verifyExactOpenFileV1(file, directory, name, bytes);
}

fn exactFileExistsV1(
    directory: std.fs.Dir,
    name: []const u8,
    expected: []const u8,
) !bool {
    const file = openSafeFileV1(
        directory,
        name,
        .existing,
    ) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close();
    try verifyExactOpenFileV1(
        file,
        directory,
        name,
        expected,
    );
    return true;
}

/// Atomically moves a candidate into an absent final name. This is used only
/// by recoverable first publication; ordinary successor selectors retain
/// atomic replace semantics.
fn renameNoReplaceV1(
    directory: std.fs.Dir,
    candidate_name: []const u8,
    final_name: []const u8,
) !void {
    const candidate_z = try std.posix.toPosixPath(candidate_name);
    const final_z = try std.posix.toPosixPath(final_name);
    const operation_errno: std.posix.E = switch (builtin.os.tag) {
        .macos, .ios => std.posix.errno(renameatx_np(
            directory.fd,
            &candidate_z,
            directory.fd,
            &final_z,
            0x0000_0004,
        )),
        .linux => linuxSyscallErrnoV1(std.os.linux.renameat2(
            directory.fd,
            &candidate_z,
            directory.fd,
            &final_z,
            0x0000_0001,
        )),
        else => return Error.UnsupportedPlatform,
    };
    switch (operation_errno) {
        .SUCCESS => return,
        .EXIST, .NOTEMPTY => return Error.PublicationMismatch,
        .NOENT => return Error.StorageIdentityChanged,
        .NOSYS => return Error.UnsupportedPlatform,
        else => return Error.StorageIo,
    }
}

fn linuxSyscallErrnoV1(result: usize) std.posix.E {
    const signed: isize = @bitCast(result);
    if (signed >= 0 or signed <= -4096) return .SUCCESS;
    return @enumFromInt(-signed);
}

fn verifyExactOpenFileV1(
    file: std.fs.File,
    directory: std.fs.Dir,
    name: []const u8,
    expected: []const u8,
) !void {
    const before = try inspectFileV1(file, directory, name);
    if (before.size != expected.len or
        !try fileContentsEqualV1(file, expected))
        return Error.StorageContentChanged;
    const after = try inspectFileV1(file, directory, name);
    if (!std.meta.eql(before, after))
        return Error.StorageIdentityChanged;
}

fn verifyPinnedExactFileV1(
    file: std.fs.File,
    directory: std.fs.Dir,
    name: []const u8,
    expected: []const u8,
    initial_view: FileViewV1,
) !void {
    const current = try inspectFileV1(file, directory, name);
    if (current.device != initial_view.device or
        current.inode != initial_view.inode or
        current.size != expected.len or
        !try fileContentsEqualV1(file, expected))
        return Error.StorageIdentityChanged;
    const verified = try inspectFileV1(file, directory, name);
    if (!std.meta.eql(current, verified))
        return Error.StorageIdentityChanged;
}

fn verifyPinnedRepairableFileV1(
    file: std.fs.File,
    directory: std.fs.Dir,
    name: []const u8,
    expected: []const u8,
    initial_view: FileViewV1,
) !void {
    const current = try inspectFileV1(file, directory, name);
    if (current.device != initial_view.device or
        current.inode != initial_view.inode)
        return Error.StorageIdentityChanged;
    if (current.size > expected.len or
        !try fileContentsEqualV1(
            file,
            expected[0..current.size],
        ))
        return Error.StorageContentChanged;
    const verified = try inspectFileV1(file, directory, name);
    if (!std.meta.eql(current, verified))
        return Error.StorageIdentityChanged;
}

fn fileContentsEqualV1(
    file: std.fs.File,
    expected: []const u8,
) !bool {
    var storage: [4096]u8 = undefined;
    var offset: usize = 0;
    while (offset < expected.len) {
        const chunk_bytes = @min(
            storage.len,
            expected.len - offset,
        );
        const chunk = storage[0..chunk_bytes];
        if (try file.preadAll(chunk, offset) != chunk.len or
            !std.mem.eql(
                u8,
                chunk,
                expected[offset .. offset + chunk_bytes],
            ))
            return false;
        offset += chunk_bytes;
    }
    return true;
}

fn readExactFileV1(
    directory: std.fs.Dir,
    name: []const u8,
    storage: []u8,
    maximum_bytes: usize,
) ![]const u8 {
    const file = try openSafeFileV1(directory, name, .existing);
    defer file.close();
    const before = try inspectFileV1(file, directory, name);
    if (before.size > maximum_bytes or before.size > storage.len)
        return Error.BufferTooSmall;
    const encoded = storage[0..before.size];
    if (try file.preadAll(encoded, 0) != encoded.len)
        return Error.StorageIo;
    const after = try inspectFileV1(file, directory, name);
    if (!std.meta.eql(before, after))
        return Error.StorageIdentityChanged;
    return encoded;
}

const FileViewV1 = struct {
    device: u64,
    inode: u64,
    size: usize,
};

fn inspectFileV1(
    file: std.fs.File,
    directory: std.fs.Dir,
    name: []const u8,
) !FileViewV1 {
    const file_stat = try std.posix.fstat(file.handle);
    const entry_stat = try std.posix.fstatat(
        directory.fd,
        name,
        std.posix.AT.SYMLINK_NOFOLLOW,
    );
    const file_view = try inspectStatV1(file_stat);
    const entry_view = try inspectStatV1(entry_stat);
    if (!std.meta.eql(file_view, entry_view))
        return Error.StorageIdentityChanged;
    return file_view;
}

fn inspectStatV1(stat: std.posix.Stat) Error!FileViewV1 {
    if ((stat.mode & std.posix.S.IFMT) != std.posix.S.IFREG)
        return Error.InvalidStorage;
    if (stat.nlink != 1) return Error.MultipleLinks;
    if ((stat.mode & 0o077) != 0) return Error.UnsafePermissions;
    return .{
        .device = std.math.cast(u64, stat.dev) orelse
            return Error.InvalidStorage,
        .inode = std.math.cast(u64, stat.ino) orelse
            return Error.InvalidStorage,
        .size = std.math.cast(usize, stat.size) orelse
            return Error.CapacityExceeded,
    };
}

fn writeU64(output: []u8, offset: usize, value: anytype) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, @intCast(value), .little);
    @memcpy(output[offset .. offset + 8], &encoded);
}

fn readU64(input: []const u8, offset: usize) u64 {
    return std.mem.readInt(
        u64,
        input[offset .. offset + 8][0..8],
        .little,
    );
}

fn finish(hash: *std.crypto.hash.sha2.Sha256) Digest {
    var output: Digest = undefined;
    hash.final(&output);
    return output;
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

fn isZero(value: Digest) bool {
    return std.mem.allEqual(u8, &value, 0);
}

fn testDigest(label: []const u8) Digest {
    var output: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(label, &output, .{});
    return output;
}

fn testInput(
    request_sha256: Digest,
    request_epoch: u64,
    sequence: u64,
    token_id: u32,
) result_sink.DeliveryInputV1 {
    var proposal_label: [64]u8 = undefined;
    const proposal = std.fmt.bufPrint(
        &proposal_label,
        "proposal:{d}",
        .{sequence},
    ) catch unreachable;
    var transition_label: [64]u8 = undefined;
    const transition = std.fmt.bufPrint(
        &transition_label,
        "transition:{d}",
        .{sequence},
    ) catch unreachable;
    var receipt_label: [64]u8 = undefined;
    const receipt = std.fmt.bufPrint(
        &receipt_label,
        "receipt:{d}",
        .{sequence},
    ) catch unreachable;
    return .{
        .request_sha256 = request_sha256,
        .request_epoch = request_epoch,
        .transaction_sequence = sequence,
        .token_id = token_id,
        .proposal_sha256 = testDigest(proposal),
        .transition_sha256 = testDigest(transition),
        .commit_receipt_sha256 = testDigest(receipt),
    };
}

test "ledger and selector encodings are canonical and mutation complete" {
    const request = testDigest("wire request");
    var semantic = try result_sink.ResultSinkV1(2).init(
        request,
        501,
        7,
        testDigest("wire implementation"),
        testDigest("wire instance"),
    );
    _ = try semantic.apply(testInput(request, 501, 7, 91));
    var ledger_storage: [2048]u8 = undefined;
    const ledger = try encodeLedgerV1(
        semantic.request_sha256,
        semantic.request_epoch,
        semantic.initial_sequence,
        semantic.sink_implementation_sha256,
        semantic.sink_instance_sha256,
        semantic.acknowledgementSlice(),
        &ledger_storage,
    );
    const decoded = try decodeLedgerV1(ledger.bytes);
    try std.testing.expectEqual(@as(usize, 1), decoded.acknowledgement_count);
    const selector = try encodeSelectorV1(2, testDigest("previous"), decoded);
    _ = try decodeSelectorV1(&selector.bytes);
    const ledger_hex = std.fmt.bytesToHex(ledger.ledger_sha256, .lower);
    const selector_hex = std.fmt.bytesToHex(
        selector.selector_sha256,
        .lower,
    );
    try std.testing.expectEqualStrings(
        "86afd3be9d7e0da5d15de2da194c8758361eeaa3630a00df4b7e6713584e87a1",
        &ledger_hex,
    );
    try std.testing.expectEqualStrings(
        "ca19dbee6b3562b12d460b12a2f07f9e70a6d0f6bb134d76abcaff532bafac70",
        &selector_hex,
    );

    var corrupted: [2048]u8 = undefined;
    for (0..ledger.bytes.len) |index| {
        @memcpy(corrupted[0..ledger.bytes.len], ledger.bytes);
        corrupted[index] ^= 1;
        const accepted = if (decodeLedgerV1(
            corrupted[0..ledger.bytes.len],
        )) |_| true else |_| false;
        try std.testing.expect(!accepted);
    }
    var selector_corrupted = selector.bytes;
    for (0..selector_corrupted.len) |index| {
        selector_corrupted = selector.bytes;
        selector_corrupted[index] ^= 1;
        const accepted = if (decodeSelectorV1(
            &selector_corrupted,
        )) |_| true else |_| false;
        try std.testing.expect(!accepted);
    }

    var overflowing_selector = selector.bytes;
    writeU64(
        &overflowing_selector,
        32,
        std.math.maxInt(u64),
    );
    writeU64(
        &overflowing_selector,
        40,
        std.math.maxInt(usize),
    );
    writeU64(&overflowing_selector, 48, 0);
    writeU64(
        &overflowing_selector,
        56,
        std.math.maxInt(usize),
    );
    const overflowing_root = selectorRootV1(
        overflowing_selector[0..selector_body_bytes],
    );
    @memcpy(
        overflowing_selector[selector_body_bytes..],
        &overflowing_root,
    );
    try std.testing.expectError(
        Error.InvalidSelector,
        decodeSelectorV1(&overflowing_selector),
    );
}

test "ledger parts encoding matches contiguous prefixes through capacity 63" {
    const maximum_capacity: usize = 63;
    const request = testDigest("ledger parts request");
    var semantic = try result_sink.ResultSinkV1(maximum_capacity).init(
        request,
        511,
        17,
        testDigest("ledger parts implementation"),
        testDigest("ledger parts instance"),
    );
    for (0..maximum_capacity) |index| {
        _ = try semantic.apply(testInput(
            request,
            511,
            17 + @as(u64, @intCast(index)),
            200 + @as(u32, @intCast(index)),
        ));
    }

    const maximum_ledger_bytes = ledger_header_bytes +
        maximum_capacity * result_sink.acknowledgement_bytes +
        ledger_footer_bytes;
    var contiguous_storage: [maximum_ledger_bytes]u8 = undefined;
    var parts_storage: [maximum_ledger_bytes]u8 = undefined;
    const acknowledgements = semantic.acknowledgementSlice();

    var count: usize = 0;
    while (count <= maximum_capacity) : (count += 1) {
        const contiguous = try encodeLedgerV1(
            semantic.request_sha256,
            semantic.request_epoch,
            semantic.initial_sequence,
            semantic.sink_implementation_sha256,
            semantic.sink_instance_sha256,
            acknowledgements[0..count],
            &contiguous_storage,
        );
        const prefix_count = count -| 1;
        const parts = try encodeLedgerPartsV1(
            semantic.request_sha256,
            semantic.request_epoch,
            semantic.initial_sequence,
            semantic.sink_implementation_sha256,
            semantic.sink_instance_sha256,
            acknowledgements[0..prefix_count],
            if (count == 0) null else acknowledgements[count - 1],
            &parts_storage,
        );
        try std.testing.expectEqualSlices(
            u8,
            contiguous.bytes,
            parts.bytes,
        );
        try std.testing.expectEqualSlices(
            u8,
            &contiguous.ledger_sha256,
            &parts.ledger_sha256,
        );
    }

    var aliased_storage: [
        maximum_ledger_bytes
    ]u8 align(@alignOf(
        result_sink.ResultAcknowledgementV1,
    )) = undefined;
    @memset(&aliased_storage, 0xa5);
    const aliased_acknowledgements: *[
        1
    ]result_sink.ResultAcknowledgementV1 = @ptrCast(
        @alignCast(
            aliased_storage[ledger_header_bytes..].ptr,
        ),
    );
    aliased_acknowledgements[0] = acknowledgements[0];
    const retained_aliased_storage = aliased_storage;
    try std.testing.expectError(
        Error.InvalidStorage,
        encodeLedgerPartsV1(
            semantic.request_sha256,
            semantic.request_epoch,
            semantic.initial_sequence,
            semantic.sink_implementation_sha256,
            semantic.sink_instance_sha256,
            aliased_acknowledgements,
            null,
            &aliased_storage,
        ),
    );
    try std.testing.expectEqualSlices(
        u8,
        &retained_aliased_storage,
        &aliased_storage,
    );
}

const InjectObserver = struct {
    phase: IoPhaseV1,
    calls: usize = 0,

    fn after(
        context: *anyopaque,
        phase: IoPhaseV1,
    ) Error!void {
        const self: *InjectObserver = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (phase == self.phase) return Error.InjectedFault;
    }
};

const durable_io_phases_v1 = [_]IoPhaseV1{
    .ledger_body_write,
    .ledger_body_sync,
    .ledger_footer_write,
    .ledger_file_sync,
    .ledger_immutable_rename,
    .ledger_directory_sync,
    .selector_temp_write,
    .selector_temp_sync,
    .selector_replace,
    .selector_directory_sync,
};

const CountObserver = struct {
    calls: usize = 0,

    fn after(
        context: *anyopaque,
        _: IoPhaseV1,
    ) Error!void {
        const self: *CountObserver = @ptrCast(@alignCast(context));
        self.calls += 1;
    }
};

const ReentrantRuntimeObserverV1 = struct {
    store: ?*RuntimeResultSinkFileV1 = null,
    input: result_sink.DeliveryInputV1,
    attempted: bool = false,
    rejected: bool = false,

    fn after(
        context: *anyopaque,
        _: IoPhaseV1,
    ) Error!void {
        const self: *ReentrantRuntimeObserverV1 =
            @ptrCast(@alignCast(context));
        const store = self.store orelse return;
        if (self.attempted) return;
        self.attempted = true;
        _ = store.apply(self.input) catch |err| {
            if (err == Error.InvalidState) {
                self.rejected = true;
                return;
            }
            return Error.PublicationMismatch;
        };
        return Error.PublicationMismatch;
    }
};

fn runtimeTestStorageV1(
    state: *result_sink.RuntimeResultSinkStateV1,
    lock: []u8,
    acknowledgements: []result_sink.ResultAcknowledgementV1,
    ledger: []u8,
) RuntimeResultSinkFileStorageV1 {
    return .{
        .semantic_state = state,
        .lock = lock,
        .acknowledgements = acknowledgements,
        .ledger = ledger,
    };
}

const runtime_test_capacity_v1: usize = 2;
const runtime_test_ledger_bytes_v1 = ledger_header_bytes +
    runtime_test_capacity_v1 *
        result_sink.acknowledgement_bytes +
    ledger_footer_bytes;

const RuntimeTestStorageV1 = struct {
    state: result_sink.RuntimeResultSinkStateV1,
    lock: [runtime_result_sink_lock_bytes_v1]u8,
    acknowledgements: [
        runtime_test_capacity_v1
    ]result_sink.ResultAcknowledgementV1,
    ledger: [
        runtime_test_ledger_bytes_v1
    ]u8 align(@alignOf(
        result_sink.ResultAcknowledgementV1,
    )),

    fn view(
        self: *RuntimeTestStorageV1,
    ) RuntimeResultSinkFileStorageV1 {
        return runtimeTestStorageV1(
            &self.state,
            &self.lock,
            &self.acknowledgements,
            &self.ledger,
        );
    }
};

const RuntimeStorageAliasV1 = enum(u8) {
    state_lock,
    state_acknowledgements,
    state_ledger,
    lock_acknowledgements,
    lock_ledger,
    acknowledgements_ledger,
};

fn expectRuntimeStorageAliasBeforeLeaseV1(
    directory: std.fs.Dir,
    alias: RuntimeStorageAliasV1,
) !void {
    const capacity: usize = 1;
    const maximum_ledger_bytes = ledger_header_bytes +
        capacity * result_sink.acknowledgement_bytes +
        ledger_footer_bytes;
    const backing_alignment: usize = @max(
        @alignOf(result_sink.RuntimeResultSinkStateV1),
        @alignOf(result_sink.ResultAcknowledgementV1),
    );
    const slot_payload_bytes: usize = @max(
        maximum_ledger_bytes,
        @max(
            @sizeOf(result_sink.RuntimeResultSinkStateV1),
            @sizeOf(result_sink.ResultAcknowledgementV1),
        ),
    );
    const slot_bytes = slot_payload_bytes * backing_alignment;
    var backing: [slot_bytes * 4]u8 align(backing_alignment) = undefined;
    @memset(&backing, 0xa5);
    const backing_before = backing;

    const state_slot: usize = 0;
    var lock_slot: usize = 1;
    var acknowledgement_slot: usize = 2;
    var ledger_slot: usize = 3;
    switch (alias) {
        .state_lock => lock_slot = state_slot,
        .state_acknowledgements => acknowledgement_slot = state_slot,
        .state_ledger => ledger_slot = state_slot,
        .lock_acknowledgements => acknowledgement_slot = lock_slot,
        .lock_ledger => ledger_slot = lock_slot,
        .acknowledgements_ledger => ledger_slot = acknowledgement_slot,
    }

    const state_bytes = backing[state_slot * slot_bytes ..];
    const state: *result_sink.RuntimeResultSinkStateV1 =
        @ptrCast(@alignCast(state_bytes.ptr));
    const lock_bytes = backing[lock_slot * slot_bytes ..][0..runtime_result_sink_lock_bytes_v1];
    const acknowledgement_bytes = backing[acknowledgement_slot * slot_bytes ..];
    const acknowledgement_pointer: [*]result_sink.ResultAcknowledgementV1 =
        @ptrCast(@alignCast(acknowledgement_bytes.ptr));
    const acknowledgements =
        acknowledgement_pointer[0..capacity];
    const ledger = backing[ledger_slot * slot_bytes ..][0..maximum_ledger_bytes];

    try std.testing.expectError(
        Error.InvalidStorage,
        RuntimeResultSinkFileV1.create(
            directory,
            @as(u64, 9301) + @intFromEnum(alias),
            testDigest("runtime alias request"),
            903,
            51,
            testDigest("runtime alias implementation"),
            testDigest("runtime alias instance"),
            runtimeTestStorageV1(
                state,
                lock_bytes,
                acknowledgements,
                ledger,
            ),
            null,
        ),
    );
    try std.testing.expectEqualSlices(
        u8,
        &backing_before,
        &backing,
    );
    try std.testing.expectError(
        error.FileNotFound,
        directory.access(lock_name, .{}),
    );
}

const ReplaceLedgerCandidateObserver = struct {
    directory: std.fs.Dir,
    candidate_name: []const u8,
    expected_body: []const u8,
    replaced: bool = false,

    fn after(
        context: *anyopaque,
        phase: IoPhaseV1,
    ) Error!void {
        const self: *ReplaceLedgerCandidateObserver =
            @ptrCast(@alignCast(context));
        if (phase != .ledger_body_write or self.replaced)
            return;
        self.replaced = true;
        self.directory.rename(
            self.candidate_name,
            "identity-drift-original",
        ) catch return Error.StorageIo;
        const replacement = self.directory.createFile(
            self.candidate_name,
            .{
                .read = true,
                .exclusive = true,
                .mode = 0o600,
            },
        ) catch return Error.StorageIo;
        defer replacement.close();
        replacement.writeAll(
            self.expected_body,
        ) catch return Error.StorageIo;
    }
};

const PublishForeignFinalObserver = struct {
    directory: std.fs.Dir,
    phase: IoPhaseV1,
    final_name: []const u8,
    foreign_bytes: []const u8,
    published: bool = false,

    fn after(
        context: *anyopaque,
        phase: IoPhaseV1,
    ) Error!void {
        const self: *PublishForeignFinalObserver =
            @ptrCast(@alignCast(context));
        if (phase != self.phase or self.published) return;
        const file = self.directory.createFile(
            self.final_name,
            .{
                .read = true,
                .exclusive = true,
                .mode = 0o600,
            },
        ) catch return Error.StorageIo;
        defer file.close();
        file.writeAll(self.foreign_bytes) catch
            return Error.StorageIo;
        file.setEndPos(self.foreign_bytes.len) catch
            return Error.StorageIo;
        file.sync() catch return Error.StorageIo;
        self.published = true;
    }
};

const TestSelectedPublicationV1 = struct {
    selector: PreparedSelectorV1,
    acknowledgement: result_sink.ResultAcknowledgementV1,
};

fn writeTestSelectedPublicationV1(
    directory: std.fs.Dir,
    ledger_storage: []u8,
) !TestSelectedPublicationV1 {
    const request = testDigest("snapshot request");
    var semantic = try result_sink.ResultSinkV1(1).init(
        request,
        811,
        31,
        testDigest("snapshot implementation"),
        testDigest("snapshot instance"),
    );
    const applied = try semantic.apply(
        testInput(request, 811, 31, 121),
    );
    const ledger = try encodeLedgerV1(
        semantic.request_sha256,
        semantic.request_epoch,
        semantic.initial_sequence,
        semantic.sink_implementation_sha256,
        semantic.sink_instance_sha256,
        semantic.acknowledgementSlice(),
        ledger_storage,
    );
    const decoded = try decodeLedgerV1(ledger.bytes);
    const selector = try encodeSelectorV1(
        2,
        testDigest("snapshot previous selector"),
        decoded,
    );
    var ledger_name_storage: [max_generated_name_bytes]u8 =
        undefined;
    const ledger_name = try ledgerNameV1(
        ledger.ledger_sha256,
        &ledger_name_storage,
    );
    try writeNewExactFileV1(
        directory,
        ledger_name,
        ledger.bytes,
    );
    try writeNewExactFileV1(
        directory,
        active_selector_name,
        &selector.bytes,
    );
    return .{
        .selector = selector,
        .acknowledgement = applied.acknowledgement,
    };
}

const ReplaceActiveSelectorSnapshotObserver = struct {
    directory: std.fs.Dir,
    replacement_name: []const u8,
    replaced: bool = false,

    fn beforeSelectorRecheck(
        context: *anyopaque,
    ) Error!void {
        const self: *ReplaceActiveSelectorSnapshotObserver =
            @ptrCast(@alignCast(context));
        self.directory.rename(
            self.replacement_name,
            active_selector_name,
        ) catch return Error.StorageIo;
        self.replaced = true;
    }
};

test "initial recovery no-replace platform table is exact" {
    try std.testing.expect(initialRecoveryOsAvailableV1(.linux));
    try std.testing.expect(initialRecoveryOsAvailableV1(.macos));
    try std.testing.expect(initialRecoveryOsAvailableV1(.ios));
    try std.testing.expect(
        !initialRecoveryOsAvailableV1(.freebsd),
    );
    try std.testing.expect(
        !initialRecoveryOsAvailableV1(.windows),
    );
}

test "read-only selected snapshot works without a lease or writable storage" {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1
        .posix_durable_file_adapter)
        return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    var publication_storage: [2048]u8 = undefined;
    const publication = try writeTestSelectedPublicationV1(
        temporary.dir,
        &publication_storage,
    );
    const selected = try decodeSelectorV1(
        &publication.selector.bytes,
    );
    var ledger_name_storage: [max_generated_name_bytes]u8 =
        undefined;
    const ledger_name = try ledgerNameV1(
        selected.ledger_sha256,
        &ledger_name_storage,
    );
    try writeNewExactFileV1(
        temporary.dir,
        ".prepared-text-result-ledger-unselected.tmp",
        "ignored ledger candidate",
    );
    try writeNewExactFileV1(
        temporary.dir,
        ".prepared-text-result-selector-unselected.tmp",
        "ignored selector candidate",
    );
    try writeNewExactFileV1(
        temporary.dir,
        "prepared-text-result-ledger-unselected.bin",
        "ignored immutable orphan",
    );

    const selector_file = try temporary.dir.openFile(
        active_selector_name,
        .{},
    );
    defer selector_file.close();
    defer selector_file.chmod(0o600) catch {};
    try selector_file.chmod(0o400);
    const ledger_file = try temporary.dir.openFile(
        ledger_name,
        .{},
    );
    defer ledger_file.close();
    defer ledger_file.chmod(0o600) catch {};
    try ledger_file.chmod(0o400);
    // `std.testing.tmpDir` may hold an O_PATH descriptor on Linux. Reopen the
    // directory for iteration so fchmod has a real directory-file descriptor.
    var permission_directory = try temporary.dir.openDir(".", .{
        .iterate = true,
        .no_follow = true,
    });
    defer permission_directory.close();
    try permission_directory.chmod(0o500);
    defer permission_directory.chmod(0o700) catch {};

    var selector_storage: [selector_bytes]u8 = undefined;
    var ledger_storage: [2048]u8 = undefined;
    const snapshot = try readSelectedSnapshotReadOnlyV1(
        temporary.dir,
        &selector_storage,
        &ledger_storage,
        1,
    );
    try std.testing.expectEqualSlices(
        u8,
        &publication.selector.bytes,
        &selector_storage,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        snapshot.ledger.acknowledgement_count,
    );
    try std.testing.expectEqual(
        publication.acknowledgement,
        try snapshot.ledger.acknowledgement(0),
    );
    try std.testing.expectEqualSlices(
        u8,
        &selected.selector_sha256,
        &snapshot.selector.selector_sha256,
    );
    try validateSelectedPairV1(
        snapshot.selector,
        snapshot.ledger,
    );
    var mismatched_selector = snapshot.selector;
    mismatched_selector.ledger_bytes += 1;
    try std.testing.expectError(
        Error.PublicationMismatch,
        validateSelectedPairV1(
            mismatched_selector,
            snapshot.ledger,
        ),
    );

    var lightweight_storage: [selector_bytes]u8 = undefined;
    const lightweight = try readActiveSelectorReadOnlyV1(
        temporary.dir,
        &lightweight_storage,
    );
    try std.testing.expectEqualSlices(
        u8,
        &selected.selector_sha256,
        &lightweight.selector_sha256,
    );
    try std.testing.expectError(
        error.FileNotFound,
        temporary.dir.access(lock_name, .{}),
    );
}

test "selected snapshot enforces caller bounds and disjoint storage" {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1
        .posix_durable_file_adapter)
        return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var publication_storage: [2048]u8 = undefined;
    _ = try writeTestSelectedPublicationV1(
        temporary.dir,
        &publication_storage,
    );

    var selector_storage: [selector_bytes]u8 = undefined;
    var ledger_storage: [2048]u8 = undefined;
    try std.testing.expectError(
        Error.CapacityExceeded,
        readSelectedSnapshotReadOnlyV1(
            temporary.dir,
            &selector_storage,
            &ledger_storage,
            0,
        ),
    );
    var small_ledger_storage: [
        ledger_header_bytes + ledger_footer_bytes
    ]u8 = undefined;
    try std.testing.expectError(
        Error.BufferTooSmall,
        readSelectedSnapshotReadOnlyV1(
            temporary.dir,
            &selector_storage,
            &small_ledger_storage,
            1,
        ),
    );

    var overlapping_storage: [2048]u8 = undefined;
    const overlapping_selector: *[selector_bytes]u8 =
        @ptrCast(&overlapping_storage);
    try std.testing.expectError(
        Error.InvalidStorage,
        readSelectedSnapshotV1(
            temporary.dir,
            overlapping_selector,
            overlapping_storage[selector_bytes - 1 ..],
            1,
        ),
    );
}

test "read-only snapshot rejects unsafe selected file surfaces" {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1
        .posix_durable_file_adapter)
        return error.SkipZigTest;

    {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try temporary.dir.makeDir(active_selector_name);
        var selector_storage: [selector_bytes]u8 = undefined;
        try std.testing.expectError(
            Error.InvalidStorage,
            readActiveSelectorReadOnlyV1(
                temporary.dir,
                &selector_storage,
            ),
        );
    }

    {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var publication_storage: [2048]u8 = undefined;
        const publication = try writeTestSelectedPublicationV1(
            temporary.dir,
            &publication_storage,
        );
        const selected = try decodeSelectorV1(
            &publication.selector.bytes,
        );
        var ledger_name_storage: [
            max_generated_name_bytes
        ]u8 = undefined;
        const ledger_name = try ledgerNameV1(
            selected.ledger_sha256,
            &ledger_name_storage,
        );
        try std.posix.linkat(
            temporary.dir.fd,
            ledger_name,
            temporary.dir.fd,
            "selected-ledger-hardlink",
            0,
        );
        var selector_storage: [selector_bytes]u8 = undefined;
        var ledger_storage: [2048]u8 = undefined;
        try std.testing.expectError(
            Error.MultipleLinks,
            readSelectedSnapshotReadOnlyV1(
                temporary.dir,
                &selector_storage,
                &ledger_storage,
                1,
            ),
        );
    }

    {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var publication_storage: [2048]u8 = undefined;
        const publication = try writeTestSelectedPublicationV1(
            temporary.dir,
            &publication_storage,
        );
        const selected = try decodeSelectorV1(
            &publication.selector.bytes,
        );
        var ledger_name_storage: [
            max_generated_name_bytes
        ]u8 = undefined;
        const ledger_name = try ledgerNameV1(
            selected.ledger_sha256,
            &ledger_name_storage,
        );
        const ledger_file = try temporary.dir.openFile(
            ledger_name,
            .{},
        );
        defer ledger_file.close();
        try ledger_file.chmod(0o644);
        var selector_storage: [selector_bytes]u8 = undefined;
        var ledger_storage: [2048]u8 = undefined;
        try std.testing.expectError(
            Error.UnsafePermissions,
            readSelectedSnapshotReadOnlyV1(
                temporary.dir,
                &selector_storage,
                &ledger_storage,
                1,
            ),
        );
    }

    {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var publication_storage: [2048]u8 = undefined;
        _ = try writeTestSelectedPublicationV1(
            temporary.dir,
            &publication_storage,
        );
        try temporary.dir.rename(
            active_selector_name,
            "selector-symlink-target",
        );
        try temporary.dir.symLink(
            "selector-symlink-target",
            active_selector_name,
            .{},
        );
        var selector_storage: [selector_bytes]u8 = undefined;
        try std.testing.expectError(
            error.SymLinkLoop,
            readActiveSelectorReadOnlyV1(
                temporary.dir,
                &selector_storage,
            ),
        );
    }

    {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var publication_storage: [2048]u8 = undefined;
        _ = try writeTestSelectedPublicationV1(
            temporary.dir,
            &publication_storage,
        );
        const selector_file = try temporary.dir.openFile(
            active_selector_name,
            .{ .mode = .read_write },
        );
        defer selector_file.close();
        try selector_file.setEndPos(selector_bytes - 1);
        var selector_storage: [selector_bytes]u8 = undefined;
        try std.testing.expectError(
            Error.StorageContentChanged,
            readActiveSelectorReadOnlyV1(
                temporary.dir,
                &selector_storage,
            ),
        );
    }
}

test "selected snapshot reports selector replacement as selection changed" {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1
        .posix_durable_file_adapter)
        return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var publication_storage: [2048]u8 = undefined;
    _ = try writeTestSelectedPublicationV1(
        temporary.dir,
        &publication_storage,
    );

    var replacement_ledger_storage: [
        ledger_header_bytes + ledger_footer_bytes
    ]u8 = undefined;
    const replacement_ledger = try encodeLedgerV1(
        testDigest("replacement snapshot request"),
        812,
        41,
        testDigest("replacement snapshot implementation"),
        testDigest("replacement snapshot instance"),
        &.{},
        &replacement_ledger_storage,
    );
    const replacement_selector =
        try prepareInitialSelectorV1(replacement_ledger);
    const replacement_name = "replacement-active-selector";
    try writeNewExactFileV1(
        temporary.dir,
        replacement_name,
        &replacement_selector.bytes,
    );
    var observer: ReplaceActiveSelectorSnapshotObserver = .{
        .directory = temporary.dir,
        .replacement_name = replacement_name,
    };
    var selector_storage: [selector_bytes]u8 = undefined;
    var ledger_storage: [2048]u8 = undefined;
    try std.testing.expectError(
        Error.SelectionChanged,
        readSelectedSnapshotObservedV1(
            temporary.dir,
            &selector_storage,
            &ledger_storage,
            1,
            .{
                .context = &observer,
                .before_selector_recheck_fn = ReplaceActiveSelectorSnapshotObserver
                    .beforeSelectorRecheck,
            },
        ),
    );
    try std.testing.expect(observer.replaced);
}

test "recoverable empty initialization creates and accepts exact selection" {
    if (comptime !initial_recovery_available_v1)
        return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const request = testDigest("empty initialization request");
    const implementation =
        testDigest("empty initialization implementation");
    const instance = testDigest("empty initialization instance");
    var observer: CountObserver = .{};
    var lock_storage: [1]u8 = undefined;
    var initialized =
        try ResultSinkFileV1(2).createOrRecoverEmpty(
            temporary.dir,
            6801,
            request,
            581,
            9,
            implementation,
            instance,
            &lock_storage,
            .{
                .context = &observer,
                .after_phase_fn = CountObserver.after,
            },
        );
    try std.testing.expectEqual(
        EmptyInitializationDispositionV1.created,
        initialized.disposition,
    );
    try std.testing.expectEqual(@as(usize, 10), observer.calls);
    try std.testing.expectEqual(
        @as(usize, 0),
        initialized.store.sink.applied_count,
    );
    const selected_sha256 =
        initialized.store.selector.selector_sha256;
    initialized.store.close();

    observer.calls = 0;
    var reopen_lock_storage: [1]u8 = undefined;
    var already_selected =
        try ResultSinkFileV1(2).createOrRecoverEmpty(
            temporary.dir,
            6801,
            request,
            581,
            9,
            implementation,
            instance,
            &reopen_lock_storage,
            .{
                .context = &observer,
                .after_phase_fn = CountObserver.after,
            },
        );
    defer already_selected.store.close();
    try std.testing.expectEqual(
        EmptyInitializationDispositionV1.already_selected,
        already_selected.disposition,
    );
    try std.testing.expectEqual(@as(usize, 0), observer.calls);
    try std.testing.expectEqualSlices(
        u8,
        &selected_sha256,
        &already_selected.store.selector.selector_sha256,
    );
}

test "empty initialization accepts a non-iterable caller directory" {
    if (comptime !initial_recovery_available_v1)
        return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.makeDir("sink");
    var caller_directory = try temporary.dir.openDir("sink", .{
        .iterate = false,
        .no_follow = true,
    });
    defer caller_directory.close();
    var lock_storage: [1]u8 = undefined;
    var initialized =
        try ResultSinkFileV1(1).createOrRecoverEmpty(
            caller_directory,
            6802,
            testDigest("non-iterable request"),
            582,
            10,
            testDigest("non-iterable implementation"),
            testDigest("non-iterable instance"),
            &lock_storage,
            null,
        );
    defer initialized.store.close();
    try std.testing.expectEqual(
        EmptyInitializationDispositionV1.created,
        initialized.disposition,
    );
}

test "every empty initialization phase recovers exact zero acknowledgements" {
    if (comptime !initial_recovery_available_v1)
        return error.SkipZigTest;
    for (durable_io_phases_v1) |phase| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const request = testDigest("empty phase request");
        const implementation =
            testDigest("empty phase implementation");
        const instance = testDigest("empty phase instance");
        var observer: InjectObserver = .{ .phase = phase };
        var lock_storage: [1]u8 = undefined;
        try std.testing.expectError(
            Error.InjectedFault,
            ResultSinkFileV1(1).createOrRecoverEmpty(
                temporary.dir,
                @as(u64, 6900) + @intFromEnum(phase),
                request,
                591,
                10,
                implementation,
                instance,
                &lock_storage,
                .{
                    .context = &observer,
                    .after_phase_fn = InjectObserver.after,
                },
            ),
        );

        var recovery_lock_storage: [1]u8 = undefined;
        var recovered =
            try ResultSinkFileV1(1).createOrRecoverEmpty(
                temporary.dir,
                @as(u64, 6900) + @intFromEnum(phase),
                request,
                591,
                10,
                implementation,
                instance,
                &recovery_lock_storage,
                null,
            );
        defer recovered.store.close();
        const expected_disposition: EmptyInitializationDispositionV1 =
            if (phase == .selector_replace or
            phase == .selector_directory_sync)
                .already_selected
            else
                .recovered;
        try std.testing.expectEqual(
            expected_disposition,
            recovered.disposition,
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            recovered.store.sink.applied_count,
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            recovered.store.selector.acknowledgement_count,
        );
        var apply_storage: [2048]u8 = undefined;
        const applied = try recovered.store.apply(
            testInput(request, 591, 10, 31),
            &apply_storage,
        );
        try std.testing.expectEqual(
            ApplyDispositionV1.applied,
            applied.disposition,
        );
    }
}

test "empty initialization never resets selected or orphaned acknowledgements" {
    if (comptime !initial_recovery_available_v1)
        return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const request = testDigest("nonempty refusal request");
    const implementation =
        testDigest("nonempty refusal implementation");
    const instance = testDigest("nonempty refusal instance");
    var lock_storage: [1]u8 = undefined;
    var initialized =
        try ResultSinkFileV1(2).createOrRecoverEmpty(
            temporary.dir,
            6951,
            request,
            596,
            15,
            implementation,
            instance,
            &lock_storage,
            null,
        );
    var empty_selector_wire: [selector_bytes]u8 = undefined;
    _ = try readExactFileV1(
        temporary.dir,
        active_selector_name,
        &empty_selector_wire,
        selector_bytes,
    );
    var ledger_storage: [2048]u8 = undefined;
    const applied = try initialized.store.apply(
        testInput(request, 596, 15, 37),
        &ledger_storage,
    );
    const selected_sha256 =
        initialized.store.selector.selector_sha256;
    initialized.store.close();

    var refusal_lock_storage: [1]u8 = undefined;
    try std.testing.expectError(
        Error.StorageContentChanged,
        ResultSinkFileV1(2).createOrRecoverEmpty(
            temporary.dir,
            6951,
            request,
            596,
            15,
            implementation,
            instance,
            &refusal_lock_storage,
            null,
        ),
    );

    var reopen_lock_storage: [1]u8 = undefined;
    var reopen_ledger_storage: [2048]u8 = undefined;
    var reopened = try ResultSinkFileV1(2).open(
        temporary.dir,
        6951,
        request,
        596,
        15,
        implementation,
        instance,
        &reopen_lock_storage,
        &reopen_ledger_storage,
        null,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        reopened.sink.applied_count,
    );
    try std.testing.expectEqualSlices(
        u8,
        &selected_sha256,
        &reopened.selector.selector_sha256,
    );
    const replayed = try reopened.apply(
        testInput(request, 596, 15, 37),
        &reopen_ledger_storage,
    );
    try std.testing.expectEqual(
        ApplyDispositionV1.replayed,
        replayed.disposition,
    );
    try std.testing.expectEqual(
        applied.acknowledgement,
        replayed.acknowledgement,
    );
    reopened.close();

    {
        var rollback_authority =
            try core.durable_directory_sync.AuthorityV1.acquire(
                temporary.dir,
            );
        defer rollback_authority.close();
        const rollback_directory = try rollback_authority.borrow();
        {
            const rollback = try rollback_directory.createFile(
                ".rollback-selector",
                .{
                    .read = true,
                    .exclusive = true,
                    .mode = 0o600,
                },
            );
            defer rollback.close();
            try rollback.writeAll(&empty_selector_wire);
            try rollback.sync();
        }
        try rollback_directory.rename(
            ".rollback-selector",
            active_selector_name,
        );
        try rollback_authority.commit();
    }
    var rollback_refusal_storage: [1]u8 = undefined;
    try std.testing.expectError(
        Error.InvalidStorage,
        ResultSinkFileV1(2).createOrRecoverEmpty(
            temporary.dir,
            6951,
            request,
            596,
            15,
            implementation,
            instance,
            &rollback_refusal_storage,
            null,
        ),
    );

    try temporary.dir.deleteFile(active_selector_name);
    var orphan_refusal_storage: [1]u8 = undefined;
    try std.testing.expectError(
        Error.InvalidStorage,
        ResultSinkFileV1(2).createOrRecoverEmpty(
            temporary.dir,
            6951,
            request,
            596,
            15,
            implementation,
            instance,
            &orphan_refusal_storage,
            null,
        ),
    );
    try std.testing.expectError(
        error.FileNotFound,
        temporary.dir.access(active_selector_name, .{}),
    );
}

test "empty initialization refuses partial active and foreign candidate wires" {
    if (comptime !initial_recovery_available_v1)
        return error.SkipZigTest;
    const request = testDigest("wire refusal request");
    const implementation = testDigest("wire refusal implementation");
    const instance = testDigest("wire refusal instance");
    var empty_ledger_storage: [
        ledger_header_bytes + ledger_footer_bytes
    ]u8 = undefined;
    const empty_ledger = try encodeLedgerV1(
        request,
        597,
        16,
        implementation,
        instance,
        &.{},
        &empty_ledger_storage,
    );
    const empty_selector =
        try prepareInitialSelectorV1(empty_ledger);

    {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const active = try temporary.dir.createFile(
            active_selector_name,
            .{
                .read = true,
                .exclusive = true,
                .mode = 0o600,
            },
        );
        try active.writeAll(
            empty_selector.bytes[0..selector_body_bytes],
        );
        active.close();
        var lock_storage: [1]u8 = undefined;
        try std.testing.expectError(
            Error.StorageContentChanged,
            ResultSinkFileV1(1).createOrRecoverEmpty(
                temporary.dir,
                6961,
                request,
                597,
                16,
                implementation,
                instance,
                &lock_storage,
                null,
            ),
        );
        const stat = try temporary.dir.statFile(
            active_selector_name,
        );
        try std.testing.expectEqual(
            @as(u64, selector_body_bytes),
            stat.size,
        );
    }

    {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var candidate_name_storage: [
            max_generated_name_bytes
        ]u8 = undefined;
        const candidate_name = try ledgerCandidateNameV1(
            empty_ledger.ledger_sha256,
            &candidate_name_storage,
        );
        const candidate = try temporary.dir.createFile(
            candidate_name,
            .{
                .read = true,
                .exclusive = true,
                .mode = 0o600,
            },
        );
        try candidate.writeAll("foreign candidate");
        candidate.close();
        var lock_storage: [1]u8 = undefined;
        try std.testing.expectError(
            Error.StorageContentChanged,
            ResultSinkFileV1(1).createOrRecoverEmpty(
                temporary.dir,
                6962,
                request,
                597,
                16,
                implementation,
                instance,
                &lock_storage,
                null,
            ),
        );
        var preserved: [32]u8 = undefined;
        const reopened = try temporary.dir.openFile(
            candidate_name,
            .{},
        );
        const read = try reopened.readAll(&preserved);
        reopened.close();
        try std.testing.expectEqualStrings(
            "foreign candidate",
            preserved[0..read],
        );
    }
}

test "empty initialization refuses linked paths and visible identity drift" {
    if (comptime !initial_recovery_available_v1)
        return error.SkipZigTest;
    const request = testDigest("namespace refusal request");
    const implementation =
        testDigest("namespace refusal implementation");
    const instance = testDigest("namespace refusal instance");

    {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var lock_storage: [1]u8 = undefined;
        var initialized =
            try ResultSinkFileV1(1).createOrRecoverEmpty(
                temporary.dir,
                6971,
                request,
                598,
                17,
                implementation,
                instance,
                &lock_storage,
                null,
            );
        initialized.store.close();
        try std.posix.linkat(
            temporary.dir.fd,
            active_selector_name,
            temporary.dir.fd,
            "active-selector-hardlink",
            0,
        );
        var refusal_storage: [1]u8 = undefined;
        try std.testing.expectError(
            Error.MultipleLinks,
            ResultSinkFileV1(1).createOrRecoverEmpty(
                temporary.dir,
                6971,
                request,
                598,
                17,
                implementation,
                instance,
                &refusal_storage,
                null,
            ),
        );
    }

    {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const target = try temporary.dir.createFile(
            "selector-symlink-target",
            .{
                .read = true,
                .exclusive = true,
                .mode = 0o600,
            },
        );
        target.close();
        try temporary.dir.symLink(
            "selector-symlink-target",
            active_selector_name,
            .{},
        );
        var lock_storage: [1]u8 = undefined;
        try std.testing.expectError(
            error.SymLinkLoop,
            ResultSinkFileV1(1).createOrRecoverEmpty(
                temporary.dir,
                6972,
                request,
                598,
                17,
                implementation,
                instance,
                &lock_storage,
                null,
            ),
        );
    }

    {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var ledger_storage: [
            ledger_header_bytes + ledger_footer_bytes
        ]u8 = undefined;
        const ledger = try encodeLedgerV1(
            request,
            598,
            17,
            implementation,
            instance,
            &.{},
            &ledger_storage,
        );
        var candidate_name_storage: [
            max_generated_name_bytes
        ]u8 = undefined;
        const candidate_name = try ledgerCandidateNameV1(
            ledger.ledger_sha256,
            &candidate_name_storage,
        );
        var observer: ReplaceLedgerCandidateObserver = .{
            .directory = temporary.dir,
            .candidate_name = candidate_name,
            .expected_body = ledger.bytes[0 .. ledger.bytes.len -
                ledger_footer_bytes],
        };
        var lock_storage: [1]u8 = undefined;
        try std.testing.expectError(
            Error.StorageIdentityChanged,
            ResultSinkFileV1(1).createOrRecoverEmpty(
                temporary.dir,
                6973,
                request,
                598,
                17,
                implementation,
                instance,
                &lock_storage,
                .{
                    .context = &observer,
                    .after_phase_fn = ReplaceLedgerCandidateObserver.after,
                },
            ),
        );
        try std.testing.expect(observer.replaced);
    }
}

test "empty initialization preserves a raced immutable ledger final" {
    if (comptime !initial_recovery_available_v1)
        return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const request = testDigest("raced ledger request");
    const implementation = testDigest("raced ledger implementation");
    const instance = testDigest("raced ledger instance");
    var ledger_storage: [
        ledger_header_bytes + ledger_footer_bytes
    ]u8 = undefined;
    const ledger = try encodeLedgerV1(
        request,
        599,
        18,
        implementation,
        instance,
        &.{},
        &ledger_storage,
    );
    var immutable_name_storage: [
        max_generated_name_bytes
    ]u8 = undefined;
    const immutable_name = try ledgerNameV1(
        ledger.ledger_sha256,
        &immutable_name_storage,
    );
    const foreign = "foreign immutable ledger authority";
    var observer: PublishForeignFinalObserver = .{
        .directory = temporary.dir,
        .phase = .ledger_file_sync,
        .final_name = immutable_name,
        .foreign_bytes = foreign,
    };
    var lock_storage: [1]u8 = undefined;
    try std.testing.expectError(
        Error.StorageContentChanged,
        ResultSinkFileV1(1).createOrRecoverEmpty(
            temporary.dir,
            6974,
            request,
            599,
            18,
            implementation,
            instance,
            &lock_storage,
            .{
                .context = &observer,
                .after_phase_fn = PublishForeignFinalObserver.after,
            },
        ),
    );
    try std.testing.expect(observer.published);
    try std.testing.expect(try exactFileExistsV1(
        temporary.dir,
        immutable_name,
        foreign,
    ));
}

test "empty initialization preserves a raced active selector" {
    if (comptime !initial_recovery_available_v1)
        return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const request = testDigest("raced selector request");
    const implementation =
        testDigest("raced selector implementation");
    const instance = testDigest("raced selector instance");
    const foreign = "foreign active selector authority";
    var observer: PublishForeignFinalObserver = .{
        .directory = temporary.dir,
        .phase = .selector_temp_sync,
        .final_name = active_selector_name,
        .foreign_bytes = foreign,
    };
    var lock_storage: [1]u8 = undefined;
    try std.testing.expectError(
        Error.StorageIdentityChanged,
        ResultSinkFileV1(1).createOrRecoverEmpty(
            temporary.dir,
            6975,
            request,
            600,
            19,
            implementation,
            instance,
            &lock_storage,
            .{
                .context = &observer,
                .after_phase_fn = PublishForeignFinalObserver.after,
            },
        ),
    );
    try std.testing.expect(observer.published);
    try std.testing.expect(try exactFileExistsV1(
        temporary.dir,
        active_selector_name,
        foreign,
    ));
}

test "empty initialization reuses a pinned recovery candidate inode" {
    if (comptime !initial_recovery_available_v1)
        return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const request = testDigest("candidate reuse request");
    const implementation = testDigest("candidate reuse implementation");
    const instance = testDigest("candidate reuse instance");
    var ledger_storage: [
        ledger_header_bytes + ledger_footer_bytes
    ]u8 = undefined;
    const ledger = try encodeLedgerV1(
        request,
        601,
        20,
        implementation,
        instance,
        &.{},
        &ledger_storage,
    );
    var candidate_name_storage: [
        max_generated_name_bytes
    ]u8 = undefined;
    const candidate_name = try ledgerCandidateNameV1(
        ledger.ledger_sha256,
        &candidate_name_storage,
    );
    const candidate = try openSafeFileV1(
        temporary.dir,
        candidate_name,
        .create,
    );
    try candidate.writeAll(ledger.bytes[0..37]);
    const candidate_view = try inspectFileV1(
        candidate,
        temporary.dir,
        candidate_name,
    );
    candidate.close();

    var lock_storage: [1]u8 = undefined;
    var recovered =
        try ResultSinkFileV1(1).createOrRecoverEmpty(
            temporary.dir,
            6976,
            request,
            601,
            20,
            implementation,
            instance,
            &lock_storage,
            null,
        );
    defer recovered.store.close();
    try std.testing.expectEqual(
        EmptyInitializationDispositionV1.recovered,
        recovered.disposition,
    );
    var immutable_name_storage: [
        max_generated_name_bytes
    ]u8 = undefined;
    const immutable_name = try ledgerNameV1(
        ledger.ledger_sha256,
        &immutable_name_storage,
    );
    const immutable = try openSafeFileV1(
        temporary.dir,
        immutable_name,
        .existing,
    );
    defer immutable.close();
    const immutable_view = try inspectFileV1(
        immutable,
        temporary.dir,
        immutable_name,
    );
    try std.testing.expectEqual(
        candidate_view.device,
        immutable_view.device,
    );
    try std.testing.expectEqual(
        candidate_view.inode,
        immutable_view.inode,
    );
}

test "empty initialization rejects mid-flight reserved artifacts" {
    if (comptime !initial_recovery_available_v1)
        return error.SkipZigTest;
    const foreign = "foreign reserved namespace authority";
    {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const foreign_name =
            ".prepared-text-result-ledger-foreign-race.tmp";
        var observer: PublishForeignFinalObserver = .{
            .directory = temporary.dir,
            .phase = .ledger_body_sync,
            .final_name = foreign_name,
            .foreign_bytes = foreign,
        };
        var lock_storage: [1]u8 = undefined;
        try std.testing.expectError(
            Error.InvalidStorage,
            ResultSinkFileV1(1).createOrRecoverEmpty(
                temporary.dir,
                6977,
                testDigest("ledger namespace race request"),
                602,
                21,
                testDigest("ledger namespace race implementation"),
                testDigest("ledger namespace race instance"),
                &lock_storage,
                .{
                    .context = &observer,
                    .after_phase_fn = PublishForeignFinalObserver.after,
                },
            ),
        );
        try std.testing.expect(observer.published);
        try std.testing.expect(try exactFileExistsV1(
            temporary.dir,
            foreign_name,
            foreign,
        ));
    }
    {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const foreign_name =
            ".prepared-text-result-selector-foreign-race.tmp";
        var observer: PublishForeignFinalObserver = .{
            .directory = temporary.dir,
            .phase = .selector_temp_sync,
            .final_name = foreign_name,
            .foreign_bytes = foreign,
        };
        var lock_storage: [1]u8 = undefined;
        try std.testing.expectError(
            Error.InvalidStorage,
            ResultSinkFileV1(1).createOrRecoverEmpty(
                temporary.dir,
                6978,
                testDigest("selector namespace race request"),
                603,
                22,
                testDigest("selector namespace race implementation"),
                testDigest("selector namespace race instance"),
                &lock_storage,
                .{
                    .context = &observer,
                    .after_phase_fn = PublishForeignFinalObserver.after,
                },
            ),
        );
        try std.testing.expect(observer.published);
        try std.testing.expect(try exactFileExistsV1(
            temporary.dir,
            foreign_name,
            foreign,
        ));
    }
}

test "durable result sink applies reopens and replays exactly" {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1
        .posix_durable_file_adapter)
        return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const request = testDigest("file request");
    const implementation = testDigest("file implementation");
    const instance = testDigest("file instance");
    var observer: CountObserver = .{};
    var lock_storage: [1]u8 = undefined;
    var caller_directory = try temporary.dir.openDir(".", .{});
    var store = ResultSinkFileV1(2).create(
        caller_directory,
        7001,
        request,
        601,
        11,
        implementation,
        instance,
        &lock_storage,
        .{
            .context = &observer,
            .after_phase_fn = CountObserver.after,
        },
    ) catch |err| {
        caller_directory.close();
        return err;
    };
    caller_directory.close();
    var ledger_storage: [2048]u8 = undefined;
    const first = try store.apply(
        testInput(request, 601, 11, 41),
        &ledger_storage,
    );
    try std.testing.expectEqual(
        ApplyDispositionV1.applied,
        first.disposition,
    );
    try std.testing.expectEqual(@as(usize, 10), observer.calls);
    const replay = try store.apply(
        testInput(request, 601, 11, 41),
        &ledger_storage,
    );
    try std.testing.expectEqual(
        ApplyDispositionV1.replayed,
        replay.disposition,
    );
    try std.testing.expectEqual(
        first.acknowledgement,
        replay.acknowledgement,
    );
    try std.testing.expectEqual(@as(usize, 10), observer.calls);
    store.close();

    var reopen_lock: [1]u8 = undefined;
    var reopen_ledger: [2048]u8 = undefined;
    var reopened = try ResultSinkFileV1(2).open(
        temporary.dir,
        7001,
        request,
        601,
        11,
        implementation,
        instance,
        &reopen_lock,
        &reopen_ledger,
        null,
    );
    defer reopened.close();
    try std.testing.expectEqual(@as(usize, 1), reopened.sink.applied_count);
    const reopened_replay = try reopened.apply(
        testInput(request, 601, 11, 41),
        &reopen_ledger,
    );
    try std.testing.expectEqual(
        ApplyDispositionV1.replayed,
        reopened_replay.disposition,
    );
    try std.testing.expectEqual(
        first.acknowledgement,
        reopened_replay.acknowledgement,
    );
}

test "durable result sink replaces stale candidates without mutating hardlinks" {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1
        .posix_durable_file_adapter)
        return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const request = testDigest("candidate request");
    const implementation = testDigest("candidate implementation");
    const instance = testDigest("candidate instance");
    var lock_storage: [1]u8 = undefined;
    var store = try ResultSinkFileV1(1).create(
        temporary.dir,
        7501,
        request,
        651,
        13,
        implementation,
        instance,
        &lock_storage,
        null,
    );
    defer store.close();

    const delivery = testInput(request, 651, 13, 51);
    var preview_sink = store.sink;
    _ = try preview_sink.apply(delivery);
    var preview_ledger_storage: [2048]u8 = undefined;
    const preview_ledger = try encodeLedgerV1(
        preview_sink.request_sha256,
        preview_sink.request_epoch,
        preview_sink.initial_sequence,
        preview_sink.sink_implementation_sha256,
        preview_sink.sink_instance_sha256,
        preview_sink.acknowledgementSlice(),
        &preview_ledger_storage,
    );
    const preview_selector = try prepareSuccessorSelectorV1(
        store.selector,
        preview_ledger,
    );
    var ledger_candidate_storage: [max_generated_name_bytes]u8 =
        undefined;
    const ledger_candidate = try ledgerCandidateNameV1(
        preview_ledger.ledger_sha256,
        &ledger_candidate_storage,
    );
    var selector_candidate_storage: [max_generated_name_bytes]u8 =
        undefined;
    const selector_candidate = try selectorCandidateNameV1(
        preview_selector.selector_sha256,
        &selector_candidate_storage,
    );

    const ledger_victim_bytes = "ledger victim must survive";
    {
        const victim = try temporary.dir.createFile(
            "ledger-victim",
            .{
                .read = true,
                .exclusive = true,
                .mode = 0o600,
            },
        );
        defer victim.close();
        try victim.writeAll(ledger_victim_bytes);
        try victim.sync();
    }
    try std.posix.linkat(
        temporary.dir.fd,
        "ledger-victim",
        temporary.dir.fd,
        ledger_candidate,
        0,
    );

    const selector_victim_bytes = "selector victim must survive";
    {
        const victim = try temporary.dir.createFile(
            "selector-victim",
            .{
                .read = true,
                .exclusive = true,
                .mode = 0o600,
            },
        );
        defer victim.close();
        try victim.writeAll(selector_victim_bytes);
        try victim.sync();
    }
    try std.posix.linkat(
        temporary.dir.fd,
        "selector-victim",
        temporary.dir.fd,
        selector_candidate,
        0,
    );

    const applied = try store.apply(delivery, &preview_ledger_storage);
    try std.testing.expectEqual(
        ApplyDispositionV1.applied,
        applied.disposition,
    );
    try std.testing.expectEqualSlices(
        u8,
        &preview_selector.selector_sha256,
        &applied.selector_sha256,
    );

    var victim_storage: [64]u8 = undefined;
    {
        const victim = try temporary.dir.openFile(
            "ledger-victim",
            .{},
        );
        defer victim.close();
        const read = try victim.readAll(&victim_storage);
        try std.testing.expectEqualStrings(
            ledger_victim_bytes,
            victim_storage[0..read],
        );
    }
    {
        const victim = try temporary.dir.openFile(
            "selector-victim",
            .{},
        );
        defer victim.close();
        const read = try victim.readAll(&victim_storage);
        try std.testing.expectEqualStrings(
            selector_victim_bytes,
            victim_storage[0..read],
        );
    }
}

test "every durable apply phase recovers previous or exact successor" {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1
        .posix_durable_file_adapter)
        return error.SkipZigTest;
    for (durable_io_phases_v1) |phase| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const request = testDigest("phase request");
        const implementation = testDigest("phase implementation");
        const instance = testDigest("phase instance");
        var observer: InjectObserver = .{ .phase = phase };
        var lock_storage: [1]u8 = undefined;
        var store = try ResultSinkFileV1(2).create(
            temporary.dir,
            @as(u64, 8000) + @intFromEnum(phase),
            request,
            701,
            21,
            implementation,
            instance,
            &lock_storage,
            .{
                .context = &observer,
                .after_phase_fn = InjectObserver.after,
            },
        );
        var ledger_storage: [2048]u8 = undefined;
        try std.testing.expectError(
            Error.InjectedFault,
            store.apply(
                testInput(request, 701, 21, 61),
                &ledger_storage,
            ),
        );
        try std.testing.expectEqual(StoreStateV1.poisoned, store.state);
        store.close();

        var reopen_lock: [1]u8 = undefined;
        var reopen_ledger: [2048]u8 = undefined;
        var reopened = try ResultSinkFileV1(2).open(
            temporary.dir,
            @as(u64, 8000) + @intFromEnum(phase),
            request,
            701,
            21,
            implementation,
            instance,
            &reopen_lock,
            &reopen_ledger,
            null,
        );
        const recovered = try reopened.apply(
            testInput(request, 701, 21, 61),
            &reopen_ledger,
        );
        try std.testing.expect(
            recovered.disposition == .applied or
                recovered.disposition == .replayed,
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            reopened.sink.applied_count,
        );
        const replay = try reopened.apply(
            testInput(request, 701, 21, 61),
            &reopen_ledger,
        );
        try std.testing.expectEqual(
            ApplyDispositionV1.replayed,
            replay.disposition,
        );
        try std.testing.expectEqual(
            recovered.acknowledgement,
            replay.acknowledgement,
        );
        reopened.close();
    }
}

test "runtime durable sink supports zero capacity through create recovery and open" {
    if (comptime !initial_recovery_available_v1)
        return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const request = testDigest("runtime zero request");
    const implementation =
        testDigest("runtime zero implementation");
    const instance = testDigest("runtime zero instance");
    const epoch: u64 = 9101;
    const request_epoch: u64 = 901;
    const initial_sequence: u64 = 31;
    const empty_ledger_bytes =
        ledger_header_bytes + ledger_footer_bytes;

    var state: result_sink.RuntimeResultSinkStateV1 =
        undefined;
    var lock: [runtime_result_sink_lock_bytes_v1]u8 =
        undefined;
    var acknowledgements: [0]result_sink.ResultAcknowledgementV1 =
        .{};
    var ledger: [empty_ledger_bytes]u8 = undefined;
    var initialization =
        try RuntimeResultSinkFileV1.createOrRecoverEmpty(
            temporary.dir,
            epoch,
            request,
            request_epoch,
            initial_sequence,
            implementation,
            instance,
            runtimeTestStorageV1(
                &state,
                &lock,
                &acknowledgements,
                &ledger,
            ),
            null,
        );
    try std.testing.expectEqual(
        EmptyInitializationDispositionV1.created,
        initialization.disposition,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        initialization.store.sink.appliedCount(),
    );
    try std.testing.expectError(
        result_sink.Error.CapacityExceeded,
        initialization.store.apply(testInput(
            request,
            request_epoch,
            initial_sequence,
            301,
        )),
    );
    try std.testing.expectEqual(
        StoreStateV1.ready,
        initialization.store.state,
    );
    initialization.store.close();

    var recovered_state: result_sink.RuntimeResultSinkStateV1 =
        undefined;
    var recovered_lock: [
        runtime_result_sink_lock_bytes_v1
    ]u8 = undefined;
    var recovered_acknowledgements: [
        0
    ]result_sink.ResultAcknowledgementV1 = .{};
    var recovered_ledger: [empty_ledger_bytes]u8 = undefined;
    var recovered =
        try RuntimeResultSinkFileV1.createOrRecoverEmpty(
            temporary.dir,
            epoch,
            request,
            request_epoch,
            initial_sequence,
            implementation,
            instance,
            runtimeTestStorageV1(
                &recovered_state,
                &recovered_lock,
                &recovered_acknowledgements,
                &recovered_ledger,
            ),
            null,
        );
    try std.testing.expectEqual(
        EmptyInitializationDispositionV1.already_selected,
        recovered.disposition,
    );
    recovered.store.close();

    var open_state: result_sink.RuntimeResultSinkStateV1 =
        undefined;
    var open_lock: [runtime_result_sink_lock_bytes_v1]u8 =
        undefined;
    var open_acknowledgements: [
        0
    ]result_sink.ResultAcknowledgementV1 = .{};
    var open_ledger: [empty_ledger_bytes]u8 = undefined;
    var opened = try RuntimeResultSinkFileV1.open(
        temporary.dir,
        epoch,
        request,
        request_epoch,
        initial_sequence,
        implementation,
        instance,
        runtimeTestStorageV1(
            &open_state,
            &open_lock,
            &open_acknowledgements,
            &open_ledger,
        ),
        null,
    );
    defer opened.close();
    try std.testing.expectError(
        result_sink.Error.CapacityExceeded,
        opened.apply(testInput(
            request,
            request_epoch,
            initial_sequence,
            302,
        )),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        opened.sink.appliedCount(),
    );
}

test "runtime durable sink prepares publishes reopens and replays exact result" {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1
        .posix_durable_file_adapter)
        return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const request = testDigest("runtime file request");
    const implementation =
        testDigest("runtime file implementation");
    const instance = testDigest("runtime file instance");
    const epoch: u64 = 9201;
    const request_epoch: u64 = 902;
    const initial_sequence: u64 = 41;

    var storage: RuntimeTestStorageV1 = undefined;
    var observer: CountObserver = .{};
    var store = try RuntimeResultSinkFileV1.create(
        temporary.dir,
        epoch,
        request,
        request_epoch,
        initial_sequence,
        implementation,
        instance,
        storage.view(),
        .{
            .context = &observer,
            .after_phase_fn = CountObserver.after,
        },
    );
    const delivery = testInput(
        request,
        request_epoch,
        initial_sequence,
        311,
    );
    const stale = try store.prepareApply(delivery);
    try std.testing.expectEqual(@as(usize, 1), stale.acknowledgement_count);
    storage.ledger[ledger_header_bytes] ^= 0xff;
    try std.testing.expectError(
        Error.StalePreparation,
        store.applyPrepared(stale),
    );
    try std.testing.expectEqual(StoreStateV1.ready, store.state);
    try std.testing.expectEqual(
        @as(usize, 0),
        storage.state.applied_count,
    );
    try std.testing.expectEqual(@as(usize, 0), observer.calls);

    const prepared = try store.prepareApply(delivery);
    var replacement_acknowledgements: [
        runtime_test_capacity_v1
    ]result_sink.ResultAcknowledgementV1 = undefined;
    @memcpy(
        std.mem.sliceAsBytes(&replacement_acknowledgements),
        std.mem.sliceAsBytes(&storage.acknowledgements),
    );
    storage.state.acknowledgements =
        replacement_acknowledgements[0..];
    try std.testing.expectError(
        Error.StorageIdentityChanged,
        store.applyPrepared(prepared),
    );
    storage.state.acknowledgements =
        storage.acknowledgements[0..];

    const ledger_acknowledgements: *[
        runtime_test_capacity_v1
    ]result_sink.ResultAcknowledgementV1 = @ptrCast(
        @alignCast(storage.ledger[0..].ptr),
    );
    storage.state.acknowledgements =
        ledger_acknowledgements[0..];
    try std.testing.expectError(
        Error.StorageIdentityChanged,
        store.applyPrepared(prepared),
    );
    storage.state.acknowledgements =
        storage.acknowledgements[0..];
    try std.testing.expectEqual(StoreStateV1.ready, store.state);
    try std.testing.expectEqual(@as(usize, 0), observer.calls);

    const applied = try store.applyPrepared(prepared);
    try std.testing.expectEqual(
        ApplyDispositionV1.applied,
        applied.disposition,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        storage.state.applied_count,
    );
    try std.testing.expectEqual(@as(usize, 10), observer.calls);
    const replay_prepared = try store.prepareApply(delivery);
    try std.testing.expect(replay_prepared.ledger == null);
    try std.testing.expect(replay_prepared.selector == null);
    const replay = try store.applyPrepared(replay_prepared);
    try std.testing.expectEqual(
        ApplyDispositionV1.replayed,
        replay.disposition,
    );
    try std.testing.expectEqual(
        applied.acknowledgement,
        replay.acknowledgement,
    );
    try std.testing.expectEqual(@as(usize, 10), observer.calls);
    store.close();

    var ledger_name_storage: [max_generated_name_bytes]u8 =
        undefined;
    const ledger_name = try ledgerNameV1(
        applied.ledger_sha256,
        &ledger_name_storage,
    );
    const selected_ledger_bytes = try ledgerBytesForCountV1(1);
    const corrupted_offset = selected_ledger_bytes - 1;
    const original_footer_byte =
        storage.ledger[corrupted_offset];
    const corrupted_footer = [1]u8{
        original_footer_byte ^ 0xff,
    };
    const selected_file = try openSafeFileV1(
        temporary.dir,
        ledger_name,
        .existing,
    );
    defer selected_file.close();
    try selected_file.pwriteAll(
        &corrupted_footer,
        corrupted_offset,
    );
    try selected_file.sync();

    var rejected_storage: RuntimeTestStorageV1 = undefined;
    @memset(std.mem.asBytes(&rejected_storage.state), 0x5a);
    @memset(
        std.mem.sliceAsBytes(
            &rejected_storage.acknowledgements,
        ),
        0xa5,
    );
    var rejected_state_before: [
        @sizeOf(result_sink.RuntimeResultSinkStateV1)
    ]u8 = undefined;
    @memcpy(
        &rejected_state_before,
        std.mem.asBytes(&rejected_storage.state),
    );
    var rejected_acknowledgements_before: [
        runtime_test_capacity_v1 *
            @sizeOf(result_sink.ResultAcknowledgementV1)
    ]u8 = undefined;
    @memcpy(
        &rejected_acknowledgements_before,
        std.mem.sliceAsBytes(
            &rejected_storage.acknowledgements,
        ),
    );
    try std.testing.expectError(
        Error.InvalidLedger,
        RuntimeResultSinkFileV1.open(
            temporary.dir,
            epoch,
            request,
            request_epoch,
            initial_sequence,
            implementation,
            instance,
            rejected_storage.view(),
            null,
        ),
    );
    try std.testing.expectEqualSlices(
        u8,
        &rejected_state_before,
        std.mem.asBytes(&rejected_storage.state),
    );
    try std.testing.expectEqualSlices(
        u8,
        &rejected_acknowledgements_before,
        std.mem.sliceAsBytes(
            &rejected_storage.acknowledgements,
        ),
    );

    const restored_footer = [1]u8{original_footer_byte};
    try selected_file.pwriteAll(
        &restored_footer,
        corrupted_offset,
    );
    try selected_file.sync();
    var reopen_storage: RuntimeTestStorageV1 = undefined;
    var reopened = try RuntimeResultSinkFileV1.open(
        temporary.dir,
        epoch,
        request,
        request_epoch,
        initial_sequence,
        implementation,
        instance,
        reopen_storage.view(),
        null,
    );
    defer reopened.close();
    try std.testing.expectEqual(
        @as(usize, 1),
        reopened.sink.appliedCount(),
    );
    const reopened_replay = try reopened.apply(delivery);
    try std.testing.expectEqual(
        ApplyDispositionV1.replayed,
        reopened_replay.disposition,
    );
    try std.testing.expectEqual(
        applied.acknowledgement,
        reopened_replay.acknowledgement,
    );
}

test "runtime durable sink rejects reentrant apply during publication" {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1
        .posix_durable_file_adapter)
        return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const request = testDigest("runtime reentrant request");
    const implementation =
        testDigest("runtime reentrant implementation");
    const instance = testDigest("runtime reentrant instance");
    const epoch: u64 = 9251;
    const request_epoch: u64 = 925;
    const initial_sequence: u64 = 45;
    const outer_delivery = testInput(
        request,
        request_epoch,
        initial_sequence,
        315,
    );
    var observer: ReentrantRuntimeObserverV1 = .{
        .input = testInput(
            request,
            request_epoch,
            initial_sequence,
            316,
        ),
    };
    var storage: RuntimeTestStorageV1 = undefined;
    var store = try RuntimeResultSinkFileV1.create(
        temporary.dir,
        epoch,
        request,
        request_epoch,
        initial_sequence,
        implementation,
        instance,
        storage.view(),
        .{
            .context = &observer,
            .after_phase_fn = ReentrantRuntimeObserverV1.after,
        },
    );
    observer.store = &store;
    const applied = try store.apply(outer_delivery);
    try std.testing.expect(observer.attempted);
    try std.testing.expect(observer.rejected);
    try std.testing.expectEqual(StoreStateV1.ready, store.state);
    try std.testing.expectEqual(
        @as(usize, 1),
        store.sink.appliedCount(),
    );
    store.close();

    var reopened_storage: RuntimeTestStorageV1 = undefined;
    var reopened = try RuntimeResultSinkFileV1.open(
        temporary.dir,
        epoch,
        request,
        request_epoch,
        initial_sequence,
        implementation,
        instance,
        reopened_storage.view(),
        null,
    );
    defer reopened.close();
    const replay = try reopened.apply(outer_delivery);
    try std.testing.expectEqual(
        ApplyDispositionV1.replayed,
        replay.disposition,
    );
    try std.testing.expectEqual(
        applied.acknowledgement,
        replay.acknowledgement,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        reopened.sink.appliedCount(),
    );
}

test "runtime durable open rejects a nonempty lock stream" {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1
        .posix_durable_file_adapter)
        return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const request = testDigest("runtime nonempty lock request");
    const implementation =
        testDigest("runtime nonempty lock implementation");
    const instance =
        testDigest("runtime nonempty lock instance");
    const epoch: u64 = 9271;
    var storage: RuntimeTestStorageV1 = undefined;
    var store = try RuntimeResultSinkFileV1.create(
        temporary.dir,
        epoch,
        request,
        927,
        47,
        implementation,
        instance,
        storage.view(),
        null,
    );
    store.close();

    const lock_file = try temporary.dir.openFile(
        lock_name,
        .{ .mode = .write_only },
    );
    defer lock_file.close();
    try lock_file.pwriteAll(&[_]u8{0xa5}, 0);
    try lock_file.sync();

    var rejected_storage: RuntimeTestStorageV1 = undefined;
    @memset(
        std.mem.asBytes(&rejected_storage.state),
        0x5a,
    );
    const retained_state =
        std.mem.asBytes(&rejected_storage.state).*;
    try std.testing.expectError(
        Error.StorageContentChanged,
        RuntimeResultSinkFileV1.open(
            temporary.dir,
            epoch,
            request,
            927,
            47,
            implementation,
            instance,
            rejected_storage.view(),
            null,
        ),
    );
    try std.testing.expectEqualSlices(
        u8,
        &retained_state,
        std.mem.asBytes(&rejected_storage.state),
    );
}

test "runtime durable storage rejects capacity undersize and alias before lease" {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1
        .posix_durable_file_adapter)
        return error.SkipZigTest;
    const capacity: usize = 1;
    const maximum_ledger_bytes = ledger_header_bytes +
        capacity * result_sink.acknowledgement_bytes +
        ledger_footer_bytes;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const request = testDigest("runtime storage request");
    const implementation =
        testDigest("runtime storage implementation");
    const instance = testDigest("runtime storage instance");
    var lock: [runtime_result_sink_lock_bytes_v1]u8 =
        undefined;
    var acknowledgements: [
        capacity
    ]result_sink.ResultAcknowledgementV1 = undefined;

    for (std.enums.values(RuntimeStorageAliasV1)) |alias| {
        try expectRuntimeStorageAliasBeforeLeaseV1(
            temporary.dir,
            alias,
        );
    }

    var state: result_sink.RuntimeResultSinkStateV1 =
        undefined;
    var short_ledger: [maximum_ledger_bytes - 1]u8 =
        undefined;
    try std.testing.expectError(
        Error.BufferTooSmall,
        RuntimeResultSinkFileV1.create(
            temporary.dir,
            9302,
            request,
            903,
            51,
            implementation,
            instance,
            runtimeTestStorageV1(
                &state,
                &lock,
                &acknowledgements,
                &short_ledger,
            ),
            null,
        ),
    );
    try std.testing.expectError(
        error.FileNotFound,
        temporary.dir.access(lock_name, .{}),
    );

    var short_lock: [
        runtime_result_sink_lock_bytes_v1 - 1
    ]u8 = undefined;
    var full_ledger: [maximum_ledger_bytes]u8 = undefined;
    try std.testing.expectError(
        Error.BufferTooSmall,
        RuntimeResultSinkFileV1.create(
            temporary.dir,
            9303,
            request,
            903,
            51,
            implementation,
            instance,
            runtimeTestStorageV1(
                &state,
                &short_lock,
                &acknowledgements,
                &full_ledger,
            ),
            null,
        ),
    );
    try std.testing.expectError(
        error.FileNotFound,
        temporary.dir.access(lock_name, .{}),
    );

    const excessive_capacity =
        runtime_result_sink_max_capacity_v1 + 1;
    const excessive_ledger_bytes = ledger_header_bytes +
        excessive_capacity * result_sink.acknowledgement_bytes +
        ledger_footer_bytes;
    var excessive_acknowledgements: [
        excessive_capacity
    ]result_sink.ResultAcknowledgementV1 = undefined;
    var excessive_ledger: [excessive_ledger_bytes]u8 =
        undefined;
    try std.testing.expectError(
        Error.CapacityExceeded,
        RuntimeResultSinkFileV1.create(
            temporary.dir,
            9304,
            request,
            903,
            51,
            implementation,
            instance,
            runtimeTestStorageV1(
                &state,
                &lock,
                &excessive_acknowledgements,
                &excessive_ledger,
            ),
            null,
        ),
    );
    try std.testing.expectError(
        error.FileNotFound,
        temporary.dir.access(lock_name, .{}),
    );
}

test "runtime durable injected phases preserve live acknowledgements and recover" {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1
        .posix_durable_file_adapter)
        return error.SkipZigTest;
    for (durable_io_phases_v1) |phase| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const request = testDigest("runtime phase request");
        const implementation =
            testDigest("runtime phase implementation");
        const instance = testDigest("runtime phase instance");
        const epoch = @as(u64, 9400) + @intFromEnum(phase);
        const request_epoch: u64 = 904;
        const initial_sequence: u64 = 61;
        const delivery = testInput(
            request,
            request_epoch,
            initial_sequence,
            321,
        );
        var observer: InjectObserver = .{ .phase = phase };
        var storage: RuntimeTestStorageV1 = undefined;
        @memset(
            std.mem.sliceAsBytes(&storage.acknowledgements),
            0xa5,
        );
        var acknowledgement_bytes_before: [
            runtime_test_capacity_v1 *
                @sizeOf(result_sink.ResultAcknowledgementV1)
        ]u8 = undefined;
        @memcpy(
            &acknowledgement_bytes_before,
            std.mem.sliceAsBytes(&storage.acknowledgements),
        );
        var store = try RuntimeResultSinkFileV1.create(
            temporary.dir,
            epoch,
            request,
            request_epoch,
            initial_sequence,
            implementation,
            instance,
            storage.view(),
            .{
                .context = &observer,
                .after_phase_fn = InjectObserver.after,
            },
        );
        try std.testing.expectError(
            Error.InjectedFault,
            store.apply(delivery),
        );
        try std.testing.expectEqual(StoreStateV1.poisoned, store.state);
        try std.testing.expectEqual(
            @as(usize, 0),
            storage.state.applied_count,
        );
        try std.testing.expectEqual(
            initial_sequence,
            storage.state.next_sequence,
        );
        try std.testing.expectEqualSlices(
            u8,
            &acknowledgement_bytes_before,
            std.mem.sliceAsBytes(&storage.acknowledgements),
        );
        store.close();

        var reopen_storage: RuntimeTestStorageV1 = undefined;
        var reopened = try RuntimeResultSinkFileV1.open(
            temporary.dir,
            epoch,
            request,
            request_epoch,
            initial_sequence,
            implementation,
            instance,
            reopen_storage.view(),
            null,
        );
        const recovered = try reopened.apply(delivery);
        try std.testing.expect(
            recovered.disposition == .applied or
                recovered.disposition == .replayed,
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            reopened.sink.appliedCount(),
        );
        const replay = try reopened.apply(delivery);
        try std.testing.expectEqual(
            ApplyDispositionV1.replayed,
            replay.disposition,
        );
        try std.testing.expectEqual(
            recovered.acknowledgement,
            replay.acknowledgement,
        );
        reopened.close();
    }
}
