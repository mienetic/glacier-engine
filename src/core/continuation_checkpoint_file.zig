//! Root-selected, copy-on-write publication for complete continuation sets.
//!
//! Checkpoint objects are encoded into one canonical immutable archive. A
//! fixed selector binds the archive root, lineage, request position, and
//! challenge. Publication writes and syncs the archive before atomically
//! renaming a selector candidate over the active selector. Recovery accepts
//! only the exact previous or successor selector.

const std = @import("std");
const platform_capabilities = @import("platform_capabilities.zig");
const capsule = @import("continuation_capsule.zig");
const sweep_file = @import("continuation_object_sweep_file.zig");
const sweep_record = @import("continuation_object_sweep_record.zig");

pub const Digest = [32]u8;
pub const set_abi: u64 = 0x4743_5345_0000_0001;
pub const selector_abi: u64 = 0x4743_5357_0000_0001;
pub const set_magic = [_]u8{ 'G', 'C', 'S', 'E', 'T', '0', '1', 0 };
pub const selector_magic = [_]u8{ 'G', 'C', 'S', 'W', 'I', 'T', '1', 0 };
pub const max_objects: usize = 8;
pub const set_header_bytes: usize = 128;
pub const set_entry_bytes: usize = 72;
pub const set_directory_bytes: usize = max_objects * set_entry_bytes;
pub const set_payload_offset: usize =
    set_header_bytes + set_directory_bytes;
pub const set_footer_bytes: usize = 32;
pub const selector_bytes: usize = 192;
pub const selector_body_bytes: usize = selector_bytes - 32;
pub const allowed_flags: u64 = 0;
pub const lock_name = ".glacier-checkpoint-lock-v1";
pub const active_selector_name = ".glacier-checkpoint-active-v1";

const set_domain = "glacier-continuation-checkpoint-set-v1\x00";
const object_domain = "glacier-continuation-checkpoint-object-v1\x00";
const selector_domain = "glacier-continuation-checkpoint-selector-v1\x00";
const max_generated_name_bytes: usize = 128;

pub const Error = sweep_file.Error || error{
    ArithmeticOverflow,
    BufferTooSmall,
    CheckpointMismatch,
    InvalidCheckpointSet,
    InvalidObject,
    InvalidSelector,
    InvalidState,
    PublicationMismatch,
    UnsafeDestination,
};

pub const ObjectKindV1 = enum(u64) {
    capsule = 1,
    ownership_manifest = 2,
    payload_snapshot = 3,
    kv_page = 4,
    runtime_state = 5,
    source_process = 6,
    extension = 7,
};

pub const MetadataV1 = struct {
    generation: u64,
    request_epoch: u64,
    publication_next_sequence: u64,
    parent_checkpoint_sha256: Digest,
    challenge_sha256: Digest,
};

pub const ObjectInputV1 = struct {
    kind: ObjectKindV1,
    ordinal: u64,
    abi_version: u64,
    bytes: []const u8,
};

pub const ObjectViewV1 = struct {
    kind: ObjectKindV1,
    ordinal: u64,
    abi_version: u64,
    bytes: []const u8,
    object_sha256: Digest,
};

pub const PreparedSetV1 = struct {
    bytes: []const u8,
    checkpoint_sha256: Digest,
};

pub const DecodedSetV1 = struct {
    metadata: MetadataV1,
    objects: [max_objects]ObjectViewV1,
    object_count: usize,
    checkpoint_sha256: Digest,

    pub fn object(
        self: *const DecodedSetV1,
        kind: ObjectKindV1,
        ordinal: u64,
    ) Error!ObjectViewV1 {
        for (self.objects[0..self.object_count]) |entry| {
            if (entry.kind == kind and entry.ordinal == ordinal)
                return entry;
        }
        return Error.InvalidObject;
    }
};

pub const PreparedSelectorV1 = struct {
    bytes: [selector_bytes]u8,
    selector_sha256: Digest,
};

pub const DecodedSelectorV1 = struct {
    generation: u64,
    request_epoch: u64,
    publication_next_sequence: u64,
    checkpoint_bytes: u64,
    previous_selector_sha256: Digest,
    checkpoint_sha256: Digest,
    challenge_sha256: Digest,
    selector_sha256: Digest,
};

pub const PreparedPublicationV1 = struct {
    set: PreparedSetV1,
    selector: PreparedSelectorV1,
};

pub const IoPhaseV1 = enum(u8) {
    archive_write,
    archive_sync,
    archive_directory_sync,
    selector_write,
    selector_sync,
    selector_rename,
    selector_directory_sync,
};

pub const ObserverV1 = struct {
    context: *anyopaque,
    after_phase_fn: *const fn (
        context: *anyopaque,
        phase: IoPhaseV1,
    ) Error!void,

    fn after(self: ObserverV1, phase: IoPhaseV1) Error!void {
        try self.after_phase_fn(self.context, phase);
    }
};

pub const ApplyDispositionV1 = enum(u8) {
    applied,
    already_applied,
};

pub const ApplyReceiptV1 = struct {
    disposition: ApplyDispositionV1,
    selector_sha256: Digest,
    checkpoint_sha256: Digest,
};

pub const LeaseStateV1 = enum(u8) {
    ready,
    poisoned,
    closed,
};

