//! Canonical direct-terminal publication for a one-token prepared-text
//! source.
//!
//! A direct terminal generation is an additive generation-two checkpoint. It
//! retains the complete generation-one source pair, the receipt-independent
//! terminal semantic, and exactly one canonical little-endian output token.
//! The record grants no live Scheduler, ResourceBank, or filesystem
//! authority; selection remains the responsibility of the checkpoint lease.

const std = @import("std");
const core = @import("core");
const checkpoint_file = core.continuation_checkpoint_file;
const model_contract = core.model_contract;
const resource_bank = core.resource_bank;
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

pub const predecessor_archive_abi: u64 =
    0x4750_5444_0000_0001;
pub const output_token_abi: u64 =
    0x4750_5444_0000_0002;

pub const predecessor_generation: u64 = 1;
pub const selected_generation: u64 = 2;
pub const terminal_publication_next_sequence: u64 = 1;
pub const selected_object_count: usize = 4;

pub const predecessor_selector_object_ordinal: u64 = 0;
pub const predecessor_archive_object_ordinal: u64 = 0;
pub const terminal_semantic_object_ordinal: u64 = 1;
pub const output_token_object_ordinal: u64 = 2;

pub const Error = checkpoint_file.Error ||
    input_archive.Error ||
    terminal_semantic.Error ||
    terminal_source_recovery.Error ||
    error{
        ArithmeticOverflow,
        InvalidLineage,
        InvalidPredecessor,
        InvalidSelection,
        InvalidTerminal,
    };

pub const PreparedV1 = struct {
    set: checkpoint_file.PreparedSetV1,
    semantic: terminal_semantic.TerminalSemanticV1,
    output_token: u32,
};

/// Fully verified direct-terminal view. Every encoded slice borrows the
/// caller-owned selected checkpoint bytes.
pub const DecodedV1 = struct {
    selected_set: checkpoint_file.DecodedSetV1,
    selected_selector: checkpoint_file.DecodedSelectorV1,
    predecessor_set: checkpoint_file.DecodedSetV1,
    predecessor_selector: checkpoint_file.DecodedSelectorV1,
    contract: terminal_source_recovery.DecodedV1,
    input: input_archive.DecodedV1,
    semantic: terminal_semantic.TerminalSemanticV1,
    canonical_output_u32_le: []const u8,

    pub fn outputToken(self: *const DecodedV1) u32 {
        return std.mem.readInt(
            u32,
            self.canonical_output_u32_le[0..4],
            .little,
        );
    }
};

const SelectionV1 = struct {
    set: checkpoint_file.DecodedSetV1,
    selector: checkpoint_file.DecodedSelectorV1,
};

const PredecessorV1 = struct {
    selection: SelectionV1,
    contract: terminal_source_recovery.DecodedV1,
    input: input_archive.DecodedV1,
};

pub fn encodedBytesV1(
    predecessor_set_bytes: usize,
) Error!usize {
    var total = std.math.add(
        usize,
        checkpoint_file.set_payload_offset +
            checkpoint_file.set_footer_bytes,
        checkpoint_file.selector_bytes,
    ) catch return Error.ArithmeticOverflow;
    total = std.math.add(
        usize,
        total,
        predecessor_set_bytes,
    ) catch return Error.ArithmeticOverflow;
    total = std.math.add(
        usize,
        total,
        terminal_semantic.semantic_bytes,
    ) catch return Error.ArithmeticOverflow;
    return std.math.add(
        usize,
        total,
        @sizeOf(u32),
    ) catch return Error.ArithmeticOverflow;
}

