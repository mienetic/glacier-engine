//! Durable, selector-compatible archive for prepared-text handoff evidence.
//!
//! The archive contains exactly four extension objects: the source checkpoint,
//! successor execution plan, successor residency binding, and successor
//! segment. Decoding is contextual: canonical bytes alone cannot choose their
//! own checkpoint bindings, source context, target ownership, or archive
//! lineage.
//!
//! This module publishes evidence only. It does not exit a source process,
//! grant target authority, or create a live restored session.

const std = @import("std");
const core = @import("core");
const checkpoint_file = core.continuation_checkpoint_file;
const model_contract = core.model_contract;
const resource_bank = core.resource_bank;
const checkpoint = @import("prepared_text_checkpoint.zig");
const restart_manifest =
    @import("prepared_text_restart_manifest.zig");
const successor = @import("prepared_text_successor.zig");
const kv = @import("kv_cache.zig");
const lane_contiguous = @import("lane_contiguous_publication.zig");
const publication = @import("lane_publication_txn.zig");

pub const Digest = [32]u8;
pub const archive_object_count: usize = 4;
pub const restart_archive_object_count: usize = 5;
pub const checkpoint_object_ordinal: u64 = 0;
pub const successor_plan_object_ordinal: u64 = 1;
pub const successor_residency_object_ordinal: u64 = 2;
pub const successor_segment_object_ordinal: u64 = 3;
pub const restart_manifest_object_ordinal: u64 = 4;
pub const archive_fixed_payload_bytes: usize =
    model_contract.execution_plan_bytes +
    model_contract.execution_residency_binding_bytes +
    successor.successor_segment_bytes;
pub const archive_overhead_bytes: usize =
    checkpoint_file.set_payload_offset +
    checkpoint_file.set_footer_bytes;

pub const Error = checkpoint_file.Error ||
    checkpoint.Error ||
    restart_manifest.Error ||
    successor.Error ||
    error{
        InvalidArchive,
        InvalidArchiveLineage,
    };

pub const PreparedArchiveV1 = struct {
    set: checkpoint_file.PreparedSetV1,
    artifacts: successor.ArtifactsV1,
};

/// Fully verified, zero-copy views borrowing the encoded archive.
pub const DecodedArchiveV1 = struct {
    archive: checkpoint_file.DecodedSetV1,
    checkpoint: checkpoint.DecodedV1,
    artifacts: successor.ArtifactsV1,
};

/// Self-contained fresh-process archive. The manifest borrows the archive
/// bytes and supplies all trusted checkpoint/source/target context needed to
/// reproduce the other four records without a mutable sidecar.
pub const DecodedRestartArchiveV1 = struct {
    archive: checkpoint_file.DecodedSetV1,
    manifest: restart_manifest.DecodedV1,
    checkpoint: checkpoint.DecodedV1,
    artifacts: successor.ArtifactsV1,
};

pub fn encodedArchiveBytesV1(
    encoded_checkpoint_bytes: usize,
) Error!usize {
    const with_fixed = std.math.add(
        usize,
        archive_overhead_bytes,
        archive_fixed_payload_bytes,
    ) catch return Error.ArithmeticOverflow;
    return std.math.add(
        usize,
        with_fixed,
        encoded_checkpoint_bytes,
    ) catch return Error.ArithmeticOverflow;
}

/// Derive and encode all successor evidence before publishing any destination
/// byte. Every failure, including an overlapping or undersized destination,
/// leaves `destination` unchanged.
pub fn encodeArchiveV1(
    archive_generation: u64,
    parent_archive_sha256: Digest,
    encoded_checkpoint: []const u8,
    expected_checkpoint: checkpoint.ExpectedBindingsV1,
    source: successor.SourceContextV1,
    target: successor.TargetOwnershipV1,
    destination: []u8,
) Error!PreparedArchiveV1 {
    try validateArchiveLineageV1(
        archive_generation,
        parent_archive_sha256,
    );
    const artifacts = try successor.makeForCheckpointV1(
        encoded_checkpoint,
        expected_checkpoint,
        source,
        target,
    );

    var encoded_plan: [model_contract.execution_plan_bytes]u8 =
        undefined;
    var encoded_residency: [model_contract.execution_residency_binding_bytes]u8 = undefined;
    var encoded_segment: [successor.successor_segment_bytes]u8 =
        undefined;
    try successor.encodeArtifactsV1(
        artifacts,
        &encoded_plan,
        &encoded_residency,
        &encoded_segment,
    );

    const objects = [_]checkpoint_file.ObjectInputV1{
        .{
            .kind = .extension,
            .ordinal = checkpoint_object_ordinal,
            .abi_version = checkpoint.checkpoint_abi,
            .bytes = encoded_checkpoint,
        },
        .{
            .kind = .extension,
            .ordinal = successor_plan_object_ordinal,
            .abi_version = model_contract.execution_plan_abi,
            .bytes = &encoded_plan,
        },
        .{
            .kind = .extension,
            .ordinal = successor_residency_object_ordinal,
            .abi_version = model_contract.execution_residency_binding_abi,
            .bytes = &encoded_residency,
        },
        .{
            .kind = .extension,
            .ordinal = successor_segment_object_ordinal,
            .abi_version = successor.successor_segment_abi,
            .bytes = &encoded_segment,
        },
    };
    const set = try checkpoint_file.encodeSetV1(
        .{
            .generation = archive_generation,
            .request_epoch = artifacts.segment.request_epoch,
            .publication_next_sequence = artifacts.segment.sequence_base,
            .parent_checkpoint_sha256 = parent_archive_sha256,
            .challenge_sha256 = artifacts.segment.challenge_sha256,
        },
        &objects,
        destination,
    );
    return .{
        .set = set,
        .artifacts = artifacts,
    };
}