pub const LeaseV1 = struct {
    directory: std.fs.Dir,
    lock: sweep_file.FileLeaseV1,
    storage_epoch: u64,
    challenge_sha256: Digest,
    active_storage: []u8,
    active_bytes: usize,
    max_set_bytes: usize,
    selector: DecodedSelectorV1,
    state: LeaseStateV1 = .ready,

    pub fn create(
        directory: std.fs.Dir,
        storage_epoch: u64,
        challenge_sha256: Digest,
        initial_set: PreparedSetV1,
        initial_selector: PreparedSelectorV1,
        max_set_bytes: usize,
        lock_storage: []u8,
        active_storage: []u8,
    ) !LeaseV1 {
        if (comptime !platform_capabilities
            .current_adapter_availability_v1.posix_durable_file_adapter)
            return Error.UnsupportedPlatform;
        if (storage_epoch == 0 or isZero(challenge_sha256) or
            initial_set.bytes.len > max_set_bytes or
            active_storage.len < max_set_bytes)
            return Error.InvalidState;
        const set = try decodeSetV1(initial_set.bytes);
        const selector = try decodeSelectorV1(&initial_selector.bytes);
        try validatePreparedPairV1(
            initial_set,
            initial_selector,
            set,
            selector,
        );
        if (selector.generation != 1 or
            !isZero(selector.previous_selector_sha256) or
            !std.mem.eql(
                u8,
                &selector.challenge_sha256,
                &challenge_sha256,
            ))
            return Error.InvalidSelector;

        var lock = try sweep_file.FileLeaseV1.create(
            directory,
            lock_name,
            .{
                .storage_epoch = storage_epoch,
                .max_bytes = sweep_record.encoded_bytes,
            },
            lock_storage,
        );
        errdefer lock.close();
        var archive_name_storage: [max_generated_name_bytes]u8 = undefined;
        const archive_name = try archiveNameV1(
            initial_set.checkpoint_sha256,
            &archive_name_storage,
        );
        try writeNewFileV1(
            directory,
            archive_name,
            initial_set.bytes,
        );
        try syncDirectory(directory);
        try writeNewFileV1(
            directory,
            active_selector_name,
            &initial_selector.bytes,
        );
        try syncDirectory(directory);
        std.mem.copyForwards(
            u8,
            active_storage[0..initial_set.bytes.len],
            initial_set.bytes,
        );
        return .{
            .directory = directory,
            .lock = lock,
            .storage_epoch = storage_epoch,
            .challenge_sha256 = challenge_sha256,
            .active_storage = active_storage,
            .active_bytes = initial_set.bytes.len,
            .max_set_bytes = max_set_bytes,
            .selector = selector,
        };
    }

    pub fn open(
        directory: std.fs.Dir,
        storage_epoch: u64,
        challenge_sha256: Digest,
        max_set_bytes: usize,
        lock_storage: []u8,
        active_storage: []u8,
    ) !LeaseV1 {
        if (comptime !platform_capabilities
            .current_adapter_availability_v1.posix_durable_file_adapter)
            return Error.UnsupportedPlatform;
        if (storage_epoch == 0 or isZero(challenge_sha256) or
            active_storage.len < max_set_bytes)
            return Error.InvalidState;
        var lock = try sweep_file.FileLeaseV1.open(
            directory,
            lock_name,
            .{
                .storage_epoch = storage_epoch,
                .max_bytes = sweep_record.encoded_bytes,
            },
            lock_storage,
        );
        errdefer lock.close();
        const loaded = try loadActiveV1(
            directory,
            challenge_sha256,
            active_storage,
            max_set_bytes,
        );
        return .{
            .directory = directory,
            .lock = lock,
            .storage_epoch = storage_epoch,
            .challenge_sha256 = challenge_sha256,
            .active_storage = active_storage,
            .active_bytes = loaded.set_bytes,
            .max_set_bytes = max_set_bytes,
            .selector = loaded.selector,
        };
    }

    pub fn close(self: *LeaseV1) void {
        if (self.state == .closed) return;
        self.state = .closed;
        self.lock.close();
    }

    pub fn stream(self: *const LeaseV1) []const u8 {
        return self.active_storage[0..self.active_bytes];
    }

    pub fn activeSet(self: *const LeaseV1) Error!DecodedSetV1 {
        if (self.state != .ready) return Error.InvalidState;
        return decodeSetV1(self.stream());
    }

    pub fn selectorRoot(self: *const LeaseV1) Digest {
        return self.selector.selector_sha256;
    }

    fn refresh(self: *LeaseV1) !void {
        const loaded = try loadActiveV1(
            self.directory,
            self.challenge_sha256,
            self.active_storage,
            self.max_set_bytes,
        );
        self.active_bytes = loaded.set_bytes;
        self.selector = loaded.selector;
    }
};

const LoadedActiveV1 = struct {
    set_bytes: usize,
    selector: DecodedSelectorV1,
};

const OpenKind = enum {
    create,
    existing,
};

const FileViewV1 = struct {
    device: u64,
    inode: u64,
    size: usize,
};