/// Prepare a generation-two direct terminal checkpoint. All supplied
/// authority-free inputs are decoded and cross-checked before the destination
/// is modified.
pub fn encodeV1(
    predecessor_set: []const u8,
    predecessor_selector: []const u8,
    semantic: terminal_semantic.TerminalSemanticV1,
    output_token: u32,
    destination: []u8,
) Error!PreparedV1 {
    const predecessor = try decodePredecessorV1(
        predecessor_set,
        predecessor_selector,
    );
    try validateTerminalV1(
        predecessor.contract,
        predecessor.input,
        semantic,
        output_token,
    );

    var encoded_semantic: [terminal_semantic.semantic_bytes]u8 =
        undefined;
    _ = try terminal_semantic.encodeV1(
        semantic,
        &encoded_semantic,
    );
    var encoded_output_token: [@sizeOf(u32)]u8 = undefined;
    std.mem.writeInt(
        u32,
        &encoded_output_token,
        output_token,
        .little,
    );

    const objects = [_]checkpoint_file.ObjectInputV1{
        .{
            .kind = .runtime_state,
            .ordinal = predecessor_selector_object_ordinal,
            .abi_version = checkpoint_file.selector_abi,
            .bytes = predecessor_selector,
        },
        .{
            .kind = .source_process,
            .ordinal = predecessor_archive_object_ordinal,
            .abi_version = predecessor_archive_abi,
            .bytes = predecessor_set,
        },
        .{
            .kind = .extension,
            .ordinal = terminal_semantic_object_ordinal,
            .abi_version = terminal_semantic.semantic_abi,
            .bytes = &encoded_semantic,
        },
        .{
            .kind = .extension,
            .ordinal = output_token_object_ordinal,
            .abi_version = output_token_abi,
            .bytes = &encoded_output_token,
        },
    };
    const set = try checkpoint_file.encodeSetV1(
        .{
            .generation = selected_generation,
            .request_epoch = predecessor.contract.request_epoch,
            .publication_next_sequence = terminal_publication_next_sequence,
            .parent_checkpoint_sha256 = predecessor.selection.set.checkpoint_sha256,
            .challenge_sha256 = predecessor.contract.challenge_sha256,
        },
        &objects,
        destination,
    );
    return .{
        .set = set,
        .semantic = semantic,
        .output_token = output_token,
    };
}

/// Decode the selected generation and its embedded generation-one source
/// pair. No separately supplied predecessor can redirect the selected
/// lineage.
pub fn decodeV1(
    selected_set: []const u8,
    selected_selector: []const u8,
) Error!DecodedV1 {
    const selected = try decodeSelectionV1(
        selected_set,
        selected_selector,
    );
    if (selected.set.object_count != selected_object_count or
        selected.set.metadata.generation != selected_generation or
        selected.set.metadata.publication_next_sequence !=
            terminal_publication_next_sequence or
        selected.selector.generation != selected_generation or
        selected.selector.publication_next_sequence !=
            terminal_publication_next_sequence)
        return Error.InvalidTerminal;

    const predecessor_selector_object = try exactObjectV1(
        selected.set,
        0,
        .runtime_state,
        predecessor_selector_object_ordinal,
        checkpoint_file.selector_abi,
    );
    const predecessor_archive_object = try exactObjectV1(
        selected.set,
        1,
        .source_process,
        predecessor_archive_object_ordinal,
        predecessor_archive_abi,
    );
    const semantic_object = try exactObjectV1(
        selected.set,
        2,
        .extension,
        terminal_semantic_object_ordinal,
        terminal_semantic.semantic_abi,
    );
    const output_object = try exactObjectV1(
        selected.set,
        3,
        .extension,
        output_token_object_ordinal,
        output_token_abi,
    );
    if (output_object.bytes.len != @sizeOf(u32))
        return Error.InvalidTerminal;

    const predecessor = try decodePredecessorV1(
        predecessor_archive_object.bytes,
        predecessor_selector_object.bytes,
    );
    if (!digestEqual(
        selected.set.metadata.parent_checkpoint_sha256,
        predecessor.selection.set.checkpoint_sha256,
    ) or !digestEqual(
        selected.selector.previous_selector_sha256,
        predecessor.selection.selector.selector_sha256,
    ) or selected.set.metadata.request_epoch !=
        predecessor.contract.request_epoch or
        selected.selector.request_epoch !=
            predecessor.contract.request_epoch or
        !digestEqual(
            selected.set.metadata.challenge_sha256,
            predecessor.contract.challenge_sha256,
        ) or !digestEqual(
        selected.selector.challenge_sha256,
        predecessor.contract.challenge_sha256,
    ))
        return Error.InvalidLineage;

    const semantic = terminal_semantic.decodeV1(
        semantic_object.bytes,
    ) catch return Error.InvalidTerminal;
    const output_token = std.mem.readInt(
        u32,
        output_object.bytes[0..4],
        .little,
    );
    try validateTerminalV1(
        predecessor.contract,
        predecessor.input,
        semantic,
        output_token,
    );
    return .{
        .selected_set = selected.set,
        .selected_selector = selected.selector,
        .predecessor_set = predecessor.selection.set,
        .predecessor_selector = predecessor.selection.selector,
        .contract = predecessor.contract,
        .input = predecessor.input,
        .semantic = semantic,
        .canonical_output_u32_le = output_object.bytes,
    };
}

