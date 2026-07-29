//! Sink-free committed-output view for a direct one-token terminal selection.
//!
//! The pure reconciler consumes only a fully decoded direct-terminal record.
//! The file inspector reads one immutable checkpoint selector/set snapshot,
//! performs no result-sink I/O, and rechecks the active selector after
//! reconciliation so a returned view spans one stable selected interval.

const std = @import("std");
const core = @import("core");
const checkpoint_file = core.continuation_checkpoint_file;
const model_contract = core.model_contract;
const resource_bank = core.resource_bank;
const direct_terminal =
    @import("prepared_text_direct_terminal.zig");
const input_archive =
    @import("prepared_text_input_archive.zig");
const package_manifest =
    @import("model/package_manifest.zig");
const publication =
    @import("lane_publication_txn.zig");
const session = @import("prepared_text_session.zig");
const source_lease =
    @import("prepared_text_source_lease.zig");
const terminal_semantic =
    @import("prepared_text_terminal_equivalence.zig");
const terminal_source_recovery =
    @import("prepared_text_terminal_source_recovery.zig");
const tokenizer = @import("tokenizer.zig");

pub const Digest = checkpoint_file.Digest;
pub const zero_digest: Digest = [_]u8{0} ** 32;

pub const view_abi: u64 = 0x4750_4456_0000_0001;
pub const view_domain =
    "glacier-prepared-text-direct-terminal-output-view-v1\x00";

pub const Error = direct_terminal.Error ||
    std.mem.Allocator.Error ||
    error{
        CheckpointSetTooLarge,
        InvalidDecodedTerminal,
        InvalidView,
        SelectionChanged,
    };

/// Optional observation point used after pure reconciliation and before the
/// final selector recheck. The inspector grants the callback no filesystem
/// authority; the opaque context remains caller-owned.
pub const InspectObserverV1 = struct {
    context: *anyopaque,
    after_reconcile_fn: *const fn (context: *anyopaque) void,

    pub fn afterReconcile(self: InspectObserverV1) void {
        self.after_reconcile_fn(self.context);
    }
};

pub const InspectOptionsV1 = struct {
    max_set_bytes: usize,
    observer: ?InspectObserverV1 = null,
};

/// Complete sink-free view. All fields are values; no slice borrows the
/// temporary checkpoint snapshot used by the file inspector.
pub const ViewV1 = struct {
    abi_version: u64 = view_abi,
    terminal: bool = true,
    generation: u64,
    request_epoch: u64,
    publication_next_sequence: u64,
    acknowledgement_count: usize = 0,
    token_count: usize = 1,
    output_token: u32,

    package_sha256: Digest,
    representation_sha256: Digest,
    input_archive_sha256: Digest,
    tokenizer_domain_sha256: Digest,
    tokenizer_behavior_sha256: Digest,
    tokenizer_config_sha256: Digest,

    local_plan_sha256: Digest,
    bound_plan_sha256: Digest,
    terminal_source_contract_sha256: Digest,
    terminal_semantic_sha256: Digest,
    terminal_output_sha256: Digest,
    terminal_state_sha256: Digest,

    selected_selector_sha256: Digest,
    selected_set_sha256: Digest,
    predecessor_selector_sha256: Digest,
    predecessor_set_sha256: Digest,
    challenge_sha256: Digest,
    view_sha256: Digest,
};

/// Reconcile a previously verified direct-terminal decode without allocation,
/// filesystem access, result-sink access, or destination writes.
pub fn reconcileV1(
    decoded: direct_terminal.DecodedV1,
) Error!ViewV1 {
    try validateDecodedTerminalV1(decoded);
    var view: ViewV1 = .{
        .generation = decoded.selected_selector.generation,
        .request_epoch = decoded.contract.request_epoch,
        .publication_next_sequence = decoded.semantic.publication_next_sequence,
        .output_token = decoded.outputToken(),
        .package_sha256 = decoded.input.package.package_sha256,
        .representation_sha256 = decoded.input.representation.representation_sha256,
        .input_archive_sha256 = decoded.input.archive_sha256,
        .tokenizer_domain_sha256 = decoded.input.tokenizer_manifest.domain_sha256,
        .tokenizer_behavior_sha256 = decoded.input.tokenizer_manifest.behavior_sha256,
        .tokenizer_config_sha256 = decoded.input.tokenizer_manifest.config_sha256,
        .local_plan_sha256 = decoded.contract.plan_sha256,
        .bound_plan_sha256 = decoded.contract.bound_plan_sha256,
        .terminal_source_contract_sha256 = decoded.contract.contract_sha256,
        .terminal_semantic_sha256 = decoded.semantic.semantic_sha256,
        .terminal_output_sha256 = decoded.semantic.output_sha256,
        .terminal_state_sha256 = decoded.semantic.state_commitment_sha256,
        .selected_selector_sha256 = decoded.selected_selector.selector_sha256,
        .selected_set_sha256 = decoded.selected_set.checkpoint_sha256,
        .predecessor_selector_sha256 = decoded.predecessor_selector.selector_sha256,
        .predecessor_set_sha256 = decoded.predecessor_set.checkpoint_sha256,
        .challenge_sha256 = decoded.selected_selector.challenge_sha256,
        .view_sha256 = zero_digest,
    };
    view.view_sha256 = viewRootV1(view);
    try validateViewV1(view);
    return view;
}