pub fn encodeSetV1(
    metadata: MetadataV1,
    objects: []const ObjectInputV1,
    destination: []u8,
) Error!PreparedSetV1 {
    try validateMetadataV1(metadata);
    if (objects.len == 0 or objects.len > max_objects)
        return Error.InvalidCheckpointSet;
    var total = set_payload_offset + set_footer_bytes;
    for (objects, 0..) |object, index| {
        try validateObjectInputV1(object);
        if (index > 0 and !objectLessThan(
            objects[index - 1].kind,
            objects[index - 1].ordinal,
            object.kind,
            object.ordinal,
        )) return Error.InvalidObject;
        total = std.math.add(
            usize,
            total,
            object.bytes.len,
        ) catch return Error.ArithmeticOverflow;
    }
    if (destination.len < total) return Error.BufferTooSmall;
    const output = destination[0..total];
    for (objects) |object| {
        if (slicesOverlap(output, object.bytes))
            return Error.UnsafeDestination;
    }
    @memset(output, 0);
    @memcpy(output[0..8], &set_magic);
    writeU64(output, 8, set_abi);
    writeU64(output, 16, total);
    writeU64(output, 24, metadata.generation);
    writeU64(output, 32, metadata.request_epoch);
    writeU64(output, 40, metadata.publication_next_sequence);
    writeU64(output, 48, objects.len);
    writeU64(output, 56, allowed_flags);
    @memcpy(output[64..96], &metadata.parent_checkpoint_sha256);
    @memcpy(output[96..128], &metadata.challenge_sha256);

    var cursor = set_payload_offset;
    for (objects, 0..) |object, index| {
        const entry_offset = set_header_bytes + index * set_entry_bytes;
        writeU64(output, entry_offset, @intFromEnum(object.kind));
        writeU64(output, entry_offset + 8, object.ordinal);
        writeU64(output, entry_offset + 16, object.abi_version);
        writeU64(output, entry_offset + 24, cursor);
        writeU64(output, entry_offset + 32, object.bytes.len);
        const object_sha256 = objectRootV1(object);
        @memcpy(
            output[entry_offset + 40 .. entry_offset + 72],
            &object_sha256,
        );
        const end = cursor + object.bytes.len;
        @memcpy(output[cursor..end], object.bytes);
        cursor = end;
    }
    if (cursor != output.len - set_footer_bytes)
        return Error.InvalidCheckpointSet;
    const checkpoint_sha256 = checkpointRootV1(
        output[0 .. output.len - set_footer_bytes],
    );
    @memcpy(output[output.len - set_footer_bytes ..], &checkpoint_sha256);
    return .{
        .bytes = output,
        .checkpoint_sha256 = checkpoint_sha256,
    };
}

pub fn decodeSetV1(encoded: []const u8) Error!DecodedSetV1 {
    if (encoded.len < set_payload_offset + set_footer_bytes or
        !std.mem.eql(u8, encoded[0..8], &set_magic) or
        readU64(encoded, 8) != set_abi or
        readU64(encoded, 16) != encoded.len or
        readU64(encoded, 56) != allowed_flags)
        return Error.InvalidCheckpointSet;
    const object_count = std.math.cast(
        usize,
        readU64(encoded, 48),
    ) orelse return Error.InvalidCheckpointSet;
    if (object_count == 0 or object_count > max_objects)
        return Error.InvalidCheckpointSet;
    const metadata: MetadataV1 = .{
        .generation = readU64(encoded, 24),
        .request_epoch = readU64(encoded, 32),
        .publication_next_sequence = readU64(encoded, 40),
        .parent_checkpoint_sha256 = encoded[64..96].*,
        .challenge_sha256 = encoded[96..128].*,
    };
    try validateMetadataV1(metadata);
    var checkpoint_sha256: Digest = undefined;
    @memcpy(
        &checkpoint_sha256,
        encoded[encoded.len - set_footer_bytes ..],
    );
    if (!std.mem.eql(
        u8,
        &checkpoint_sha256,
        &checkpointRootV1(encoded[0 .. encoded.len - set_footer_bytes]),
    )) return Error.InvalidCheckpointSet;

    var objects: [max_objects]ObjectViewV1 = undefined;
    var cursor = set_payload_offset;
    for (0..object_count) |index| {
        const entry_offset = set_header_bytes + index * set_entry_bytes;
        const kind = std.meta.intToEnum(
            ObjectKindV1,
            readU64(encoded, entry_offset),
        ) catch return Error.InvalidObject;
        const ordinal = readU64(encoded, entry_offset + 8);
        const abi_version = readU64(encoded, entry_offset + 16);
        const payload_offset = std.math.cast(
            usize,
            readU64(encoded, entry_offset + 24),
        ) orelse return Error.InvalidObject;
        const payload_bytes = std.math.cast(
            usize,
            readU64(encoded, entry_offset + 32),
        ) orelse return Error.InvalidObject;
        if (payload_offset != cursor or payload_bytes == 0)
            return Error.InvalidObject;
        const end = std.math.add(
            usize,
            cursor,
            payload_bytes,
        ) catch return Error.ArithmeticOverflow;
        if (end > encoded.len - set_footer_bytes)
            return Error.InvalidObject;
        if (index > 0 and !objectLessThan(
            objects[index - 1].kind,
            objects[index - 1].ordinal,
            kind,
            ordinal,
        )) return Error.InvalidObject;
        var object_sha256: Digest = undefined;
        @memcpy(
            &object_sha256,
            encoded[entry_offset + 40 .. entry_offset + 72],
        );
        const view: ObjectViewV1 = .{
            .kind = kind,
            .ordinal = ordinal,
            .abi_version = abi_version,
            .bytes = encoded[cursor..end],
            .object_sha256 = object_sha256,
        };
        try validateObjectViewV1(view);
        objects[index] = view;
        cursor = end;
    }
    const unused_start = set_header_bytes + object_count * set_entry_bytes;
    if (!std.mem.allEqual(
        u8,
        encoded[unused_start..set_payload_offset],
        0,
    ) or cursor != encoded.len - set_footer_bytes)
        return Error.InvalidCheckpointSet;
    return .{
        .metadata = metadata,
        .objects = objects,
        .object_count = object_count,
        .checkpoint_sha256 = checkpoint_sha256,
    };
}