fn decodeSelectionV1(
    encoded_set: []const u8,
    encoded_selector: []const u8,
) Error!SelectionV1 {
    const set = checkpoint_file.decodeSetV1(
        encoded_set,
    ) catch return Error.InvalidSelection;
    const selector = checkpoint_file.decodeSelectorV1(
        encoded_selector,
    ) catch return Error.InvalidSelection;
    const checkpoint_bytes = std.math.cast(
        u64,
        encoded_set.len,
    ) orelse return Error.InvalidSelection;
    if (selector.generation != set.metadata.generation or
        selector.request_epoch != set.metadata.request_epoch or
        selector.publication_next_sequence !=
            set.metadata.publication_next_sequence or
        selector.checkpoint_bytes != checkpoint_bytes or
        !digestEqual(
            selector.checkpoint_sha256,
            set.checkpoint_sha256,
        ) or !digestEqual(
        selector.challenge_sha256,
        set.metadata.challenge_sha256,
    ))
        return Error.InvalidSelection;
    return .{
        .set = set,
        .selector = selector,
    };
}

fn decodePredecessorV1(
    encoded_set: []const u8,
    encoded_selector: []const u8,
) Error!PredecessorV1 {
    const selection = decodeSelectionV1(
        encoded_set,
        encoded_selector,
    ) catch return Error.InvalidPredecessor;
    if (selection.set.object_count != 3 or
        selection.set.metadata.generation !=
            predecessor_generation or
        selection.set.metadata.publication_next_sequence !=
            terminal_publication_next_sequence or
        selection.selector.generation !=
            predecessor_generation or
        selection.selector.publication_next_sequence !=
            terminal_publication_next_sequence or
        !isZero(
            selection.set.metadata.parent_checkpoint_sha256,
        ) or !isZero(
        selection.selector.previous_selector_sha256,
    ))
        return Error.InvalidPredecessor;

    const marker = exactObjectV1(
        selection.set,
        0,
        .extension,
        source_lease.source_live_object_ordinal,
        source_lease.source_live_marker_abi,
    ) catch return Error.InvalidPredecessor;
    const contract_object = exactObjectV1(
        selection.set,
        1,
        .extension,
        source_lease.source_recovery_object_ordinal,
        terminal_source_recovery.contract_abi,
    ) catch return Error.InvalidPredecessor;
    const input_object = exactObjectV1(
        selection.set,
        2,
        .extension,
        source_lease.source_input_object_ordinal,
        input_archive.archive_abi,
    ) catch return Error.InvalidPredecessor;
    if (!std.mem.eql(
        u8,
        marker.bytes,
        source_lease.source_live_marker,
    ))
        return Error.InvalidPredecessor;

    const contract = terminal_source_recovery.decodeV1(
        contract_object.bytes,
    ) catch return Error.InvalidPredecessor;
    const input = input_archive.decodeV1(
        input_object.bytes,
    ) catch return Error.InvalidPredecessor;
    if (contract.publication_next_sequence !=
        terminal_publication_next_sequence or
        contract.options.max_new_tokens != 1 or
        selection.set.metadata.request_epoch !=
            contract.request_epoch or
        selection.selector.request_epoch !=
            contract.request_epoch or
        !digestEqual(
            selection.set.metadata.challenge_sha256,
            contract.challenge_sha256,
        ) or !digestEqual(
        selection.selector.challenge_sha256,
        contract.challenge_sha256,
    ) or !source_lease.terminalRecoveryInputMatchesContractV1(
        input,
        contract,
    ))
        return Error.InvalidPredecessor;
    return .{
        .selection = selection,
        .contract = contract,
        .input = input,
    };
}