/// Decode the exact four-object archive and reproduce its successor artifacts
/// from caller-retained context. A coherently re-rooted foreign archive is not
/// accepted merely because its internal hashes are valid.
pub fn decodeArchiveV1(
    encoded_archive: []const u8,
    expected_archive_generation: u64,
    expected_parent_archive_sha256: Digest,
    expected_checkpoint: checkpoint.ExpectedBindingsV1,
    source: successor.SourceContextV1,
    target: successor.TargetOwnershipV1,
) Error!DecodedArchiveV1 {
    try validateArchiveLineageV1(
        expected_archive_generation,
        expected_parent_archive_sha256,
    );
    const archive = try checkpoint_file.decodeSetV1(
        encoded_archive,
    );
    if (archive.object_count != archive_object_count or
        archive.metadata.generation != expected_archive_generation or
        !digestEqual(
            archive.metadata.parent_checkpoint_sha256,
            expected_parent_archive_sha256,
        ))
        return Error.InvalidArchive;

    const checkpoint_object = try exactObjectV1(
        archive,
        0,
        checkpoint_object_ordinal,
        checkpoint.checkpoint_abi,
    );
    const plan_object = try exactObjectV1(
        archive,
        1,
        successor_plan_object_ordinal,
        model_contract.execution_plan_abi,
    );
    const residency_object = try exactObjectV1(
        archive,
        2,
        successor_residency_object_ordinal,
        model_contract.execution_residency_binding_abi,
    );
    const segment_object = try exactObjectV1(
        archive,
        3,
        successor_segment_object_ordinal,
        successor.successor_segment_abi,
    );

    const decoded_checkpoint = try checkpoint.decodeCheckpointV1(
        checkpoint_object.bytes,
        expected_checkpoint,
    );
    const artifacts =
        try successor.decodeAndVerifyForCheckpointV1(
            plan_object.bytes,
            residency_object.bytes,
            segment_object.bytes,
            checkpoint_object.bytes,
            expected_checkpoint,
            source,
            target,
        );
    if (archive.metadata.request_epoch !=
        artifacts.segment.request_epoch or
        archive.metadata.publication_next_sequence !=
            artifacts.segment.sequence_base or
        !digestEqual(
            archive.metadata.challenge_sha256,
            artifacts.segment.challenge_sha256,
        ) or
        archive.metadata.request_epoch !=
            decoded_checkpoint.request_epoch or
        archive.metadata.publication_next_sequence !=
            decoded_checkpoint.publication_next_sequence or
        !digestEqual(
            archive.metadata.challenge_sha256,
            decoded_checkpoint.challenge_sha256,
        ))
        return Error.InvalidArchive;

    return .{
        .archive = archive,
        .checkpoint = decoded_checkpoint,
        .artifacts = artifacts,
    };
}

pub fn encodedRestartArchiveBytesV1(
    encoded_checkpoint_bytes: usize,
    encoded_manifest_bytes: usize,
) Error!usize {
    const legacy = try encodedArchiveBytesV1(
        encoded_checkpoint_bytes,
    );
    return std.math.add(
        usize,
        legacy,
        encoded_manifest_bytes,
    ) catch return Error.ArithmeticOverflow;
}