pub fn prepareInitialSelectorV1(
    set: PreparedSetV1,
) Error!PreparedSelectorV1 {
    const decoded = try decodeSetV1(set.bytes);
    if (decoded.metadata.generation != 1 or
        !isZero(decoded.metadata.parent_checkpoint_sha256))
        return Error.InvalidSelector;
    return encodeSelectorV1(capsule.zero_digest, set, decoded);
}

pub fn preparePublicationV1(
    lease: *const LeaseV1,
    set: PreparedSetV1,
) Error!PreparedPublicationV1 {
    if (lease.state != .ready) return Error.InvalidState;
    const decoded = try decodeSetV1(set.bytes);
    const next_generation = std.math.add(
        u64,
        lease.selector.generation,
        1,
    ) catch return Error.ArithmeticOverflow;
    if (decoded.metadata.generation != next_generation or
        decoded.metadata.request_epoch != lease.selector.request_epoch or
        decoded.metadata.publication_next_sequence <
            lease.selector.publication_next_sequence or
        !std.mem.eql(
            u8,
            &decoded.metadata.parent_checkpoint_sha256,
            &lease.selector.checkpoint_sha256,
        ) or
        !std.mem.eql(
            u8,
            &decoded.metadata.challenge_sha256,
            &lease.challenge_sha256,
        ))
        return Error.PublicationMismatch;
    return .{
        .set = set,
        .selector = try encodeSelectorV1(
            lease.selector.selector_sha256,
            set,
            decoded,
        ),
    };
}

pub fn decodeSelectorV1(
    encoded: []const u8,
) Error!DecodedSelectorV1 {
    if (encoded.len != selector_bytes or
        !std.mem.eql(u8, encoded[0..8], &selector_magic) or
        readU64(encoded, 8) != selector_abi or
        readU64(encoded, 16) != selector_bytes or
        readU64(encoded, 56) != allowed_flags)
        return Error.InvalidSelector;
    var selector_sha256: Digest = undefined;
    @memcpy(&selector_sha256, encoded[selector_body_bytes..]);
    if (!std.mem.eql(
        u8,
        &selector_sha256,
        &selectorRootV1(encoded[0..selector_body_bytes]),
    )) return Error.InvalidSelector;
    const decoded: DecodedSelectorV1 = .{
        .generation = readU64(encoded, 24),
        .request_epoch = readU64(encoded, 32),
        .publication_next_sequence = readU64(encoded, 40),
        .checkpoint_bytes = readU64(encoded, 48),
        .previous_selector_sha256 = encoded[64..96].*,
        .checkpoint_sha256 = encoded[96..128].*,
        .challenge_sha256 = encoded[128..160].*,
        .selector_sha256 = selector_sha256,
    };
    if (decoded.generation == 0 or decoded.request_epoch == 0 or
        decoded.publication_next_sequence == 0 or
        decoded.checkpoint_bytes <
            set_payload_offset + set_footer_bytes or
        isZero(decoded.checkpoint_sha256) or
        isZero(decoded.challenge_sha256) or
        (decoded.generation == 1 and
            !isZero(decoded.previous_selector_sha256)) or
        (decoded.generation > 1 and
            isZero(decoded.previous_selector_sha256)))
        return Error.InvalidSelector;
    return decoded;
}

pub fn publishV1(
    lease: *LeaseV1,
    prepared: PreparedPublicationV1,
) !ApplyReceiptV1 {
    return publishObservedV1(lease, prepared, null);
}

pub fn publishObservedV1(
    lease: *LeaseV1,
    prepared: PreparedPublicationV1,
    observer: ?ObserverV1,
) !ApplyReceiptV1 {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1.posix_durable_file_adapter)
        return Error.UnsupportedPlatform;
    if (lease.state != .ready) return Error.InvalidState;
    const validated = try validatePublicationForLeaseV1(lease, prepared);
    errdefer lease.state = .poisoned;
    var archive_name_storage: [max_generated_name_bytes]u8 = undefined;
    const archive_name = try archiveNameV1(
        prepared.set.checkpoint_sha256,
        &archive_name_storage,
    );
    try writeNewFileV1(lease.directory, archive_name, prepared.set.bytes);
    if (observer) |value| try value.after(.archive_write);
    try syncNamedFileV1(lease.directory, archive_name, prepared.set.bytes);
    if (observer) |value| try value.after(.archive_sync);
    try syncDirectory(lease.directory);
    if (observer) |value| try value.after(.archive_directory_sync);

    var candidate_name_storage: [max_generated_name_bytes]u8 = undefined;
    const candidate_name = try selectorCandidateNameV1(
        prepared.selector.selector_sha256,
        &candidate_name_storage,
    );
    try writeNewFileV1(
        lease.directory,
        candidate_name,
        &prepared.selector.bytes,
    );
    if (observer) |value| try value.after(.selector_write);
    try syncNamedFileV1(
        lease.directory,
        candidate_name,
        &prepared.selector.bytes,
    );
    if (observer) |value| try value.after(.selector_sync);
    try lease.directory.rename(candidate_name, active_selector_name);
    if (observer) |value| try value.after(.selector_rename);
    try syncDirectory(lease.directory);
    if (observer) |value| try value.after(.selector_directory_sync);
    try lease.refresh();
    if (!std.mem.eql(
        u8,
        &lease.selector.selector_sha256,
        &validated.selector_sha256,
    )) return Error.PublicationMismatch;
    return .{
        .disposition = .applied,
        .selector_sha256 = validated.selector_sha256,
        .checkpoint_sha256 = validated.checkpoint_sha256,
    };
}

