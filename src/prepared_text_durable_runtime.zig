//! Public write-side durable runtime for prepared-text requests.
//!
//! `bootstrapFileV1` materializes the canonical generation-one source
//! recovery contract and raw-input archive, then creates or exactly recovers
//! their checkpoint-file selection. `advanceSourceFileV1` reopens that
//! selection, verifies the archived input against a loaded model, commits
//! exactly the first source token, and publishes the recoverable
//! generation-two source-exit authority. `advanceTargetFileV1` consumes one
//! selected restart, durably applies its one-token acknowledgement, and
//! publishes either the next acknowledged restart or canonical terminal
//! selection.
//!
//! Loaded models, runtime storage, directories, and configured identities
//! remain caller-owned. File leases and live runtime ownership are closed
//! before a typed receipt is returned.

const std = @import("std");
const core = @import("core");
const checkpoint_file = core.continuation_checkpoint_file;
const lane = core.lane_weave_qos;
const resource_bank = core.resource_bank;
const publication = @import("lane_publication_txn.zig");
const loader = @import("loader.zig");
const package_manifest = @import("model/package_manifest.zig");
const checkpoint = @import("prepared_text_checkpoint.zig");
const durable = @import("prepared_text_durable_handoff.zig");
const archive = @import("prepared_text_handoff_archive.zig");
const acknowledged_progress =
    @import("prepared_text_acknowledged_progress.zig");
const acknowledged_restore =
    @import("prepared_text_acknowledged_restore.zig");
const input_archive =
    @import("prepared_text_input_archive.zig");
const lane_contiguous =
    @import("lane_contiguous_publication.zig");
const restart_manifest =
    @import("prepared_text_restart_manifest.zig");
const restore = @import("prepared_text_restore_admission.zig");
const result_sink = @import("prepared_text_result_sink.zig");
const result_sink_file =
    @import("prepared_text_result_sink_file.zig");
const session = @import("prepared_text_session.zig");
const source_lease = @import("prepared_text_source_lease.zig");
const source_recovery =
    @import("prepared_text_source_recovery.zig");
const successor = @import("prepared_text_successor.zig");
const terminal =
    @import("prepared_text_terminal_equivalence.zig");
const tokenizer = @import("tokenizer.zig");

pub const Digest = checkpoint_file.Digest;
pub const ObserverV1 = checkpoint_file.ObserverV1;
pub const InitialDispositionV1 =
    checkpoint_file.InitialDispositionV1;
pub const SourceRuntimeIdentityV1 =
    source_recovery.SourceRuntimeIdentityV1;
pub const TargetOwnershipV1 = successor.TargetOwnershipV1;
pub const bootstrap_file_available_v1 =
    checkpoint_file.initial_recovery_available_v1;

const initial_publication_next_sequence: u64 = 1;
const initial_sink_sequence: u64 = 1;
const zero_digest: Digest = [_]u8{0} ** 32;

pub const Error = error{
    AuthorityCapacityTooSmall,
    InvalidAdvancePlan,
    InvalidInitialSelection,
    InvalidSourceRecoveryContract,
    InvalidSourceRecoveryGeneration,
    InvalidSourceRuntime,
    InvalidSourceSequence,
    InvalidSourceSink,
    InvalidStepSink,
    InvalidTargetActivation,
    InvalidTargetPlan,
    InvalidTargetProgress,
    InvalidTargetRuntime,
    InvalidTargetSequence,
    InvalidTargetSink,
    InvalidTerminalSelection,
    OutputStorageTooSmall,
    RuntimeAuthorityLeak,
    SourceAdmissionRejected,
    TargetAdmissionRejected,
    TargetRecoveryRequired,
};

/// Result-sink identity retained in the generation-one recovery contract.
///
/// `capacity` must cover the remaining output after sequence one. The
/// recovery-contract encoder validates that it is exactly
/// `options.max_new_tokens - 1`.
pub const SinkConfigV1 = struct {
    storage_epoch: u64,
    capacity: usize,
    implementation_sha256: Digest,
    instance_sha256: Digest,
};

/// Immutable roots known before generation-one storage mutation begins.
///
/// A crash harness can retain this plan in process-local observation state so
/// an after-phase callback can distinguish the predecessor from the exact
/// successor. Observing the plan grants no checkpoint or result-sink
/// authority.
pub const BootstrapPlanV1 = struct {
    generation: u64,
    request_epoch: u64,
    publication_next_sequence: u64,
    checkpoint_sha256: Digest,
    selector_sha256: Digest,
    source_recovery_contract_sha256: Digest,
    input_archive_sha256: Digest,
};

pub const BootstrapPlanObserverV1 = struct {
    context: *anyopaque,
    observe_fn: *const fn (
        context: *anyopaque,
        plan: BootstrapPlanV1,
    ) void,

    pub fn observe(
        self: BootstrapPlanObserverV1,
        plan: BootstrapPlanV1,
    ) void {
        self.observe_fn(self.context, plan);
    }
};

/// Checkpoint-file authority supplied by the caller.
///
/// `directory` is borrowed and remains open after the call. `max_set_bytes`
/// bounds both the newly encoded set and any exact set loaded during
/// recovery.
pub const FileStorageV1 = struct {
    directory: std.fs.Dir,
    storage_epoch: u64,
    max_set_bytes: usize,
};

/// Complete caller-owned context for one generation-one bootstrap.
///
/// The Scheduler must be address-stable, open, and exclusively inspected for
/// the duration of the call. Its durable identity and challenge are checked
/// against `source_runtime` and the recomputed bound plan. The optional
/// observer is forwarded unchanged to the checkpoint-file publication so
/// crash campaigns can observe every durable I/O phase.
pub const BootstrapFileInputV1 = struct {
    model: *const loader.LoadedModel,
    package: package_manifest.ManifestV1,
    representation: package_manifest.PreparedRepresentationV1,
    raw_text: []const u8,
    tokenizer_manifest: tokenizer.Utf8ByteManifestV1,
    options: session.OptionsV1,
    scheduling: session.SchedulingV1,
    bound_plan_input: session.BoundPlanInputV1,
    source_runtime: SourceRuntimeIdentityV1,
    scheduler: *lane.Scheduler,
    target: TargetOwnershipV1,
    sink: SinkConfigV1,
    file: FileStorageV1,
    plan_observer: ?BootstrapPlanObserverV1 = null,
    observer: ?ObserverV1 = null,
};

/// Durable evidence returned after the checkpoint lease has been released.
pub const BootstrapFileReceiptV1 = struct {
    disposition: InitialDispositionV1,
    generation: u64,
    request_epoch: u64,
    publication_next_sequence: u64,
    checkpoint_sha256: Digest,
    selector_sha256: Digest,
    source_recovery_contract_sha256: Digest,
    input_archive_sha256: Digest,
};

/// Live source runtime borrowed for one generation-one execution attempt.
///
/// The Bank and Scheduler must be the exact pair used to create the bound
/// plan retained by the source contract. `advanceSourceFileV1` drains and
/// closes the Scheduler before returning successfully.
pub const SourceRuntimeV1 = struct {
    bank: *resource_bank.Bank,
    scheduler: *lane.Scheduler,
};

/// Application-owned routing policy for the target runtime.
///
/// The resolver receives the freshly recomputed source bound plan. The
/// returned pointer-free ownership value must exactly match the value retained
/// in the recovery contract.
pub const TargetOwnershipResolverV1 = struct {
    context: *anyopaque,
    resolve_fn: *const fn (
        context: *anyopaque,
        bound_plan: session.BoundPlanV1,
    ) anyerror!TargetOwnershipV1,

    pub fn resolve(
        self: TargetOwnershipResolverV1,
        bound_plan: session.BoundPlanV1,
    ) !TargetOwnershipV1 {
        return self.resolve_fn(self.context, bound_plan);
    }
};

/// Deterministic acknowledgement identity used by the first in-process
/// publication transaction. Both values are retained by the captured source
/// checkpoint, so applications must supply stable nonzero identities.
pub const SourceStepSinkV1 = struct {
    sink_epoch: u64,
    reservation_id: u64,
};

pub const AdvanceDispositionV1 = enum(u8) {
    advanced,
    already_selected,
};

pub const AdvancePhaseV1 = enum(u8) {
    after_recovery_admission,
    after_initial_sink,
    after_step,
    after_handoff_prepare,
    after_exit_commit,
    after_generation_two,
};

/// Current externally visible roots at one logical transition barrier.
pub const AdvanceProgressV1 = struct {
    phase: AdvancePhaseV1,
    input_generation: u64,
    input_sequence: u64,
    sink_count: usize,
    sink_ledger_sha256: Digest,
    sink_selector_sha256: Digest,
    checkpoint_selector_sha256: Digest,
};

pub const AdvanceProgressObserverV1 = struct {
    context: *anyopaque,
    after_phase_fn: *const fn (
        context: *anyopaque,
        progress: AdvanceProgressV1,
    ) anyerror!void,

    pub fn after(
        self: AdvanceProgressObserverV1,
        progress: AdvanceProgressV1,
    ) !void {
        try self.after_phase_fn(self.context, progress);
    }
};

/// Immutable predecessor and empty-sink facts known before logical execution.
pub const AdvanceRecoveredPlanV1 = struct {
    input_generation: u64,
    input_sequence: u64,
    checkpoint_selector_sha256: Digest,
    empty_sink_ledger_sha256: Digest,
    empty_sink_selector_sha256: Digest,
};

/// Immutable generation-two roots known before checkpoint publication.
pub const AdvanceSuccessorPlanV1 = struct {
    checkpoint_sha256: Digest,
    selector_sha256: Digest,
};

pub const AdvancePlanV1 = union(enum) {
    recovered: AdvanceRecoveredPlanV1,
    successor: AdvanceSuccessorPlanV1,
};

pub const AdvancePlanObserverV1 = struct {
    context: *anyopaque,
    observe_fn: *const fn (
        context: *anyopaque,
        plan: AdvancePlanV1,
    ) void,

    pub fn observe(
        self: AdvancePlanObserverV1,
        plan: AdvancePlanV1,
    ) void {
        self.observe_fn(self.context, plan);
    }
};

/// Required fail-stop policy after durable source-exit commit.
///
/// Once the source exit is committed, returning an ordinary error could
/// expose a half-transitioned process-local authority. Every subsequent
/// failure, including an injected observer failure, is routed here.
pub const FailStopV1 = struct {
    context: *anyopaque,
    invoke_fn: *const fn (context: *anyopaque) noreturn,

    pub fn invoke(self: FailStopV1) noreturn {
        self.invoke_fn(self.context);
    }
};

pub const AdvanceObserversV1 = struct {
    plan: ?AdvancePlanObserverV1 = null,
    progress: ?AdvanceProgressObserverV1 = null,
    sink: ?result_sink_file.PhaseObserverV1 = null,
    checkpoint: ?checkpoint_file.ObserverV1 = null,
};