/// Inspect the exact selected direct-terminal checkpoint. No sink selector or
/// ledger path is opened.
pub fn inspectDirectoryV1(
    allocator: std.mem.Allocator,
    directory: std.fs.Dir,
    options: InspectOptionsV1,
) !ViewV1 {
    var sizing_selector_storage: [checkpoint_file.selector_bytes]u8 = undefined;
    const sizing_selector =
        try checkpoint_file.readActiveSelectorReadOnlyV1(
            directory,
            &sizing_selector_storage,
        );
    const selected_set_bytes = std.math.cast(
        usize,
        sizing_selector.checkpoint_bytes,
    ) orelse return Error.CheckpointSetTooLarge;
    if (selected_set_bytes > options.max_set_bytes)
        return Error.CheckpointSetTooLarge;

    const selected_storage = try allocator.alloc(
        u8,
        selected_set_bytes,
    );
    defer allocator.free(selected_storage);
    var selected_selector_storage: [checkpoint_file.selector_bytes]u8 = undefined;
    const selected =
        checkpoint_file.readSelectedSnapshotReadOnlyV1(
            directory,
            &selected_selector_storage,
            selected_storage,
            selected_storage.len,
        ) catch |snapshot_error| switch (snapshot_error) {
            error.BufferTooSmall, error.CapacityExceeded => {
                try requireSizingSelectorUnchangedV1(
                    directory,
                    &sizing_selector_storage,
                );
                return snapshot_error;
            },
            else => return snapshot_error,
        };
    const decoded = try direct_terminal.decodeV1(
        selected.set_bytes,
        selected.selector_bytes,
    );
    const view = try reconcileV1(decoded);

    if (options.observer) |observer|
        observer.afterReconcile();

    // A byte-identical selector after the complete decode/join proves that
    // the immutable selected archive remained authoritative throughout the
    // inspected interval.
    var selector_recheck: [checkpoint_file.selector_bytes]u8 = undefined;
    _ = checkpoint_file.readActiveSelectorReadOnlyV1(
        directory,
        &selector_recheck,
    ) catch return Error.SelectionChanged;
    if (!std.mem.eql(
        u8,
        &selected_selector_storage,
        &selector_recheck,
    ))
        return Error.SelectionChanged;
    return view;
}

pub fn validateViewV1(view: ViewV1) Error!void {
    if (view.abi_version != view_abi or
        !view.terminal or
        view.generation != direct_terminal.selected_generation or
        view.request_epoch == 0 or
        view.publication_next_sequence !=
            direct_terminal.terminal_publication_next_sequence or
        view.acknowledgement_count != 0 or
        view.token_count != 1 or
        isZero(view.package_sha256) or
        isZero(view.representation_sha256) or
        isZero(view.input_archive_sha256) or
        isZero(view.tokenizer_domain_sha256) or
        isZero(view.tokenizer_behavior_sha256) or
        isZero(view.tokenizer_config_sha256) or
        isZero(view.local_plan_sha256) or
        isZero(view.bound_plan_sha256) or
        isZero(view.terminal_source_contract_sha256) or
        isZero(view.terminal_semantic_sha256) or
        isZero(view.terminal_output_sha256) or
        isZero(view.terminal_state_sha256) or
        isZero(view.selected_selector_sha256) or
        isZero(view.selected_set_sha256) or
        isZero(view.predecessor_selector_sha256) or
        isZero(view.predecessor_set_sha256) or
        isZero(view.challenge_sha256) or
        isZero(view.view_sha256) or
        !digestEqual(view.view_sha256, viewRootV1(view)))
        return Error.InvalidView;
}