pub fn recoverV1(
    lease: *LeaseV1,
    prepared: PreparedPublicationV1,
) !ApplyReceiptV1 {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1.posix_durable_file_adapter)
        return Error.UnsupportedPlatform;
    if (lease.state != .ready) return Error.InvalidState;
    const target = try validatePreparedPublicationV1(prepared);
    try lease.refresh();
    if (std.mem.eql(
        u8,
        &lease.selector.selector_sha256,
        &target.selector_sha256,
    )) {
        if (!std.mem.eql(
            u8,
            &lease.selector.checkpoint_sha256,
            &target.checkpoint_sha256,
        )) return Error.CheckpointMismatch;
        try syncDirectory(lease.directory);
        return .{
            .disposition = .already_applied,
            .selector_sha256 = target.selector_sha256,
            .checkpoint_sha256 = target.checkpoint_sha256,
        };
    }
    if (!std.mem.eql(
        u8,
        &lease.selector.selector_sha256,
        &target.previous_selector_sha256,
    )) return Error.PublicationMismatch;

    errdefer lease.state = .poisoned;
    var archive_name_storage: [max_generated_name_bytes]u8 = undefined;
    const archive_name = try archiveNameV1(
        prepared.set.checkpoint_sha256,
        &archive_name_storage,
    );
    try ensureExactFileV1(
        lease.directory,
        archive_name,
        prepared.set.bytes,
    );
    try syncDirectory(lease.directory);
    var candidate_name_storage: [max_generated_name_bytes]u8 = undefined;
    const candidate_name = try selectorCandidateNameV1(
        prepared.selector.selector_sha256,
        &candidate_name_storage,
    );
    try ensureExactFileV1(
        lease.directory,
        candidate_name,
        &prepared.selector.bytes,
    );
    try lease.directory.rename(candidate_name, active_selector_name);
    try syncDirectory(lease.directory);
    try lease.refresh();
    if (!std.mem.eql(
        u8,
        &lease.selector.selector_sha256,
        &target.selector_sha256,
    )) return Error.PublicationMismatch;
    return .{
        .disposition = .applied,
        .selector_sha256 = target.selector_sha256,
        .checkpoint_sha256 = target.checkpoint_sha256,
    };
}