/// Caller-owned context for one idempotent source-live to source-exited
/// transition.
pub const AdvanceSourceFileInputV1 = struct {
    model: *loader.LoadedModel,
    runtime: SourceRuntimeV1,
    target: TargetOwnershipResolverV1,
    step_sink: SourceStepSinkV1,
    sink: SinkConfigV1,
    file: FileStorageV1,
    observers: AdvanceObserversV1 = .{},
    fail_stop: FailStopV1,
};

/// Durable transition evidence returned after every live authority is closed.
pub const AdvanceSourceFileReceiptV1 = struct {
    disposition: AdvanceDispositionV1,
    input_generation: u64,
    input_sequence: u64,
    output_generation: u64,
    output_sequence: u64,
    output_token: u32,
    sink_count: usize,
    sink_next_sequence: u64,
    sink_ledger_sha256: Digest,
    sink_selector_sha256: Digest,
    checkpoint_sha256: Digest,
    checkpoint_selector_sha256: Digest,
    source_recovery_contract_sha256: Digest,
    ownership_closed: bool,
};

pub const TargetRuntimeV1 = SourceRuntimeV1;

/// Lazily initialize caller-owned target runtime storage after the selected
/// restart reveals its exact target ownership identity.
pub const TargetRuntimeFactoryV1 = struct {
    context: *anyopaque,
    init_fn: *const fn (
        context: *anyopaque,
        target: TargetOwnershipV1,
    ) anyerror!TargetRuntimeV1,

    pub fn init(
        self: TargetRuntimeFactoryV1,
        target: TargetOwnershipV1,
    ) !TargetRuntimeV1 {
        return self.init_fn(self.context, target);
    }
};

/// Optional application oracle over an already canonical terminal semantic.
///
/// The callback receives the value by copy and cannot replace bytes or roots
/// selected by the runtime. Omitting it skips only external equivalence
/// policy; canonical construction and validation remain mandatory.
pub const TerminalSemanticVerifierV1 = struct {
    context: *anyopaque,
    verify_fn: *const fn (
        context: *anyopaque,
        semantic: terminal.TerminalSemanticV1,
    ) anyerror!void,

    pub fn verify(
        self: TerminalSemanticVerifierV1,
        semantic: terminal.TerminalSemanticV1,
    ) !void {
        try self.verify_fn(self.context, semantic);
    }
};

pub const TargetPhaseV1 = enum(u8) {
    after_step_before_sink,
    after_sink_before_selector,
};

pub const TargetProgressV1 = struct {
    phase: TargetPhaseV1,
    input_generation: u64,
    input_sequence: u64,
    sink_count: usize,
    sink_ledger_sha256: Digest,
    sink_selector_sha256: Digest,
    checkpoint_selector_sha256: Digest,
};

pub const TargetProgressObserverV1 = struct {
    context: *anyopaque,
    after_phase_fn: *const fn (
        context: *anyopaque,
        progress: TargetProgressV1,
    ) anyerror!void,

    pub fn after(
        self: TargetProgressObserverV1,
        progress: TargetProgressV1,
    ) !void {
        try self.after_phase_fn(self.context, progress);
    }
};

pub const TargetSinkPlanV1 = struct {
    acknowledgement_count: usize,
    ledger_sha256: Digest,
    selector_sha256: Digest,
};

pub const TargetCheckpointPlanV1 = struct {
    checkpoint_sha256: Digest,
    selector_sha256: Digest,
};

pub const TargetPlanV1 = union(enum) {
    sink: TargetSinkPlanV1,
    checkpoint: TargetCheckpointPlanV1,
};

pub const TargetPlanObserverV1 = struct {
    context: *anyopaque,
    observe_fn: *const fn (
        context: *anyopaque,
        plan: TargetPlanV1,
    ) void,

    pub fn observe(
        self: TargetPlanObserverV1,
        plan: TargetPlanV1,
    ) void {
        self.observe_fn(self.context, plan);
    }
};

pub const TargetObserversV1 = struct {
    plan: ?TargetPlanObserverV1 = null,
    progress: ?TargetProgressObserverV1 = null,
    sink: ?result_sink_file.PhaseObserverV1 = null,
    checkpoint: ?checkpoint_file.ObserverV1 = null,
};

pub const TargetSinkDispositionV1 = enum(u8) {
    none,
    applied,
    replayed,
};

pub const AdvanceTargetDispositionV1 = enum(u8) {
    advanced,
    already_terminal,
};

/// Caller-owned context for one acknowledged target step.
///
/// `output_storage` receives the complete visible token prefix and is borrowed
/// by the returned receipt. `request_epoch`, `sink_initial_sequence`, and
/// `challenge_sha256` are independent expected values for legacy selections
/// and are also checked against every recoverable contract.
pub const AdvanceTargetFileInputV1 = struct {
    model: *loader.LoadedModel,
    runtime_factory: TargetRuntimeFactoryV1,
    next_target: TargetOwnershipResolverV1,
    step_sink: SourceStepSinkV1,
    request_epoch: u64,
    sink_initial_sequence: u64,
    challenge_sha256: Digest,
    sink: SinkConfigV1,
    file: FileStorageV1,
    output_storage: []u32,
    terminal_verifier: ?TerminalSemanticVerifierV1 = null,
    observers: TargetObserversV1 = .{},
    fail_stop: FailStopV1,
};

/// Durable target-step evidence returned with all runtime and file ownership
/// released. `output_tokens` borrows the caller's `output_storage`.
pub const AdvanceTargetFileReceiptV1 = struct {
    disposition: AdvanceTargetDispositionV1,
    input_generation: u64,
    input_sequence: u64,
    output_generation: u64,
    output_sequence: u64,
    sink_disposition: TargetSinkDispositionV1,
    sink_count: usize,
    sink_next_sequence: u64,
    sink_ledger_sha256: Digest,
    sink_selector_sha256: Digest,
    checkpoint_sha256: Digest,
    checkpoint_selector_sha256: Digest,
    terminal: bool,
    output_tokens: []const u32,
    terminal_semantic_sha256: Digest,
    ownership_closed: bool,
};

/// Create or exactly recover the canonical generation-one prepared-text
/// checkpoint.
///
/// All request evidence is recomputed from the loaded model and raw UTF-8
/// bytes. No caller-supplied plan or encoded archive is trusted. A successful
/// return never retains process-local model, Scheduler, allocator, or
/// directory authority.
pub fn bootstrapFileV1(
    allocator: std.mem.Allocator,
    input: BootstrapFileInputV1,
) !BootstrapFileReceiptV1 {
    if (comptime !bootstrap_file_available_v1)
        return checkpoint_file.Error.UnsupportedPlatform;
    const scheduler_identity =
        try input.scheduler.identityV1();
    if (!runtimeIdentityMatchesV1(
        input.source_runtime,
        scheduler_identity,
    ))
        return Error.InvalidSourceRuntime;

    var tokenized = try tokenizer.tokenizeUtf8BytesV1(
        allocator,
        input.tokenizer_manifest,
        input.raw_text,
    );
    defer tokenized.deinit();

    const local_plan = try session.makePlanV1(
        input.model.*,
        tokenized.tokens,
        input.options,
    );
    const bound_plan = try session.makeBoundPlanV1(
        input.model.*,
        tokenized.tokens,
        input.options,
        local_plan,
        input.scheduling,
        input.scheduler,
        input.bound_plan_input,
    );
    const recovery_input: source_recovery.InputV1 = .{
        .prompt = tokenized.tokens,
        .options = input.options,
        .scheduling = input.scheduling,
        .bound_plan_input = input.bound_plan_input,
        .plan = local_plan,
        .bound_plan = bound_plan,
        .source_runtime = input.source_runtime,
        .request_epoch = input.bound_plan_input.request_epoch,
        .publication_next_sequence = initial_publication_next_sequence,
        .challenge_sha256 = scheduler_identity.challenge_sha256,
        .target = input.target,
        .sink_storage_epoch = input.sink.storage_epoch,
        .sink_capacity = input.sink.capacity,
        .sink_initial_sequence = initial_sink_sequence,
        .sink_implementation_sha256 = input.sink.implementation_sha256,
        .sink_instance_sha256 = input.sink.instance_sha256,
    };

    const contract_storage = try allocator.alloc(
        u8,
        try source_recovery.encodedBytesV1(
            tokenized.tokens.len,
        ),
    );
    defer allocator.free(contract_storage);
    const encoded_contract = try source_recovery.encodeV1(
        recovery_input,
        contract_storage,
    );
    const decoded_contract = try source_recovery.decodeV1(
        encoded_contract.bytes,
    );
    try source_recovery.verifyContextV1(
        decoded_contract,
        recovery_input,
    );

    const archive_storage = try allocator.alloc(
        u8,
        try input_archive.encodedBytesV1(
            input.raw_text.len,
        ),
    );
    defer allocator.free(archive_storage);
    const encoded_archive = try input_archive.encodeV1(
        .{
            .package = input.package,
            .representation = input.representation,
            .raw_text = input.raw_text,
            .tokenized = &tokenized,
            .local_plan = local_plan,
            .bound_plan = bound_plan,
        },
        archive_storage,
    );

    const live_bytes = try recoverableSetBytesV1(
        encoded_contract.bytes.len,
        encoded_archive.bytes.len,
    );
    if (input.file.max_set_bytes < live_bytes)
        return Error.AuthorityCapacityTooSmall;
    const live_storage =
        try allocator.alloc(u8, live_bytes);
    defer allocator.free(live_storage);
    const live_set =
        try source_lease.encodeRawRecoverableSourceLiveSetV1(
            encoded_contract,
            encoded_archive,
            live_storage,
        );
    const initial_selector =
        try checkpoint_file.prepareInitialSelectorV1(
            live_set,
        );
    const expected_selector =
        try checkpoint_file.decodeSelectorV1(
            &initial_selector.bytes,
        );
    const bootstrap_plan: BootstrapPlanV1 = .{
        .generation = expected_selector.generation,
        .request_epoch = expected_selector.request_epoch,
        .publication_next_sequence = expected_selector.publication_next_sequence,
        .checkpoint_sha256 = expected_selector.checkpoint_sha256,
        .selector_sha256 = expected_selector.selector_sha256,
        .source_recovery_contract_sha256 = encoded_contract.contract_sha256,
        .input_archive_sha256 = encoded_archive.archive_sha256,
    };
    if (input.plan_observer) |observer|
        observer.observe(bootstrap_plan);

    const active_storage = try allocator.alloc(
        u8,
        input.file.max_set_bytes,
    );
    defer allocator.free(active_storage);
    var lock_storage: [1]u8 = undefined;
    const initialization =
        try checkpoint_file.LeaseV1
            .createOrRecoverInitialObservedV1(
            input.file.directory,
            input.file.storage_epoch,
            scheduler_identity.challenge_sha256,
            live_set,
            initial_selector,
            input.file.max_set_bytes,
            &lock_storage,
            active_storage,
            input.observer,
        );
    var lease = initialization.lease;
    defer lease.close();

    if (!std.mem.eql(u8, lease.stream(), live_set.bytes) or
        !std.meta.eql(lease.selector, expected_selector))
        return Error.InvalidInitialSelection;

    return .{
        .disposition = initialization.disposition,
        .generation = lease.selector.generation,
        .request_epoch = lease.selector.request_epoch,
        .publication_next_sequence = lease.selector.publication_next_sequence,
        .checkpoint_sha256 = lease.selector.checkpoint_sha256,
        .selector_sha256 = lease.selector.selector_sha256,
        .source_recovery_contract_sha256 = bootstrap_plan.source_recovery_contract_sha256,
        .input_archive_sha256 = bootstrap_plan.input_archive_sha256,
    };
}

