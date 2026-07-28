//! Root-selected, copy-on-write publication for complete continuation sets.
//!
//! Checkpoint objects are encoded into one canonical immutable archive. A
//! fixed selector binds the archive root, lineage, request position, and
//! challenge. Publication writes and syncs the archive before atomically
//! renaming a selector candidate over the active selector. Recovery accepts
//! only the exact previous or successor selector.

const std = @import("std");
const builtin = @import("builtin");
const platform_capabilities = @import("platform_capabilities.zig");
const capsule = @import("continuation_capsule.zig");
const sweep_file = @import("continuation_object_sweep_file.zig");
const sweep_record = @import("continuation_object_sweep_record.zig");

extern "c" fn renameatx_np(
    old_directory: std.posix.fd_t,
    old_name: [*:0]const u8,
    new_directory: std.posix.fd_t,
    new_name: [*:0]const u8,
    flags: c_uint,
) c_int;

pub const Digest = [32]u8;
pub const set_abi: u64 = 0x4743_5345_0000_0001;
pub const selector_abi: u64 = 0x4743_5357_0000_0001;
pub const consumer_claim_abi: u64 = 0x4743_5343_0000_0001;
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
/// Strict initial recovery needs an atomic no-replace rename in addition to the
/// baseline durable POSIX file adapter.
pub const initial_recovery_available_v1 =
    platform_capabilities.current_adapter_availability_v1
        .posix_durable_file_adapter and
    switch (builtin.os.tag) {
        .linux, .macos, .ios => true,
        else => false,
    };

const set_domain = "glacier-continuation-checkpoint-set-v1\x00";
const object_domain = "glacier-continuation-checkpoint-object-v1\x00";
const selector_domain = "glacier-continuation-checkpoint-selector-v1\x00";
const consumer_claim_domain =
    "glacier-continuation-checkpoint-consumer-claim-v1\x00";
const max_generated_name_bytes: usize = 128;