pub fn checkpointRootV1(body: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(set_domain);
    hash.update(body);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

pub fn selectorRootV1(body: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(selector_domain);
    hash.update(body);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

pub fn objectRootV1(object: ObjectInputV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(object_domain);
    hashU64(&hash, @intFromEnum(object.kind));
    hashU64(&hash, object.ordinal);
    hashU64(&hash, object.abi_version);
    hashU64(&hash, object.bytes.len);
    hash.update(object.bytes);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn encodeSelectorV1(
    previous_selector_sha256: Digest,
    set: PreparedSetV1,
    decoded: DecodedSetV1,
) Error!PreparedSelectorV1 {
    if (!std.mem.eql(
        u8,
        &decoded.checkpoint_sha256,
        &set.checkpoint_sha256,
    )) return Error.InvalidCheckpointSet;
    var output = [_]u8{0} ** selector_bytes;
    @memcpy(output[0..8], &selector_magic);
    writeU64(&output, 8, selector_abi);
    writeU64(&output, 16, selector_bytes);
    writeU64(&output, 24, decoded.metadata.generation);
    writeU64(&output, 32, decoded.metadata.request_epoch);
    writeU64(&output, 40, decoded.metadata.publication_next_sequence);
    writeU64(&output, 48, set.bytes.len);
    writeU64(&output, 56, allowed_flags);
    @memcpy(output[64..96], &previous_selector_sha256);
    @memcpy(output[96..128], &set.checkpoint_sha256);
    @memcpy(output[128..160], &decoded.metadata.challenge_sha256);
    const selector_sha256 = selectorRootV1(
        output[0..selector_body_bytes],
    );
    @memcpy(output[selector_body_bytes..], &selector_sha256);
    return .{
        .bytes = output,
        .selector_sha256 = selector_sha256,
    };
}

fn validatePreparedPairV1(
    prepared_set: PreparedSetV1,
    prepared_selector: PreparedSelectorV1,
    set: DecodedSetV1,
    selector: DecodedSelectorV1,
) Error!void {
    if (!std.mem.eql(
        u8,
        &prepared_set.checkpoint_sha256,
        &set.checkpoint_sha256,
    ) or !std.mem.eql(
        u8,
        &prepared_selector.selector_sha256,
        &selector.selector_sha256,
    ) or selector.generation != set.metadata.generation or
        selector.request_epoch != set.metadata.request_epoch or
        selector.publication_next_sequence !=
            set.metadata.publication_next_sequence or
        selector.checkpoint_bytes != prepared_set.bytes.len or
        !std.mem.eql(
            u8,
            &selector.checkpoint_sha256,
            &set.checkpoint_sha256,
        ) or
        !std.mem.eql(
            u8,
            &selector.challenge_sha256,
            &set.metadata.challenge_sha256,
        ))
        return Error.CheckpointMismatch;
}

fn validatePreparedPublicationV1(
    prepared: PreparedPublicationV1,
) Error!DecodedSelectorV1 {
    const set = try decodeSetV1(prepared.set.bytes);
    const selector = try decodeSelectorV1(&prepared.selector.bytes);
    try validatePreparedPairV1(
        prepared.set,
        prepared.selector,
        set,
        selector,
    );
    return selector;
}

fn validatePublicationForLeaseV1(
    lease: *const LeaseV1,
    prepared: PreparedPublicationV1,
) Error!DecodedSelectorV1 {
    const selector = try validatePreparedPublicationV1(prepared);
    const set = try decodeSetV1(prepared.set.bytes);
    const next_generation = std.math.add(
        u64,
        lease.selector.generation,
        1,
    ) catch return Error.ArithmeticOverflow;
    if (selector.generation != next_generation or
        selector.request_epoch != lease.selector.request_epoch or
        selector.publication_next_sequence <
            lease.selector.publication_next_sequence or
        !std.mem.eql(
            u8,
            &selector.previous_selector_sha256,
            &lease.selector.selector_sha256,
        ) or
        !std.mem.eql(
            u8,
            &set.metadata.parent_checkpoint_sha256,
            &lease.selector.checkpoint_sha256,
        ) or
        !std.mem.eql(
            u8,
            &selector.challenge_sha256,
            &lease.challenge_sha256,
        ))
        return Error.PublicationMismatch;
    return selector;
}

fn validateMetadataV1(metadata: MetadataV1) Error!void {
    if (metadata.generation == 0 or metadata.request_epoch == 0 or
        metadata.publication_next_sequence == 0 or
        isZero(metadata.challenge_sha256) or
        (metadata.generation == 1 and
            !isZero(metadata.parent_checkpoint_sha256)) or
        (metadata.generation > 1 and
            isZero(metadata.parent_checkpoint_sha256)))
        return Error.InvalidCheckpointSet;
}

fn validateObjectInputV1(object: ObjectInputV1) Error!void {
    if (object.abi_version == 0 or object.bytes.len == 0)
        return Error.InvalidObject;
}

fn validateObjectViewV1(object: ObjectViewV1) Error!void {
    const input: ObjectInputV1 = .{
        .kind = object.kind,
        .ordinal = object.ordinal,
        .abi_version = object.abi_version,
        .bytes = object.bytes,
    };
    try validateObjectInputV1(input);
    if (!std.mem.eql(
        u8,
        &object.object_sha256,
        &objectRootV1(input),
    )) return Error.InvalidObject;
}

fn objectLessThan(
    left_kind: ObjectKindV1,
    left_ordinal: u64,
    right_kind: ObjectKindV1,
    right_ordinal: u64,
) bool {
    const left = @intFromEnum(left_kind);
    const right = @intFromEnum(right_kind);
    return left < right or
        (left == right and left_ordinal < right_ordinal);
}

fn loadActiveV1(
    directory: std.fs.Dir,
    challenge_sha256: Digest,
    active_storage: []u8,
    max_set_bytes: usize,
) !LoadedActiveV1 {
    var selector_storage: [selector_bytes]u8 = undefined;
    const selector_wire = try readExactFileV1(
        directory,
        active_selector_name,
        &selector_storage,
        selector_bytes,
    );
    const selector = try decodeSelectorV1(selector_wire);
    if (!std.mem.eql(
        u8,
        &selector.challenge_sha256,
        &challenge_sha256,
    )) return Error.CheckpointMismatch;
    var archive_name_storage: [max_generated_name_bytes]u8 = undefined;
    const archive_name = try archiveNameV1(
        selector.checkpoint_sha256,
        &archive_name_storage,
    );
    const set_wire = try readExactFileV1(
        directory,
        archive_name,
        active_storage,
        max_set_bytes,
    );
    const set = try decodeSetV1(set_wire);
    const prepared_set: PreparedSetV1 = .{
        .bytes = set_wire,
        .checkpoint_sha256 = set.checkpoint_sha256,
    };
    const prepared_selector: PreparedSelectorV1 = .{
        .bytes = selector_storage,
        .selector_sha256 = selector.selector_sha256,
    };
    try validatePreparedPairV1(
        prepared_set,
        prepared_selector,
        set,
        selector,
    );
    return .{
        .set_bytes = set_wire.len,
        .selector = selector,
    };
}

fn archiveNameV1(
    checkpoint_sha256: Digest,
    storage: []u8,
) ![]const u8 {
    const hex = std.fmt.bytesToHex(checkpoint_sha256, .lower);
    return std.fmt.bufPrint(storage, "checkpoint-{s}.set", .{&hex});
}

fn selectorCandidateNameV1(
    selector_sha256: Digest,
    storage: []u8,
) ![]const u8 {
    const hex = std.fmt.bytesToHex(selector_sha256, .lower);
    return std.fmt.bufPrint(
        storage,
        "checkpoint-switch-{s}.candidate",
        .{&hex},
    );
}

fn writeNewFileV1(
    directory: std.fs.Dir,
    name: []const u8,
    bytes: []const u8,
) !void {
    const file = try openSafeFileV1(directory, name, .create);
    defer file.close();
    try file.writeAll(bytes);
    const view = try inspectFileV1(file, directory, name);
    if (view.size != bytes.len) return Error.StorageIdentityChanged;
}

fn syncNamedFileV1(
    directory: std.fs.Dir,
    name: []const u8,
    expected: []const u8,
) !void {
    const file = try openSafeFileV1(directory, name, .existing);
    defer file.close();
    const before = try inspectFileV1(file, directory, name);
    if (before.size != expected.len)
        return Error.StorageIdentityChanged;
    try file.sync();
    if (!try fileContentsEqualV1(file, expected))
        return Error.StorageIdentityChanged;
    const after = try inspectFileV1(file, directory, name);
    if (!std.meta.eql(before, after))
        return Error.StorageIdentityChanged;
}

fn ensureExactFileV1(
    directory: std.fs.Dir,
    name: []const u8,
    expected: []const u8,
) !void {
    const file = openSafeFileV1(directory, name, .create) catch |err| switch (err) {
        error.PathAlreadyExists => try openSafeFileV1(
            directory,
            name,
            .existing,
        ),
        else => return err,
    };
    defer file.close();
    const before = try inspectFileV1(file, directory, name);
    if (before.size != expected.len or
        !try fileContentsEqualV1(file, expected))
    {
        try file.setEndPos(0);
        try file.pwriteAll(expected, 0);
        try file.setEndPos(expected.len);
    }
    if (!try fileContentsEqualV1(file, expected))
        return Error.StorageIdentityChanged;
    try file.sync();
    const after = try inspectFileV1(file, directory, name);
    if (after.size != expected.len or
        before.device != after.device or
        before.inode != after.inode)
        return Error.StorageIdentityChanged;
}

fn fileContentsEqualV1(
    file: std.fs.File,
    expected: []const u8,
) !bool {
    var storage: [4096]u8 = undefined;
    var offset: usize = 0;
    while (offset < expected.len) {
        const chunk_bytes = @min(storage.len, expected.len - offset);
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
    max_bytes: usize,
) ![]const u8 {
    const file = try openSafeFileV1(directory, name, .existing);
    defer file.close();
    const before = try inspectFileV1(file, directory, name);
    if (before.size > max_bytes or before.size > storage.len)
        return Error.BufferTooSmall;
    const encoded = storage[0..before.size];
    if (try file.preadAll(encoded, 0) != encoded.len)
        return Error.StorageIo;
    const after = try inspectFileV1(file, directory, name);
    if (!std.meta.eql(before, after))
        return Error.StorageIdentityChanged;
    return encoded;
}

fn openSafeFileV1(
    directory: std.fs.Dir,
    name: []const u8,
    kind: OpenKind,
) !std.fs.File {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1.posix_durable_file_adapter)
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

fn syncDirectory(directory: std.fs.Dir) !void {
    try std.posix.fsync(directory.fd);
}

fn writeU64(output: []u8, offset: usize, value: anytype) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @intCast(value), .little);
    @memcpy(output[offset .. offset + 8], &bytes);
}

fn readU64(input: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, input[offset .. offset + 8][0..8], .little);
}

fn hashU64(hash: *std.crypto.hash.sha2.Sha256, value: anytype) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @intCast(value), .little);
    hash.update(&bytes);
}