/// Advance an exact generation-one source selection to its recoverable
/// generation-two source-exit selection.
///
/// `sink_capacity` is part of the concrete durable result-sink type and must
/// equal both `input.sink.capacity` and the capacity retained by the recovery
/// contract. The call is idempotent: an already-selected exact generation two
/// is verified and returned without executing the model again. After the
/// scheduler identity is read successfully, this is a consuming call: the
/// supplied source scheduler is closed before either success or ordinary
/// failure returns.
pub fn advanceSourceFileV1(
    comptime sink_capacity: usize,
    allocator: std.mem.Allocator,
    input: AdvanceSourceFileInputV1,
) !AdvanceSourceFileReceiptV1 {
    const DurableSinkV1 =
        result_sink_file.ResultSinkFileV1(sink_capacity);
    if (input.sink.capacity != sink_capacity or
        input.step_sink.sink_epoch == 0 or
        input.step_sink.reservation_id == 0)
        return Error.InvalidAdvancePlan;

    const scheduler_identity =
        try input.runtime.scheduler.identityV1();
    var runtime_closed = false;
    defer {
        if (!runtime_closed)
            _ = input.runtime.scheduler.close() catch {};
    }

    const active_storage = try allocator.alloc(
        u8,
        input.file.max_set_bytes,
    );
    defer allocator.free(active_storage);
    const retained_storage = try allocator.alloc(
        u8,
        input.file.max_set_bytes,
    );
    defer allocator.free(retained_storage);
    var checkpoint_lock_storage: [1]u8 = undefined;
    var lease = try checkpoint_file.LeaseV1.open(
        input.file.directory,
        input.file.storage_epoch,
        scheduler_identity.challenge_sha256,
        input.file.max_set_bytes,
        &checkpoint_lock_storage,
        active_storage,
    );
    defer lease.close();

    const active_set = try lease.activeSet();
    if (active_set.metadata.generation ==
        durable.source_exited_set_generation)
    {
        var receipt = try selectedSourceExitReceiptV1(
            sink_capacity,
            allocator,
            input,
            &lease,
            retained_storage,
            scheduler_identity,
        );
        try requireRuntimeZeroV1(input.runtime);
        _ = try input.runtime.scheduler.close();
        runtime_closed = true;
        receipt.ownership_closed = true;
        return receipt;
    }
    if (active_set.metadata.generation !=
        source_lease.source_live_set_generation)
        return Error.InvalidSourceRecoveryGeneration;

    const source_context =
        try selectedSourceRecoveryContextV1(&lease);
    const contract = source_context.contract;
    const recovery_input = source_context.input_archive;
    if (!runtimeIdentityMatchesV1(
        contract.source_runtime,
        scheduler_identity,
    ) or !digestEqual(
        contract.challenge_sha256,
        scheduler_identity.challenge_sha256,
    ) or !sinkConfigMatchesContractV1(
        sink_capacity,
        input.sink,
        contract,
    ))
        return Error.InvalidSourceRecoveryContract;
    const encoded_contract: source_recovery.EncodedV1 = .{
        .bytes = contract.encoded,
        .contract_sha256 = contract.contract_sha256,
    };
    const contract_sha256 = contract.contract_sha256;
    const input_generation =
        source_lease.source_live_set_generation;
    const input_sequence = contract.publication_next_sequence;
    const predecessor_selector_sha256 =
        lease.selector.selector_sha256;

    var tokenized = try input_archive.retokenizeV1(
        allocator,
        recovery_input,
    );
    defer tokenized.deinit();
    if (tokenized.tokens.len != contract.promptCount() or
        input_sequence != 1)
        return Error.InvalidSourceRecoveryContract;
    for (tokenized.tokens, 0..) |token, index| {
        if (token != try contract.promptToken(index))
            return Error.InvalidSourceRecoveryContract;
    }

    const local_plan = try session.makePlanV1(
        input.model.*,
        tokenized.tokens,
        contract.options,
    );
    const bound_plan = try session.makeBoundPlanV1(
        input.model.*,
        tokenized.tokens,
        contract.options,
        local_plan,
        contract.scheduling,
        input.runtime.scheduler,
        contract.bound_plan_input,
    );
    const target = try input.target.resolve(bound_plan);
    try source_recovery.verifyContextV1(
        contract,
        .{
            .prompt = tokenized.tokens,
            .options = contract.options,
            .scheduling = contract.scheduling,
            .bound_plan_input = contract.bound_plan_input,
            .plan = local_plan,
            .bound_plan = bound_plan,
            .source_runtime = contract.source_runtime,
            .request_epoch = contract.request_epoch,
            .publication_next_sequence = contract.publication_next_sequence,
            .challenge_sha256 = contract.challenge_sha256,
            .target = target,
            .sink_storage_epoch = contract.sink.storage_epoch,
            .sink_capacity = sink_capacity,
            .sink_initial_sequence = contract.sink.initial_sequence,
            .sink_implementation_sha256 = contract.sink.implementation_sha256,
            .sink_instance_sha256 = contract.sink.instance_sha256,
        },
    );
    try input_archive.verifySourceContextV1(
        recovery_input,
        &tokenized,
        local_plan,
        bound_plan,
    );

    var live_grant: source_lease.SourceLiveGrantV1 = .{};
    try source_lease.initSourceLiveGrantV1(
        &live_grant,
        &lease,
    );
    defer if (live_grant.lease != null and
        (live_grant.phase == .ready or
            live_grant.phase == .bound))
    {
        source_lease.releaseSourceLiveGrantV1(
            &live_grant,
        ) catch {};
    };

    if (input.observers.plan) |observer| {
        observer.observe(.{ .recovered = .{
            .input_generation = input_generation,
            .input_sequence = input_sequence,
            .checkpoint_selector_sha256 = predecessor_selector_sha256,
            .empty_sink_ledger_sha256 = contract.sink.empty_ledger_sha256,
            .empty_sink_selector_sha256 = contract.sink.empty_selector_sha256,
        } });
    }
    try observeAdvanceProgressV1(
        input.observers.progress,
        .{
            .phase = .after_recovery_admission,
            .input_generation = input_generation,
            .input_sequence = input_sequence,
            .sink_count = 0,
            .sink_ledger_sha256 = zero_digest,
            .sink_selector_sha256 = zero_digest,
            .checkpoint_selector_sha256 = predecessor_selector_sha256,
        },
    );

    var sink_lock_storage: [1]u8 = undefined;
    const sink_initialization =
        try DurableSinkV1.createOrRecoverEmpty(
            input.file.directory,
            contract.sink.storage_epoch,
            local_plan.plan_sha256,
            contract.request_epoch,
            contract.sink.initial_sequence,
            contract.sink.implementation_sha256,
            contract.sink.instance_sha256,
            &sink_lock_storage,
            input.observers.sink,
        );
    var sink_store = sink_initialization.store;
    defer sink_store.close();
    try validateEmptySinkSelectionV1(
        sink_capacity,
        sink_store.selector,
        input.sink,
        contract,
    );
    var current_sink = sink_store.selector;
    try observeAdvanceProgressV1(
        input.observers.progress,
        progressForSelectionV1(
            .after_initial_sink,
            input_generation,
            input_sequence,
            current_sink,
            predecessor_selector_sha256,
        ),
    );

    var source_session: session.SessionV3 = .{};
    defer source_session.deinit();
    switch (try source_session.start(
        allocator,
        input.model,
        tokenized.tokens,
        contract.options,
        local_plan,
        contract.bound_plan_input,
        bound_plan,
        contract.scheduling,
        input.runtime.scheduler,
        input.runtime.bank,
    )) {
        .started => {},
        .rejected => return Error.SourceAdmissionRejected,
    }
    var step_sink: OneTokenReceiptSinkV1 = .{
        .sink_epoch = input.step_sink.sink_epoch,
        .reservation_id = input.step_sink.reservation_id,
    };
    _ = try source_session.step(
        try input.runtime.scheduler.prepareService(),
        step_sink.interface(),
    );
    if (step_sink.prepare_calls != 1 or
        step_sink.commit_calls != 1 or
        step_sink.abort_calls != 0 or
        source_session.outputTokens().len != 1 or
        source_session.outputTokens().len != input_sequence)
        return Error.InvalidSourceSequence;
    const output_token = source_session.outputTokens()[0];
    try observeAdvanceProgressV1(
        input.observers.progress,
        progressForSelectionV1(
            .after_step,
            input_generation,
            input_sequence,
            current_sink,
            predecessor_selector_sha256,
        ),
    );
    try source_session.attachSourceLiveGrantV1(&live_grant);

    const encoded_checkpoint =
        try source_session.captureCheckpointV1(
            allocator,
            contract.challenge_sha256,
        );
    defer allocator.free(encoded_checkpoint);
    const checkpoint_context = try checkpointContextV1(
        &source_session,
        input.model,
        bound_plan,
        local_plan,
        contract.request_epoch,
        contract.challenge_sha256,
    );
    if (checkpoint_context.boundary.base.publication
        .next_sequence != input_sequence)
        return Error.InvalidSourceSequence;
    const manifest_storage = try allocator.alloc(
        u8,
        try restart_manifest.encodedBytesV1(
            tokenized.tokens.len,
        ),
    );
    defer allocator.free(manifest_storage);
    const encoded_manifest = try restart_manifest.encodeV1(
        .{
            .prompt = tokenized.tokens,
            .options = contract.options,
            .plan = local_plan,
            .bound_plan = bound_plan,
            .expected_checkpoint = checkpoint_context.expected,
            .source = checkpoint_context.source,
            .target = target,
        },
        manifest_storage,
    );
    const evidence_storage = try allocator.alloc(
        u8,
        try archive.encodedBoundRestartArchiveBytesV1(
            encoded_checkpoint.len,
            encoded_manifest.bytes.len,
            recovery_input.encoded.len,
        ),
    );
    defer allocator.free(evidence_storage);
    const evidence =
        try archive.encodeBoundRestartArchiveV1(
            input_sequence,
            zero_digest,
            encoded_checkpoint,
            encoded_manifest.bytes,
            recovery_input.encoded,
            evidence_storage,
        );
    _ = try source_session.beginDurableHandoffV1(
        encoded_checkpoint,
        contract.challenge_sha256,
        target,
        evidence.set.checkpoint_sha256,
        lease.selectorRoot(),
    );
    try source_session.validateDurableHandoffV1();
    try observeAdvanceProgressV1(
        input.observers.progress,
        progressForSelectionV1(
            .after_handoff_prepare,
            input_generation,
            input_sequence,
            current_sink,
            predecessor_selector_sha256,
        ),
    );

    const source_exit =
        try source_session.commitDurableHandoffV1();
    observeAdvanceProgressV1(
        input.observers.progress,
        progressForSelectionV1(
            .after_exit_commit,
            input_generation,
            input_sequence,
            current_sink,
            predecessor_selector_sha256,
        ),
    ) catch input.fail_stop.invoke();

    const authority_bytes =
        durable.encodedRecoverableSourceExitedSetBytesV1(
            evidence.set.bytes.len,
            encoded_contract.bytes.len,
        ) catch input.fail_stop.invoke();
    const authority_storage = allocator.alloc(
        u8,
        authority_bytes,
    ) catch input.fail_stop.invoke();
    defer allocator.free(authority_storage);
    const authority =
        durable.encodeRawRecoverableSourceExitedSetV1(
            evidence,
            source_exit,
            active_set.checkpoint_sha256,
            encoded_contract,
            authority_storage,
        ) catch input.fail_stop.invoke();
    const checkpoint_publication =
        checkpoint_file.preparePublicationV1(
            &lease,
            authority,
        ) catch input.fail_stop.invoke();
    if (input.observers.plan) |observer| {
        observer.observe(.{ .successor = .{
            .checkpoint_sha256 = checkpoint_publication.set.checkpoint_sha256,
            .selector_sha256 = checkpoint_publication.selector.selector_sha256,
        } });
    }
    const checkpoint_applied =
        if (input.observers.checkpoint) |observer|
            checkpoint_file.publishObservedV1(
                &lease,
                checkpoint_publication,
                observer,
            ) catch input.fail_stop.invoke()
        else
            checkpoint_file.recoverV1(
                &lease,
                checkpoint_publication,
            ) catch input.fail_stop.invoke();
    source_session.completeDurableHandoffV1(.{
        .checkpoint_sha256 = checkpoint_applied.checkpoint_sha256,
        .selector_sha256 = checkpoint_applied.selector_sha256,
    }) catch input.fail_stop.invoke();
    if (live_grant.phase != .completed)
        input.fail_stop.invoke();
    requireRuntimeZeroV1(input.runtime) catch
        input.fail_stop.invoke();
    _ = input.runtime.scheduler.close() catch
        input.fail_stop.invoke();
    runtime_closed = true;

    const checkpoint_selector = lease.selector;
    current_sink = sink_store.selector;
    observeAdvanceProgressV1(
        input.observers.progress,
        progressForSelectionV1(
            .after_generation_two,
            input_generation,
            input_sequence,
            current_sink,
            checkpoint_selector.selector_sha256,
        ),
    ) catch input.fail_stop.invoke();

    return .{
        .disposition = .advanced,
        .input_generation = input_generation,
        .input_sequence = input_sequence,
        .output_generation = checkpoint_selector.generation,
        .output_sequence = checkpoint_selector.publication_next_sequence,
        .output_token = output_token,
        .sink_count = current_sink.acknowledgement_count,
        .sink_next_sequence = current_sink.next_sequence,
        .sink_ledger_sha256 = current_sink.ledger_sha256,
        .sink_selector_sha256 = current_sink.selector_sha256,
        .checkpoint_sha256 = checkpoint_selector.checkpoint_sha256,
        .checkpoint_selector_sha256 = checkpoint_selector.selector_sha256,
        .source_recovery_contract_sha256 = contract_sha256,
        .ownership_closed = true,
    };
}