/// Encode the durable fresh-process archive. The canonical manifest is
/// validated first, then used as the sole contextual authority for deriving
/// the checkpoint and successor records embedded beside it.
pub fn encodeRestartArchiveV1(
    archive_generation: u64,
    parent_archive_sha256: Digest,
    encoded_checkpoint: []const u8,
    encoded_manifest: []const u8,
    destination: []u8,
) Error!PreparedArchiveV1 {
    try validateArchiveLineageV1(
        archive_generation,
        parent_archive_sha256,
    );
    const manifest = try restart_manifest.decodeV1(
        encoded_manifest,
    );
    _ = try checkpoint.decodeCheckpointV1(
        encoded_checkpoint,
        manifest.expected_checkpoint,
    );
    const artifacts = try successor.makeForCheckpointV1(
        encoded_checkpoint,
        manifest.expected_checkpoint,
        manifest.source,
        manifest.target,
    );

    var encoded_plan: [model_contract.execution_plan_bytes]u8 =
        undefined;
    var encoded_residency: [model_contract.execution_residency_binding_bytes]u8 = undefined;
    var encoded_segment: [successor.successor_segment_bytes]u8 =
        undefined;
    try successor.encodeArtifactsV1(
        artifacts,
        &encoded_plan,
        &encoded_residency,
        &encoded_segment,
    );
    const objects = [_]checkpoint_file.ObjectInputV1{
        .{
            .kind = .extension,
            .ordinal = checkpoint_object_ordinal,
            .abi_version = checkpoint.checkpoint_abi,
            .bytes = encoded_checkpoint,
        },
        .{
            .kind = .extension,
            .ordinal = successor_plan_object_ordinal,
            .abi_version = model_contract.execution_plan_abi,
            .bytes = &encoded_plan,
        },
        .{
            .kind = .extension,
            .ordinal = successor_residency_object_ordinal,
            .abi_version = model_contract.execution_residency_binding_abi,
            .bytes = &encoded_residency,
        },
        .{
            .kind = .extension,
            .ordinal = successor_segment_object_ordinal,
            .abi_version = successor.successor_segment_abi,
            .bytes = &encoded_segment,
        },
        .{
            .kind = .extension,
            .ordinal = restart_manifest_object_ordinal,
            .abi_version = restart_manifest.manifest_abi,
            .bytes = encoded_manifest,
        },
    };
    const set = try checkpoint_file.encodeSetV1(
        .{
            .generation = archive_generation,
            .request_epoch = artifacts.segment.request_epoch,
            .publication_next_sequence = artifacts.segment.sequence_base,
            .parent_checkpoint_sha256 = parent_archive_sha256,
            .challenge_sha256 = artifacts.segment.challenge_sha256,
        },
        &objects,
        destination,
    );
    return .{
        .set = set,
        .artifacts = artifacts,
    };
}

/// Decode all fresh-process context from the selected archive itself. The
/// caller supplies only lineage; the manifest cannot choose its own parent
/// selector or archive generation.
pub fn decodeRestartArchiveV1(
    encoded_archive: []const u8,
    expected_archive_generation: u64,
    expected_parent_archive_sha256: Digest,
) Error!DecodedRestartArchiveV1 {
    try validateArchiveLineageV1(
        expected_archive_generation,
        expected_parent_archive_sha256,
    );
    const decoded_archive = try checkpoint_file.decodeSetV1(
        encoded_archive,
    );
    if (decoded_archive.object_count !=
        restart_archive_object_count or
        decoded_archive.metadata.generation !=
            expected_archive_generation or
        !digestEqual(
            decoded_archive.metadata.parent_checkpoint_sha256,
            expected_parent_archive_sha256,
        ))
        return Error.InvalidArchive;

    const checkpoint_object = try exactObjectV1(
        decoded_archive,
        0,
        checkpoint_object_ordinal,
        checkpoint.checkpoint_abi,
    );
    const plan_object = try exactObjectV1(
        decoded_archive,
        1,
        successor_plan_object_ordinal,
        model_contract.execution_plan_abi,
    );
    const residency_object = try exactObjectV1(
        decoded_archive,
        2,
        successor_residency_object_ordinal,
        model_contract.execution_residency_binding_abi,
    );
    const segment_object = try exactObjectV1(
        decoded_archive,
        3,
        successor_segment_object_ordinal,
        successor.successor_segment_abi,
    );
    const manifest_object = try exactObjectV1(
        decoded_archive,
        4,
        restart_manifest_object_ordinal,
        restart_manifest.manifest_abi,
    );
    const manifest = try restart_manifest.decodeV1(
        manifest_object.bytes,
    );
    const decoded_checkpoint = try checkpoint.decodeCheckpointV1(
        checkpoint_object.bytes,
        manifest.expected_checkpoint,
    );
    const artifacts =
        try successor.decodeAndVerifyForCheckpointV1(
            plan_object.bytes,
            residency_object.bytes,
            segment_object.bytes,
            checkpoint_object.bytes,
            manifest.expected_checkpoint,
            manifest.source,
            manifest.target,
        );
    if (decoded_archive.metadata.request_epoch !=
        artifacts.segment.request_epoch or
        decoded_archive.metadata.publication_next_sequence !=
            artifacts.segment.sequence_base or
        !digestEqual(
            decoded_archive.metadata.challenge_sha256,
            artifacts.segment.challenge_sha256,
        ) or decoded_archive.metadata.request_epoch !=
        decoded_checkpoint.request_epoch or
        decoded_archive.metadata.publication_next_sequence !=
            decoded_checkpoint.publication_next_sequence or
        !digestEqual(
            decoded_archive.metadata.challenge_sha256,
            decoded_checkpoint.challenge_sha256,
        ))
        return Error.InvalidArchive;

    return .{
        .archive = decoded_archive,
        .manifest = manifest,
        .checkpoint = decoded_checkpoint,
        .artifacts = artifacts,
    };
}