fn isZero(value: Digest) bool {
    return std.mem.allEqual(u8, &value, 0);
}

fn slicesOverlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    const a_end = std.math.add(usize, a_start, a.len) catch return true;
    const b_end = std.math.add(usize, b_start, b.len) catch return true;
    return a_start < b_end and b_start < a_end;
}

test "checkpoint set and selector are canonical and mutation complete" {
    const objects = [_]ObjectInputV1{
        .{
            .kind = .capsule,
            .ordinal = 0,
            .abi_version = 11,
            .bytes = "capsule-fixture",
        },
        .{
            .kind = .runtime_state,
            .ordinal = 0,
            .abi_version = 12,
            .bytes = "runtime-fixture",
        },
    };
    var storage: [1024]u8 = undefined;
    const prepared = try encodeSetV1(.{
        .generation = 1,
        .request_epoch = 71,
        .publication_next_sequence = 17,
        .parent_checkpoint_sha256 = capsule.zero_digest,
        .challenge_sha256 = [_]u8{0x53} ** 32,
    }, &objects, &storage);
    const decoded = try decodeSetV1(prepared.bytes);
    try std.testing.expectEqual(@as(usize, 2), decoded.object_count);
    try std.testing.expectEqualStrings(
        "runtime-fixture",
        (try decoded.object(.runtime_state, 0)).bytes,
    );
    const selector = try prepareInitialSelectorV1(prepared);
    _ = try decodeSelectorV1(&selector.bytes);
    var expected_set: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_set,
        "28a31df6cf0972481ce2e17b3fb0b54f" ++
            "217c3c54025d746f05fe93b58ea697dc",
    );
    var expected_selector: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_selector,
        "789052b3ce4994889bee859e3f180b576" ++
            "bd26ce89ab8b90b51f9c8aae55a43df",
    );
    try std.testing.expectEqualSlices(
        u8,
        &expected_set,
        &prepared.checkpoint_sha256,
    );
    try std.testing.expectEqualSlices(
        u8,
        &expected_selector,
        &selector.selector_sha256,
    );

    var corrupted: [1024]u8 = undefined;
    for (0..prepared.bytes.len) |index| {
        @memcpy(corrupted[0..prepared.bytes.len], prepared.bytes);
        corrupted[index] ^= 1;
        const accepted = if (decodeSetV1(
            corrupted[0..prepared.bytes.len],
        )) |_| true else |_| false;
        try std.testing.expect(!accepted);
    }
    @memcpy(corrupted[0..prepared.bytes.len], prepared.bytes);
    writeU64(corrupted[0..prepared.bytes.len], 56, 1);
    const rerooted_set = checkpointRootV1(
        corrupted[0 .. prepared.bytes.len - set_footer_bytes],
    );
    @memcpy(
        corrupted[prepared.bytes.len - set_footer_bytes .. prepared.bytes.len],
        &rerooted_set,
    );
    try std.testing.expectError(
        Error.InvalidCheckpointSet,
        decodeSetV1(corrupted[0..prepared.bytes.len]),
    );
    var selector_corrupted = selector.bytes;
    for (0..selector_corrupted.len) |index| {
        selector_corrupted = selector.bytes;
        selector_corrupted[index] ^= 1;
        const accepted = if (decodeSelectorV1(
            &selector_corrupted,
        )) |_| true else |_| false;
        try std.testing.expect(!accepted);
    }
    selector_corrupted = selector.bytes;
    writeU64(&selector_corrupted, 56, 1);
    const rerooted_selector = selectorRootV1(
        selector_corrupted[0..selector_body_bytes],
    );
    @memcpy(
        selector_corrupted[selector_body_bytes..],
        &rerooted_selector,
    );
    try std.testing.expectError(
        Error.InvalidSelector,
        decodeSelectorV1(&selector_corrupted),
    );
}