/// Consume one selected restart and publish its acknowledged successor.
///
/// The result-sink capacity is part of the concrete store type. The maximum
/// visible output count is `sink_initial_sequence + sink_capacity`; caller
/// output storage must cover that complete terminal prefix.
pub fn advanceTargetFileV1(
    comptime sink_capacity: usize,
    allocator: std.mem.Allocator,
    input: AdvanceTargetFileInputV1,
) !AdvanceTargetFileReceiptV1 {
    const DurableSinkV1 =
        result_sink_file.ResultSinkFileV1(sink_capacity);
    const maximum_output = try maximumOutputCountV1(
        sink_capacity,
        input.sink_initial_sequence,
    );
    if (input.sink.capacity != sink_capacity or
        input.request_epoch == 0 or
        input.sink_initial_sequence == 0 or
        input.step_sink.sink_epoch == 0 or
        input.step_sink.reservation_id == 0 or
        std.mem.allEqual(
            u8,
            &input.challenge_sha256,
            0,
        ))
        return Error.InvalidTargetPlan;
    if (input.output_storage.len < maximum_output)
        return Error.OutputStorageTooSmall;

    const active_storage = try allocator.alloc(
        u8,
        input.file.max_set_bytes,
    );
    defer allocator.free(active_storage);
    const retained_storage = try allocator.alloc(
        u8,
        input.file.max_set_bytes,
    );
    defer allocator.free(retained_storage);
    var checkpoint_lock_storage: [1]u8 = undefined;
    var lease = try checkpoint_file.LeaseV1.open(
        input.file.directory,
        input.file.storage_epoch,
        input.challenge_sha256,
        input.file.max_set_bytes,
        &checkpoint_lock_storage,
        active_storage,
    );
    var lease_open = true;
    defer if (lease_open) {
        if (lease.consumer_claim) |claim|
            lease.releaseConsumerClaimV1(claim) catch {};
        lease.close();
    };

    const input_generation = lease.selector.generation;
    const input_sequence =
        lease.selector.publication_next_sequence;
    const active_decoded = try lease.activeSet();
    if (active_decoded.object_count ==
        acknowledged_progress.terminal_object_count)
    {
        const receipt = try selectedTerminalReceiptV1(
            sink_capacity,
            allocator,
            input,
            &lease,
            maximum_output,
        );
        lease.close();
        lease_open = false;
        return receipt;
    }
    if (input_sequence >= maximum_output)
        return Error.InvalidTargetSequence;
    const selected_predecessor_storage =
        try allocator.dupe(u8, lease.stream());
    defer allocator.free(selected_predecessor_storage);

    var active_selector_wire: [checkpoint_file.selector_bytes]u8 = undefined;
    const active_selector =
        try checkpoint_file.readActiveSelectorReadOnlyV1(
            input.file.directory,
            &active_selector_wire,
        );
    if (!std.meta.eql(active_selector, lease.selector))
        return Error.InvalidTargetProgress;
    const retained = try lease.loadRetainedSetV1(
        active_decoded.metadata.parent_checkpoint_sha256,
        retained_storage,
    );

    const ledger_bytes =
        try result_sink_file.ledgerBytesForCountV1(
            sink_capacity,
        );
    const preactivation_ledger_storage =
        try allocator.alloc(u8, ledger_bytes);
    defer allocator.free(
        preactivation_ledger_storage,
    );
    var activation_grant: restore.SelectedRestartGrantV1 = .{};
    var selected: SelectedTargetRestartV1 = undefined;
    var source_sink_contract: ?source_recovery.DecodedV1 = null;
    var preactivation_sink_lock_storage: [1]u8 = undefined;
    var preactivation_sink: ?DurableSinkV1 = null;
    defer if (preactivation_sink) |*store|
        store.close();

    if (input_generation ==
        durable.source_exited_set_generation)
    {
        const decoded =
            try durable.decodeSourceExitedSetV1(
                lease.stream(),
                lease.selector,
                active_decoded.metadata
                    .parent_checkpoint_sha256,
            );
        if (decoded.source_recovery_contract) |_| {
            const contract =
                try durable
                    .validateRecoverableSourcePredecessorV1(
                    &lease,
                    decoded,
                    retained_storage,
                );
            if (contract.request_epoch !=
                input.request_epoch or
                !digestEqual(
                    contract.challenge_sha256,
                    input.challenge_sha256,
                ) or !sinkConfigMatchesContractV1(
                sink_capacity,
                input.sink,
                contract,
            ) or contract.sink.initial_sequence !=
                input.sink_initial_sequence)
                return Error.InvalidTargetPlan;
            preactivation_sink =
                try DurableSinkV1.open(
                    input.file.directory,
                    contract.sink.storage_epoch,
                    contract.plan_sha256,
                    contract.request_epoch,
                    contract.sink.initial_sequence,
                    contract.sink
                        .implementation_sha256,
                    contract.sink.instance_sha256,
                    &preactivation_sink_lock_storage,
                    preactivation_ledger_storage,
                    null,
                );
            try validateRecoverableTargetSinkV1(
                sink_capacity,
                &preactivation_sink.?,
                input,
                contract,
                input_sequence,
            );
            try durable
                .initSelectedRecoverableSourceExitGrantV1(
                &activation_grant,
                &lease,
                decoded,
                retained_storage,
            );
            source_sink_contract = contract;
        } else {
            const live_bytes =
                checkpoint_file.set_payload_offset +
                durable.source_live_marker.len +
                checkpoint_file.set_footer_bytes;
            const live_storage =
                try allocator.alloc(u8, live_bytes);
            defer allocator.free(live_storage);
            const expected_live =
                try durable.encodeSourceLiveSetV1(
                    input.request_epoch,
                    input.sink_initial_sequence,
                    input.challenge_sha256,
                    live_storage,
                );
            if (!std.mem.eql(
                u8,
                retained.bytes,
                expected_live.bytes,
            ))
                return Error.InvalidTargetProgress;
            try durable.initSelectedSourceExitGrantV1(
                &activation_grant,
                &lease,
                decoded,
            );
        }
        const encoded_plan =
            try decoded.evidence.archive.object(
                .extension,
                archive.successor_plan_object_ordinal,
            );
        const encoded_residency =
            try decoded.evidence.archive.object(
                .extension,
                archive
                    .successor_residency_object_ordinal,
            );
        const encoded_segment =
            try decoded.evidence.archive.object(
                .extension,
                archive
                    .successor_segment_object_ordinal,
            );
        selected = .{
            .manifest = decoded.evidence.manifest,
            .checkpoint = decoded.evidence.checkpoint,
            .artifacts = decoded.evidence.artifacts,
            .input_archive = decoded.input_archive,
            .encoded_checkpoint = decoded.evidence.checkpoint.encoded,
            .encoded_plan = encoded_plan.bytes,
            .encoded_residency = encoded_residency.bytes,
            .encoded_segment = encoded_segment.bytes,
            .predecessor_set = retained.bytes,
            .predecessor_selector = &active_selector_wire,
            .active_set = selected_predecessor_storage,
            .active_selector = &active_selector_wire,
        };
    } else {
        if (active_decoded.object_count !=
            acknowledged_progress
                .nonterminal_object_count and
            active_decoded.object_count !=
                acknowledged_progress
                    .bound_nonterminal_object_count)
            return Error.InvalidTargetProgress;
        const embedded_selector =
            active_decoded.objects[0];
        if (embedded_selector.kind != .runtime_state or
            embedded_selector.ordinal !=
                acknowledged_progress
                    .nonterminal_predecessor_selector_object_ordinal or
            embedded_selector.abi_version !=
                checkpoint_file.selector_abi)
            return Error.InvalidTargetProgress;
        const decoded =
            try acknowledged_progress
                .decodeNonterminalV1(
                retained.bytes,
                embedded_selector.bytes,
                lease.stream(),
                &active_selector_wire,
            );
        try acknowledged_restore
            .initSelectedProgressGrantV1(
            &activation_grant,
            &lease,
            decoded,
        );
        selected = .{
            .manifest = decoded.manifest,
            .checkpoint = decoded.checkpoint,
            .artifacts = decoded.artifacts,
            .input_archive = decoded.input_archive,
            .encoded_checkpoint = active_decoded.objects[1].bytes,
            .encoded_plan = active_decoded.objects[2].bytes,
            .encoded_residency = active_decoded.objects[3].bytes,
            .encoded_segment = active_decoded.objects[4].bytes,
            .predecessor_set = retained.bytes,
            .predecessor_selector = embedded_selector.bytes,
            .active_set = selected_predecessor_storage,
            .active_selector = &active_selector_wire,
        };
    }

    const recovered_prompt = try allocator.alloc(
        u32,
        selected.manifest.promptCount(),
    );
    defer allocator.free(recovered_prompt);
    for (recovered_prompt, 0..) |*token, index|
        token.* =
            try selected.manifest.promptToken(index);
    if (selected.input_archive) |decoded_input| {
        var retokenized =
            try input_archive.retokenizeV1(
                allocator,
                decoded_input,
            );
        defer retokenized.deinit();
        if (!std.mem.eql(
            u32,
            retokenized.tokens,
            recovered_prompt,
        ))
            return Error.InvalidTargetPlan;
    }
    const local_plan = try session.makePlanV1(
        input.model.*,
        recovered_prompt,
        selected.manifest.options,
    );
    if (!std.meta.eql(
        local_plan,
        selected.manifest.plan,
    ) or local_plan.max_new_tokens != maximum_output or
        selected.manifest.expected_checkpoint
            .request_epoch != input.request_epoch or
        !digestEqual(
            selected.manifest.expected_checkpoint
                .challenge_sha256,
            input.challenge_sha256,
        ))
        return Error.InvalidTargetPlan;
    try session.validateBoundPlanV1(
        selected.manifest.bound_plan,
    );
    if (selected.input_archive) |decoded_input| {
        try input_archive.verifyCurrentPlanV1(
            decoded_input,
            local_plan,
            selected.manifest.bound_plan,
        );
    }

    const runtime = try input.runtime_factory.init(
        selected.manifest.target,
    );
    var runtime_closed = false;
    defer {
        if (!runtime_closed)
            _ = runtime.scheduler.close() catch {};
    }
    const runtime_identity =
        try runtime.scheduler.identityV1();
    if (!targetRuntimeMatchesV1(
        selected.manifest.target,
        runtime_identity,
        input.challenge_sha256,
    ))
        return Error.InvalidTargetRuntime;

    const restore_evidence: restore.EvidenceV1 = .{
        .encoded_plan = selected.encoded_plan,
        .encoded_residency = selected.encoded_residency,
        .encoded_segment = selected.encoded_segment,
        .encoded_checkpoint = selected.encoded_checkpoint,
        .expected_checkpoint = selected.manifest.expected_checkpoint,
        .source = selected.manifest.source,
        .target = selected.manifest.target,
    };
    var restored_session: session.SessionV3 = .{};
    defer restored_session.deinit();
    const restore_decision =
        try restore.prepareRestoredAdmissionV1(
            runtime.scheduler,
            runtime.bank,
            restored_session
                .restoredPublicationSessionIdV1(),
            restore_evidence,
            &activation_grant,
        );
    var prepared_restore = switch (restore_decision) {
        .prepared => |value| value,
        .rejected => return Error.TargetAdmissionRejected,
        .recovery_required => return Error.TargetRecoveryRequired,
    };
    try restore.validatePreparedRestoredAdmissionV1(
        &prepared_restore,
        restore_evidence,
        &activation_grant,
    );
    try restored_session.startRestoredV1(
        allocator,
        input.model,
        recovered_prompt,
        selected.manifest.options,
        local_plan,
        selected.manifest.bound_plan,
        &prepared_restore,
        restore_evidence,
        &activation_grant,
    );
    if (activation_grant.phase != .consumed)
        return Error.InvalidTargetActivation;

    const sink_ledger_storage =
        try allocator.alloc(u8, ledger_bytes);
    defer allocator.free(sink_ledger_storage);
    var sink_lock_storage: [1]u8 = undefined;
    var sink_store: DurableSinkV1 = undefined;
    if (preactivation_sink) |store| {
        sink_store = store;
        preactivation_sink = null;
    } else {
        sink_store = try DurableSinkV1.open(
            input.file.directory,
            if (source_sink_contract) |contract|
                contract.sink.storage_epoch
            else
                input.sink.storage_epoch,
            selected.manifest.plan.plan_sha256,
            if (source_sink_contract) |contract|
                contract.request_epoch
            else
                input.request_epoch,
            if (source_sink_contract) |contract|
                contract.sink.initial_sequence
            else
                input.sink_initial_sequence,
            if (source_sink_contract) |contract|
                contract.sink.implementation_sha256
            else
                input.sink.implementation_sha256,
            if (source_sink_contract) |contract|
                contract.sink.instance_sha256
            else
                input.sink.instance_sha256,
            &sink_lock_storage,
            sink_ledger_storage,
            null,
        );
    }
    defer sink_store.close();
    sink_store.observer = input.observers.sink;
    if (!sinkSelectionMatchesExpectedV1(
        sink_store.selector,
        input,
    ) or sink_store.selector.next_sequence <
        input_sequence or
        sink_store.selector.next_sequence >
            input_sequence + 1)
        return Error.InvalidTargetSink;

    var receipt_sink: OneTokenReceiptSinkV1 = .{
        .sink_epoch = input.step_sink.sink_epoch,
        .reservation_id = input.step_sink.reservation_id,
    };
    _ = try restored_session.step(
        try runtime.scheduler.prepareService(),
        receipt_sink.interface(),
    );
    if (receipt_sink.prepare_calls != 1 or
        receipt_sink.commit_calls != 1 or
        receipt_sink.abort_calls != 0)
        return Error.InvalidTargetSequence;
    try observeTargetProgressV1(
        input.observers.progress,
        targetProgressForSelectionV1(
            .after_step_before_sink,
            input_generation,
            input_sequence,
            sink_store.selector,
            lease.selector.selector_sha256,
        ),
    );
    const delivery =
        try result_sink
            .deliveryInputFromCommitReceiptV1(
            selected.manifest.plan.plan_sha256,
            receipt_sink.receipt,
        );
    if (delivery.transaction_sequence !=
        input_sequence)
        return Error.InvalidTargetSequence;

    const output_tokens =
        restored_session.outputTokens();
    const output_generation =
        try std.math.add(u64, input_generation, 1);
    const output_sequence =
        try std.math.add(u64, input_sequence, 1);
    if (output_tokens.len != output_sequence or
        output_tokens.len > maximum_output)
        return Error.InvalidTargetSequence;
    const staged_output_tokens =
        try allocator.alloc(u32, output_tokens.len);
    defer allocator.free(staged_output_tokens);
    @memcpy(staged_output_tokens, output_tokens);
    var terminal_semantic: ?terminal.TerminalSemanticV1 = null;
    if (restored_session.isFinished()) {
        const boundary =
            try restored_session.snapshotVerified();
        const semantic = try terminal.makeV1(
            boundary,
            restored_session.inner.bound_plan,
            local_plan,
            staged_output_tokens,
            lane_contiguous.logicalKvPrefixSha256(
                &restored_session.inner.inner
                    .resources.cache,
                restored_session.inner.inner
                    .resources.cache.len,
            ),
        );
        if (input.terminal_verifier) |verifier|
            try verifier.verify(semantic);
        terminal_semantic = semantic;
    }

    var preview_sink = sink_store.sink;
    const preview_result =
        try preview_sink.apply(delivery);
    if (preview_result.disposition == .applied) {
        const preview_ledger_storage =
            try allocator.alloc(u8, ledger_bytes);
        defer allocator.free(
            preview_ledger_storage,
        );
        const preview_ledger =
            try result_sink_file.encodeLedgerV1(
                preview_sink.request_sha256,
                preview_sink.request_epoch,
                preview_sink.initial_sequence,
                preview_sink
                    .sink_implementation_sha256,
                preview_sink.sink_instance_sha256,
                preview_sink.acknowledgementSlice(),
                preview_ledger_storage,
            );
        const preview_selector =
            try result_sink_file
                .prepareSuccessorSelectorV1(
                sink_store.selector,
                preview_ledger,
            );
        if (input.observers.plan) |observer| {
            observer.observe(.{ .sink = .{
                .acknowledgement_count = preview_sink.applied_count,
                .ledger_sha256 = preview_ledger.ledger_sha256,
                .selector_sha256 = preview_selector.selector_sha256,
            } });
        }
    } else if (input.observers.plan) |observer| {
        observer.observe(.{ .sink = .{
            .acknowledgement_count = sink_store.selector
                .acknowledgement_count,
            .ledger_sha256 = sink_store.selector.ledger_sha256,
            .selector_sha256 = sink_store.selector.selector_sha256,
        } });
    }

    var sink_commit_started = true;
    errdefer if (sink_commit_started)
        input.fail_stop.invoke();
    const sink_apply = try sink_store.apply(
        delivery,
        sink_ledger_storage,
    );
    const sink_disposition: TargetSinkDispositionV1 =
        switch (sink_apply.disposition) {
            .applied => .applied,
            .replayed => .replayed,
        };
    try observeTargetProgressV1(
        input.observers.progress,
        targetProgressForSelectionV1(
            .after_sink_before_selector,
            input_generation,
            input_sequence,
            sink_store.selector,
            lease.selector.selector_sha256,
        ),
    );

    var encoded_ack: [result_sink.acknowledgement_bytes]u8 =
        undefined;
    _ = try result_sink.encodeAcknowledgementV1(
        sink_apply.acknowledgement,
        &encoded_ack,
    );
    var selected_set: checkpoint_file.PreparedSetV1 = undefined;
    var selected_storage: ?[]u8 = null;
    defer if (selected_storage) |storage|
        allocator.free(storage);
    const terminal_selected =
        terminal_semantic != null;
    var terminal_semantic_sha256 = zero_digest;

    if (!terminal_selected) {
        const encoded_checkpoint =
            try restored_session.captureCheckpointV1(
                allocator,
                input.challenge_sha256,
            );
        defer allocator.free(encoded_checkpoint);
        const checkpoint_context =
            try checkpointContextV1(
                &restored_session,
                input.model,
                restored_session.inner.bound_plan,
                local_plan,
                input.request_epoch,
                input.challenge_sha256,
            );
        if (checkpoint_context.boundary.base
            .publication.next_sequence !=
            output_sequence)
            return Error.InvalidTargetSequence;
        const next_target =
            try input.next_target.resolve(
                restored_session.inner.bound_plan,
            );
        const manifest_storage =
            try allocator.alloc(
                u8,
                try restart_manifest.encodedBytesV1(
                    recovered_prompt.len,
                ),
            );
        defer allocator.free(manifest_storage);
        const encoded_manifest =
            try restart_manifest.encodeV1(
                .{
                    .prompt = recovered_prompt,
                    .options = selected.manifest.options,
                    .plan = local_plan,
                    .bound_plan = restored_session.inner
                        .bound_plan,
                    .expected_checkpoint = checkpoint_context.expected,
                    .source = checkpoint_context.source,
                    .target = next_target,
                },
                manifest_storage,
            );
        const restart_bytes =
            if (selected.input_archive) |decoded_input|
                try archive
                    .encodedBoundRestartArchiveBytesV1(
                    encoded_checkpoint.len,
                    encoded_manifest.bytes.len,
                    decoded_input.encoded.len,
                )
            else
                try archive
                    .encodedRestartArchiveBytesV1(
                    encoded_checkpoint.len,
                    encoded_manifest.bytes.len,
                );
        const restart_storage =
            try allocator.alloc(u8, restart_bytes);
        defer allocator.free(restart_storage);
        if (selected.input_archive) |decoded_input| {
            _ = try archive
                .encodeBoundRestartArchiveV1(
                output_generation,
                active_decoded.checkpoint_sha256,
                encoded_checkpoint,
                encoded_manifest.bytes,
                decoded_input.encoded,
                restart_storage,
            );
        } else {
            _ = try archive.encodeRestartArchiveV1(
                output_generation,
                active_decoded.checkpoint_sha256,
                encoded_checkpoint,
                encoded_manifest.bytes,
                restart_storage,
            );
        }
        const selected_bytes =
            if (selected.input_archive != null)
                try acknowledged_progress
                    .encodedBoundNonterminalBytesV1(
                    restart_storage.len,
                )
            else
                try acknowledged_progress
                    .encodedNonterminalBytesV1(
                    restart_storage.len,
                );
        selected_storage =
            try allocator.alloc(u8, selected_bytes);
        const encoded_progress =
            if (selected.input_archive != null)
                try acknowledged_progress
                    .encodeBoundNonterminalV1(
                    selected.active_set,
                    selected.active_selector,
                    restart_storage,
                    &encoded_ack,
                    selected_storage.?,
                )
            else
                try acknowledged_progress
                    .encodeNonterminalV1(
                    selected.active_set,
                    selected.active_selector,
                    restart_storage,
                    &encoded_ack,
                    selected_storage.?,
                );
        selected_set = encoded_progress.set;
    } else {
        const semantic = terminal_semantic.?;
        var semantic_wire: [terminal.semantic_bytes]u8 = undefined;
        _ = try terminal.encodeV1(
            semantic,
            &semantic_wire,
        );
        const output_wire = try allocator.alloc(
            u8,
            staged_output_tokens.len * @sizeOf(u32),
        );
        defer allocator.free(output_wire);
        encodeOutputTokensV1(
            staged_output_tokens,
            output_wire,
        );
        selected_storage = try allocator.alloc(
            u8,
            try acknowledged_progress
                .encodedTerminalBytesV1(
                selected.active_set.len,
                output_wire.len,
            ),
        );
        const encoded_terminal =
            try acknowledged_progress.encodeTerminalV1(
                selected.active_set,
                selected.active_selector,
                &semantic_wire,
                &encoded_ack,
                output_wire,
                selected_storage.?,
            );
        selected_set = encoded_terminal.set;
        terminal_semantic_sha256 =
            semantic.semantic_sha256;
    }

    const checkpoint_publication =
        try checkpoint_file.preparePublicationV1(
            &lease,
            selected_set,
        );
    if (input.observers.plan) |observer| {
        observer.observe(.{ .checkpoint = .{
            .checkpoint_sha256 = checkpoint_publication.set
                .checkpoint_sha256,
            .selector_sha256 = checkpoint_publication.selector
                .selector_sha256,
        } });
    }
    const checkpoint_applied =
        if (input.observers.checkpoint) |observer|
            try checkpoint_file.publishObservedV1(
                &lease,
                checkpoint_publication,
                observer,
            )
        else
            try checkpoint_file.recoverV1(
                &lease,
                checkpoint_publication,
            );
    if (checkpoint_applied.disposition != .applied and
        checkpoint_applied.disposition !=
            .already_applied)
        return Error.InvalidTargetProgress;

    if (terminal_selected) {
        const decoded =
            try acknowledged_progress
                .decodeTerminalV1(
                selected.active_set,
                selected.active_selector,
                selected_set.bytes,
                &checkpoint_publication
                    .selector.bytes,
            );
        try acknowledged_restore
            .markTerminalSelectedV1(
            &activation_grant,
            decoded,
        );
        _ = try restored_session.retire();
    } else {
        const decoded =
            try acknowledged_progress
                .decodeNonterminalV1(
                selected.active_set,
                selected.active_selector,
                selected_set.bytes,
                &checkpoint_publication
                    .selector.bytes,
            );
        try acknowledged_restore
            .markNonterminalSelectedV1(
            &activation_grant,
            decoded,
        );
        _ = try restored_session.cancel();
    }
    if (activation_grant.phase != .completed)
        return Error.InvalidTargetActivation;
    try requireRuntimeZeroV1(runtime);
    _ = try runtime.scheduler.close();
    runtime_closed = true;
    @memcpy(
        input.output_storage[0..staged_output_tokens.len],
        staged_output_tokens,
    );
    sink_commit_started = false;

    const sink_selector = sink_store.selector;
    const checkpoint_selector = lease.selector;
    return .{
        .disposition = .advanced,
        .input_generation = input_generation,
        .input_sequence = input_sequence,
        .output_generation = output_generation,
        .output_sequence = output_sequence,
        .sink_disposition = sink_disposition,
        .sink_count = sink_selector.acknowledgement_count,
        .sink_next_sequence = sink_selector.next_sequence,
        .sink_ledger_sha256 = sink_selector.ledger_sha256,
        .sink_selector_sha256 = sink_selector.selector_sha256,
        .checkpoint_sha256 = checkpoint_selector.checkpoint_sha256,
        .checkpoint_selector_sha256 = checkpoint_selector.selector_sha256,
        .terminal = terminal_selected,
        .output_tokens = input.output_storage[0..staged_output_tokens.len],
        .terminal_semantic_sha256 = terminal_semantic_sha256,
        .ownership_closed = true,
    };
}