fn validateTerminalV1(
    contract: terminal_source_recovery.DecodedV1,
    input: input_archive.DecodedV1,
    semantic: terminal_semantic.TerminalSemanticV1,
    output_token: u32,
) Error!void {
    terminal_semantic.validateV1(semantic) catch
        return Error.InvalidTerminal;
    const prompt_tokens = std.math.cast(
        u64,
        contract.promptCount(),
    ) orelse return Error.InvalidTerminal;
    const expected_output_sha256 = outputRootV1(
        contract.artifact_sha256,
        contract.bound_plan_input.token_domain_sha256,
        contract.bound_plan_input
            .token_domain_config_sha256,
        output_token,
    );
    if (semantic.request_epoch != contract.request_epoch or
        semantic.publication_next_sequence !=
            terminal_publication_next_sequence or
        semantic.prompt_tokens != prompt_tokens or
        semantic.max_new_tokens != 1 or
        semantic.sampling_calls != 1 or
        semantic.output_length != 1 or
        semantic.output_bytes != @sizeOf(u32) or
        !digestEqual(
            semantic.local_plan_sha256,
            contract.plan_sha256,
        ) or !digestEqual(
        semantic.artifact_sha256,
        contract.artifact_sha256,
    ) or !digestEqual(
        semantic.token_domain_sha256,
        contract.bound_plan_input.token_domain_sha256,
    ) or !digestEqual(
        semantic.token_domain_config_sha256,
        contract.bound_plan_input
            .token_domain_config_sha256,
    ) or !digestEqual(
        semantic.image_container_sha256,
        input.representation.container_sha256,
    ) or !digestEqual(
        semantic.prompt_sha256,
        contract.prompt_sha256,
    ) or !digestEqual(
        semantic.output_sha256,
        expected_output_sha256,
    ))
        return Error.InvalidTerminal;
}

fn exactObjectV1(
    set: checkpoint_file.DecodedSetV1,
    index: usize,
    kind: checkpoint_file.ObjectKindV1,
    ordinal: u64,
    abi_version: u64,
) Error!checkpoint_file.ObjectViewV1 {
    if (index >= set.object_count)
        return Error.InvalidTerminal;
    const object = set.objects[index];
    if (object.kind != kind or
        object.ordinal != ordinal or
        object.abi_version != abi_version)
        return Error.InvalidTerminal;
    return object;
}

fn outputRootV1(
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
    value: u64,
) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, value, .little);
    hash.update(&encoded);
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