test "checkpoint selector promotion recovers exact previous or successor" {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1.posix_durable_file_adapter)
        return error.SkipZigTest;
    const testing = std.testing;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const challenge = [_]u8{0x63} ** 32;
    const first_objects = [_]ObjectInputV1{.{
        .kind = .capsule,
        .ordinal = 0,
        .abi_version = 1,
        .bytes = "checkpoint-one",
    }};
    var first_storage: [1024]u8 = undefined;
    const first = try encodeSetV1(.{
        .generation = 1,
        .request_epoch = 71,
        .publication_next_sequence = 17,
        .parent_checkpoint_sha256 = capsule.zero_digest,
        .challenge_sha256 = challenge,
    }, &first_objects, &first_storage);
    const first_selector = try prepareInitialSelectorV1(first);
    var lock_storage: [1]u8 = undefined;
    var active_storage: [1024]u8 = undefined;
    var lease = try LeaseV1.create(
        temporary.dir,
        9001,
        challenge,
        first,
        first_selector,
        active_storage.len,
        &lock_storage,
        &active_storage,
    );
    const second_objects = [_]ObjectInputV1{.{
        .kind = .capsule,
        .ordinal = 0,
        .abi_version = 1,
        .bytes = "checkpoint-two",
    }};
    var second_storage: [1024]u8 = undefined;
    const second = try encodeSetV1(.{
        .generation = 2,
        .request_epoch = 71,
        .publication_next_sequence = 18,
        .parent_checkpoint_sha256 = first.checkpoint_sha256,
        .challenge_sha256 = challenge,
    }, &second_objects, &second_storage);
    const publication = try preparePublicationV1(&lease, second);
    const applied = try publishV1(&lease, publication);
    try testing.expectEqual(ApplyDispositionV1.applied, applied.disposition);
    try testing.expectEqualStrings(
        "checkpoint-two",
        (try (try lease.activeSet()).object(.capsule, 0)).bytes,
    );
    lease.close();

    var reopened_lock: [1]u8 = undefined;
    var reopened_storage: [1024]u8 = undefined;
    var reopened = try LeaseV1.open(
        temporary.dir,
        9001,
        challenge,
        reopened_storage.len,
        &reopened_lock,
        &reopened_storage,
    );
    defer reopened.close();
    const repeated = try recoverV1(&reopened, publication);
    try testing.expectEqual(
        ApplyDispositionV1.already_applied,
        repeated.disposition,
    );
}

test "checkpoint recovery repairs only the prepared inactive successor" {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1.posix_durable_file_adapter)
        return error.SkipZigTest;
    const testing = std.testing;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const challenge = [_]u8{0x64} ** 32;
    const first_objects = [_]ObjectInputV1{.{
        .kind = .extension,
        .ordinal = 0,
        .abi_version = 1,
        .bytes = "previous",
    }};
    var first_storage: [1024]u8 = undefined;
    const first = try encodeSetV1(.{
        .generation = 1,
        .request_epoch = 72,
        .publication_next_sequence = 5,
        .parent_checkpoint_sha256 = capsule.zero_digest,
        .challenge_sha256 = challenge,
    }, &first_objects, &first_storage);
    const first_selector = try prepareInitialSelectorV1(first);
    var lock_storage: [1]u8 = undefined;
    var active_storage: [1024]u8 = undefined;
    var lease = try LeaseV1.create(
        temporary.dir,
        9002,
        challenge,
        first,
        first_selector,
        active_storage.len,
        &lock_storage,
        &active_storage,
    );
    defer lease.close();
    const next_objects = [_]ObjectInputV1{.{
        .kind = .extension,
        .ordinal = 0,
        .abi_version = 1,
        .bytes = "successor",
    }};
    var next_storage: [1024]u8 = undefined;
    const next = try encodeSetV1(.{
        .generation = 2,
        .request_epoch = 72,
        .publication_next_sequence = 6,
        .parent_checkpoint_sha256 = first.checkpoint_sha256,
        .challenge_sha256 = challenge,
    }, &next_objects, &next_storage);
    const publication = try preparePublicationV1(&lease, next);
    var archive_name_storage: [max_generated_name_bytes]u8 = undefined;
    const archive_name = try archiveNameV1(
        next.checkpoint_sha256,
        &archive_name_storage,
    );
    const partial_archive = try openSafeFileV1(
        temporary.dir,
        archive_name,
        .create,
    );
    try partial_archive.writeAll(next.bytes[0..17]);
    partial_archive.close();
    var candidate_name_storage: [max_generated_name_bytes]u8 = undefined;
    const candidate_name = try selectorCandidateNameV1(
        publication.selector.selector_sha256,
        &candidate_name_storage,
    );
    const corrupt_candidate = try openSafeFileV1(
        temporary.dir,
        candidate_name,
        .create,
    );
    var corrupt = publication.selector.bytes;
    corrupt[31] ^= 1;
    try corrupt_candidate.writeAll(&corrupt);
    corrupt_candidate.close();

    const recovered = try recoverV1(&lease, publication);
    try testing.expectEqual(ApplyDispositionV1.applied, recovered.disposition);
    try testing.expectEqualStrings(
        "successor",
        (try (try lease.activeSet()).object(.extension, 0)).bytes,
    );
}