const SelectedTargetRestartV1 = struct {
    manifest: restart_manifest.DecodedV1,
    checkpoint: checkpoint.DecodedV1,
    artifacts: successor.ArtifactsV1,
    input_archive: ?input_archive.DecodedV1 = null,
    encoded_checkpoint: []const u8,
    encoded_plan: []const u8,
    encoded_residency: []const u8,
    encoded_segment: []const u8,
    predecessor_set: []const u8,
    predecessor_selector: []const u8,
    active_set: []const u8,
    active_selector: []const u8,
};

fn maximumOutputCountV1(
    comptime sink_capacity: usize,
    initial_sequence: u64,
) !usize {
    const capacity_u64 = std.math.cast(
        u64,
        sink_capacity,
    ) orelse return Error.InvalidTargetPlan;
    const maximum = std.math.add(
        u64,
        initial_sequence,
        capacity_u64,
    ) catch return Error.InvalidTargetPlan;
    return std.math.cast(
        usize,
        maximum,
    ) orelse Error.InvalidTargetPlan;
}

fn selectedTerminalReceiptV1(
    comptime sink_capacity: usize,
    allocator: std.mem.Allocator,
    input: AdvanceTargetFileInputV1,
    lease: *checkpoint_file.LeaseV1,
    maximum_output: usize,
) !AdvanceTargetFileReceiptV1 {
    const DurableSinkV1 =
        result_sink_file.ResultSinkFileV1(sink_capacity);
    var selector_wire: [checkpoint_file.selector_bytes]u8 = undefined;
    const selected_selector =
        try checkpoint_file.readActiveSelectorReadOnlyV1(
            input.file.directory,
            &selector_wire,
        );
    if (!std.meta.eql(
        selected_selector,
        lease.selector,
    ))
        return Error.InvalidTargetProgress;
    const selected_set = try lease.activeSet();
    if (selected_set.object_count !=
        acknowledged_progress.terminal_object_count)
        return Error.InvalidTerminalSelection;
    const predecessor_selector_object =
        selected_set.objects[
            acknowledged_progress
                .terminal_predecessor_selector_object_ordinal
        ];
    const predecessor_set_object =
        selected_set.objects[
            acknowledged_progress
                .terminal_predecessor_set_object_ordinal
        ];
    const decoded =
        try acknowledged_progress.decodeTerminalV1(
            predecessor_set_object.bytes,
            predecessor_selector_object.bytes,
            lease.stream(),
            &selector_wire,
        );
    if (decoded.outputCount() != maximum_output or
        decoded.selected.selector.generation !=
            lease.selector.generation or
        decoded.selected.selector
            .publication_next_sequence !=
            maximum_output or
        decoded.semantic.max_new_tokens !=
            maximum_output or
        decoded.semantic.output_length !=
            maximum_output or
        decoded.semantic.request_epoch !=
            input.request_epoch)
        return Error.InvalidTerminalSelection;
    const staged_output_tokens =
        try allocator.alloc(u32, maximum_output);
    defer allocator.free(staged_output_tokens);
    for (
        staged_output_tokens,
        0..,
    ) |*token, index| {
        token.* = try decoded.outputToken(index);
    }
    if (input.terminal_verifier) |verifier|
        try verifier.verify(decoded.semantic);

    const ledger_storage = try allocator.alloc(
        u8,
        try result_sink_file.ledgerBytesForCountV1(
            sink_capacity,
        ),
    );
    defer allocator.free(ledger_storage);
    var sink_lock_storage: [1]u8 = undefined;
    var sink_store = try DurableSinkV1.open(
        input.file.directory,
        input.sink.storage_epoch,
        decoded.semantic.local_plan_sha256,
        input.request_epoch,
        input.sink_initial_sequence,
        input.sink.implementation_sha256,
        input.sink.instance_sha256,
        &sink_lock_storage,
        ledger_storage,
        null,
    );
    defer sink_store.close();
    if (!sinkSelectionMatchesExpectedV1(
        sink_store.selector,
        input,
    ) or sink_store.selector
        .acknowledgement_count != sink_capacity or
        sink_store.selector.next_sequence !=
            maximum_output)
        return Error.InvalidTargetSink;
    const acknowledgements =
        sink_store.sink.acknowledgementSlice();
    if (acknowledgements.len != sink_capacity or
        !std.meta.eql(
            acknowledgements[
                acknowledgements.len - 1
            ],
            decoded.acknowledgement,
        ))
        return Error.InvalidTargetSink;
    for (
        acknowledgements,
        0..,
    ) |acknowledgement, index| {
        const expected_sequence = std.math.add(
            u64,
            input.sink_initial_sequence,
            @as(u64, @intCast(index)),
        ) catch return Error.InvalidTargetSink;
        const token_index = std.math.cast(
            usize,
            expected_sequence,
        ) orelse return Error.InvalidTargetSink;
        if (token_index >= maximum_output or
            acknowledgement.transaction_sequence !=
                expected_sequence or
            acknowledgement.token_id !=
                staged_output_tokens[token_index] or
            !digestEqual(
                acknowledgement.request_sha256,
                decoded.semantic.local_plan_sha256,
            ))
            return Error.InvalidTargetSink;
    }

    @memcpy(
        input.output_storage[0..maximum_output],
        staged_output_tokens,
    );
    return .{
        .disposition = .already_terminal,
        .input_generation = lease.selector.generation,
        .input_sequence = lease.selector.publication_next_sequence,
        .output_generation = lease.selector.generation,
        .output_sequence = lease.selector.publication_next_sequence,
        .sink_disposition = .none,
        .sink_count = sink_store.selector.acknowledgement_count,
        .sink_next_sequence = sink_store.selector.next_sequence,
        .sink_ledger_sha256 = sink_store.selector.ledger_sha256,
        .sink_selector_sha256 = sink_store.selector.selector_sha256,
        .checkpoint_sha256 = lease.selector.checkpoint_sha256,
        .checkpoint_selector_sha256 = lease.selector.selector_sha256,
        .terminal = true,
        .output_tokens = input.output_storage[0..maximum_output],
        .terminal_semantic_sha256 = decoded.semantic.semantic_sha256,
        .ownership_closed = true,
    };
}