fn validateArchiveLineageV1(
    generation: u64,
    parent_archive_sha256: Digest,
) Error!void {
    if (generation == 0 or
        (generation == 1 and !isZero(parent_archive_sha256)) or
        (generation > 1 and isZero(parent_archive_sha256)))
        return Error.InvalidArchiveLineage;
}

fn exactObjectV1(
    archive: checkpoint_file.DecodedSetV1,
    index: usize,
    ordinal: u64,
    abi_version: u64,
) Error!checkpoint_file.ObjectViewV1 {
    if (index >= archive.object_count)
        return Error.InvalidArchive;
    const object = archive.objects[index];
    if (object.kind != .extension or
        object.ordinal != ordinal or
        object.abi_version != abi_version)
        return Error.InvalidArchive;
    return object;
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

fn isZero(value: Digest) bool {
    return std.mem.eql(u8, &value, &([_]u8{0} ** 32));
}

const TestFixture = struct {
    allocator: std.mem.Allocator,
    encoded_checkpoint: []u8,
    expected_checkpoint: checkpoint.ExpectedBindingsV1,
    source: successor.SourceContextV1,
    target: successor.TargetOwnershipV1,

    fn init(allocator: std.mem.Allocator) !TestFixture {
        const request_claim: resource_bank.Claim = .{
            .capsule_bytes = 64,
            .kv_bytes = 224,
            .activation_bytes = 12,
            .partial_bytes = 64,
            .logits_bytes = 1024,
            .output_journal_bytes = 20,
            .staging_bytes = 32,
            .queue_slots = 1,
        };
        const total_claim: resource_bank.Claim = .{
            .capsule_bytes = 4160,
            .kv_bytes = request_claim.kv_bytes,
            .activation_bytes = request_claim.activation_bytes,
            .partial_bytes = request_claim.partial_bytes,
            .logits_bytes = request_claim.logits_bytes,
            .output_journal_bytes = request_claim.output_journal_bytes,
            .staging_bytes = request_claim.staging_bytes,
            .queue_slots = request_claim.queue_slots,
        };
        var slots = [_]resource_bank.Slot{.{}};
        var bank = try resource_bank.Bank.init(
            &slots,
            .{
                .host_bytes = 1 << 20,
                .capsule_bytes = 1 << 20,
                .kv_bytes = 1 << 20,
                .activation_bytes = 1 << 20,
                .partial_bytes = 1 << 20,
                .logits_bytes = 1 << 20,
                .output_journal_bytes = 1 << 20,
                .staging_bytes = 1 << 20,
                .device_bytes = 1 << 20,
                .io_bytes = 1 << 20,
                .queue_slots = 4,
            },
            41,
        );
        const reservation = try bank.reserve(1001, request_claim);
        const receipt = try bank.commit(reservation);

        const artifact =
            try model_contract.makeArtifactManifestFromDigestV1(
                .autoregressive,
                0x474c_5446_0000_0001,
                .token_ids,
                .token_ids,
                .implementation_defined,
                1,
                3,
                5,
                @sizeOf(u32),
                @sizeOf(u32),
                1,
                4096,
                filledDigest(0x41),
                filledDigest(0x42),
                filledDigest(0x43),
            );
        const source_execution =
            try model_contract.makeExecutionPlanV1(
                artifact,
                .generate_sequence,
                .{
                    .request_epoch = 0x0102_0304_0506_0708,
                    .generation = 7,
                    .batch_items = 1,
                    .publication_next_sequence = 0,
                    .maximum_absolute_output = 255,
                    .claim = total_claim,
                    .media_object_sha256 = filledDigest(0x31),
                    .processor_state_sha256 = filledDigest(0x32),
                    .processor_bundle_sha256 = filledDigest(0x33),
                    .cache_bundle_sha256 = filledDigest(0x34),
                    .cache_payload_sha256 = filledDigest(0x35),
                    .ownership_sha256 = filledDigest(0x36),
                    .challenge_sha256 = filledDigest(0xcc),
                    .previous_plan_sha256 = [_]u8{0} ** 32,
                    .input_schema_sha256 = filledDigest(0x37),
                    .output_schema_sha256 = filledDigest(0x38),
                    .scratch_bytes = request_claim.partial_bytes,
                },
            );
        const source_residency =
            try model_contract.makeExecutionResidencyBindingV1(
                source_execution,
                .shared_read_only,
                4096,
                request_claim,
            );

        var cache = try kv.KVCache.init(allocator, 2, 2, 7);
        defer cache.deinit();
        for (0..cache.num_layers) |layer| {
            var keys: [8]f32 = undefined;
            var values: [8]f32 = undefined;
            for (&keys, 0..) |*value, index| {
                const bits: u32 = @intCast(
                    0x3f00_0000 + layer * 0x1000 + index,
                );
                value.* = @bitCast(bits);
            }
            for (&values, 0..) |*value, index| {
                const bits: u32 = @intCast(
                    0xbf00_0000 + layer * 0x1000 + index,
                );
                value.* = @bitCast(bits);
            }
            _ = try cache.appendRows(layer, &keys, &values, 4);
        }
        cache.commitRows(4);

        const output_tokens = [_]u32{ 17, 29 };
        const rng_state: lane_contiguous.RngState = .{
            0x0102_0304_0506_0708,
            0x1112_1314_1516_1718,
            0x2122_2324_2526_2728,
            0x3132_3334_3536_3738,
        };
        const state = publication.makeStateCommitmentV1(
            lane_contiguous.abi,
            4,
            try checkpoint.incrementalKvStateRootV1(&cache, 3),
            lane_contiguous.rng_state_abi,
            lane_contiguous.rngStateSha256(rng_state),
            2,
            2,
            lane_contiguous.outputStateSha256(
                &output_tokens,
                false,
            ),
        );
        const transcript_sha256 = filledDigest(0x77);
        const bound_plan_sha256 = filledDigest(0x22);
        const boundary_sha256 = filledDigest(0x66);
        const challenge_sha256 = filledDigest(0xcc);
        const expected_checkpoint: checkpoint.ExpectedBindingsV1 = .{
            .local_plan_sha256 = filledDigest(0x11),
            .bound_plan_sha256 = bound_plan_sha256,
            .artifact_sha256 = artifact.artifact_sha256,
            .execution_plan_sha256 = source_execution.plan_sha256,
            .residency_binding_sha256 = source_residency.binding_sha256,
            .boundary_sha256 = boundary_sha256,
            .transcript_sha256 = transcript_sha256,
            .state_commitment_sha256 = state.commitment_sha256,
            .request_epoch = source_execution.request_epoch,
            .publication_next_sequence = 2,
            .prompt_tokens = 3,
            .max_new_tokens = 5,
            .vocab_size = 256,
            .num_layers = 2,
            .kv_dim = 2,
            .max_kv_positions = 7,
            .kv_positions = 4,
            .output_count = 2,
            .sampling_calls = 2,
            .challenge_sha256 = challenge_sha256,
        };
        const required =
            try checkpoint.encodedCheckpointBytesV1(2, 2, 4, 2);
        const encoded_checkpoint =
            try allocator.alloc(u8, required);
        errdefer allocator.free(encoded_checkpoint);
        _ = try checkpoint.encodeCheckpointV1(
            .{
                .local_plan_sha256 = expected_checkpoint.local_plan_sha256,
                .bound_plan_sha256 = bound_plan_sha256,
                .artifact_sha256 = artifact.artifact_sha256,
                .execution_plan_sha256 = source_execution.plan_sha256,
                .residency_binding_sha256 = source_residency.binding_sha256,
                .boundary_sha256 = boundary_sha256,
                .transcript_sha256 = transcript_sha256,
                .state_commitment_sha256 = state.commitment_sha256,
                .request_epoch = source_execution.request_epoch,
                .publication_next_sequence = 2,
                .prompt_tokens = 3,
                .max_new_tokens = 5,
                .vocab_size = 256,
                .output_tokens = &output_tokens,
                .rng_state = rng_state,
                .sampling_calls = 2,
                .cache = &cache,
                .challenge_sha256 = challenge_sha256,
            },
            encoded_checkpoint,
        );
        return .{
            .allocator = allocator,
            .encoded_checkpoint = encoded_checkpoint,
            .expected_checkpoint = expected_checkpoint,
            .source = .{
                .bound_plan_sha256 = bound_plan_sha256,
                .execution = source_execution,
                .residency = source_residency,
                .boundary_sha256 = boundary_sha256,
                .publication = .{
                    .request_epoch = source_execution.request_epoch,
                    .execution_abi = lane_contiguous.abi,
                    .next_sequence = 2,
                    .last_resource_permit_generation = 19,
                    .terminal = false,
                    .state = state,
                    .transcript_sha256 = transcript_sha256,
                },
                .receipt = receipt,
            },
            .target = .{
                .scheduler_epoch = 51,
                .coordinator_id = 52,
                .bank_epoch = 42,
                .request_generation = 8,
                .resource_owner_key = 2001,
                .tree_key = 2002,
                .authority_key = 2003,
                .tenant_key = 2004,
                .scope_key = 2005,
                .cache_node_key = 2006,
                .cache_binding_key = 2007,
                .intent_generation = 8,
                .request_claim = request_claim,
            },
        };
    }

    fn deinit(self: *TestFixture) void {
        self.allocator.free(self.encoded_checkpoint);
        self.* = undefined;
    }
};

test "prepared text handoff archive is canonical and exactly typed" {
    var fixture = try TestFixture.init(std.testing.allocator);
    defer fixture.deinit();
    const archive_generation: u64 = 11;
    const parent_archive_sha256 = filledDigest(0xa5);
    const required = try encodedArchiveBytesV1(
        fixture.encoded_checkpoint.len,
    );
    const first_storage =
        try std.testing.allocator.alloc(u8, required);
    defer std.testing.allocator.free(first_storage);
    const second_storage =
        try std.testing.allocator.alloc(u8, required);
    defer std.testing.allocator.free(second_storage);

    const first = try encodeArchiveV1(
        archive_generation,
        parent_archive_sha256,
        fixture.encoded_checkpoint,
        fixture.expected_checkpoint,
        fixture.source,
        fixture.target,
        first_storage,
    );
    const second = try encodeArchiveV1(
        archive_generation,
        parent_archive_sha256,
        fixture.encoded_checkpoint,
        fixture.expected_checkpoint,
        fixture.source,
        fixture.target,
        second_storage,
    );
    try std.testing.expectEqual(required, first.set.bytes.len);
    try std.testing.expectEqualSlices(
        u8,
        first.set.bytes,
        second.set.bytes,
    );
    try std.testing.expectEqualSlices(
        u8,
        &first.set.checkpoint_sha256,
        &second.set.checkpoint_sha256,
    );

    const decoded = try decodeArchiveV1(
        first.set.bytes,
        archive_generation,
        parent_archive_sha256,
        fixture.expected_checkpoint,
        fixture.source,
        fixture.target,
    );
    try std.testing.expectEqual(
        archive_object_count,
        decoded.archive.object_count,
    );
    try std.testing.expectEqual(
        archive_generation,
        decoded.archive.metadata.generation,
    );
    try std.testing.expectEqual(
        fixture.expected_checkpoint.request_epoch,
        decoded.archive.metadata.request_epoch,
    );
    try std.testing.expectEqual(
        fixture.expected_checkpoint.publication_next_sequence,
        decoded.archive.metadata.publication_next_sequence,
    );
    try std.testing.expectEqualSlices(
        u8,
        &parent_archive_sha256,
        &decoded.archive.metadata.parent_checkpoint_sha256,
    );
    try std.testing.expectEqualSlices(
        u8,
        &fixture.expected_checkpoint.challenge_sha256,
        &decoded.archive.metadata.challenge_sha256,
    );
    try std.testing.expect(std.meta.eql(
        first.artifacts,
        decoded.artifacts,
    ));
    try std.testing.expectEqualSlices(
        u8,
        &decoded.checkpoint.checkpoint_sha256,
        &decoded.artifacts.segment.source_checkpoint_sha256,
    );

    const expected_ordinals = [_]u64{ 0, 1, 2, 3 };
    const expected_abis = [_]u64{
        checkpoint.checkpoint_abi,
        model_contract.execution_plan_abi,
        model_contract.execution_residency_binding_abi,
        successor.successor_segment_abi,
    };
    for (
        decoded.archive.objects[0..archive_object_count],
        0..,
    ) |object, index| {
        try std.testing.expectEqual(
            checkpoint_file.ObjectKindV1.extension,
            object.kind,
        );
        try std.testing.expectEqual(
            expected_ordinals[index],
            object.ordinal,
        );
        try std.testing.expectEqual(
            expected_abis[index],
            object.abi_version,
        );
    }
}

test "prepared text handoff archive rejects every committed mutation" {
    var fixture = try TestFixture.init(std.testing.allocator);
    defer fixture.deinit();
    const archive_generation: u64 = 11;
    const parent_archive_sha256 = filledDigest(0xa5);
    const required = try encodedArchiveBytesV1(
        fixture.encoded_checkpoint.len,
    );
    const storage = try std.testing.allocator.alloc(u8, required);
    defer std.testing.allocator.free(storage);
    const prepared = try encodeArchiveV1(
        archive_generation,
        parent_archive_sha256,
        fixture.encoded_checkpoint,
        fixture.expected_checkpoint,
        fixture.source,
        fixture.target,
        storage,
    );
    const mutated = try std.testing.allocator.dupe(
        u8,
        prepared.set.bytes,
    );
    defer std.testing.allocator.free(mutated);

    for (mutated) |*byte| {
        byte.* ^= 0x01;
        try expectArchiveReject(
            mutated,
            archive_generation,
            parent_archive_sha256,
            fixture.expected_checkpoint,
            fixture.source,
            fixture.target,
        );
        byte.* ^= 0x01;
    }
}

test "prepared text handoff archive rejects contextual substitution" {
    var fixture = try TestFixture.init(std.testing.allocator);
    defer fixture.deinit();
    const archive_generation: u64 = 11;
    const parent_archive_sha256 = filledDigest(0xa5);
    const required = try encodedArchiveBytesV1(
        fixture.encoded_checkpoint.len,
    );
    const storage = try std.testing.allocator.alloc(u8, required);
    defer std.testing.allocator.free(storage);

    var foreign_target = fixture.target;
    foreign_target.resource_owner_key += 101;
    const foreign = try encodeArchiveV1(
        archive_generation,
        parent_archive_sha256,
        fixture.encoded_checkpoint,
        fixture.expected_checkpoint,
        fixture.source,
        foreign_target,
        storage,
    );
    _ = try decodeArchiveV1(
        foreign.set.bytes,
        archive_generation,
        parent_archive_sha256,
        fixture.expected_checkpoint,
        fixture.source,
        foreign_target,
    );
    try expectArchiveReject(
        foreign.set.bytes,
        archive_generation,
        parent_archive_sha256,
        fixture.expected_checkpoint,
        fixture.source,
        fixture.target,
    );
    try expectArchiveReject(
        foreign.set.bytes,
        archive_generation + 1,
        filledDigest(0xa6),
        fixture.expected_checkpoint,
        fixture.source,
        foreign_target,
    );
}

test "prepared text handoff archive enforces exact metadata and objects" {
    var fixture = try TestFixture.init(std.testing.allocator);
    defer fixture.deinit();
    const archive_generation: u64 = 11;
    const parent_archive_sha256 = filledDigest(0xa5);
    const required = try encodedArchiveBytesV1(
        fixture.encoded_checkpoint.len,
    );
    const storage = try std.testing.allocator.alloc(u8, required);
    defer std.testing.allocator.free(storage);
    const prepared = try encodeArchiveV1(
        archive_generation,
        parent_archive_sha256,
        fixture.encoded_checkpoint,
        fixture.expected_checkpoint,
        fixture.source,
        fixture.target,
        storage,
    );
    const generic = try checkpoint_file.decodeSetV1(
        prepared.set.bytes,
    );

    var objects: [checkpoint_file.max_objects]checkpoint_file.ObjectInputV1 = undefined;
    for (generic.objects[0..generic.object_count], 0..) |
        object,
        index,
    | {
        objects[index] = .{
            .kind = object.kind,
            .ordinal = object.ordinal,
            .abi_version = object.abi_version,
            .bytes = object.bytes,
        };
    }

    var wrong_metadata = generic.metadata;
    wrong_metadata.request_epoch += 1;
    const metadata_storage =
        try std.testing.allocator.alloc(u8, required);
    defer std.testing.allocator.free(metadata_storage);
    const metadata_archive = try checkpoint_file.encodeSetV1(
        wrong_metadata,
        objects[0..archive_object_count],
        metadata_storage,
    );
    try expectArchiveReject(
        metadata_archive.bytes,
        archive_generation,
        parent_archive_sha256,
        fixture.expected_checkpoint,
        fixture.source,
        fixture.target,
    );

    objects[2].abi_version += 1;
    const abi_storage =
        try std.testing.allocator.alloc(u8, required);
    defer std.testing.allocator.free(abi_storage);
    const abi_archive = try checkpoint_file.encodeSetV1(
        generic.metadata,
        objects[0..archive_object_count],
        abi_storage,
    );
    try expectArchiveReject(
        abi_archive.bytes,
        archive_generation,
        parent_archive_sha256,
        fixture.expected_checkpoint,
        fixture.source,
        fixture.target,
    );
    objects[2].abi_version -= 1;

    const extra_payload = [_]u8{0x5a};
    objects[4] = .{
        .kind = .extension,
        .ordinal = 4,
        .abi_version = 1,
        .bytes = &extra_payload,
    };
    const extra_storage =
        try std.testing.allocator.alloc(u8, required + 1);
    defer std.testing.allocator.free(extra_storage);
    const extra_archive = try checkpoint_file.encodeSetV1(
        generic.metadata,
        objects[0 .. archive_object_count + 1],
        extra_storage,
    );
    try expectArchiveReject(
        extra_archive.bytes,
        archive_generation,
        parent_archive_sha256,
        fixture.expected_checkpoint,
        fixture.source,
        fixture.target,
    );
}

test "prepared text handoff archive failures preserve output" {
    var fixture = try TestFixture.init(std.testing.allocator);
    defer fixture.deinit();
    const archive_generation: u64 = 11;
    const parent_archive_sha256 = filledDigest(0xa5);
    const required = try encodedArchiveBytesV1(
        fixture.encoded_checkpoint.len,
    );
    const destination =
        try std.testing.allocator.alloc(u8, required);
    defer std.testing.allocator.free(destination);
    @memset(destination, 0x6d);
    const before = try std.testing.allocator.dupe(
        u8,
        destination,
    );
    defer std.testing.allocator.free(before);

    var invalid_target = fixture.target;
    invalid_target.intent_generation += 1;
    try expectEncodeReject(
        archive_generation,
        parent_archive_sha256,
        fixture.encoded_checkpoint,
        fixture.expected_checkpoint,
        fixture.source,
        invalid_target,
        destination,
    );
    try std.testing.expectEqualSlices(u8, before, destination);

    try expectEncodeReject(
        1,
        parent_archive_sha256,
        fixture.encoded_checkpoint,
        fixture.expected_checkpoint,
        fixture.source,
        fixture.target,
        destination,
    );
    try std.testing.expectEqualSlices(u8, before, destination);

    try expectEncodeReject(
        archive_generation,
        [_]u8{0} ** 32,
        fixture.encoded_checkpoint,
        fixture.expected_checkpoint,
        fixture.source,
        fixture.target,
        destination,
    );
    try std.testing.expectEqualSlices(u8, before, destination);

    try expectEncodeReject(
        archive_generation,
        parent_archive_sha256,
        fixture.encoded_checkpoint,
        fixture.expected_checkpoint,
        fixture.source,
        fixture.target,
        destination[0 .. destination.len - 1],
    );
    try std.testing.expectEqualSlices(u8, before, destination);

    const overlap = try std.testing.allocator.alloc(u8, required);
    defer std.testing.allocator.free(overlap);
    @memset(overlap, 0x9c);
    @memcpy(
        overlap[0..fixture.encoded_checkpoint.len],
        fixture.encoded_checkpoint,
    );
    const overlap_before = try std.testing.allocator.dupe(
        u8,
        overlap,
    );
    defer std.testing.allocator.free(overlap_before);
    try expectEncodeReject(
        archive_generation,
        parent_archive_sha256,
        overlap[0..fixture.encoded_checkpoint.len],
        fixture.expected_checkpoint,
        fixture.source,
        fixture.target,
        overlap,
    );
    try std.testing.expectEqualSlices(
        u8,
        overlap_before,
        overlap,
    );
}

fn expectArchiveReject(
    encoded_archive: []const u8,
    expected_archive_generation: u64,
    expected_parent_archive_sha256: Digest,
    expected_checkpoint: checkpoint.ExpectedBindingsV1,
    source: successor.SourceContextV1,
    target: successor.TargetOwnershipV1,
) !void {
    if (decodeArchiveV1(
        encoded_archive,
        expected_archive_generation,
        expected_parent_archive_sha256,
        expected_checkpoint,
        source,
        target,
    )) |_| {
        return error.TestExpectedError;
    } else |_| {}
}

fn expectEncodeReject(
    archive_generation: u64,
    parent_archive_sha256: Digest,
    encoded_checkpoint: []const u8,
    expected_checkpoint: checkpoint.ExpectedBindingsV1,
    source: successor.SourceContextV1,
    target: successor.TargetOwnershipV1,
    destination: []u8,
) !void {
    if (encodeArchiveV1(
        archive_generation,
        parent_archive_sha256,
        encoded_checkpoint,
        expected_checkpoint,
        source,
        target,
        destination,
    )) |_| {
        return error.TestExpectedError;
    } else |_| {}
}

fn filledDigest(byte: u8) Digest {
    return [_]u8{byte} ** 32;
}