pub fn viewRootV1(view: ViewV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(view_domain);
    hashU64(&hash, view.abi_version);
    hashU64(&hash, @intFromBool(view.terminal));
    hashU64(&hash, view.generation);
    hashU64(&hash, view.request_epoch);
    hashU64(&hash, view.publication_next_sequence);
    hashU64(&hash, view.acknowledgement_count);
    hashU64(&hash, view.token_count);
    hashU32(&hash, view.output_token);
    hash.update(&view.package_sha256);
    hash.update(&view.representation_sha256);
    hash.update(&view.input_archive_sha256);
    hash.update(&view.tokenizer_domain_sha256);
    hash.update(&view.tokenizer_behavior_sha256);
    hash.update(&view.tokenizer_config_sha256);
    hash.update(&view.local_plan_sha256);
    hash.update(&view.bound_plan_sha256);
    hash.update(&view.terminal_source_contract_sha256);
    hash.update(&view.terminal_semantic_sha256);
    hash.update(&view.terminal_output_sha256);
    hash.update(&view.terminal_state_sha256);
    hash.update(&view.selected_selector_sha256);
    hash.update(&view.selected_set_sha256);
    hash.update(&view.predecessor_selector_sha256);
    hash.update(&view.predecessor_set_sha256);
    hash.update(&view.challenge_sha256);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn validateDecodedTerminalV1(
    decoded: direct_terminal.DecodedV1,
) Error!void {
    const selected = decoded.selected_set;
    const selected_selector = decoded.selected_selector;
    if (selected.object_count !=
        direct_terminal.selected_object_count or
        selected.metadata.generation !=
            direct_terminal.selected_generation or
        selected.metadata.publication_next_sequence !=
            direct_terminal.terminal_publication_next_sequence or
        selected_selector.generation !=
            direct_terminal.selected_generation or
        selected_selector.publication_next_sequence !=
            direct_terminal.terminal_publication_next_sequence or
        selected.metadata.request_epoch !=
            decoded.contract.request_epoch or
        selected_selector.request_epoch !=
            decoded.contract.request_epoch or
        !digestEqual(
            selected.checkpoint_sha256,
            selected_selector.checkpoint_sha256,
        ) or !digestEqual(
        selected.metadata.parent_checkpoint_sha256,
        decoded.predecessor_set.checkpoint_sha256,
    ) or !digestEqual(
        selected_selector.previous_selector_sha256,
        decoded.predecessor_selector.selector_sha256,
    ) or !digestEqual(
        selected.metadata.challenge_sha256,
        decoded.contract.challenge_sha256,
    ) or !digestEqual(
        selected_selector.challenge_sha256,
        decoded.contract.challenge_sha256,
    ) or !canonicalSelectorValidV1(selected_selector))
        return Error.InvalidDecodedTerminal;

    const predecessor_selector_object = try exactObjectV1(
        selected,
        0,
        .runtime_state,
        direct_terminal.predecessor_selector_object_ordinal,
        checkpoint_file.selector_abi,
    );
    const predecessor_archive_object = try exactObjectV1(
        selected,
        1,
        .source_process,
        direct_terminal.predecessor_archive_object_ordinal,
        direct_terminal.predecessor_archive_abi,
    );
    const semantic_object = try exactObjectV1(
        selected,
        2,
        .extension,
        direct_terminal.terminal_semantic_object_ordinal,
        terminal_semantic.semantic_abi,
    );
    const output_object = try exactObjectV1(
        selected,
        3,
        .extension,
        direct_terminal.output_token_object_ordinal,
        direct_terminal.output_token_abi,
    );
    if (!objectsCanonicalV1(selected) or
        predecessor_selector_object.bytes.len !=
            checkpoint_file.selector_bytes or
        output_object.bytes.len != @sizeOf(u32) or
        decoded.canonical_output_u32_le.ptr !=
            output_object.bytes.ptr or
        decoded.canonical_output_u32_le.len !=
            output_object.bytes.len)
        return Error.InvalidDecodedTerminal;

    const canonical_predecessor_selector =
        checkpoint_file.decodeSelectorV1(
            predecessor_selector_object.bytes,
        ) catch return Error.InvalidDecodedTerminal;
    const canonical_predecessor_set =
        checkpoint_file.decodeSetV1(
            predecessor_archive_object.bytes,
        ) catch return Error.InvalidDecodedTerminal;
    const expected_predecessor_bytes = std.math.cast(
        u64,
        predecessor_archive_object.bytes.len,
    ) orelse return Error.InvalidDecodedTerminal;
    const expected_selected_bytes = std.math.cast(
        u64,
        direct_terminal.encodedBytesV1(
            predecessor_archive_object.bytes.len,
        ) catch return Error.InvalidDecodedTerminal,
    ) orelse return Error.InvalidDecodedTerminal;
    if (!std.meta.eql(
        canonical_predecessor_selector,
        decoded.predecessor_selector,
    ) or !decodedSetsEqualV1(
        canonical_predecessor_set,
        decoded.predecessor_set,
    ) or !canonicalSelectorValidV1(
        decoded.predecessor_selector,
    ) or decoded.predecessor_selector.checkpoint_bytes !=
        expected_predecessor_bytes or
        selected_selector.checkpoint_bytes !=
            expected_selected_bytes)
        return Error.InvalidDecodedTerminal;

    const predecessor = decoded.predecessor_set;
    if (predecessor.object_count != 3 or
        predecessor.metadata.generation !=
            direct_terminal.predecessor_generation or
        predecessor.metadata.publication_next_sequence !=
            direct_terminal.terminal_publication_next_sequence or
        decoded.predecessor_selector.generation !=
            direct_terminal.predecessor_generation or
        decoded.predecessor_selector.publication_next_sequence !=
            direct_terminal.terminal_publication_next_sequence or
        !isZero(
            predecessor.metadata.parent_checkpoint_sha256,
        ) or !isZero(
        decoded.predecessor_selector.previous_selector_sha256,
    ) or !digestEqual(
        predecessor.checkpoint_sha256,
        decoded.predecessor_selector.checkpoint_sha256,
    ) or !objectsCanonicalV1(predecessor))
        return Error.InvalidDecodedTerminal;

    const marker = try exactObjectV1(
        predecessor,
        0,
        .extension,
        source_lease.source_live_object_ordinal,
        source_lease.source_live_marker_abi,
    );
    const contract_object = try exactObjectV1(
        predecessor,
        1,
        .extension,
        source_lease.source_recovery_object_ordinal,
        terminal_source_recovery.contract_abi,
    );
    const input_object = try exactObjectV1(
        predecessor,
        2,
        .extension,
        source_lease.source_input_object_ordinal,
        input_archive.archive_abi,
    );
    if (!std.mem.eql(
        u8,
        marker.bytes,
        source_lease.source_live_marker,
    ) or decoded.contract.encoded.ptr !=
        contract_object.bytes.ptr or
        decoded.contract.encoded.len !=
            contract_object.bytes.len or
        decoded.input.encoded.ptr != input_object.bytes.ptr or
        decoded.input.encoded.len != input_object.bytes.len)
        return Error.InvalidDecodedTerminal;

    const canonical_contract =
        terminal_source_recovery.decodeV1(
            contract_object.bytes,
        ) catch return Error.InvalidDecodedTerminal;
    const canonical_input = input_archive.decodeV1(
        input_object.bytes,
    ) catch return Error.InvalidDecodedTerminal;
    if (!contractViewsEqualV1(
        decoded.contract,
        canonical_contract,
    ) or !inputViewsEqualV1(
        decoded.input,
        canonical_input,
    ) or !source_lease
        .terminalRecoveryInputMatchesContractV1(
        canonical_input,
        canonical_contract,
    ))
        return Error.InvalidDecodedTerminal;

    const canonical_semantic = terminal_semantic.decodeV1(
        semantic_object.bytes,
    ) catch return Error.InvalidDecodedTerminal;
    terminal_semantic.validateV1(canonical_semantic) catch
        return Error.InvalidDecodedTerminal;
    if (!std.meta.eql(
        canonical_semantic,
        decoded.semantic,
    ) or decoded.outputToken() != std.mem.readInt(
        u32,
        output_object.bytes[0..4],
        .little,
    ) or decoded.semantic.request_epoch !=
        decoded.contract.request_epoch or
        decoded.semantic.publication_next_sequence != 1 or
        decoded.semantic.max_new_tokens != 1 or
        decoded.semantic.sampling_calls != 1 or
        decoded.semantic.output_length != 1 or
        decoded.semantic.output_bytes != @sizeOf(u32) or
        !digestEqual(
            decoded.semantic.local_plan_sha256,
            decoded.contract.plan_sha256,
        ) or !digestEqual(
        decoded.semantic.artifact_sha256,
        decoded.contract.artifact_sha256,
    ) or !digestEqual(
        decoded.semantic.token_domain_sha256,
        decoded.contract.bound_plan_input
            .token_domain_sha256,
    ) or !digestEqual(
        decoded.semantic.token_domain_config_sha256,
        decoded.contract.bound_plan_input
            .token_domain_config_sha256,
    ) or !digestEqual(
        decoded.semantic.image_container_sha256,
        decoded.input.representation.container_sha256,
    ) or !digestEqual(
        decoded.semantic.prompt_sha256,
        decoded.contract.prompt_sha256,
    ) or !digestEqual(
        decoded.semantic.output_sha256,
        directOutputRootV1(
            decoded.contract.artifact_sha256,
            decoded.contract.bound_plan_input
                .token_domain_sha256,
            decoded.contract.bound_plan_input
                .token_domain_config_sha256,
            decoded.outputToken(),
        ),
    ))
        return Error.InvalidDecodedTerminal;
}

fn exactObjectV1(
    set: checkpoint_file.DecodedSetV1,
    index: usize,
    kind: checkpoint_file.ObjectKindV1,
    ordinal: u64,
    abi_version: u64,
) Error!checkpoint_file.ObjectViewV1 {
    if (index >= set.object_count)
        return Error.InvalidDecodedTerminal;
    const object = set.objects[index];
    if (object.kind != kind or object.ordinal != ordinal or
        object.abi_version != abi_version)
        return Error.InvalidDecodedTerminal;
    return object;
}

fn objectsCanonicalV1(
    set: checkpoint_file.DecodedSetV1,
) bool {
    for (set.objects[0..set.object_count]) |object| {
        if (!digestEqual(
            object.object_sha256,
            checkpoint_file.objectRootV1(.{
                .kind = object.kind,
                .ordinal = object.ordinal,
                .abi_version = object.abi_version,
                .bytes = object.bytes,
            }),
        ))
            return false;
    }
    return true;
}

fn canonicalSelectorValidV1(
    selector: checkpoint_file.DecodedSelectorV1,
) bool {
    var encoded =
        [_]u8{0} ** checkpoint_file.selector_bytes;
    @memcpy(encoded[0..8], &checkpoint_file.selector_magic);
    writeU64(&encoded, 8, checkpoint_file.selector_abi);
    writeU64(&encoded, 16, checkpoint_file.selector_bytes);
    writeU64(&encoded, 24, selector.generation);
    writeU64(&encoded, 32, selector.request_epoch);
    writeU64(
        &encoded,
        40,
        selector.publication_next_sequence,
    );
    writeU64(&encoded, 48, selector.checkpoint_bytes);
    writeU64(&encoded, 56, checkpoint_file.allowed_flags);
    @memcpy(
        encoded[64..96],
        &selector.previous_selector_sha256,
    );
    @memcpy(
        encoded[96..128],
        &selector.checkpoint_sha256,
    );
    @memcpy(
        encoded[128..160],
        &selector.challenge_sha256,
    );
    const root = checkpoint_file.selectorRootV1(
        encoded[0..checkpoint_file.selector_body_bytes],
    );
    if (!digestEqual(root, selector.selector_sha256))
        return false;
    @memcpy(
        encoded[checkpoint_file.selector_body_bytes..],
        &root,
    );
    const canonical = checkpoint_file.decodeSelectorV1(
        &encoded,
    ) catch return false;
    return std.meta.eql(canonical, selector);
}

fn decodedSetsEqualV1(
    supplied: checkpoint_file.DecodedSetV1,
    canonical: checkpoint_file.DecodedSetV1,
) bool {
    if (!std.meta.eql(
        supplied.metadata,
        canonical.metadata,
    ) or supplied.object_count != canonical.object_count or
        !digestEqual(
            supplied.checkpoint_sha256,
            canonical.checkpoint_sha256,
        ))
        return false;
    for (
        supplied.objects[0..supplied.object_count],
        canonical.objects[0..canonical.object_count],
    ) |left, right| {
        if (left.kind != right.kind or
            left.ordinal != right.ordinal or
            left.abi_version != right.abi_version or
            left.bytes.ptr != right.bytes.ptr or
            left.bytes.len != right.bytes.len or
            !digestEqual(
                left.object_sha256,
                right.object_sha256,
            ))
            return false;
    }
    return true;
}

fn contractViewsEqualV1(
    supplied: terminal_source_recovery.DecodedV1,
    canonical: terminal_source_recovery.DecodedV1,
) bool {
    return supplied.encoded.ptr == canonical.encoded.ptr and
        supplied.encoded.len == canonical.encoded.len and
        supplied.canonical_prompt_u32_le.ptr ==
            canonical.canonical_prompt_u32_le.ptr and
        supplied.canonical_prompt_u32_le.len ==
            canonical.canonical_prompt_u32_le.len and
        std.meta.eql(supplied.options, canonical.options) and
        std.meta.eql(supplied.scheduling, canonical.scheduling) and
        std.meta.eql(
            supplied.bound_plan_input,
            canonical.bound_plan_input,
        ) and
        std.meta.eql(
            supplied.source_runtime,
            canonical.source_runtime,
        ) and
        supplied.request_epoch == canonical.request_epoch and
        supplied.publication_next_sequence ==
            canonical.publication_next_sequence and
        digestEqual(
            supplied.challenge_sha256,
            canonical.challenge_sha256,
        ) and
        digestEqual(
            supplied.plan_sha256,
            canonical.plan_sha256,
        ) and
        digestEqual(
            supplied.bound_plan_sha256,
            canonical.bound_plan_sha256,
        ) and
        digestEqual(
            supplied.prompt_sha256,
            canonical.prompt_sha256,
        ) and
        digestEqual(
            supplied.artifact_sha256,
            canonical.artifact_sha256,
        ) and
        digestEqual(
            supplied.execution_plan_sha256,
            canonical.execution_plan_sha256,
        ) and
        digestEqual(
            supplied.residency_binding_sha256,
            canonical.residency_binding_sha256,
        ) and
        digestEqual(
            supplied.contract_sha256,
            canonical.contract_sha256,
        );
}

fn inputViewsEqualV1(
    supplied: input_archive.DecodedV1,
    canonical: input_archive.DecodedV1,
) bool {
    return supplied.encoded.ptr == canonical.encoded.ptr and
        supplied.encoded.len == canonical.encoded.len and
        std.meta.eql(supplied.package, canonical.package) and
        std.meta.eql(
            supplied.representation,
            canonical.representation,
        ) and
        std.meta.eql(
            supplied.tokenizer_manifest,
            canonical.tokenizer_manifest,
        ) and
        std.meta.eql(
            supplied.tokenizer_prompt,
            canonical.tokenizer_prompt,
        ) and
        std.meta.eql(supplied.binding, canonical.binding) and
        supplied.raw_text.ptr == canonical.raw_text.ptr and
        supplied.raw_text.len == canonical.raw_text.len and
        digestEqual(
            supplied.archive_sha256,
            canonical.archive_sha256,
        );
}

fn directOutputRootV1(
    artifact_sha256: Digest,
    token_domain_sha256: Digest,
    token_domain_config_sha256: Digest,
    output_token: u32,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(
        "glacier-prepared-text-terminal-output-semantic-v1\x00",
    );
    hash.update(&artifact_sha256);
    hash.update(&token_domain_sha256);
    hash.update(&token_domain_config_sha256);
    hashU64(&hash, 1);
    hashU32(&hash, output_token);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn requireSizingSelectorUnchangedV1(
    directory: std.fs.Dir,
    expected: *const [checkpoint_file.selector_bytes]u8,
) Error!void {
    var current: [checkpoint_file.selector_bytes]u8 =
        undefined;
    _ = checkpoint_file.readActiveSelectorReadOnlyV1(
        directory,
        &current,
    ) catch return Error.SelectionChanged;
    if (!std.mem.eql(u8, expected, &current))
        return Error.SelectionChanged;
}

fn writeU64(
    destination: []u8,
    offset: usize,
    value: anytype,
) void {
    std.mem.writeInt(
        u64,
        destination[offset..][0..8],
        @intCast(value),
        .little,
    );
}

fn hashU32(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u32,
) void {
    var encoded: [4]u8 = undefined;
    std.mem.writeInt(u32, &encoded, value, .little);
    hash.update(&encoded);
}

fn hashU64(
    hash: *std.crypto.hash.sha2.Sha256,
    value: anytype,
) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, @intCast(value), .little);
    hash.update(&encoded);
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

fn isZero(value: Digest) bool {
    return digestEqual(value, zero_digest);
}

fn filledDigest(byte: u8) Digest {
    return [_]u8{byte} ** 32;
}

const TestFixture = struct {
    prompt: [3]u32,
    raw_text: [3]u8,
    recovery_input: terminal_source_recovery.InputV1,
    package: package_manifest.ManifestV1,
    representation: package_manifest.PreparedRepresentationV1,

    fn init(variant: u8) !TestFixture {
        const prompt = [_]u32{ 5, 7, 11 };
        const raw_text = [_]u8{ 5, 7, 11 };
        const options: session.OptionsV1 = .{
            .max_new_tokens = 1,
            .eos_token = std.math.maxInt(u32),
            .seed = 0x1020_3040_5060_7080,
        };
        const scheduling: session.SchedulingV1 = .{
            .tenant_key = 0x501,
            .request_key = 0x502,
            .request_generation = 1,
            .resource_owner_key = 0x503,
            .weight = 1,
        };
        const source_runtime: terminal_source_recovery.SourceRuntimeIdentityV1 = .{
            .scheduler_epoch = 0x601,
            .coordinator_id = 0x602,
            .bank_epoch = 0x603,
        };
        const request_epoch =
            @as(u64, 0x0102_0304_0506_0708) + variant;
        const token_manifest =
            try tokenizer.makeUtf8ByteManifestV1(256, 256);
        const license_sha256 = filledDigest(0x43);
        const bound_plan_input: session.BoundPlanInputV1 = .{
            .request_epoch = request_epoch,
            .token_domain_sha256 = token_manifest.domain_sha256,
            .token_domain_config_sha256 = token_manifest.config_sha256,
            .artifact_license_sha256 = license_sha256,
        };
        const request_claim: resource_bank.Claim = .{
            .capsule_bytes = 64,
            .kv_bytes = 224,
            .activation_bytes = 12,
            .partial_bytes = 64,
            .logits_bytes = 1024,
            .output_journal_bytes = @sizeOf(u32),
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
        var plan: session.PlanV1 = .{
            .image_identity = .{
                .source_fingerprint = filledDigest(0x51),
                .abi_fingerprint = filledDigest(0x52),
                .container_bytes = 4096,
                .container_sha256 = filledDigest(0x41),
            },
            .prompt_tokens = prompt.len,
            .prompt_sha256 = terminal_source_recovery.promptRootV1(&prompt),
            .max_new_tokens = 1,
            .eos_token = options.eos_token,
            .seed = options.seed,
            .claim = request_claim,
            .plan_sha256 = zero_digest,
        };
        plan.plan_sha256 =
            terminal_source_recovery.planRootV1(plan);
        const artifact =
            try model_contract.makeArtifactManifestFromDigestV1(
                .autoregressive,
                session.prepared_artifact_profile_abi,
                .token_ids,
                .token_ids,
                .implementation_defined,
                1,
                prompt.len,
                1,
                @sizeOf(u32),
                @sizeOf(u32),
                1,
                plan.image_identity.container_bytes,
                plan.image_identity.container_sha256,
                filledDigest(0x42),
                license_sha256,
            );
        const challenge_sha256 =
            filledDigest(0xcc - variant);
        const execution =
            try model_contract.makeExecutionPlanV1(
                artifact,
                .generate_sequence,
                .{
                    .request_epoch = request_epoch,
                    .generation = scheduling.request_generation,
                    .batch_items = 1,
                    .publication_next_sequence = 0,
                    .maximum_absolute_output = 255,
                    .claim = total_claim,
                    .media_object_sha256 = plan.prompt_sha256,
                    .processor_state_sha256 = token_manifest.domain_sha256,
                    .processor_bundle_sha256 = token_manifest.config_sha256,
                    .cache_bundle_sha256 = filledDigest(0x34),
                    .cache_payload_sha256 = filledDigest(0x35),
                    .ownership_sha256 = terminal_source_recovery
                        .sourceOwnershipRootV1(
                        scheduling,
                        source_runtime,
                        request_epoch,
                    ),
                    .challenge_sha256 = challenge_sha256,
                    .previous_plan_sha256 = bound_plan_input
                        .previous_plan_sha256,
                    .input_schema_sha256 = filledDigest(0x37),
                    .output_schema_sha256 = filledDigest(0x38),
                    .scratch_bytes = request_claim.partial_bytes,
                },
            );
        const residency =
            try model_contract
                .makeExecutionResidencyBindingV1(
                execution,
                .shared_read_only,
                plan.image_identity.container_bytes,
                request_claim,
            );
        var bound_plan: session.BoundPlanV1 = .{
            .local_plan_sha256 = plan.plan_sha256,
            .artifact = artifact,
            .execution = execution,
            .residency = residency,
            .token_domain_sha256 = token_manifest.domain_sha256,
            .token_domain_config_sha256 = token_manifest.config_sha256,
            .artifact_license_sha256 = license_sha256,
            .bound_plan_sha256 = zero_digest,
        };
        bound_plan.bound_plan_sha256 =
            session.boundPlanRootV1(bound_plan);
        try session.validateBoundPlanV1(bound_plan);

        const package = try package_manifest.makeV1(.{
            .family = .autoregressive,
            .source_format = .safetensors,
            .portable_format_abi = 0x474c_4143_0000_0001,
            .conversion_profile_abi = 0x474c_4350_0000_0001,
            .conversion_plan_abi = 0x474c_434e_0000_0001,
            .tokenizer_manifest_abi = tokenizer.utf8_byte_manifest_abi,
            .tokenizer_manifest_bytes = tokenizer.utf8_byte_manifest_bytes,
            .source_bytes = 1000,
            .portable_bytes = 700,
            .portable_page_count = 4,
            .license_bytes = 21,
            .config = .{
                .dim = 64,
                .hidden_dim = 128,
                .layers = 2,
                .vocab = 256,
                .heads = 1,
                .head_dim = 64,
                .kv_heads = 1,
                .rms_eps = 1e-5,
                .rope_theta = 10000,
                .tie_embeddings = false,
            },
            .source_sha256 = filledDigest(0x11),
            .portable_artifact_sha256 = filledDigest(0x22),
            .conversion_profile_sha256 = filledDigest(0x23),
            .conversion_plan_sha256 = filledDigest(0x24),
            .model_content_sha256 = plan.image_identity.source_fingerprint,
            .tokenizer_config_sha256 = token_manifest.config_sha256,
            .tokenizer_domain_sha256 = token_manifest.domain_sha256,
            .tokenizer_behavior_sha256 = token_manifest.behavior_sha256,
            .license_sha256 = license_sha256,
        });
        const representation =
            try package_manifest.makePreparedRepresentationV1(
                package,
                0x474c_5254_0000_0002,
                1,
                plan.image_identity,
            );

        return .{
            .prompt = prompt,
            .raw_text = raw_text,
            .recovery_input = .{
                .prompt = &.{},
                .options = options,
                .scheduling = scheduling,
                .bound_plan_input = bound_plan_input,
                .plan = plan,
                .bound_plan = bound_plan,
                .source_runtime = source_runtime,
                .request_epoch = request_epoch,
                .publication_next_sequence = 1,
                .challenge_sha256 = challenge_sha256,
            },
            .package = package,
            .representation = representation,
        };
    }

    fn recoveryInput(
        self: *const TestFixture,
    ) terminal_source_recovery.InputV1 {
        var value = self.recovery_input;
        value.prompt = &self.prompt;
        return value;
    }
};

const CanonicalFixture = struct {
    allocator: std.mem.Allocator,
    contract_storage: []u8,
    input_storage: []u8,
    predecessor_storage: []u8,
    selected_storage: []u8,
    predecessor_selector: checkpoint_file.PreparedSelectorV1,
    selected_selector: [checkpoint_file.selector_bytes]u8,
    semantic: terminal_semantic.TerminalSemanticV1,
    output_token: u32,

    fn init(
        allocator: std.mem.Allocator,
        variant: u8,
    ) !CanonicalFixture {
        const logical = try TestFixture.init(variant);
        const recovery_input = logical.recoveryInput();

        const contract_storage = try allocator.alloc(
            u8,
            try terminal_source_recovery.encodedBytesV1(
                logical.prompt.len,
            ),
        );
        errdefer allocator.free(contract_storage);
        const contract =
            try terminal_source_recovery.encodeV1(
                recovery_input,
                contract_storage,
            );

        const token_manifest =
            try tokenizer.makeUtf8ByteManifestV1(256, 256);
        var tokenized = try tokenizer.tokenizeUtf8BytesV1(
            allocator,
            token_manifest,
            &logical.raw_text,
        );
        defer tokenized.deinit();
        const input_storage = try allocator.alloc(
            u8,
            try input_archive.encodedBytesV1(
                logical.raw_text.len,
            ),
        );
        errdefer allocator.free(input_storage);
        const encoded_input = try input_archive.encodeV1(
            .{
                .package = logical.package,
                .representation = logical.representation,
                .raw_text = &logical.raw_text,
                .tokenized = &tokenized,
                .local_plan = logical.recovery_input.plan,
                .bound_plan = logical.recovery_input.bound_plan,
            },
            input_storage,
        );

        const predecessor_bytes =
            checkpoint_file.set_payload_offset +
            checkpoint_file.set_footer_bytes +
            source_lease.source_live_marker.len +
            contract.bytes.len +
            encoded_input.bytes.len;
        const predecessor_storage =
            try allocator.alloc(u8, predecessor_bytes);
        errdefer allocator.free(predecessor_storage);
        const predecessor =
            try source_lease
                .encodeRawTerminalSourceLiveSetV1(
                contract,
                encoded_input,
                predecessor_storage,
            );
        const predecessor_selector =
            try checkpoint_file.prepareInitialSelectorV1(
                predecessor,
            );

        const output_token: u32 =
            @as(u32, 0x0102_0304) + @as(u32, variant);
        const state = publication.makeStateCommitmentV1(
            0x4750_5445_0000_0001,
            logical.prompt.len,
            filledDigest(0xa1),
            0x4750_5452_0000_0001,
            filledDigest(0xa2),
            1,
            1,
            filledDigest(0xa3),
        );
        var semantic: terminal_semantic.TerminalSemanticV1 = .{
            .request_epoch = logical.recovery_input.request_epoch,
            .publication_next_sequence = 1,
            .prompt_tokens = logical.prompt.len,
            .max_new_tokens = 1,
            .kv_position = state.kv_position,
            .sampling_calls = 1,
            .output_length = 1,
            .output_bytes = @sizeOf(u32),
            .execution_abi = state.execution_abi,
            .rng_state_abi = state.rng_state_abi,
            .local_plan_sha256 = logical.recovery_input.plan.plan_sha256,
            .artifact_sha256 = logical.recovery_input
                .bound_plan.artifact.artifact_sha256,
            .token_domain_sha256 = logical.recovery_input.bound_plan
                .token_domain_sha256,
            .token_domain_config_sha256 = logical.recovery_input.bound_plan
                .token_domain_config_sha256,
            .image_container_sha256 = logical.recovery_input.plan
                .image_identity.container_sha256,
            .prompt_sha256 = logical.recovery_input.plan.prompt_sha256,
            .output_sha256 = directOutputRootV1(
                logical.recovery_input.bound_plan
                    .artifact.artifact_sha256,
                logical.recovery_input.bound_plan
                    .token_domain_sha256,
                logical.recovery_input.bound_plan
                    .token_domain_config_sha256,
                output_token,
            ),
            .logical_kv_sha256 = filledDigest(0xa4),
            .kv_state_sha256 = state.kv_state_sha256,
            .rng_state_sha256 = state.rng_state_sha256,
            .output_state_sha256 = state.output_state_sha256,
            .state_commitment_sha256 = state.commitment_sha256,
            .semantic_sha256 = zero_digest,
        };
        semantic.semantic_sha256 =
            terminal_semantic.semanticRootV1(semantic);
        try terminal_semantic.validateV1(semantic);

        const selected_storage = try allocator.alloc(
            u8,
            try direct_terminal.encodedBytesV1(
                predecessor.bytes.len,
            ),
        );
        errdefer allocator.free(selected_storage);
        const selected = try direct_terminal.encodeV1(
            predecessor.bytes,
            &predecessor_selector.bytes,
            semantic,
            output_token,
            selected_storage,
        );
        const selected_selector =
            try testSelectorForSetV1(
                predecessor_selector.selector_sha256,
                selected.set.bytes,
            );
        return .{
            .allocator = allocator,
            .contract_storage = contract_storage,
            .input_storage = input_storage,
            .predecessor_storage = predecessor_storage,
            .selected_storage = selected_storage,
            .predecessor_selector = predecessor_selector,
            .selected_selector = selected_selector,
            .semantic = semantic,
            .output_token = output_token,
        };
    }

    fn deinit(self: *CanonicalFixture) void {
        self.allocator.free(self.selected_storage);
        self.allocator.free(self.predecessor_storage);
        self.allocator.free(self.input_storage);
        self.allocator.free(self.contract_storage);
        self.* = undefined;
    }

    fn predecessorSet(
        self: *const CanonicalFixture,
    ) !checkpoint_file.PreparedSetV1 {
        const decoded = try checkpoint_file.decodeSetV1(
            self.predecessor_storage,
        );
        return .{
            .bytes = self.predecessor_storage,
            .checkpoint_sha256 = decoded.checkpoint_sha256,
        };
    }

    fn selectedSet(
        self: *const CanonicalFixture,
    ) !checkpoint_file.PreparedSetV1 {
        const decoded = try checkpoint_file.decodeSetV1(
            self.selected_storage,
        );
        return .{
            .bytes = self.selected_storage,
            .checkpoint_sha256 = decoded.checkpoint_sha256,
        };
    }
};

test "direct terminal reconciles to one sink-free token" {
    var fixture = try CanonicalFixture.init(
        std.testing.allocator,
        0,
    );
    defer fixture.deinit();

    const decoded = try direct_terminal.decodeV1(
        fixture.selected_storage,
        &fixture.selected_selector,
    );
    const view = try reconcileV1(decoded);
    try std.testing.expect(view.terminal);
    try std.testing.expectEqual(
        direct_terminal.selected_generation,
        view.generation,
    );
    try std.testing.expectEqual(
        direct_terminal.terminal_publication_next_sequence,
        view.publication_next_sequence,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        view.acknowledgement_count,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        view.token_count,
    );
    try std.testing.expectEqual(
        fixture.output_token,
        view.output_token,
    );
    try std.testing.expectEqualDeep(
        decoded.input.package.package_sha256,
        view.package_sha256,
    );
    try std.testing.expectEqualDeep(
        decoded.input.representation
            .representation_sha256,
        view.representation_sha256,
    );
    try std.testing.expectEqualDeep(
        decoded.input.archive_sha256,
        view.input_archive_sha256,
    );
    try std.testing.expectEqualDeep(
        decoded.contract.contract_sha256,
        view.terminal_source_contract_sha256,
    );
    try std.testing.expectEqualDeep(
        decoded.semantic.semantic_sha256,
        view.terminal_semantic_sha256,
    );
    try std.testing.expectEqualDeep(
        decoded.selected_selector.selector_sha256,
        view.selected_selector_sha256,
    );
    try std.testing.expectEqualDeep(
        decoded.predecessor_selector.selector_sha256,
        view.predecessor_selector_sha256,
    );
    try validateViewV1(view);

    var changed = view;
    changed.output_token +%= 1;
    try std.testing.expectError(
        Error.InvalidView,
        validateViewV1(changed),
    );
    changed = view;
    changed.acknowledgement_count = 1;
    changed.view_sha256 = viewRootV1(changed);
    try std.testing.expectError(
        Error.InvalidView,
        validateViewV1(changed),
    );
}

test "directory inspection returns the pure direct terminal view" {
    if (comptime !checkpoint_file.initial_recovery_available_v1)
        return error.SkipZigTest;
    var fixture = try CanonicalFixture.init(
        std.testing.allocator,
        0,
    );
    defer fixture.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try installFixtureV1(
        std.testing.allocator,
        temporary.dir,
        &fixture,
        0x9001,
    );

    const decoded = try direct_terminal.decodeV1(
        fixture.selected_storage,
        &fixture.selected_selector,
    );
    const expected = try reconcileV1(decoded);
    const inspected = try inspectDirectoryV1(
        std.testing.allocator,
        temporary.dir,
        .{ .max_set_bytes = fixture.selected_storage.len },
    );
    try std.testing.expectEqualDeep(expected, inspected);
}

test "directory inspection rejects selector change after reconcile" {
    if (comptime !checkpoint_file.initial_recovery_available_v1)
        return error.SkipZigTest;
    var fixture = try CanonicalFixture.init(
        std.testing.allocator,
        0,
    );
    defer fixture.deinit();
    var replacement = try CanonicalFixture.init(
        std.testing.allocator,
        1,
    );
    defer replacement.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try installFixtureV1(
        std.testing.allocator,
        temporary.dir,
        &fixture,
        0x9002,
    );
    const replacement_name =
        "direct-terminal-selector-replacement";
    try writeTestFileV1(
        temporary.dir,
        replacement_name,
        &replacement.selected_selector,
    );
    var observer_context: SelectorReplacementObserverV1 = .{
        .directory = &temporary.dir,
        .replacement_name = replacement_name,
    };
    try std.testing.expectError(
        Error.SelectionChanged,
        inspectDirectoryV1(
            std.testing.allocator,
            temporary.dir,
            .{
                .max_set_bytes = fixture.selected_storage.len,
                .observer = .{
                    .context = &observer_context,
                    .after_reconcile_fn = SelectorReplacementObserverV1
                        .afterReconcile,
                },
            },
        ),
    );
    try std.testing.expect(observer_context.replaced);
    try std.testing.expect(
        observer_context.operation_error == null,
    );
}

const SelectorReplacementObserverV1 = struct {
    directory: *std.fs.Dir,
    replacement_name: []const u8,
    replaced: bool = false,
    operation_error: ?anyerror = null,

    fn afterReconcile(raw: *anyopaque) void {
        const self: *SelectorReplacementObserverV1 =
            @ptrCast(@alignCast(raw));
        self.directory.rename(
            self.replacement_name,
            checkpoint_file.active_selector_name,
        ) catch |operation_error| {
            self.operation_error = operation_error;
            return;
        };
        self.replaced = true;
    }
};

fn installFixtureV1(
    allocator: std.mem.Allocator,
    directory: std.fs.Dir,
    fixture: *const CanonicalFixture,
    storage_epoch: u64,
) !void {
    const predecessor = try fixture.predecessorSet();
    const selected = try fixture.selectedSet();
    const predecessor_selector =
        try checkpoint_file.decodeSelectorV1(
            &fixture.predecessor_selector.bytes,
        );
    const maximum_bytes = @max(
        predecessor.bytes.len,
        selected.bytes.len,
    );
    const active_storage = try allocator.alloc(
        u8,
        maximum_bytes,
    );
    defer allocator.free(active_storage);
    var lock_storage: [1]u8 = undefined;
    var lease = try checkpoint_file.LeaseV1.create(
        directory,
        storage_epoch,
        predecessor_selector.challenge_sha256,
        predecessor,
        fixture.predecessor_selector,
        maximum_bytes,
        &lock_storage,
        active_storage,
    );
    defer lease.close();
    const prepared =
        try checkpoint_file.preparePublicationV1(
            &lease,
            selected,
        );
    try std.testing.expectEqualSlices(
        u8,
        &fixture.selected_selector,
        &prepared.selector.bytes,
    );
    _ = try checkpoint_file.publishV1(
        &lease,
        prepared,
    );
}

fn writeTestFileV1(
    directory: std.fs.Dir,
    name: []const u8,
    bytes: []const u8,
) !void {
    var file = try directory.createFile(
        name,
        .{
            .exclusive = true,
            .mode = 0o600,
        },
    );
    defer file.close();
    try file.writeAll(bytes);
    try file.sync();
}

fn testSelectorForSetV1(
    previous_selector_sha256: Digest,
    encoded_set: []const u8,
) ![checkpoint_file.selector_bytes]u8 {
    const set = try checkpoint_file.decodeSetV1(
        encoded_set,
    );
    var bytes =
        [_]u8{0} ** checkpoint_file.selector_bytes;
    @memcpy(bytes[0..8], &checkpoint_file.selector_magic);
    writeU64(&bytes, 8, checkpoint_file.selector_abi);
    writeU64(&bytes, 16, checkpoint_file.selector_bytes);
    writeU64(&bytes, 24, set.metadata.generation);
    writeU64(&bytes, 32, set.metadata.request_epoch);
    writeU64(
        &bytes,
        40,
        set.metadata.publication_next_sequence,
    );
    writeU64(&bytes, 48, encoded_set.len);
    writeU64(&bytes, 56, checkpoint_file.allowed_flags);
    @memcpy(
        bytes[64..96],
        &previous_selector_sha256,
    );
    @memcpy(
        bytes[96..128],
        &set.checkpoint_sha256,
    );
    @memcpy(
        bytes[128..160],
        &set.metadata.challenge_sha256,
    );
    const root = checkpoint_file.selectorRootV1(
        bytes[0..checkpoint_file.selector_body_bytes],
    );
    @memcpy(
        bytes[checkpoint_file.selector_body_bytes..],
        &root,
    );
    _ = try checkpoint_file.decodeSelectorV1(&bytes);
    return bytes;
}