fn validateRecoverableTargetSinkV1(
    comptime sink_capacity: usize,
    store: *const result_sink_file
        .ResultSinkFileV1(sink_capacity),
    input: AdvanceTargetFileInputV1,
    contract: source_recovery.DecodedV1,
    selected_sequence: u64,
) !void {
    if (selected_sequence !=
        contract.sink.initial_sequence or
        contract.request_epoch != input.request_epoch or
        contract.sink.initial_sequence !=
            input.sink_initial_sequence or
        !sinkConfigMatchesContractV1(
            sink_capacity,
            input.sink,
            contract,
        ))
        return Error.InvalidTargetSink;
    if (store.selector.acknowledgement_count == 0) {
        try validateEmptySinkSelectionV1(
            sink_capacity,
            store.selector,
            input.sink,
            contract,
        );
        return;
    }

    const expected_next = std.math.add(
        u64,
        selected_sequence,
        1,
    ) catch return Error.InvalidTargetSink;
    const acknowledgements =
        store.sink.acknowledgementSlice();
    if (store.selector.generation != 2 or
        store.selector.acknowledgement_count != 1 or
        store.selector.initial_sequence !=
            contract.sink.initial_sequence or
        store.selector.next_sequence != expected_next or
        store.selector.request_epoch !=
            contract.request_epoch or
        !digestEqual(
            store.selector.request_sha256,
            contract.plan_sha256,
        ) or !digestEqual(
        store.selector.sink_implementation_sha256,
        contract.sink.implementation_sha256,
    ) or !digestEqual(
        store.selector.sink_instance_sha256,
        contract.sink.instance_sha256,
    ) or store.sink.applied_count != 1 or
        store.sink.next_sequence != expected_next or
        acknowledgements.len != 1)
        return Error.InvalidTargetSink;

    const acknowledgement = acknowledgements[0];
    try result_sink.validateAcknowledgementV1(
        acknowledgement,
    );
    if (acknowledgement.request_epoch !=
        contract.request_epoch or
        acknowledgement.transaction_sequence !=
            selected_sequence or
        acknowledgement.application_ordinal != 1 or
        acknowledgement.application_count != 1 or
        !digestEqual(
            acknowledgement.request_sha256,
            contract.plan_sha256,
        ) or !digestEqual(
        acknowledgement.sink_implementation_sha256,
        contract.sink.implementation_sha256,
    ) or !digestEqual(
        acknowledgement.sink_instance_sha256,
        contract.sink.instance_sha256,
    ) or !durable
        .recoverableOneAheadSinkLineageValidV1(
        contract.sink.empty_selector_sha256,
        store.selector.previous_selector_sha256,
        acknowledgement
            .predecessor_acknowledgement_sha256,
        acknowledgement
            .predecessor_sink_prefix_sha256,
    ))
        return Error.InvalidTargetSink;
}