pub const Error = sweep_file.Error || error{
    ArithmeticOverflow,
    BufferTooSmall,
    CheckpointMismatch,
    InvalidCheckpointSet,
    InvalidObject,
    InvalidSelector,
    InvalidState,
    ConsumerClaimInFlight,
    StaleConsumerClaim,
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

/// Verified immutable archive retained beneath a live checkpoint-file lease.
/// `bytes` and every object slice in `set` borrow caller-owned `storage`.
pub const LoadedRetainedSetV1 = struct {
    bytes: []const u8,
    set: DecodedSetV1,
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

pub const InitialDispositionV1 = enum(u8) {
    /// This call created the lock and both candidate-to-final publications.
    created,
    /// This call completed a pre-existing lock, final archive, or candidate.
    recovered,
    /// The exact active selector/archive pair existed when the lock was taken.
    already_selected,
};

pub const LeaseStateV1 = enum(u8) {
    ready,
    poisoned,
    closed,
};

/// Process-local, address-fenced claim over one lease-selected lineage. It is
/// deliberately not durable evidence; the OS file lease remains the
/// cross-process exclusion authority.
pub const ConsumerClaimV1 = struct {
    abi_version: u64 = consumer_claim_abi,
    lease_address: usize = 0,
    owner_address: usize = 0,
    claim_generation: u64 = 0,
    selector_generation: u64 = 0,
    selector_sha256: Digest = [_]u8{0} ** 32,
    claim_sha256: Digest = [_]u8{0} ** 32,
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
    next_consumer_claim_generation: u64 = 1,
    consumer_claim: ?ConsumerClaimV1 = null,
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

    pub fn createOrRecoverInitialV1(
        directory: std.fs.Dir,
        storage_epoch: u64,
        challenge_sha256: Digest,
        initial_set: PreparedSetV1,
        initial_selector: PreparedSelectorV1,
        max_set_bytes: usize,
        lock_storage: []u8,
        active_storage: []u8,
    ) !InitialLeaseResultV1 {
        return createOrRecoverInitialObservedV1(
            directory,
            storage_epoch,
            challenge_sha256,
            initial_set,
            initial_selector,
            max_set_bytes,
            lock_storage,
            active_storage,
            null,
        );
    }

    /// Create or recover the exact generation-one selector under one
    /// create-or-open exclusive lock. Candidate files may be repaired because
    /// they are not authority. A mismatched immutable archive or any partial or
    /// foreign active selector is rejected without rewriting either final.
    pub fn createOrRecoverInitialObservedV1(
        directory: std.fs.Dir,
        storage_epoch: u64,
        challenge_sha256: Digest,
        initial_set: PreparedSetV1,
        initial_selector: PreparedSelectorV1,
        max_set_bytes: usize,
        lock_storage: []u8,
        active_storage: []u8,
        observer: ?ObserverV1,
    ) !InitialLeaseResultV1 {
        if (comptime !initial_recovery_available_v1)
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
        if (set.metadata.generation != 1 or
            !isZero(set.metadata.parent_checkpoint_sha256) or
            selector.generation != 1 or
            !isZero(selector.previous_selector_sha256) or
            !std.mem.eql(
                u8,
                &selector.challenge_sha256,
                &challenge_sha256,
            ))
            return Error.InvalidSelector;

        const lock_options: sweep_file.AcquireOptionsV1 = .{
            .storage_epoch = storage_epoch,
            .max_bytes = sweep_record.encoded_bytes,
        };
        var lock_created = true;
        var lock = sweep_file.FileLeaseV1.create(
            directory,
            lock_name,
            lock_options,
            lock_storage,
        ) catch |err| switch (err) {
            error.PathAlreadyExists => opened: {
                lock_created = false;
                break :opened try sweep_file.FileLeaseV1.open(
                    directory,
                    lock_name,
                    lock_options,
                    lock_storage,
                );
            },
            else => return err,
        };
        errdefer lock.close();
        if (lock.stream().len != 0)
            return Error.StorageIdentityChanged;

        var archive_name_storage: [max_generated_name_bytes]u8 =
            undefined;
        const archive_name = try archiveNameV1(
            initial_set.checkpoint_sha256,
            &archive_name_storage,
        );
        var archive_candidate_storage: [
            max_generated_name_bytes
        ]u8 = undefined;
        const archive_candidate = try archiveCandidateNameV1(
            initial_set.checkpoint_sha256,
            &archive_candidate_storage,
        );
        var selector_candidate_storage: [
            max_generated_name_bytes
        ]u8 = undefined;
        const selector_candidate = try selectorCandidateNameV1(
            initial_selector.selector_sha256,
            &selector_candidate_storage,
        );
        try auditInitialNamespaceV1(
            directory,
            archive_name,
            archive_candidate,
            selector_candidate,
        );
        const active_state = try exactFileStateV1(
            directory,
            active_selector_name,
            &initial_selector.bytes,
        );
        switch (active_state) {
            .mismatched => return Error.InvalidSelector,
            .exact => {
                if (try exactFileStateV1(
                    directory,
                    archive_name,
                    initial_set.bytes,
                ) != .exact)
                    return Error.CheckpointMismatch;
                try syncNamedFileV1(
                    directory,
                    archive_name,
                    initial_set.bytes,
                );
                try syncNamedFileV1(
                    directory,
                    active_selector_name,
                    &initial_selector.bytes,
                );
                try syncDirectory(directory);
                try auditInitialNamespaceV1(
                    directory,
                    archive_name,
                    archive_candidate,
                    selector_candidate,
                );
                const lease = try initializedLeaseV1(
                    directory,
                    lock,
                    storage_epoch,
                    challenge_sha256,
                    initial_set,
                    initial_selector,
                    max_set_bytes,
                    active_storage,
                );
                return .{
                    .lease = lease,
                    .disposition = .already_selected,
                };
            },
            .missing => {},
        }

        var recovered_debris = !lock_created;
        switch (try exactFileStateV1(
            directory,
            archive_name,
            initial_set.bytes,
        )) {
            .mismatched => return Error.CheckpointMismatch,
            .exact => {
                recovered_debris = true;
                try syncNamedFileV1(
                    directory,
                    archive_name,
                    initial_set.bytes,
                );
                try syncDirectory(directory);
            },
            .missing => {
                recovered_debris = (try publishInitialCandidateV1(
                    directory,
                    archive_candidate,
                    archive_name,
                    initial_set.bytes,
                    .archive_write,
                    .archive_sync,
                    null,
                    .archive_directory_sync,
                    observer,
                )) or recovered_debris;
            },
        }

        try auditInitialNamespaceV1(
            directory,
            archive_name,
            archive_candidate,
            selector_candidate,
        );
        if (try exactFileStateV1(
            directory,
            active_selector_name,
            &initial_selector.bytes,
        ) != .missing)
            return Error.PublicationMismatch;
        recovered_debris = (try publishInitialCandidateV1(
            directory,
            selector_candidate,
            active_selector_name,
            &initial_selector.bytes,
            .selector_write,
            .selector_sync,
            .selector_rename,
            .selector_directory_sync,
            observer,
        )) or recovered_debris;
        try auditInitialNamespaceV1(
            directory,
            archive_name,
            archive_candidate,
            selector_candidate,
        );

        const lease = try initializedLeaseV1(
            directory,
            lock,
            storage_epoch,
            challenge_sha256,
            initial_set,
            initial_selector,
            max_set_bytes,
            active_storage,
        );
        return .{
            .lease = lease,
            .disposition = if (recovered_debris)
                .recovered
            else
                .created,
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
        if (self.consumer_claim != null)
            @panic("checkpoint lease closed with a live consumer claim");
        self.state = .closed;
        self.lock.close();
    }

    pub fn beginConsumerClaimV1(
        self: *LeaseV1,
        owner_address: usize,
    ) Error!ConsumerClaimV1 {
        if (self.state != .ready or owner_address == 0)
            return Error.InvalidState;
        if (self.consumer_claim != null)
            return Error.ConsumerClaimInFlight;
        if (self.next_consumer_claim_generation == 0 or
            self.next_consumer_claim_generation ==
                std.math.maxInt(u64))
            return Error.ArithmeticOverflow;
        var claim: ConsumerClaimV1 = .{
            .lease_address = @intFromPtr(self),
            .owner_address = owner_address,
            .claim_generation = self.next_consumer_claim_generation,
            .selector_generation = self.selector.generation,
            .selector_sha256 = self.selector.selector_sha256,
        };
        claim.claim_sha256 = consumerClaimRootV1(claim);
        self.next_consumer_claim_generation += 1;
        self.consumer_claim = claim;
        return claim;
    }

    pub fn validateConsumerClaimV1(
        self: *const LeaseV1,
        claim: ConsumerClaimV1,
    ) Error!void {
        if (self.state != .ready)
            return Error.InvalidState;
        const pending = self.consumer_claim orelse
            return Error.StaleConsumerClaim;
        if (!consumerClaimValidForLeaseV1(self, claim) or
            !std.meta.eql(pending, claim) or
            self.selector.generation !=
                claim.selector_generation or
            !std.mem.eql(
                u8,
                &self.selector.selector_sha256,
                &claim.selector_sha256,
            ))
            return Error.StaleConsumerClaim;
    }

    /// Advance a retained claim after this same lease publishes the immediate
    /// successor selector. The update is allocation-free and cannot perform
    /// I/O; callers should treat failure after successful publication as
    /// fail-stop corruption.
    pub fn advanceConsumerClaimV1(
        self: *LeaseV1,
        claim: ConsumerClaimV1,
    ) Error!ConsumerClaimV1 {
        if (self.state != .ready)
            return Error.InvalidState;
        const pending = self.consumer_claim orelse
            return Error.StaleConsumerClaim;
        if (!consumerClaimValidForLeaseV1(self, claim) or
            !std.meta.eql(pending, claim))
            return Error.StaleConsumerClaim;
        const next_generation = std.math.add(
            u64,
            claim.selector_generation,
            1,
        ) catch return Error.ArithmeticOverflow;
        if (self.selector.generation != next_generation or
            !std.mem.eql(
                u8,
                &self.selector.previous_selector_sha256,
                &claim.selector_sha256,
            ))
            return Error.StaleConsumerClaim;
        var advanced = claim;
        advanced.selector_generation = self.selector.generation;
        advanced.selector_sha256 = self.selector.selector_sha256;
        advanced.claim_sha256 =
            consumerClaimRootV1(advanced);
        self.consumer_claim = advanced;
        return advanced;
    }

    pub fn releaseConsumerClaimV1(
        self: *LeaseV1,
        claim: ConsumerClaimV1,
    ) Error!void {
        try self.validateConsumerClaimV1(claim);
        self.consumer_claim = null;
    }

    pub fn stream(self: *const LeaseV1) []const u8 {
        return self.active_storage[0..self.active_bytes];
    }

    pub fn activeSet(self: *const LeaseV1) Error!DecodedSetV1 {
        if (self.state != .ready) return Error.InvalidState;
        return decodeSetV1(self.stream());
    }

    /// Load one content-addressed predecessor archive while this lease keeps
    /// the directory lineage exclusive. The expected root chooses the file
    /// name but never bypasses full wire/root verification.
    pub fn loadRetainedSetV1(
        self: *const LeaseV1,
        expected_checkpoint_sha256: Digest,
        storage: []u8,
    ) !LoadedRetainedSetV1 {
        if (self.state != .ready or
            isZero(expected_checkpoint_sha256))
            return Error.InvalidState;
        if (slicesOverlap(storage, self.active_storage))
            return Error.UnsafeDestination;
        var archive_name_storage: [max_generated_name_bytes]u8 =
            undefined;
        const archive_name = archiveNameV1(
            expected_checkpoint_sha256,
            &archive_name_storage,
        ) catch return Error.InvalidState;
        const bytes = try readExactFileV1(
            self.directory,
            archive_name,
            storage,
            self.max_set_bytes,
        );
        const set = try decodeSetV1(bytes);
        if (!std.mem.eql(
            u8,
            &set.checkpoint_sha256,
            &expected_checkpoint_sha256,
        ))
            return Error.CheckpointMismatch;
        return .{ .bytes = bytes, .set = set };
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

pub const InitialLeaseResultV1 = struct {
    lease: LeaseV1,
    disposition: InitialDispositionV1,
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

const ExactFileStateV1 = enum {
    missing,
    exact,
    mismatched,
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

pub fn consumerClaimRootV1(
    claim: ConsumerClaimV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(consumer_claim_domain);
    hashU64(&hash, claim.abi_version);
    hashU64(
        &hash,
        @as(u64, @intCast(claim.lease_address)),
    );
    hashU64(
        &hash,
        @as(u64, @intCast(claim.owner_address)),
    );
    hashU64(&hash, claim.claim_generation);
    hashU64(&hash, claim.selector_generation);
    hash.update(&claim.selector_sha256);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn consumerClaimValidForLeaseV1(
    lease: *const LeaseV1,
    claim: ConsumerClaimV1,
) bool {
    return claim.abi_version == consumer_claim_abi and
        claim.lease_address == @intFromPtr(lease) and
        claim.owner_address != 0 and
        claim.claim_generation != 0 and
        claim.selector_generation != 0 and
        !isZero(claim.selector_sha256) and
        !isZero(claim.claim_sha256) and
        std.mem.eql(
            u8,
            &claim.claim_sha256,
            &consumerClaimRootV1(claim),
        );
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

fn initializedLeaseV1(
    directory: std.fs.Dir,
    lock: sweep_file.FileLeaseV1,
    storage_epoch: u64,
    challenge_sha256: Digest,
    initial_set: PreparedSetV1,
    initial_selector: PreparedSelectorV1,
    max_set_bytes: usize,
    active_storage: []u8,
) !LeaseV1 {
    const loaded = try loadActiveV1(
        directory,
        challenge_sha256,
        active_storage,
        max_set_bytes,
    );
    if (loaded.set_bytes != initial_set.bytes.len or
        !std.mem.eql(
            u8,
            &loaded.selector.selector_sha256,
            &initial_selector.selector_sha256,
        ) or !std.mem.eql(
        u8,
        &loaded.selector.checkpoint_sha256,
        &initial_set.checkpoint_sha256,
    ))
        return Error.CheckpointMismatch;
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

fn exactFileStateV1(
    directory: std.fs.Dir,
    name: []const u8,
    expected: []const u8,
) !ExactFileStateV1 {
    const file = openSafeFileV1(
        directory,
        name,
        .existing,
    ) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => return err,
    };
    defer file.close();
    const before = try inspectFileV1(file, directory, name);
    const exact = before.size == expected.len and
        try fileContentsEqualV1(file, expected);
    const after = try inspectFileV1(file, directory, name);
    if (!std.meta.eql(before, after))
        return Error.StorageIdentityChanged;
    return if (exact) .exact else .mismatched;
}

/// Initialization owns a closed namespace: only the exact generation-one
/// archive/candidates may coexist with its lock and active selector. Refusing
/// every other reserved name observed while the directory lease is held stops
/// a missing or rolled-back selector from hiding a durable successor.
fn auditInitialNamespaceV1(
    directory: std.fs.Dir,
    archive_name: []const u8,
    archive_candidate: []const u8,
    selector_candidate: []const u8,
) !void {
    var scan_directory = try directory.openDir(".", .{
        .iterate = true,
        .no_follow = true,
    });
    defer scan_directory.close();
    var iterator = scan_directory.iterate();
    while (try iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.name, lock_name) or
            std.mem.eql(u8, entry.name, active_selector_name) or
            std.mem.eql(u8, entry.name, archive_name) or
            std.mem.eql(u8, entry.name, archive_candidate) or
            std.mem.eql(u8, entry.name, selector_candidate))
            continue;
        if (std.mem.startsWith(u8, entry.name, "checkpoint-") or
            std.mem.startsWith(
                u8,
                entry.name,
                ".glacier-checkpoint-",
            ))
            return Error.PublicationMismatch;
    }
    try validateOptionalInitialCandidateV1(
        directory,
        archive_candidate,
    );
    try validateOptionalInitialCandidateV1(
        directory,
        selector_candidate,
    );
}

fn validateOptionalInitialCandidateV1(
    directory: std.fs.Dir,
    name: []const u8,
) !void {
    const file = openSafeFileV1(
        directory,
        name,
        .existing,
    ) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close();
    const before = try inspectFileV1(file, directory, name);
    const after = try inspectFileV1(file, directory, name);
    if (!std.meta.eql(before, after))
        return Error.StorageIdentityChanged;
}

/// Publish one repairable candidate beneath a pinned descriptor, then atomically
/// rename it to an absent final name. The returned flag is true when recovery
/// reused candidate debris from an earlier attempt.
fn publishInitialCandidateV1(
    directory: std.fs.Dir,
    candidate_name: []const u8,
    final_name: []const u8,
    expected: []const u8,
    write_phase: IoPhaseV1,
    sync_phase: IoPhaseV1,
    rename_phase: ?IoPhaseV1,
    directory_sync_phase: IoPhaseV1,
    observer: ?ObserverV1,
) !bool {
    var candidate_created = true;
    const file = openSafeFileV1(
        directory,
        candidate_name,
        .create,
    ) catch |err| switch (err) {
        error.PathAlreadyExists => opened: {
            candidate_created = false;
            break :opened try openSafeFileV1(
                directory,
                candidate_name,
                .existing,
            );
        },
        else => return err,
    };
    defer file.close();
    const initial_view = try inspectFileV1(
        file,
        directory,
        candidate_name,
    );
    const needs_write = initial_view.size != expected.len or
        !try fileContentsEqualV1(file, expected);
    if (needs_write) {
        try file.setEndPos(0);
        try file.pwriteAll(expected, 0);
        try file.setEndPos(expected.len);
        if (observer) |value| try value.after(write_phase);
    }
    try file.sync();
    if (observer) |value| try value.after(sync_phase);
    try verifyPinnedExactFileV1(
        file,
        directory,
        candidate_name,
        expected,
        initial_view,
    );

    try renameNoReplaceV1(
        directory,
        candidate_name,
        final_name,
    );
    if (rename_phase) |phase|
        if (observer) |value| try value.after(phase);
    try verifyPinnedExactFileV1(
        file,
        directory,
        final_name,
        expected,
        initial_view,
    );
    try syncDirectory(directory);
    if (observer) |value| try value.after(
        directory_sync_phase,
    );
    return !candidate_created;
}

/// Atomically publishes one candidate only while the final name is absent.
/// Unlike POSIX `rename`, these primitives cannot replace a foreign final that
/// appears after validation. Unsupported kernels fail closed.
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

fn archiveNameV1(
    checkpoint_sha256: Digest,
    storage: []u8,
) ![]const u8 {
    const hex = std.fmt.bytesToHex(checkpoint_sha256, .lower);
    return std.fmt.bufPrint(storage, "checkpoint-{s}.set", .{&hex});
}

fn archiveCandidateNameV1(
    checkpoint_sha256: Digest,
    storage: []u8,
) ![]const u8 {
    const hex = std.fmt.bytesToHex(checkpoint_sha256, .lower);
    return std.fmt.bufPrint(
        storage,
        "checkpoint-{s}.set.candidate",
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
    const aliased_active_storage = lease.active_storage;
    try testing.expectError(
        Error.UnsafeDestination,
        lease.loadRetainedSetV1(
            first.checkpoint_sha256,
            aliased_active_storage,
        ),
    );
    try testing.expectEqualStrings(
        "checkpoint-two",
        (try (try lease.activeSet()).object(.capsule, 0)).bytes,
    );
    var retained_storage: [1024]u8 = undefined;
    const retained = try lease.loadRetainedSetV1(
        first.checkpoint_sha256,
        &retained_storage,
    );
    try testing.expectEqualSlices(
        u8,
        first.bytes,
        retained.bytes,
    );
    try testing.expectEqualStrings(
        "checkpoint-one",
        (try retained.set.object(.capsule, 0)).bytes,
    );
    try testing.expectError(
        Error.InvalidState,
        lease.loadRetainedSetV1(
            capsule.zero_digest,
            &retained_storage,
        ),
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

const InitialTestPairV1 = struct {
    set: PreparedSetV1,
    selector: PreparedSelectorV1,
};

fn initialTestPairV1(
    storage: []u8,
    challenge_sha256: Digest,
    request_epoch: u64,
    payload: []const u8,
) !InitialTestPairV1 {
    const objects = [_]ObjectInputV1{.{
        .kind = .extension,
        .ordinal = 0,
        .abi_version = 1,
        .bytes = payload,
    }};
    const set = try encodeSetV1(.{
        .generation = 1,
        .request_epoch = request_epoch,
        .publication_next_sequence = 1,
        .parent_checkpoint_sha256 = capsule.zero_digest,
        .challenge_sha256 = challenge_sha256,
    }, &objects, storage);
    return .{
        .set = set,
        .selector = try prepareInitialSelectorV1(set),
    };
}

const InitialFaultObserverV1 = struct {
    target: IoPhaseV1,
    calls: usize = 0,

    fn after(
        raw: *anyopaque,
        phase: IoPhaseV1,
    ) Error!void {
        const self: *InitialFaultObserverV1 =
            @ptrCast(@alignCast(raw));
        self.calls += 1;
        if (phase == self.target) return Error.InjectedFault;
    }
};

fn createEmptyCheckpointLockForTestV1(
    directory: std.fs.Dir,
    storage_epoch: u64,
    storage: []u8,
) !void {
    var lock = try sweep_file.FileLeaseV1.create(
        directory,
        lock_name,
        .{
            .storage_epoch = storage_epoch,
            .max_bytes = sweep_record.encoded_bytes,
        },
        storage,
    );
    lock.close();
}

test "initial checkpoint create-or-recover is allocation-free and idempotent" {
    if (comptime !initial_recovery_available_v1)
        return error.SkipZigTest;
    const testing = std.testing;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const challenge = [_]u8{0x81} ** 32;
    var set_storage: [1024]u8 = undefined;
    const pair = try initialTestPairV1(
        &set_storage,
        challenge,
        801,
        "initial-idempotent",
    );

    var lock_storage: [1]u8 = undefined;
    var active_storage: [1024]u8 = undefined;
    var created = try LeaseV1.createOrRecoverInitialV1(
        temporary.dir,
        9801,
        challenge,
        pair.set,
        pair.selector,
        active_storage.len,
        &lock_storage,
        &active_storage,
    );
    try testing.expectEqual(
        InitialDispositionV1.created,
        created.disposition,
    );
    try testing.expectEqualSlices(
        u8,
        pair.set.bytes,
        created.lease.stream(),
    );
    created.lease.close();

    var reopened_lock_storage: [1]u8 = undefined;
    var reopened_active_storage: [1024]u8 = undefined;
    var reopened = try LeaseV1.createOrRecoverInitialV1(
        temporary.dir,
        9801,
        challenge,
        pair.set,
        pair.selector,
        reopened_active_storage.len,
        &reopened_lock_storage,
        &reopened_active_storage,
    );
    defer reopened.lease.close();
    try testing.expectEqual(
        InitialDispositionV1.already_selected,
        reopened.disposition,
    );
    try testing.expectEqualSlices(
        u8,
        &pair.selector.selector_sha256,
        &reopened.lease.selector.selector_sha256,
    );

    {
        var lock_only_temporary = testing.tmpDir(.{});
        defer lock_only_temporary.cleanup();
        var lock_only_set_storage: [1024]u8 = undefined;
        const lock_only_pair = try initialTestPairV1(
            &lock_only_set_storage,
            challenge,
            802,
            "initial-lock-only",
        );
        var abandoned_lock_storage: [1]u8 = undefined;
        try createEmptyCheckpointLockForTestV1(
            lock_only_temporary.dir,
            9802,
            &abandoned_lock_storage,
        );
        var recovered_lock_storage: [1]u8 = undefined;
        var recovered_active_storage: [1024]u8 = undefined;
        var recovered = try LeaseV1.createOrRecoverInitialV1(
            lock_only_temporary.dir,
            9802,
            challenge,
            lock_only_pair.set,
            lock_only_pair.selector,
            recovered_active_storage.len,
            &recovered_lock_storage,
            &recovered_active_storage,
        );
        defer recovered.lease.close();
        try testing.expectEqual(
            InitialDispositionV1.recovered,
            recovered.disposition,
        );
    }
}

test "initial checkpoint recovery scans privately and recovers archive rename boundary" {
    if (comptime !initial_recovery_available_v1)
        return error.SkipZigTest;
    const testing = std.testing;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var caller_directory = try temporary.dir.openDir(".", .{});
    defer caller_directory.close();
    const challenge = [_]u8{0x88} ** 32;
    var set_storage: [1024]u8 = undefined;
    const pair = try initialTestPairV1(
        &set_storage,
        challenge,
        810,
        "archive-rename-boundary",
    );
    var abandoned_lock_storage: [1]u8 = undefined;
    try createEmptyCheckpointLockForTestV1(
        caller_directory,
        9810,
        &abandoned_lock_storage,
    );

    var archive_name_storage: [max_generated_name_bytes]u8 =
        undefined;
    const archive_name = try archiveNameV1(
        pair.set.checkpoint_sha256,
        &archive_name_storage,
    );
    var candidate_name_storage: [max_generated_name_bytes]u8 =
        undefined;
    const candidate_name = try archiveCandidateNameV1(
        pair.set.checkpoint_sha256,
        &candidate_name_storage,
    );
    try writeNewFileV1(
        caller_directory,
        candidate_name,
        pair.set.bytes,
    );
    const candidate = try openSafeFileV1(
        caller_directory,
        candidate_name,
        .existing,
    );
    try candidate.sync();
    candidate.close();
    try renameNoReplaceV1(
        caller_directory,
        candidate_name,
        archive_name,
    );

    var recovered_lock_storage: [1]u8 = undefined;
    var recovered_active_storage: [1024]u8 = undefined;
    var recovered = try LeaseV1.createOrRecoverInitialV1(
        caller_directory,
        9810,
        challenge,
        pair.set,
        pair.selector,
        recovered_active_storage.len,
        &recovered_lock_storage,
        &recovered_active_storage,
    );
    defer recovered.lease.close();
    try testing.expectEqual(
        InitialDispositionV1.recovered,
        recovered.disposition,
    );
    try testing.expectEqualSlices(
        u8,
        pair.set.bytes,
        recovered.lease.stream(),
    );
}

test "every initial checkpoint phase recovers missing or exact selection" {
    if (comptime !initial_recovery_available_v1)
        return error.SkipZigTest;
    const testing = std.testing;
    const phases = [_]IoPhaseV1{
        .archive_write,
        .archive_sync,
        .archive_directory_sync,
        .selector_write,
        .selector_sync,
        .selector_rename,
        .selector_directory_sync,
    };
    for (phases, 0..) |phase, index| {
        var temporary = testing.tmpDir(.{});
        defer temporary.cleanup();
        const challenge = [_]u8{0x82} ** 32;
        var set_storage: [1024]u8 = undefined;
        const pair = try initialTestPairV1(
            &set_storage,
            challenge,
            820 + index,
            "initial-phase-recovery",
        );
        var observer: InitialFaultObserverV1 = .{
            .target = phase,
        };
        var lock_storage: [1]u8 = undefined;
        var active_storage: [1024]u8 = undefined;
        try testing.expectError(
            Error.InjectedFault,
            LeaseV1.createOrRecoverInitialObservedV1(
                temporary.dir,
                9820 + index,
                challenge,
                pair.set,
                pair.selector,
                active_storage.len,
                &lock_storage,
                &active_storage,
                .{
                    .context = &observer,
                    .after_phase_fn = InitialFaultObserverV1.after,
                },
            ),
        );
        try testing.expect(observer.calls > 0);

        const selected_before_recovery =
            phase == .selector_rename or
            phase == .selector_directory_sync;
        try testing.expectEqual(
            if (selected_before_recovery)
                ExactFileStateV1.exact
            else
                ExactFileStateV1.missing,
            try exactFileStateV1(
                temporary.dir,
                active_selector_name,
                &pair.selector.bytes,
            ),
        );

        if (phase == .archive_write) {
            var name_storage: [max_generated_name_bytes]u8 =
                undefined;
            const name = try archiveCandidateNameV1(
                pair.set.checkpoint_sha256,
                &name_storage,
            );
            const file = try openSafeFileV1(
                temporary.dir,
                name,
                .existing,
            );
            try file.setEndPos(17);
            file.close();
        } else if (phase == .selector_write) {
            var name_storage: [max_generated_name_bytes]u8 =
                undefined;
            const name = try selectorCandidateNameV1(
                pair.selector.selector_sha256,
                &name_storage,
            );
            const file = try openSafeFileV1(
                temporary.dir,
                name,
                .existing,
            );
            try file.setEndPos(17);
            file.close();
        }

        var recovered_lock_storage: [1]u8 = undefined;
        var recovered_active_storage: [1024]u8 = undefined;
        var recovered = try LeaseV1.createOrRecoverInitialV1(
            temporary.dir,
            9820 + index,
            challenge,
            pair.set,
            pair.selector,
            recovered_active_storage.len,
            &recovered_lock_storage,
            &recovered_active_storage,
        );
        try testing.expectEqual(
            if (selected_before_recovery)
                InitialDispositionV1.already_selected
            else
                InitialDispositionV1.recovered,
            recovered.disposition,
        );
        try testing.expectEqualSlices(
            u8,
            pair.set.bytes,
            recovered.lease.stream(),
        );
        recovered.lease.close();

        var repeated_lock_storage: [1]u8 = undefined;
        var repeated_active_storage: [1024]u8 = undefined;
        var repeated = try LeaseV1.createOrRecoverInitialV1(
            temporary.dir,
            9820 + index,
            challenge,
            pair.set,
            pair.selector,
            repeated_active_storage.len,
            &repeated_lock_storage,
            &repeated_active_storage,
        );
        defer repeated.lease.close();
        try testing.expectEqual(
            InitialDispositionV1.already_selected,
            repeated.disposition,
        );
    }
}

const InitialIdentityReplacementObserverV1 = struct {
    directory: *std.fs.Dir,
    candidate_name: []const u8,
    replacement: []const u8,
    replaced: bool = false,

    fn after(
        raw: *anyopaque,
        phase: IoPhaseV1,
    ) Error!void {
        const self: *InitialIdentityReplacementObserverV1 =
            @ptrCast(@alignCast(raw));
        if (phase != .archive_write or self.replaced) return;
        self.directory.rename(
            self.candidate_name,
            "displaced-initial-candidate",
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
        replacement.writeAll(self.replacement) catch
            return Error.StorageIo;
        replacement.sync() catch return Error.StorageIo;
        self.replaced = true;
    }
};

const InitialForeignFinalObserverV1 = struct {
    directory: *std.fs.Dir,
    target: IoPhaseV1,
    final_name: []const u8,
    foreign_bytes: []const u8,
    inserted: bool = false,

    fn after(
        raw: *anyopaque,
        phase: IoPhaseV1,
    ) Error!void {
        const self: *InitialForeignFinalObserverV1 =
            @ptrCast(@alignCast(raw));
        if (phase != self.target or self.inserted) return;
        const file = openSafeFileV1(
            self.directory.*,
            self.final_name,
            .create,
        ) catch return Error.StorageIo;
        defer file.close();
        file.writeAll(self.foreign_bytes) catch
            return Error.StorageIo;
        file.sync() catch return Error.StorageIo;
        self.inserted = true;
    }
};

fn publishInitialTestSuccessorV1(
    lease: *LeaseV1,
    set_storage: []u8,
    payload: []const u8,
) !PreparedPublicationV1 {
    const objects = [_]ObjectInputV1{.{
        .kind = .extension,
        .ordinal = 0,
        .abi_version = 1,
        .bytes = payload,
    }};
    const set = try encodeSetV1(.{
        .generation = lease.selector.generation + 1,
        .request_epoch = lease.selector.request_epoch,
        .publication_next_sequence = lease.selector.publication_next_sequence + 1,
        .parent_checkpoint_sha256 = lease.selector.checkpoint_sha256,
        .challenge_sha256 = lease.challenge_sha256,
    }, &objects, set_storage);
    const publication = try preparePublicationV1(lease, set);
    _ = try publishV1(lease, publication);
    return publication;
}

test "initial checkpoint recovery refuses authoritative and namespace drift" {
    if (comptime !initial_recovery_available_v1)
        return error.SkipZigTest;
    const testing = std.testing;
    const challenge = [_]u8{0x83} ** 32;

    {
        var temporary = testing.tmpDir(.{});
        defer temporary.cleanup();
        var set_storage: [1024]u8 = undefined;
        const pair = try initialTestPairV1(
            &set_storage,
            challenge,
            831,
            "partial-active",
        );
        var lock_storage: [1]u8 = undefined;
        try createEmptyCheckpointLockForTestV1(
            temporary.dir,
            9831,
            &lock_storage,
        );
        const partial = pair.selector.bytes[0..17];
        try writeNewFileV1(
            temporary.dir,
            active_selector_name,
            partial,
        );
        var reopen_lock_storage: [1]u8 = undefined;
        var active_storage: [1024]u8 = undefined;
        try testing.expectError(
            Error.InvalidSelector,
            LeaseV1.createOrRecoverInitialV1(
                temporary.dir,
                9831,
                challenge,
                pair.set,
                pair.selector,
                active_storage.len,
                &reopen_lock_storage,
                &active_storage,
            ),
        );
        try testing.expectEqual(
            ExactFileStateV1.exact,
            try exactFileStateV1(
                temporary.dir,
                active_selector_name,
                partial,
            ),
        );
    }

    {
        var temporary = testing.tmpDir(.{});
        defer temporary.cleanup();
        var expected_storage: [1024]u8 = undefined;
        const expected = try initialTestPairV1(
            &expected_storage,
            challenge,
            832,
            "expected-active",
        );
        var foreign_storage: [1024]u8 = undefined;
        const foreign = try initialTestPairV1(
            &foreign_storage,
            challenge,
            833,
            "foreign-active",
        );
        var lock_storage: [1]u8 = undefined;
        try createEmptyCheckpointLockForTestV1(
            temporary.dir,
            9832,
            &lock_storage,
        );
        try writeNewFileV1(
            temporary.dir,
            active_selector_name,
            &foreign.selector.bytes,
        );
        var reopen_lock_storage: [1]u8 = undefined;
        var active_storage: [1024]u8 = undefined;
        try testing.expectError(
            Error.InvalidSelector,
            LeaseV1.createOrRecoverInitialV1(
                temporary.dir,
                9832,
                challenge,
                expected.set,
                expected.selector,
                active_storage.len,
                &reopen_lock_storage,
                &active_storage,
            ),
        );
        try testing.expectEqual(
            ExactFileStateV1.exact,
            try exactFileStateV1(
                temporary.dir,
                active_selector_name,
                &foreign.selector.bytes,
            ),
        );
    }

    {
        var temporary = testing.tmpDir(.{});
        defer temporary.cleanup();
        var set_storage: [1024]u8 = undefined;
        const pair = try initialTestPairV1(
            &set_storage,
            challenge,
            834,
            "immutable-mismatch",
        );
        var lock_storage: [1]u8 = undefined;
        try createEmptyCheckpointLockForTestV1(
            temporary.dir,
            9834,
            &lock_storage,
        );
        var archive_name_storage: [max_generated_name_bytes]u8 =
            undefined;
        const archive_name = try archiveNameV1(
            pair.set.checkpoint_sha256,
            &archive_name_storage,
        );
        const foreign = "foreign immutable bytes";
        try writeNewFileV1(
            temporary.dir,
            archive_name,
            foreign,
        );
        var reopen_lock_storage: [1]u8 = undefined;
        var active_storage: [1024]u8 = undefined;
        try testing.expectError(
            Error.CheckpointMismatch,
            LeaseV1.createOrRecoverInitialV1(
                temporary.dir,
                9834,
                challenge,
                pair.set,
                pair.selector,
                active_storage.len,
                &reopen_lock_storage,
                &active_storage,
            ),
        );
        try testing.expectEqual(
            ExactFileStateV1.exact,
            try exactFileStateV1(
                temporary.dir,
                archive_name,
                foreign,
            ),
        );
    }

    {
        var temporary = testing.tmpDir(.{});
        defer temporary.cleanup();
        var set_storage: [1024]u8 = undefined;
        const pair = try initialTestPairV1(
            &set_storage,
            challenge,
            835,
            "unsafe-candidate",
        );
        var lock_storage: [1]u8 = undefined;
        try createEmptyCheckpointLockForTestV1(
            temporary.dir,
            9835,
            &lock_storage,
        );
        const victim = try temporary.dir.createFile(
            "candidate-victim",
            .{
                .read = true,
                .exclusive = true,
                .mode = 0o600,
            },
        );
        try victim.writeAll("victim must not change");
        victim.close();
        var candidate_name_storage: [max_generated_name_bytes]u8 =
            undefined;
        const candidate_name = try archiveCandidateNameV1(
            pair.set.checkpoint_sha256,
            &candidate_name_storage,
        );
        try std.posix.linkat(
            temporary.dir.fd,
            "candidate-victim",
            temporary.dir.fd,
            candidate_name,
            0,
        );
        var reopen_lock_storage: [1]u8 = undefined;
        var active_storage: [1024]u8 = undefined;
        try testing.expectError(
            Error.MultipleLinks,
            LeaseV1.createOrRecoverInitialV1(
                temporary.dir,
                9835,
                challenge,
                pair.set,
                pair.selector,
                active_storage.len,
                &reopen_lock_storage,
                &active_storage,
            ),
        );
        try temporary.dir.deleteFile(candidate_name);
        try testing.expectEqual(
            ExactFileStateV1.exact,
            try exactFileStateV1(
                temporary.dir,
                "candidate-victim",
                "victim must not change",
            ),
        );
    }

    {
        var temporary = testing.tmpDir(.{});
        defer temporary.cleanup();
        var set_storage: [1024]u8 = undefined;
        const pair = try initialTestPairV1(
            &set_storage,
            challenge,
            836,
            "symlink-candidate",
        );
        var lock_storage: [1]u8 = undefined;
        try createEmptyCheckpointLockForTestV1(
            temporary.dir,
            9836,
            &lock_storage,
        );
        const victim = try temporary.dir.createFile(
            "symlink-victim",
            .{
                .read = true,
                .exclusive = true,
                .mode = 0o600,
            },
        );
        victim.close();
        var candidate_name_storage: [max_generated_name_bytes]u8 =
            undefined;
        const candidate_name = try archiveCandidateNameV1(
            pair.set.checkpoint_sha256,
            &candidate_name_storage,
        );
        try temporary.dir.symLink(
            "symlink-victim",
            candidate_name,
            .{},
        );
        var reopen_lock_storage: [1]u8 = undefined;
        var active_storage: [1024]u8 = undefined;
        try testing.expectError(
            error.SymLinkLoop,
            LeaseV1.createOrRecoverInitialV1(
                temporary.dir,
                9836,
                challenge,
                pair.set,
                pair.selector,
                active_storage.len,
                &reopen_lock_storage,
                &active_storage,
            ),
        );
    }

    {
        var temporary = testing.tmpDir(.{});
        defer temporary.cleanup();
        var set_storage: [1024]u8 = undefined;
        const pair = try initialTestPairV1(
            &set_storage,
            challenge,
            837,
            "identity-replacement",
        );
        var candidate_name_storage: [max_generated_name_bytes]u8 =
            undefined;
        const candidate_name = try archiveCandidateNameV1(
            pair.set.checkpoint_sha256,
            &candidate_name_storage,
        );
        var observer: InitialIdentityReplacementObserverV1 = .{
            .directory = &temporary.dir,
            .candidate_name = candidate_name,
            .replacement = pair.set.bytes,
        };
        var lock_storage: [1]u8 = undefined;
        var active_storage: [1024]u8 = undefined;
        try testing.expectError(
            Error.StorageIdentityChanged,
            LeaseV1.createOrRecoverInitialObservedV1(
                temporary.dir,
                9837,
                challenge,
                pair.set,
                pair.selector,
                active_storage.len,
                &lock_storage,
                &active_storage,
                .{
                    .context = &observer,
                    .after_phase_fn = InitialIdentityReplacementObserverV1.after,
                },
            ),
        );
        try testing.expect(observer.replaced);
        try testing.expectEqual(
            ExactFileStateV1.missing,
            try exactFileStateV1(
                temporary.dir,
                active_selector_name,
                &pair.selector.bytes,
            ),
        );
    }

    {
        var temporary = testing.tmpDir(.{});
        defer temporary.cleanup();
        var set_storage: [1024]u8 = undefined;
        const pair = try initialTestPairV1(
            &set_storage,
            challenge,
            839,
            "selected-without-archive",
        );
        var lock_storage: [1]u8 = undefined;
        try createEmptyCheckpointLockForTestV1(
            temporary.dir,
            9839,
            &lock_storage,
        );
        try writeNewFileV1(
            temporary.dir,
            active_selector_name,
            &pair.selector.bytes,
        );
        var reopen_lock_storage: [1]u8 = undefined;
        var active_storage: [1024]u8 = undefined;
        try testing.expectError(
            Error.CheckpointMismatch,
            LeaseV1.createOrRecoverInitialV1(
                temporary.dir,
                9839,
                challenge,
                pair.set,
                pair.selector,
                active_storage.len,
                &reopen_lock_storage,
                &active_storage,
            ),
        );
        try testing.expectEqual(
            ExactFileStateV1.exact,
            try exactFileStateV1(
                temporary.dir,
                active_selector_name,
                &pair.selector.bytes,
            ),
        );
    }

    {
        var temporary = testing.tmpDir(.{});
        defer temporary.cleanup();
        var set_storage: [1024]u8 = undefined;
        const pair = try initialTestPairV1(
            &set_storage,
            challenge,
            840,
            "nonempty-lock",
        );
        try writeNewFileV1(
            temporary.dir,
            lock_name,
            "x",
        );
        var lock_storage: [1]u8 = undefined;
        var active_storage: [1024]u8 = undefined;
        try testing.expectError(
            Error.StorageIdentityChanged,
            LeaseV1.createOrRecoverInitialV1(
                temporary.dir,
                9840,
                challenge,
                pair.set,
                pair.selector,
                active_storage.len,
                &lock_storage,
                &active_storage,
            ),
        );
        try testing.expectEqual(
            ExactFileStateV1.exact,
            try exactFileStateV1(
                temporary.dir,
                lock_name,
                "x",
            ),
        );
    }

    {
        var temporary = testing.tmpDir(.{});
        defer temporary.cleanup();
        const objects = [_]ObjectInputV1{.{
            .kind = .extension,
            .ordinal = 0,
            .abi_version = 1,
            .bytes = "generation-two",
        }};
        var set_storage: [1024]u8 = undefined;
        const set = try encodeSetV1(.{
            .generation = 2,
            .request_epoch = 838,
            .publication_next_sequence = 2,
            .parent_checkpoint_sha256 = [_]u8{0x84} ** 32,
            .challenge_sha256 = challenge,
        }, &objects, &set_storage);
        const selector = try encodeSelectorV1(
            [_]u8{0x85} ** 32,
            set,
            try decodeSetV1(set.bytes),
        );
        var lock_storage: [1]u8 = undefined;
        var active_storage: [1024]u8 = undefined;
        try testing.expectError(
            Error.InvalidSelector,
            LeaseV1.createOrRecoverInitialV1(
                temporary.dir,
                9838,
                challenge,
                set,
                selector,
                active_storage.len,
                &lock_storage,
                &active_storage,
            ),
        );
        try testing.expectEqual(
            ExactFileStateV1.missing,
            try exactFileStateV1(
                temporary.dir,
                lock_name,
                &.{},
            ),
        );
    }
}

test "initial checkpoint publication refuses raced foreign namespace changes" {
    if (comptime !initial_recovery_available_v1)
        return error.SkipZigTest;
    const testing = std.testing;
    const challenge = [_]u8{0x86} ** 32;
    const race_cases = [_]IoPhaseV1{
        .archive_sync,
        .selector_sync,
    };

    for (race_cases, 0..) |phase, index| {
        var temporary = testing.tmpDir(.{});
        defer temporary.cleanup();
        var set_storage: [1024]u8 = undefined;
        const pair = try initialTestPairV1(
            &set_storage,
            challenge,
            850 + index,
            "foreign-final-race",
        );
        var archive_name_storage: [max_generated_name_bytes]u8 =
            undefined;
        const archive_name = try archiveNameV1(
            pair.set.checkpoint_sha256,
            &archive_name_storage,
        );
        const final_name = if (phase == .archive_sync)
            archive_name
        else
            active_selector_name;
        const foreign = "foreign final must survive";
        var observer: InitialForeignFinalObserverV1 = .{
            .directory = &temporary.dir,
            .target = phase,
            .final_name = final_name,
            .foreign_bytes = foreign,
        };
        var lock_storage: [1]u8 = undefined;
        var active_storage: [1024]u8 = undefined;
        try testing.expectError(
            Error.PublicationMismatch,
            LeaseV1.createOrRecoverInitialObservedV1(
                temporary.dir,
                9850 + index,
                challenge,
                pair.set,
                pair.selector,
                active_storage.len,
                &lock_storage,
                &active_storage,
                .{
                    .context = &observer,
                    .after_phase_fn = InitialForeignFinalObserverV1.after,
                },
            ),
        );
        try testing.expect(observer.inserted);
        try testing.expectEqual(
            ExactFileStateV1.exact,
            try exactFileStateV1(
                temporary.dir,
                final_name,
                foreign,
            ),
        );
    }

    {
        var temporary = testing.tmpDir(.{});
        defer temporary.cleanup();
        var set_storage: [1024]u8 = undefined;
        const pair = try initialTestPairV1(
            &set_storage,
            challenge,
            852,
            "foreign-successor-race",
        );
        var foreign_name_storage: [max_generated_name_bytes]u8 =
            undefined;
        const foreign_name = try archiveNameV1(
            [_]u8{0x99} ** 32,
            &foreign_name_storage,
        );
        const foreign = "successor appeared after initial audit";
        var observer: InitialForeignFinalObserverV1 = .{
            .directory = &temporary.dir,
            .target = .archive_sync,
            .final_name = foreign_name,
            .foreign_bytes = foreign,
        };
        var lock_storage: [1]u8 = undefined;
        var active_storage: [1024]u8 = undefined;
        try testing.expectError(
            Error.PublicationMismatch,
            LeaseV1.createOrRecoverInitialObservedV1(
                temporary.dir,
                9852,
                challenge,
                pair.set,
                pair.selector,
                active_storage.len,
                &lock_storage,
                &active_storage,
                .{
                    .context = &observer,
                    .after_phase_fn = InitialForeignFinalObserverV1.after,
                },
            ),
        );
        try testing.expect(observer.inserted);
        try testing.expectEqual(
            ExactFileStateV1.exact,
            try exactFileStateV1(
                temporary.dir,
                foreign_name,
                foreign,
            ),
        );
        try testing.expectEqual(
            ExactFileStateV1.missing,
            try exactFileStateV1(
                temporary.dir,
                active_selector_name,
                &pair.selector.bytes,
            ),
        );
    }
}

test "initial checkpoint recovery rejects durable successor rollback" {
    if (comptime !initial_recovery_available_v1)
        return error.SkipZigTest;
    const testing = std.testing;
    const challenge = [_]u8{0x87} ** 32;

    for ([_]bool{ false, true }, 0..) |
        restore_initial_selector,
        index,
    | {
        var temporary = testing.tmpDir(.{});
        defer temporary.cleanup();
        var initial_storage: [1024]u8 = undefined;
        const initial = try initialTestPairV1(
            &initial_storage,
            challenge,
            860 + index,
            "rollback-initial",
        );
        var lock_storage: [1]u8 = undefined;
        var active_storage: [1024]u8 = undefined;
        var initial_result = try LeaseV1.createOrRecoverInitialV1(
            temporary.dir,
            9860 + index,
            challenge,
            initial.set,
            initial.selector,
            active_storage.len,
            &lock_storage,
            &active_storage,
        );
        var successor_storage: [1024]u8 = undefined;
        const successor = try publishInitialTestSuccessorV1(
            &initial_result.lease,
            &successor_storage,
            "durable-generation-two",
        );
        initial_result.lease.close();

        try temporary.dir.deleteFile(active_selector_name);
        if (restore_initial_selector)
            try writeNewFileV1(
                temporary.dir,
                active_selector_name,
                &initial.selector.bytes,
            );

        var reopen_lock_storage: [1]u8 = undefined;
        var reopen_active_storage: [1024]u8 = undefined;
        try testing.expectError(
            Error.PublicationMismatch,
            LeaseV1.createOrRecoverInitialV1(
                temporary.dir,
                9860 + index,
                challenge,
                initial.set,
                initial.selector,
                reopen_active_storage.len,
                &reopen_lock_storage,
                &reopen_active_storage,
            ),
        );

        var successor_name_storage: [
            max_generated_name_bytes
        ]u8 = undefined;
        const successor_name = try archiveNameV1(
            successor.set.checkpoint_sha256,
            &successor_name_storage,
        );
        try testing.expectEqual(
            ExactFileStateV1.exact,
            try exactFileStateV1(
                temporary.dir,
                successor_name,
                successor.set.bytes,
            ),
        );
        try testing.expectEqual(
            if (restore_initial_selector)
                ExactFileStateV1.exact
            else
                ExactFileStateV1.missing,
            try exactFileStateV1(
                temporary.dir,
                active_selector_name,
                &initial.selector.bytes,
            ),
        );
    }
}