fn isZero(value: Digest) bool {
    return std.mem.allEqual(u8, &value, 0);
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
            try tokenizer.makeUtf8ByteManifestV1(
                256,
                256,
            );
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
            .plan_sha256 = [_]u8{0} ** 32,
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
                    .previous_plan_sha256 = bound_plan_input.previous_plan_sha256,
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
            .bound_plan_sha256 = [_]u8{0} ** 32,
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
            .model_profile_id = @enumFromInt(255),
            .tensor_profile_abi = 1,
            .tensor_count = 21,
            .tensor_inventory_sha256 = filledDigest(0x25),
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

        var result: TestFixture = undefined;
        result.prompt = prompt;
        result.raw_text = raw_text;
        result.recovery_input = .{
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
        };
        result.package = package;
        result.representation = representation;
        return result;
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
            try source_lease.encodeRawTerminalSourceLiveSetV1(
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
            .token_domain_sha256 = logical.recovery_input
                .bound_plan.token_domain_sha256,
            .token_domain_config_sha256 = logical.recovery_input.bound_plan
                .token_domain_config_sha256,
            .image_container_sha256 = logical.recovery_input.plan.image_identity
                .container_sha256,
            .prompt_sha256 = logical.recovery_input.plan.prompt_sha256,
            .output_sha256 = outputRootV1(
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
            .semantic_sha256 = [_]u8{0} ** 32,
        };
        semantic.semantic_sha256 =
            terminal_semantic.semanticRootV1(semantic);
        try terminal_semantic.validateV1(semantic);

        const selected_storage = try allocator.alloc(
            u8,
            try encodedBytesV1(predecessor.bytes.len),
        );
        errdefer allocator.free(selected_storage);
        const selected = try encodeV1(
            predecessor.bytes,
            &predecessor_selector.bytes,
            semantic,
            output_token,
            selected_storage,
        );
        const selected_selector = try testSelectorForSetV1(
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
};

test "direct terminal is an exact additive one-token selection" {
    var fixture = try CanonicalFixture.init(
        std.testing.allocator,
        0,
    );
    defer fixture.deinit();

    const decoded = try decodeV1(
        fixture.selected_storage,
        &fixture.selected_selector,
    );
    try std.testing.expectEqual(
        try encodedBytesV1(fixture.predecessor_storage.len),
        fixture.selected_storage.len,
    );
    try std.testing.expectEqual(
        selected_generation,
        decoded.selected_set.metadata.generation,
    );
    try std.testing.expectEqual(
        terminal_publication_next_sequence,
        decoded.selected_set.metadata
            .publication_next_sequence,
    );
    try std.testing.expectEqual(
        fixture.output_token,
        decoded.outputToken(),
    );
    try std.testing.expectEqualDeep(
        fixture.semantic,
        decoded.semantic,
    );
    try std.testing.expectEqualSlices(
        u8,
        &fixture.predecessor_selector.bytes,
        decoded.selected_set.objects[0].bytes,
    );
    try std.testing.expectEqualSlices(
        u8,
        fixture.predecessor_storage,
        decoded.selected_set.objects[1].bytes,
    );
    try std.testing.expectEqual(
        predecessor_archive_abi,
        decoded.selected_set.objects[1].abi_version,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        decoded.contract.options.max_new_tokens,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        decoded.semantic.publication_next_sequence,
    );
    try std.testing.expectEqual(
        decoded.contract.request_epoch,
        decoded.semantic.request_epoch,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        decoded.semantic.max_new_tokens,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        decoded.semantic.sampling_calls,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        decoded.semantic.output_length,
    );
    try std.testing.expectEqual(
        @as(usize, @sizeOf(u32)),
        decoded.canonical_output_u32_le.len,
    );
    var expected_token_bytes: [4]u8 = undefined;
    std.mem.writeInt(
        u32,
        &expected_token_bytes,
        fixture.output_token,
        .little,
    );
    try std.testing.expectEqualSlices(
        u8,
        &expected_token_bytes,
        decoded.canonical_output_u32_le,
    );
    try std.testing.expectError(
        Error.ArithmeticOverflow,
        encodedBytesV1(std.math.maxInt(usize)),
    );
}

test "direct terminal rejects every selected byte mutation and size drift" {
    var fixture = try CanonicalFixture.init(
        std.testing.allocator,
        0,
    );
    defer fixture.deinit();

    const allocator = std.testing.allocator;
    const mutated_set = try allocator.dupe(
        u8,
        fixture.selected_storage,
    );
    defer allocator.free(mutated_set);
    for (0..mutated_set.len) |index| {
        @memcpy(mutated_set, fixture.selected_storage);
        mutated_set[index] ^= 1;
        try expectDecodeRejectedV1(
            mutated_set,
            &fixture.selected_selector,
        );
    }

    var mutated_selector = fixture.selected_selector;
    for (0..mutated_selector.len) |index| {
        mutated_selector = fixture.selected_selector;
        mutated_selector[index] ^= 1;
        try expectDecodeRejectedV1(
            fixture.selected_storage,
            &mutated_selector,
        );
    }
    try expectDecodeRejectedV1(
        fixture.selected_storage[0 .. fixture.selected_storage.len - 1],
        &fixture.selected_selector,
    );
    const extended = try allocator.alloc(
        u8,
        fixture.selected_storage.len + 1,
    );
    defer allocator.free(extended);
    @memcpy(
        extended[0..fixture.selected_storage.len],
        fixture.selected_storage,
    );
    extended[extended.len - 1] = 0;
    try expectDecodeRejectedV1(
        extended,
        &fixture.selected_selector,
    );
}

test "direct terminal rejects coherent lineage object and payload drift" {
    const allocator = std.testing.allocator;
    var canonical = try CanonicalFixture.init(allocator, 0);
    defer canonical.deinit();
    var foreign = try CanonicalFixture.init(allocator, 1);
    defer foreign.deinit();

    const decoded_set = try checkpoint_file.decodeSetV1(
        canonical.selected_storage,
    );
    var objects = objectInputsV1(decoded_set);
    var metadata = decoded_set.metadata;

    metadata.generation = selected_generation + 1;
    try expectCoherentSetRejectedV1(
        allocator,
        canonical.predecessor_selector.selector_sha256,
        metadata,
        &objects,
    );
    metadata = decoded_set.metadata;
    metadata.publication_next_sequence = 2;
    try expectCoherentSetRejectedV1(
        allocator,
        canonical.predecessor_selector.selector_sha256,
        metadata,
        &objects,
    );
    metadata = decoded_set.metadata;
    metadata.parent_checkpoint_sha256 =
        filledDigest(0xe1);
    try expectCoherentSetRejectedV1(
        allocator,
        canonical.predecessor_selector.selector_sha256,
        metadata,
        &objects,
    );
    try expectCoherentSetRejectedV1(
        allocator,
        filledDigest(0xe2),
        decoded_set.metadata,
        &objects,
    );

    objects = objectInputsV1(decoded_set);
    objects[0].kind = .payload_snapshot;
    try expectCoherentSetRejectedV1(
        allocator,
        canonical.predecessor_selector.selector_sha256,
        decoded_set.metadata,
        &objects,
    );
    objects = objectInputsV1(decoded_set);
    objects[1].kind = .extension;
    try expectCoherentSetRejectedV1(
        allocator,
        canonical.predecessor_selector.selector_sha256,
        decoded_set.metadata,
        &objects,
    );
    objects = objectInputsV1(decoded_set);
    objects[2].ordinal = 0;
    try expectCoherentSetRejectedV1(
        allocator,
        canonical.predecessor_selector.selector_sha256,
        decoded_set.metadata,
        &objects,
    );
    objects = objectInputsV1(decoded_set);
    objects[3].ordinal = 3;
    try expectCoherentSetRejectedV1(
        allocator,
        canonical.predecessor_selector.selector_sha256,
        decoded_set.metadata,
        &objects,
    );
    for (0..objects.len) |index| {
        objects = objectInputsV1(decoded_set);
        objects[index].abi_version +%= 1;
        try expectCoherentSetRejectedV1(
            allocator,
            canonical.predecessor_selector.selector_sha256,
            decoded_set.metadata,
            &objects,
        );
    }

    objects = objectInputsV1(decoded_set);
    try expectCoherentSetRejectedV1(
        allocator,
        canonical.predecessor_selector.selector_sha256,
        decoded_set.metadata,
        objects[0..3],
    );
    var extra_objects: [5]checkpoint_file.ObjectInputV1 =
        undefined;
    @memcpy(extra_objects[0..4], &objects);
    extra_objects[4] = .{
        .kind = .extension,
        .ordinal = 3,
        .abi_version = output_token_abi,
        .bytes = &.{0},
    };
    try expectCoherentSetRejectedV1(
        allocator,
        canonical.predecessor_selector.selector_sha256,
        decoded_set.metadata,
        &extra_objects,
    );

    const foreign_set = try checkpoint_file.decodeSetV1(
        foreign.selected_storage,
    );
    objects = objectInputsV1(decoded_set);
    objects[0].bytes = foreign_set.objects[0].bytes;
    objects[1].bytes = foreign_set.objects[1].bytes;
    try expectCoherentSetRejectedV1(
        allocator,
        canonical.predecessor_selector.selector_sha256,
        decoded_set.metadata,
        &objects,
    );

    objects = objectInputsV1(decoded_set);
    var changed_token_bytes: [4]u8 = undefined;
    std.mem.writeInt(
        u32,
        &changed_token_bytes,
        canonical.output_token + 1,
        .little,
    );
    objects[3].bytes = &changed_token_bytes;
    try expectCoherentSetRejectedV1(
        allocator,
        canonical.predecessor_selector.selector_sha256,
        decoded_set.metadata,
        &objects,
    );
    const oversized_token_bytes: [8]u8 =
        [_]u8{0} ** 8;
    objects[3].bytes = &oversized_token_bytes;
    try expectCoherentSetRejectedV1(
        allocator,
        canonical.predecessor_selector.selector_sha256,
        decoded_set.metadata,
        &objects,
    );

    objects = objectInputsV1(decoded_set);
    var foreign_semantic = canonical.semantic;
    foreign_semantic.max_new_tokens = 2;
    foreign_semantic.semantic_sha256 =
        terminal_semantic.semanticRootV1(foreign_semantic);
    var foreign_semantic_bytes: [terminal_semantic.semantic_bytes]u8 = undefined;
    _ = try terminal_semantic.encodeV1(
        foreign_semantic,
        &foreign_semantic_bytes,
    );
    objects[2].bytes = &foreign_semantic_bytes;
    try expectCoherentSetRejectedV1(
        allocator,
        canonical.predecessor_selector.selector_sha256,
        decoded_set.metadata,
        &objects,
    );

    foreign_semantic = canonical.semantic;
    foreign_semantic.request_epoch += 1;
    foreign_semantic.semantic_sha256 =
        terminal_semantic.semanticRootV1(foreign_semantic);
    _ = try terminal_semantic.encodeV1(
        foreign_semantic,
        &foreign_semantic_bytes,
    );
    objects[2].bytes = &foreign_semantic_bytes;
    try expectCoherentSetRejectedV1(
        allocator,
        canonical.predecessor_selector.selector_sha256,
        decoded_set.metadata,
        &objects,
    );

    const multi_state = publication.makeStateCommitmentV1(
        canonical.semantic.execution_abi,
        canonical.semantic.prompt_tokens + 1,
        canonical.semantic.kv_state_sha256,
        canonical.semantic.rng_state_abi,
        canonical.semantic.rng_state_sha256,
        2,
        2,
        canonical.semantic.output_state_sha256,
    );
    foreign_semantic = canonical.semantic;
    foreign_semantic.publication_next_sequence = 2;
    foreign_semantic.max_new_tokens = 2;
    foreign_semantic.kv_position = multi_state.kv_position;
    foreign_semantic.sampling_calls = 2;
    foreign_semantic.output_length = 2;
    foreign_semantic.output_bytes = 2 * @sizeOf(u32);
    foreign_semantic.state_commitment_sha256 =
        multi_state.commitment_sha256;
    foreign_semantic.semantic_sha256 =
        terminal_semantic.semanticRootV1(foreign_semantic);
    _ = try terminal_semantic.encodeV1(
        foreign_semantic,
        &foreign_semantic_bytes,
    );
    objects[2].bytes = &foreign_semantic_bytes;
    try expectCoherentSetRejectedV1(
        allocator,
        canonical.predecessor_selector.selector_sha256,
        decoded_set.metadata,
        &objects,
    );
}

test "direct terminal encode validates before publishing destination bytes" {
    var fixture = try CanonicalFixture.init(
        std.testing.allocator,
        0,
    );
    defer fixture.deinit();

    const required = try encodedBytesV1(
        fixture.predecessor_storage.len,
    );
    const destination = try std.testing.allocator.alloc(
        u8,
        required - 1,
    );
    defer std.testing.allocator.free(destination);
    @memset(destination, 0xa5);
    try std.testing.expectError(
        error.BufferTooSmall,
        encodeV1(
            fixture.predecessor_storage,
            &fixture.predecessor_selector.bytes,
            fixture.semantic,
            fixture.output_token,
            destination,
        ),
    );
    try std.testing.expect(
        std.mem.allEqual(u8, destination, 0xa5),
    );

    var invalid_semantic = fixture.semantic;
    invalid_semantic.request_epoch += 1;
    invalid_semantic.semantic_sha256 =
        terminal_semantic.semanticRootV1(invalid_semantic);
    try std.testing.expectError(
        Error.InvalidTerminal,
        encodeV1(
            fixture.predecessor_storage,
            &fixture.predecessor_selector.bytes,
            invalid_semantic,
            fixture.output_token,
            destination,
        ),
    );
    try std.testing.expect(
        std.mem.allEqual(u8, destination, 0xa5),
    );
}

fn objectInputsV1(
    set: checkpoint_file.DecodedSetV1,
) [selected_object_count]checkpoint_file.ObjectInputV1 {
    var objects: [selected_object_count]checkpoint_file.ObjectInputV1 =
        undefined;
    for (
        set.objects[0..selected_object_count],
        &objects,
    ) |object, *input| {
        input.* = .{
            .kind = object.kind,
            .ordinal = object.ordinal,
            .abi_version = object.abi_version,
            .bytes = object.bytes,
        };
    }
    return objects;
}

fn expectCoherentSetRejectedV1(
    allocator: std.mem.Allocator,
    previous_selector_sha256: Digest,
    metadata: checkpoint_file.MetadataV1,
    objects: []const checkpoint_file.ObjectInputV1,
) !void {
    var required =
        checkpoint_file.set_payload_offset +
        checkpoint_file.set_footer_bytes;
    for (objects) |object|
        required = try std.math.add(
            usize,
            required,
            object.bytes.len,
        );
    const storage = try allocator.alloc(u8, required);
    defer allocator.free(storage);
    const prepared = try checkpoint_file.encodeSetV1(
        metadata,
        objects,
        storage,
    );
    const selector = try testSelectorForSetV1(
        previous_selector_sha256,
        prepared.bytes,
    );
    try expectDecodeRejectedV1(
        prepared.bytes,
        &selector,
    );
}

fn expectDecodeRejectedV1(
    selected_set: []const u8,
    selected_selector: []const u8,
) !void {
    if (decodeV1(
        selected_set,
        selected_selector,
    )) |_| {
        return error.TestExpectedError;
    } else |_| {}
}

fn testSelectorForSetV1(
    previous_selector_sha256: Digest,
    encoded_set: []const u8,
) ![checkpoint_file.selector_bytes]u8 {
    const set = try checkpoint_file.decodeSetV1(encoded_set);
    var bytes: [checkpoint_file.selector_bytes]u8 =
        [_]u8{0} ** checkpoint_file.selector_bytes;
    @memcpy(bytes[0..8], &checkpoint_file.selector_magic);
    testWriteU64(&bytes, 8, checkpoint_file.selector_abi);
    testWriteU64(&bytes, 16, checkpoint_file.selector_bytes);
    testWriteU64(&bytes, 24, set.metadata.generation);
    testWriteU64(&bytes, 32, set.metadata.request_epoch);
    testWriteU64(
        &bytes,
        40,
        set.metadata.publication_next_sequence,
    );
    testWriteU64(&bytes, 48, encoded_set.len);
    testWriteU64(&bytes, 56, checkpoint_file.allowed_flags);
    @memcpy(bytes[64..96], &previous_selector_sha256);
    @memcpy(bytes[96..128], &set.checkpoint_sha256);
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

fn testWriteU64(
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