fn sinkSelectionMatchesExpectedV1(
    selector: result_sink_file.DecodedSelectorV1,
    input: AdvanceTargetFileInputV1,
) bool {
    return selector.request_epoch ==
        input.request_epoch and
        selector.initial_sequence ==
            input.sink_initial_sequence and
        digestEqual(
            selector.sink_implementation_sha256,
            input.sink.implementation_sha256,
        ) and digestEqual(
        selector.sink_instance_sha256,
        input.sink.instance_sha256,
    );
}

fn targetRuntimeMatchesV1(
    target: TargetOwnershipV1,
    identity: lane.IdentityV1,
    challenge_sha256: Digest,
) bool {
    return identity.scheduler_epoch ==
        target.scheduler_epoch and
        identity.coordinator_id ==
            target.coordinator_id and
        identity.bank_epoch == target.bank_epoch and
        digestEqual(
            identity.challenge_sha256,
            challenge_sha256,
        );
}

fn targetProgressForSelectionV1(
    phase: TargetPhaseV1,
    input_generation: u64,
    input_sequence: u64,
    sink_selector: result_sink_file.DecodedSelectorV1,
    checkpoint_selector_sha256: Digest,
) TargetProgressV1 {
    return .{
        .phase = phase,
        .input_generation = input_generation,
        .input_sequence = input_sequence,
        .sink_count = sink_selector.acknowledgement_count,
        .sink_ledger_sha256 = sink_selector.ledger_sha256,
        .sink_selector_sha256 = sink_selector.selector_sha256,
        .checkpoint_selector_sha256 = checkpoint_selector_sha256,
    };
}

fn observeTargetProgressV1(
    observer: ?TargetProgressObserverV1,
    progress_value: TargetProgressV1,
) !void {
    if (observer) |value|
        try value.after(progress_value);
}

fn encodeOutputTokensV1(
    tokens: []const u32,
    destination: []u8,
) void {
    std.debug.assert(
        destination.len ==
            tokens.len * @sizeOf(u32),
    );
    for (tokens, 0..) |token, index| {
        const offset = index * @sizeOf(u32);
        std.mem.writeInt(
            u32,
            destination[offset..][0..4],
            token,
            .little,
        );
    }
}

const SelectedSourceRecoveryV1 = struct {
    contract: source_recovery.DecodedV1,
    input_archive: input_archive.DecodedV1,
};

const SourceCheckpointContextV1 = struct {
    boundary: session.BoundarySnapshotV2,
    expected: checkpoint.ExpectedBindingsV1,
    source: successor.SourceContextV1,
};

const OneTokenReceiptSinkV1 = struct {
    sink_epoch: u64,
    reservation_id: u64,
    receipt: publication.CommitReceiptV1 = undefined,
    prepare_calls: usize = 0,
    commit_calls: usize = 0,
    abort_calls: usize = 0,

    fn interface(
        self: *OneTokenReceiptSinkV1,
    ) publication.SinkV1 {
        return .{
            .context = self,
            .prepare = prepare,
            .commit = commit,
            .abort = abort,
        };
    }

    fn prepare(
        raw: *anyopaque,
        proposal: *const publication.ProposalV1,
        acknowledgement: *publication.PrepareAckV1,
    ) publication.SinkPrepareError!void {
        const self: *OneTokenReceiptSinkV1 =
            @ptrCast(@alignCast(raw));
        self.prepare_calls +|= 1;
        acknowledgement.* = .{
            .proposal_sha256 = publication.proposalSha256(proposal.*),
            .sink_epoch = self.sink_epoch,
            .reservation_id = self.reservation_id,
        };
    }

    fn commit(
        raw: *anyopaque,
        receipt: *const publication.CommitReceiptV1,
    ) void {
        const self: *OneTokenReceiptSinkV1 =
            @ptrCast(@alignCast(raw));
        if (self.commit_calls == 0)
            self.receipt = receipt.*;
        self.commit_calls +|= 1;
    }

    fn abort(
        raw: *anyopaque,
        _: *const publication.ProposalV1,
        _: *const publication.PrepareAckV1,
    ) void {
        const self: *OneTokenReceiptSinkV1 =
            @ptrCast(@alignCast(raw));
        self.abort_calls +|= 1;
    }
};

fn selectedSourceRecoveryContextV1(
    lease: *checkpoint_file.LeaseV1,
) !SelectedSourceRecoveryV1 {
    const selected = try lease.activeSet();
    if (selected.object_count != 3 or
        selected.metadata.generation !=
            source_lease.source_live_set_generation or
        selected.metadata.request_epoch == 0 or
        selected.metadata.publication_next_sequence == 0 or
        !std.mem.allEqual(
            u8,
            &selected.metadata.parent_checkpoint_sha256,
            0,
        ))
        return Error.InvalidSourceRecoveryContract;
    const marker = selected.objects[0];
    const contract_object = selected.objects[1];
    const input_object = selected.objects[2];
    if (marker.kind != .extension or
        marker.ordinal !=
            source_lease.source_live_object_ordinal or
        marker.abi_version !=
            source_lease.source_live_marker_abi or
        !std.mem.eql(
            u8,
            marker.bytes,
            source_lease.source_live_marker,
        ) or contract_object.kind != .extension or
        contract_object.ordinal !=
            source_lease.source_recovery_object_ordinal or
        contract_object.abi_version !=
            source_recovery.contract_abi or
        input_object.kind != .extension or
        input_object.ordinal !=
            source_lease.source_input_object_ordinal or
        input_object.abi_version != input_archive.archive_abi)
        return Error.InvalidSourceRecoveryContract;
    const contract = try source_recovery.decodeV1(
        contract_object.bytes,
    );
    const decoded_input = try input_archive.decodeV1(
        input_object.bytes,
    );
    if (contract.request_epoch !=
        selected.metadata.request_epoch or
        contract.publication_next_sequence !=
            selected.metadata.publication_next_sequence or
        !digestEqual(
            contract.challenge_sha256,
            selected.metadata.challenge_sha256,
        ) or !source_lease.recoveryInputMatchesContractV1(
        decoded_input,
        contract,
    ))
        return Error.InvalidSourceRecoveryContract;
    return .{
        .contract = contract,
        .input_archive = decoded_input,
    };
}

fn selectedSourceExitReceiptV1(
    comptime sink_capacity: usize,
    allocator: std.mem.Allocator,
    input: AdvanceSourceFileInputV1,
    lease: *checkpoint_file.LeaseV1,
    retained_storage: []u8,
    scheduler_identity: lane.IdentityV1,
) !AdvanceSourceFileReceiptV1 {
    const DurableSinkV1 =
        result_sink_file.ResultSinkFileV1(sink_capacity);
    const active = try lease.activeSet();
    const selected = try durable.decodeSourceExitedSetV1(
        lease.stream(),
        lease.selector,
        active.metadata.parent_checkpoint_sha256,
    );
    const contract =
        try durable.validateRecoverableSourcePredecessorV1(
            lease,
            selected,
            retained_storage,
        );
    if (!runtimeIdentityMatchesV1(
        contract.source_runtime,
        scheduler_identity,
    ) or !digestEqual(
        contract.challenge_sha256,
        scheduler_identity.challenge_sha256,
    ) or !sinkConfigMatchesContractV1(
        sink_capacity,
        input.sink,
        contract,
    ))
        return Error.InvalidSourceRecoveryContract;

    const ledger_storage = try allocator.alloc(
        u8,
        try result_sink_file.ledgerBytesForCountV1(
            sink_capacity,
        ),
    );
    defer allocator.free(ledger_storage);
    var sink_lock_storage: [1]u8 = undefined;
    var sink_store = try DurableSinkV1.open(
        input.file.directory,
        contract.sink.storage_epoch,
        contract.plan_sha256,
        contract.request_epoch,
        contract.sink.initial_sequence,
        contract.sink.implementation_sha256,
        contract.sink.instance_sha256,
        &sink_lock_storage,
        ledger_storage,
        null,
    );
    defer sink_store.close();
    try validateEmptySinkSelectionV1(
        sink_capacity,
        sink_store.selector,
        input.sink,
        contract,
    );

    const decoded_checkpoint = selected.evidence.checkpoint;
    if (decoded_checkpoint.output_count != 1 or
        decoded_checkpoint.canonical_output_u32_le.len !=
            @sizeOf(u32))
        return Error.InvalidSourceSequence;
    const output_token = std.mem.readInt(
        u32,
        decoded_checkpoint
            .canonical_output_u32_le[0..4],
        .little,
    );
    const sink_selector = sink_store.selector;
    return .{
        .disposition = .already_selected,
        .input_generation = source_lease.source_live_set_generation,
        .input_sequence = contract.publication_next_sequence,
        .output_generation = lease.selector.generation,
        .output_sequence = lease.selector.publication_next_sequence,
        .output_token = output_token,
        .sink_count = sink_selector.acknowledgement_count,
        .sink_next_sequence = sink_selector.next_sequence,
        .sink_ledger_sha256 = sink_selector.ledger_sha256,
        .sink_selector_sha256 = sink_selector.selector_sha256,
        .checkpoint_sha256 = lease.selector.checkpoint_sha256,
        .checkpoint_selector_sha256 = lease.selector.selector_sha256,
        .source_recovery_contract_sha256 = contract.contract_sha256,
        .ownership_closed = false,
    };
}

fn sinkConfigMatchesContractV1(
    comptime sink_capacity: usize,
    expected: SinkConfigV1,
    contract: source_recovery.DecodedV1,
) bool {
    return contract.sink.capacity == sink_capacity and
        expected.capacity == sink_capacity and
        contract.sink.storage_epoch ==
            expected.storage_epoch and
        digestEqual(
            contract.sink.implementation_sha256,
            expected.implementation_sha256,
        ) and digestEqual(
        contract.sink.instance_sha256,
        expected.instance_sha256,
    );
}

fn validateEmptySinkSelectionV1(
    comptime sink_capacity: usize,
    selector: result_sink_file.DecodedSelectorV1,
    expected: SinkConfigV1,
    contract: source_recovery.DecodedV1,
) !void {
    if (!sinkConfigMatchesContractV1(
        sink_capacity,
        expected,
        contract,
    ) or selector.generation != 1 or
        selector.acknowledgement_count != 0 or
        selector.initial_sequence !=
            contract.sink.initial_sequence or
        selector.next_sequence !=
            contract.sink.initial_sequence or
        selector.request_epoch != contract.request_epoch or
        !digestEqual(
            selector.request_sha256,
            contract.plan_sha256,
        ) or !digestEqual(
        selector.sink_implementation_sha256,
        contract.sink.implementation_sha256,
    ) or !digestEqual(
        selector.sink_instance_sha256,
        contract.sink.instance_sha256,
    ) or !digestEqual(
        selector.ledger_sha256,
        contract.sink.empty_ledger_sha256,
    ) or !digestEqual(
        selector.selector_sha256,
        contract.sink.empty_selector_sha256,
    ))
        return Error.InvalidSourceSink;
}

fn progressForSelectionV1(
    phase: AdvancePhaseV1,
    input_generation: u64,
    input_sequence: u64,
    sink_selector: result_sink_file.DecodedSelectorV1,
    checkpoint_selector_sha256: Digest,
) AdvanceProgressV1 {
    return .{
        .phase = phase,
        .input_generation = input_generation,
        .input_sequence = input_sequence,
        .sink_count = sink_selector.acknowledgement_count,
        .sink_ledger_sha256 = sink_selector.ledger_sha256,
        .sink_selector_sha256 = sink_selector.selector_sha256,
        .checkpoint_selector_sha256 = checkpoint_selector_sha256,
    };
}

fn observeAdvanceProgressV1(
    observer: ?AdvanceProgressObserverV1,
    progress: AdvanceProgressV1,
) !void {
    if (observer) |value| try value.after(progress);
}

fn checkpointContextV1(
    source_session: *session.SessionV3,
    model: *const loader.LoadedModel,
    bound_plan: session.BoundPlanV1,
    local_plan: session.PlanV1,
    request_epoch: u64,
    challenge_sha256: Digest,
) !SourceCheckpointContextV1 {
    const boundary = try source_session.snapshotVerified();
    const cache =
        &source_session.inner.inner.resources.cache;
    const expected: checkpoint.ExpectedBindingsV1 = .{
        .local_plan_sha256 = local_plan.plan_sha256,
        .bound_plan_sha256 = bound_plan.bound_plan_sha256,
        .artifact_sha256 = bound_plan.artifact.artifact_sha256,
        .execution_plan_sha256 = bound_plan.execution.plan_sha256,
        .residency_binding_sha256 = bound_plan.residency.binding_sha256,
        .boundary_sha256 = boundary.boundary_sha256,
        .transcript_sha256 = boundary.base.publication.transcript_sha256,
        .state_commitment_sha256 = boundary.base.publication.state
            .commitment_sha256,
        .request_epoch = request_epoch,
        .publication_next_sequence = boundary.base.publication.next_sequence,
        .prompt_tokens = local_plan.prompt_tokens,
        .max_new_tokens = local_plan.max_new_tokens,
        .vocab_size = @intCast(model.config.vocab_size),
        .num_layers = @intCast(cache.num_layers),
        .kv_dim = @intCast(cache.dim),
        .max_kv_positions = @intCast(cache.max_seq),
        .kv_positions = @intCast(cache.len),
        .output_count = @intCast(source_session.outputTokens().len),
        .sampling_calls = source_session.inner.inner.sampling_calls,
        .challenge_sha256 = challenge_sha256,
    };
    return .{
        .boundary = boundary,
        .expected = expected,
        .source = .{
            .bound_plan_sha256 = bound_plan.bound_plan_sha256,
            .execution = bound_plan.execution,
            .residency = bound_plan.residency,
            .boundary_sha256 = boundary.boundary_sha256,
            .publication = boundary.base.publication,
            .receipt = source_session.result_receipt,
        },
    };
}

fn requireRuntimeZeroV1(
    runtime: SourceRuntimeV1,
) !void {
    const bank_snapshot = try runtime.bank.snapshotV3();
    const scheduler_snapshot =
        try runtime.scheduler.snapshot();
    if (!bank_snapshot.used.isZero() or
        bank_snapshot.active_lease_trees != 0 or
        bank_snapshot.active_lease_scopes != 0 or
        bank_snapshot.active_lease_nodes != 0 or
        bank_snapshot.live_allocations != 0 or
        scheduler_snapshot.active != 0)
        return Error.RuntimeAuthorityLeak;
}

fn runtimeIdentityMatchesV1(
    source: SourceRuntimeIdentityV1,
    scheduler: lane.IdentityV1,
) bool {
    return source.scheduler_epoch ==
        scheduler.scheduler_epoch and
        source.coordinator_id == scheduler.coordinator_id and
        source.bank_epoch == scheduler.bank_epoch;
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

fn recoverableSetBytesV1(
    contract_bytes: usize,
    archive_bytes: usize,
) !usize {
    var total = checkpoint_file.set_payload_offset;
    total = try std.math.add(
        usize,
        total,
        source_lease.source_live_marker.len,
    );
    total = try std.math.add(
        usize,
        total,
        contract_bytes,
    );
    total = try std.math.add(
        usize,
        total,
        archive_bytes,
    );
    return std.math.add(
        usize,
        total,
        checkpoint_file.set_footer_bytes,
    );
}

test "runtime identity comparison excludes process address" {
    const source: SourceRuntimeIdentityV1 = .{
        .scheduler_epoch = 11,
        .coordinator_id = 12,
        .bank_epoch = 13,
    };
    const scheduler: lane.IdentityV1 = .{
        .scheduler_epoch = 11,
        .coordinator_id = 12,
        .coordinator_address = 0xdead_beef,
        .bank_epoch = 13,
        .challenge_sha256 = [_]u8{0xa5} ** 32,
    };
    try std.testing.expect(
        runtimeIdentityMatchesV1(source, scheduler),
    );
    var wrong = scheduler;
    wrong.coordinator_id += 1;
    try std.testing.expect(
        !runtimeIdentityMatchesV1(source, wrong),
    );
}

test "recoverable set sizing includes all canonical objects" {
    const contract_bytes: usize = 1_111;
    const archive_bytes: usize = 2_222;
    try std.testing.expectEqual(
        checkpoint_file.set_payload_offset +
            source_lease.source_live_marker.len +
            contract_bytes +
            archive_bytes +
            checkpoint_file.set_footer_bytes,
        try recoverableSetBytesV1(
            contract_bytes,
            archive_bytes,
        ),
    );
    try std.testing.expectError(
        error.Overflow,
        recoverableSetBytesV1(
            std.math.maxInt(usize),
            archive_bytes,
        ),
    );
}
