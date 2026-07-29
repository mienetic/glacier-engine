//! Supported experimental raw-text command for one prepared CPU profile.
//!
//! This path intentionally bypasses the compatibility `generate` command. It
//! validates a prepared GLRT image, hashes exact license bytes, tokenizes one
//! strict UTF-8 prompt, binds that evidence into the Common Model Contract,
//! executes through SessionV3, seals the terminal result, and proves final
//! logical ownership returns to zero.

const std = @import("std");
const engine = @import("engine");
const bounded_input = engine.bounded_file_input;

const maximum_license_bytes =
    engine.model_package_producer.maximum_license_bytes;
const tokenizer_input_limit =
    engine.model_package_producer.tokenizer_max_input_bytes;
const maximum_new_tokens: usize = 64;
const default_durable_max_set_bytes: usize = 8 * 1024 * 1024;
const maximum_durable_max_set_bytes: usize = 64 * 1024 * 1024;
const durable_challenge_domain =
    "glacier-prepared-text-durable-cli-challenge-v1\x00";
const durable_runtime_identity_domain =
    "glacier-prepared-text-durable-cli-runtime-v1\x00";
const durable_scheduling_identity_domain =
    "glacier-prepared-text-durable-cli-scheduling-v1\x00";
const request_epoch: u64 = 0x5231_4b42_0000_0001;
const bank_epoch: u64 = 0x5231_4b42_0000_0002;
const scheduler_epoch: u64 = 0x5231_4b42_0000_0003;
const coordinator_id: u64 = 0x5231_4b42_0000_0004;
const retained_fixture_source_fingerprint = [32]u8{
    0x85, 0x3f, 0xd0, 0xc2, 0x4d, 0x0c, 0x5a, 0x84,
    0x74, 0x17, 0x29, 0x2a, 0xfe, 0x09, 0xe2, 0x98,
    0x47, 0xc7, 0xef, 0x72, 0x07, 0x0e, 0x2a, 0x6f,
    0xd6, 0x40, 0x8a, 0x90, 0x67, 0x7c, 0xf7, 0x47,
};
const retained_fixture_license_sha256 = [32]u8{
    0x43, 0xc3, 0xaf, 0xa8, 0x1d, 0x9e, 0xa0, 0xff,
    0xdd, 0xe3, 0x29, 0x3b, 0x4d, 0xcc, 0x0f, 0x8d,
    0x17, 0xe2, 0xa0, 0xfb, 0x76, 0xb7, 0xd2, 0xd8,
    0xff, 0x8a, 0x84, 0x1f, 0xd5, 0x6f, 0x58, 0x88,
};

const DurableSelectionV1 = enum {
    absent,
    source_live,
    terminal,
};

const DurableSelectionFactsV1 = struct {
    kind: DurableSelectionV1,
    selector: ?engine.core.continuation_checkpoint_file.DecodedSelectorV1,
};

const DurableIdentityV1 = struct {
    request_id_sha256: [32]u8,
    challenge_sha256: [32]u8,
    request_epoch: u64,
    storage_epoch: u64,
    source_runtime: engine.prepared_text_durable_runtime
        .TerminalSourceRuntimeIdentityV1,
    scheduling: engine.prepared_text_session.SchedulingV1,
    step_sink: engine.prepared_text_durable_runtime.SourceStepSinkV1,
};

const DurableSourceRuntimeV1 = struct {
    bank_slots: [2]engine.resource_bank.Slot = undefined,
    lane_slots: [2]engine.lane_weave_qos.Slot = undefined,
    projection_slots: [2]engine.lane_weave_qos.ProjectionSlot =
        undefined,
    bank: engine.resource_bank.Bank = undefined,
    scheduler: engine.lane_weave_qos.Scheduler = undefined,

    fn init(
        self: *DurableSourceRuntimeV1,
        identity: engine.prepared_text_durable_runtime
            .TerminalSourceRuntimeIdentityV1,
        challenge_sha256: [32]u8,
    ) !void {
        self.bank = try engine.resource_bank.Bank.init(
            &self.bank_slots,
            .{},
            identity.bank_epoch,
        );
        self.scheduler = try engine.lane_weave_qos.Scheduler.init(
            &self.bank,
            .{
                .slots = &self.lane_slots,
                .projection = &self.projection_slots,
            },
            .{
                .scheduler_epoch = identity.scheduler_epoch,
                .coordinator_id = identity.coordinator_id,
                .challenge = challenge_sha256,
                .max_weight = 1,
            },
        );
    }
};

const ReceiptSinkV1 = struct {
    prepare_calls: usize = 0,
    commit_calls: usize = 0,
    abort_calls: usize = 0,
    last_transcript_sha256: [32]u8 = [_]u8{0} ** 32,

    fn interface(self: *ReceiptSinkV1) engine.lane_publication_txn.SinkV1 {
        return .{
            .context = self,
            .prepare = prepare,
            .commit = commit,
            .abort = abort,
        };
    }

    fn prepare(
        raw: *anyopaque,
        proposal: *const engine.lane_publication_txn.ProposalV1,
        acknowledgement: *engine.lane_publication_txn.PrepareAckV1,
    ) engine.lane_publication_txn.SinkPrepareError!void {
        const self: *ReceiptSinkV1 = @ptrCast(@alignCast(raw));
        self.prepare_calls += 1;
        acknowledgement.* = .{
            .proposal_sha256 = engine.lane_publication_txn.proposalSha256(proposal.*),
            .sink_epoch = 0x5231_4b42_0000_0010,
            .reservation_id = self.prepare_calls,
        };
    }

    fn commit(
        raw: *anyopaque,
        receipt: *const engine.lane_publication_txn.CommitReceiptV1,
    ) void {
        const self: *ReceiptSinkV1 = @ptrCast(@alignCast(raw));
        self.commit_calls += 1;
        self.last_transcript_sha256 = receipt.transcript_sha256;
    }

    fn abort(
        raw: *anyopaque,
        _: *const engine.lane_publication_txn.ProposalV1,
        _: *const engine.lane_publication_txn.PrepareAckV1,
    ) void {
        const self: *ReceiptSinkV1 = @ptrCast(@alignCast(raw));
        self.abort_calls += 1;
    }
};

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    writer: *std.Io.Writer,
) !void {
    if (args.len < 7) {
        try usage(writer);
        return error.InvalidUsage;
    }
    const model_path = args[2];
    var raw_text: ?[]const u8 = null;
    var raw_text_path: ?[]const u8 = null;
    var license_path: ?[]const u8 = null;
    var package_path: ?[]const u8 = null;
    var durable_directory: ?[]const u8 = null;
    var durable_request_id: ?[]const u8 = null;
    var durable_bootstrap_only = false;
    var reveal_output = false;
    var durable_max_set_bytes = default_durable_max_set_bytes;
    var durable_max_set_bytes_supplied = false;
    var new_tokens: usize = 4;
    var new_tokens_supplied = false;
    var index: usize = 3;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--text")) {
            if (raw_text != null or raw_text_path != null)
                return error.InvalidUsage;
            index += 1;
            if (index >= args.len) return error.InvalidUsage;
            raw_text = args[index];
        } else if (std.mem.eql(u8, argument, "--text-file")) {
            if (raw_text != null or raw_text_path != null)
                return error.InvalidUsage;
            index += 1;
            if (index >= args.len) return error.InvalidUsage;
            raw_text_path = args[index];
        } else if (std.mem.eql(u8, argument, "--license")) {
            if (license_path != null) return error.InvalidUsage;
            index += 1;
            if (index >= args.len) return error.InvalidUsage;
            license_path = args[index];
        } else if (std.mem.eql(u8, argument, "--package")) {
            if (package_path != null) return error.InvalidUsage;
            index += 1;
            if (index >= args.len) return error.InvalidUsage;
            package_path = args[index];
        } else if (std.mem.eql(u8, argument, "--n")) {
            if (new_tokens_supplied) return error.InvalidUsage;
            new_tokens_supplied = true;
            index += 1;
            if (index >= args.len) return error.InvalidUsage;
            new_tokens = std.fmt.parseInt(
                usize,
                args[index],
                10,
            ) catch return error.InvalidUsage;
        } else if (std.mem.eql(u8, argument, "--durable-dir")) {
            if (durable_directory != null)
                return error.InvalidUsage;
            index += 1;
            if (index >= args.len) return error.InvalidUsage;
            durable_directory = args[index];
        } else if (std.mem.eql(u8, argument, "--request-id")) {
            if (durable_request_id != null)
                return error.InvalidUsage;
            index += 1;
            if (index >= args.len) return error.InvalidUsage;
            durable_request_id = args[index];
        } else if (std.mem.eql(u8, argument, "--bootstrap-only")) {
            if (durable_bootstrap_only)
                return error.InvalidUsage;
            durable_bootstrap_only = true;
        } else if (std.mem.eql(u8, argument, "--reveal-output")) {
            if (reveal_output)
                return error.InvalidUsage;
            reveal_output = true;
        } else if (std.mem.eql(u8, argument, "--max-set-bytes")) {
            if (durable_max_set_bytes_supplied)
                return error.InvalidUsage;
            durable_max_set_bytes_supplied = true;
            index += 1;
            if (index >= args.len) return error.InvalidUsage;
            durable_max_set_bytes = std.fmt.parseInt(
                usize,
                args[index],
                10,
            ) catch return error.InvalidUsage;
        } else {
            return error.InvalidUsage;
        }
    }
    const durable_requested = durable_directory != null;
    if (durable_requested) {
        if (package_path == null or
            durable_request_id == null or
            new_tokens != 1 or
            !std.fs.path.isAbsolute(durable_directory.?) or
            (durable_bootstrap_only and reveal_output) or
            durable_max_set_bytes == 0 or
            durable_max_set_bytes >
                maximum_durable_max_set_bytes)
            return error.InvalidUsage;
    } else if (durable_request_id != null or
        durable_bootstrap_only or
        reveal_output or
        durable_max_set_bytes_supplied)
        return error.InvalidUsage;
    var owned_text: ?[]u8 = null;
    defer if (owned_text) |bytes| allocator.free(bytes);
    const text = raw_text orelse blk: {
        const path = raw_text_path orelse {
            try usage(writer);
            return error.InvalidUsage;
        };
        const bytes = try bounded_input.readAllocV1(
            allocator,
            path,
            tokenizer_input_limit,
        );
        owned_text = bytes;
        break :blk bytes;
    };
    const selected_license_path = license_path orelse {
        try usage(writer);
        return error.InvalidUsage;
    };
    if (new_tokens == 0 or new_tokens > maximum_new_tokens)
        return error.InvalidUsage;
    if (text.len == 0) return error.EmptyInput;
    if (text.len > tokenizer_input_limit)
        return error.InputTooLarge;
    if (!std.unicode.utf8ValidateSlice(text))
        return error.InvalidUtf8;

    const license_bytes = try bounded_input.readAllocV1(
        allocator,
        selected_license_path,
        maximum_license_bytes,
    );
    defer allocator.free(license_bytes);
    if (license_bytes.len == 0) return error.InvalidLicense;
    const artifact_license_sha256 =
        engine.core.model_contract.sha256(license_bytes);

    var package_storage: ?[]u8 = null;
    defer if (package_storage) |bytes| allocator.free(bytes);
    const admitted_bundle = if (package_path) |path| blk: {
        const bytes = try bounded_input.readAllocV1(
            allocator,
            path,
            engine.model_package_manifest.admission_bundle_bytes,
        );
        package_storage = bytes;
        if (bytes.len !=
            engine.model_package_manifest.admission_bundle_bytes)
            return error.InvalidPackageLength;
        const admission = try engine.model_package_manifest
            .decodeAdmissionBundleV1(bytes);
        const package = admission.package;
        _ = try engine.model_package_producer
            .validateSupportedPackageV1(package);
        const license_byte_count = std.math.cast(
            u64,
            license_bytes.len,
        ) orelse return error.InvalidLicense;
        if (package.license_bytes != license_byte_count or
            !std.mem.eql(
                u8,
                &package.license_sha256,
                &artifact_license_sha256,
            ))
            return error.PackageLicenseMismatch;
        break :blk admission;
    } else null;
    if (admitted_bundle == null and
        !std.mem.eql(
            u8,
            &artifact_license_sha256,
            &retained_fixture_license_sha256,
        ))
        return error.UnsupportedFixtureLicense;

    const model_file = try bounded_input.openRegularV1(model_path);
    var model = try engine.loader.loadPreparedOwnedFileWithOptionsV1(
        allocator,
        model_file,
        .{
            .expected_source_fingerprint = if (admitted_bundle) |admission|
                admission.package.model_content_sha256
            else
                retained_fixture_source_fingerprint,
            .mlp_layout = .separate_required,
        },
    );
    defer model.deinit();
    const image_identity = try model.preparedImageIdentityV1();
    var admitted_representation: ?engine.model_package_manifest.PreparedRepresentationV1 = null;
    const manifest = if (admitted_bundle) |admission| blk: {
        const package = admission.package;
        admitted_representation = try engine
            .model_package_producer
            .preparedRepresentationForModelV1(
            package,
            &model,
        );
        if (!std.meta.eql(
            admitted_representation.?,
            admission.representation,
        ))
            return error.PackageRepresentationMismatch;
        break :blk try engine.model_package_producer
            .validateSupportedPackageV1(package);
    } else blk: {
        if (!std.mem.eql(
            u8,
            &image_identity.source_fingerprint,
            &retained_fixture_source_fingerprint,
        ) or
            model.config.dim != 32 or
            model.config.hidden_dim != 32 or
            model.config.num_layers != 1 or
            model.config.vocab_size != 256 or
            model.config.num_heads != 1 or
            model.config.head_dim != 32 or
            model.config.num_kv_heads != 1 or
            model.config.rms_eps != @as(f32, 1e-6) or
            model.config.rope_theta != @as(f32, 10000.0) or
            model.config.tie_word_embeddings)
            return error.UnsupportedFixtureImage;
        const vocab_size = std.math.cast(
            u32,
            model.config.vocab_size,
        ) orelse return error.UnsupportedVocabulary;
        break :blk try engine.tokenizer
            .makeUtf8ByteManifestV1(
            vocab_size,
            tokenizer_input_limit,
        );
    };
    var tokenized = try engine.tokenizer.tokenizeUtf8BytesV1(
        allocator,
        manifest,
        text,
    );
    defer tokenized.deinit();

    if (durable_directory) |directory_path| {
        const admission = admitted_bundle orelse
            return error.PackageRequiredForDurableRun;
        const representation = admitted_representation orelse
            return error.PackageRequiredForDurableRun;
        return runDurableDirectTerminalV1(
            allocator,
            writer,
            &model,
            admission.package,
            representation,
            text,
            tokenized.receipt.raw_text_sha256,
            manifest,
            artifact_license_sha256,
            durable_request_id.?,
            directory_path,
            durable_max_set_bytes,
            durable_bootstrap_only,
            reveal_output,
        );
    }

    var bank_slots: [2]engine.resource_bank.Slot = undefined;
    var lane_slots: [2]engine.lane_weave_qos.Slot = undefined;
    var projection_slots: [2]engine.lane_weave_qos.ProjectionSlot =
        undefined;
    var bank = try engine.resource_bank.Bank.init(
        &bank_slots,
        .{},
        bank_epoch,
    );
    var scheduler = try engine.lane_weave_qos.Scheduler.init(
        &bank,
        .{
            .slots = &lane_slots,
            .projection = &projection_slots,
        },
        .{
            .scheduler_epoch = scheduler_epoch,
            .coordinator_id = coordinator_id,
            .challenge = tokenized.receipt.receipt_sha256,
            .max_weight = 1,
        },
    );
    var scheduler_closed = false;
    defer if (!scheduler_closed) {
        _ = scheduler.close() catch {};
    };
    const scheduling: engine.prepared_text_session.SchedulingV1 = .{
        .tenant_key = 0x5231_4b42_0000_0021,
        .request_key = 0x5231_4b42_0000_0022,
        .request_generation = 1,
        .resource_owner_key = 0x5231_4b42_0000_0023,
        .weight = 1,
    };
    const options: engine.prepared_text_session.OptionsV1 = .{
        .max_new_tokens = new_tokens,
    };
    const local_plan = try engine.prepared_text_session.makePlanV1(
        model,
        tokenized.tokens,
        options,
    );
    const bound_input =
        try engine.prepared_text_raw_input.makeBoundPlanInputV1(
            request_epoch,
            manifest,
            artifact_license_sha256,
        );
    const bound_plan =
        try engine.prepared_text_session.makeBoundPlanV1(
            model,
            tokenized.tokens,
            options,
            local_plan,
            scheduling,
            &scheduler,
            bound_input,
        );
    const raw_input_binding =
        try engine.prepared_text_raw_input.makeBindingV1(
            text,
            &tokenized,
            local_plan,
            bound_plan,
        );

    var session: engine.prepared_text_session.SessionV3 = .{};
    defer session.deinit();
    const start = try session.start(
        allocator,
        &model,
        tokenized.tokens,
        options,
        local_plan,
        bound_input,
        bound_plan,
        scheduling,
        &scheduler,
        &bank,
    );
    switch (start) {
        .started => {},
        .rejected => return error.AdmissionRejected,
    }

    var sink: ReceiptSinkV1 = .{};
    while (!session.isFinished()) {
        _ = try session.step(
            try scheduler.prepareService(),
            sink.interface(),
        );
    }
    if (sink.prepare_calls != new_tokens or
        sink.commit_calls != new_tokens or
        sink.abort_calls != 0)
        return error.PublicationMismatch;
    const terminal = try session.sealTerminalResult();
    const output = session.outputTokens();
    if (output.len != new_tokens)
        return error.PublicationMismatch;
    _ = try session.retire();
    _ = try scheduler.close();
    scheduler_closed = true;
    const bank_snapshot = try bank.snapshot();
    if (!bank_snapshot.used.isZero() or
        bank_snapshot.committed_receipts != 0)
        return error.ResourceLeak;

    var tokenizer_manifest_wire: [engine.tokenizer.utf8_byte_manifest_bytes]u8 = undefined;
    _ = try engine.tokenizer.encodeUtf8ByteManifestV1(
        manifest,
        &tokenizer_manifest_wire,
    );
    var prompt_receipt_wire: [engine.tokenizer.utf8_byte_prompt_bytes]u8 = undefined;
    _ = try engine.tokenizer.encodeUtf8BytePromptReceiptV1(
        tokenized.receipt,
        &prompt_receipt_wire,
    );
    var raw_input_binding_wire: [engine.prepared_text_raw_input.binding_bytes]u8 = undefined;
    _ = try engine.prepared_text_raw_input.encodeV1(
        raw_input_binding,
        &raw_input_binding_wire,
    );
    var artifact_wire: [engine.core.model_contract.artifact_manifest_bytes]u8 =
        undefined;
    try engine.core.model_contract.encodeArtifactManifestV1(
        bound_plan.artifact,
        &artifact_wire,
    );
    var execution_plan_wire: [engine.core.model_contract.execution_plan_bytes]u8 =
        undefined;
    try engine.core.model_contract.encodeExecutionPlanV1(
        bound_plan.execution,
        &execution_plan_wire,
    );
    var residency_binding_wire: [engine.core.model_contract.execution_residency_binding_bytes]u8 =
        undefined;
    try engine.core.model_contract.encodeExecutionResidencyBindingV1(
        bound_plan.residency,
        &residency_binding_wire,
    );
    var result_envelope_wire: [engine.core.model_contract.result_envelope_bytes]u8 =
        undefined;
    try engine.core.model_contract.encodeResultEnvelopeV1(
        terminal.result,
        &result_envelope_wire,
    );

    const tokenizer_domain_hex = std.fmt.bytesToHex(
        manifest.domain_sha256,
        .lower,
    );
    const tokenizer_behavior_hex = std.fmt.bytesToHex(
        manifest.behavior_sha256,
        .lower,
    );
    const tokenizer_config_hex = std.fmt.bytesToHex(
        manifest.config_sha256,
        .lower,
    );
    const prompt_receipt_hex = std.fmt.bytesToHex(
        tokenized.receipt.receipt_sha256,
        .lower,
    );
    const raw_binding_hex = std.fmt.bytesToHex(
        raw_input_binding.binding_sha256,
        .lower,
    );
    const raw_text_hex = std.fmt.bytesToHex(
        tokenized.receipt.raw_text_sha256,
        .lower,
    );
    const token_ids_hex = std.fmt.bytesToHex(
        tokenized.receipt.token_ids_sha256,
        .lower,
    );
    const prepared_prompt_hex = std.fmt.bytesToHex(
        local_plan.prompt_sha256,
        .lower,
    );
    const local_plan_hex = std.fmt.bytesToHex(
        local_plan.plan_sha256,
        .lower,
    );
    const prepared_image_hex = std.fmt.bytesToHex(
        local_plan.image_identity.container_sha256,
        .lower,
    );
    const prepared_source_hex = std.fmt.bytesToHex(
        local_plan.image_identity.source_fingerprint,
        .lower,
    );
    const bound_plan_hex = std.fmt.bytesToHex(
        bound_plan.bound_plan_sha256,
        .lower,
    );
    const artifact_hex = std.fmt.bytesToHex(
        bound_plan.artifact.artifact_sha256,
        .lower,
    );
    const plan_hex = std.fmt.bytesToHex(
        bound_plan.execution.plan_sha256,
        .lower,
    );
    const residency_hex = std.fmt.bytesToHex(
        bound_plan.residency.binding_sha256,
        .lower,
    );
    const license_hex = std.fmt.bytesToHex(
        artifact_license_sha256,
        .lower,
    );
    const result_hex = std.fmt.bytesToHex(
        terminal.evidence_sha256,
        .lower,
    );
    const output_hex = std.fmt.bytesToHex(
        terminal.result.output_sha256,
        .lower,
    );
    const sink_transcript_hex = std.fmt.bytesToHex(
        sink.last_transcript_sha256,
        .lower,
    );
    const prepared_abi_hex = std.fmt.bytesToHex(
        local_plan.image_identity.abi_fingerprint,
        .lower,
    );
    const boundary_hex = std.fmt.bytesToHex(
        terminal.boundary.boundary_sha256,
        .lower,
    );
    const result_envelope_hex = std.fmt.bytesToHex(
        terminal.result.result_sha256,
        .lower,
    );
    const publication_after_hex = std.fmt.bytesToHex(
        terminal.publication_state_after_sha256,
        .lower,
    );
    const publication_previous_result_hex = std.fmt.bytesToHex(
        terminal.publication_state_after.previous_result_sha256,
        .lower,
    );
    const tokenizer_manifest_wire_hex = std.fmt.bytesToHex(
        tokenizer_manifest_wire,
        .lower,
    );
    const prompt_receipt_wire_hex = std.fmt.bytesToHex(
        prompt_receipt_wire,
        .lower,
    );
    const raw_input_binding_wire_hex = std.fmt.bytesToHex(
        raw_input_binding_wire,
        .lower,
    );
    const artifact_wire_hex = std.fmt.bytesToHex(
        artifact_wire,
        .lower,
    );
    const execution_plan_wire_hex = std.fmt.bytesToHex(
        execution_plan_wire,
        .lower,
    );
    const residency_binding_wire_hex = std.fmt.bytesToHex(
        residency_binding_wire,
        .lower,
    );
    const result_envelope_wire_hex = std.fmt.bytesToHex(
        result_envelope_wire,
        .lower,
    );
    const prompt_source =
        if (raw_text_path != null) "file" else "argv";
    const package_admission = admitted_bundle != null;
    try writer.print(
        "{{\"schema\":\"glacier.prepared-text-raw-run/v1\"," ++
            "\"profile\":\"utf8-byte-v1\"," ++
            "\"model_profile\":\"{s}\"," ++
            "\"prompt_source\":\"{s}\"," ++
            "\"output_rendering\":\"token-ids\"," ++
            "\"prepared_image\":true,\"common_plan\":true," ++
            "\"transactional_publication\":true," ++
            "\"durable_result_sink\":false," ++
            "\"fresh_process_recovery\":false," ++
            "\"production_model\":false," ++
            "\"package_admission\":{s}," ++
            "\"user_supplied_model\":{s}," ++
            "\"retained_fixture_profile_verified\":{s}," ++
            "\"prompt_hashes_are_anonymized\":false," ++
            "\"replay_safe\":false," ++
            "\"boundary_snapshot_independently_verified\":false," ++
            "\"publication_transcript_replayed\":false,",
        .{
            if (package_admission)
                "ordinary-package-v1"
            else
                "retained-r1kb1-fixture-v1",
            prompt_source,
            if (package_admission) "true" else "false",
            if (package_admission) "true" else "false",
            if (package_admission) "false" else "true",
        },
    );
    if (admitted_bundle) |admission| {
        const package = admission.package;
        const package_hex = std.fmt.bytesToHex(
            package.package_sha256,
            .lower,
        );
        const representation_hex = std.fmt.bytesToHex(
            admitted_representation.?.representation_sha256,
            .lower,
        );
        try writer.print(
            "\"package_sha256\":\"{s}\"," ++
                "\"representation_sha256\":\"{s}\",",
            .{
                &package_hex,
                &representation_hex,
            },
        );
    } else {
        try writer.writeAll(
            "\"package_sha256\":null," ++
                "\"representation_sha256\":null,",
        );
    }
    try writer.print(
        "\"prompt_bytes\":{d},\"prompt_tokens\":{d}," ++
            "\"output_tokens\":[",
        .{ text.len, tokenized.tokens.len },
    );
    for (output, 0..) |token, token_index| {
        if (token_index != 0) try writer.writeByte(',');
        try writer.print("{d}", .{token});
    }
    try writer.print(
        "],\"request_epoch\":{d}," ++
            "\"tokenizer_vocab_size\":{d}," ++
            "\"tokenizer_max_input_bytes\":{d}," ++
            "\"tokenizer_domain_sha256\":\"{s}\"," ++
            "\"tokenizer_behavior_sha256\":\"{s}\"," ++
            "\"tokenizer_config_sha256\":\"{s}\"," ++
            "\"prompt_receipt_sha256\":\"{s}\"," ++
            "\"raw_text_sha256\":\"{s}\"," ++
            "\"token_ids_sha256\":\"{s}\"," ++
            "\"prepared_prompt_sha256\":\"{s}\"," ++
            "\"local_plan_sha256\":\"{s}\"," ++
            "\"prepared_image_sha256\":\"{s}\"," ++
            "\"prepared_source_fingerprint\":\"{s}\"," ++
            "\"prepared_abi_fingerprint\":\"{s}\"," ++
            "\"prepared_image_bytes\":{d}," ++
            "\"local_plan_max_new_tokens\":{d}," ++
            "\"local_plan_eos_token\":{d}," ++
            "\"local_plan_seed\":{d}," ++
            "\"local_claim\":{{" ++
            "\"capsule_bytes\":{d},\"kv_bytes\":{d}," ++
            "\"activation_bytes\":{d},\"partial_bytes\":{d}," ++
            "\"logits_bytes\":{d},\"output_journal_bytes\":{d}," ++
            "\"staging_bytes\":{d},\"device_bytes\":{d}," ++
            "\"io_bytes\":{d},\"queue_slots\":{d}}},",
        .{
            request_epoch,
            manifest.vocab_size,
            manifest.max_input_bytes,
            &tokenizer_domain_hex,
            &tokenizer_behavior_hex,
            &tokenizer_config_hex,
            &prompt_receipt_hex,
            &raw_text_hex,
            &token_ids_hex,
            &prepared_prompt_hex,
            &local_plan_hex,
            &prepared_image_hex,
            &prepared_source_hex,
            &prepared_abi_hex,
            local_plan.image_identity.container_bytes,
            local_plan.max_new_tokens,
            local_plan.eos_token,
            local_plan.seed,
            local_plan.claim.capsule_bytes,
            local_plan.claim.kv_bytes,
            local_plan.claim.activation_bytes,
            local_plan.claim.partial_bytes,
            local_plan.claim.logits_bytes,
            local_plan.claim.output_journal_bytes,
            local_plan.claim.staging_bytes,
            local_plan.claim.device_bytes,
            local_plan.claim.io_bytes,
            local_plan.claim.queue_slots,
        },
    );
    try writer.print(
        "\"bound_plan_sha256\":\"{s}\"," ++
            "\"raw_input_binding_sha256\":\"{s}\"," ++
            "\"artifact_sha256\":\"{s}\"," ++
            "\"execution_plan_sha256\":\"{s}\"," ++
            "\"residency_binding_sha256\":\"{s}\"," ++
            "\"artifact_license_sha256\":\"{s}\"," ++
            "\"output_sha256\":\"{s}\"," ++
            "\"boundary_sha256\":\"{s}\"," ++
            "\"result_envelope_sha256\":\"{s}\"," ++
            "\"publication_state_after_sha256\":\"{s}\"," ++
            "\"publication_state_after_request_epoch\":{d}," ++
            "\"publication_state_after_next_sequence\":{d}," ++
            "\"publication_state_after_visible_results\":{d}," ++
            "\"publication_state_after_previous_result_sha256\":\"{s}\"," ++
            "\"result_evidence_sha256\":\"{s}\"," ++
            "\"last_sink_transcript_sha256\":\"{s}\"," ++
            "\"tokenizer_manifest_wire_hex\":\"{s}\"," ++
            "\"prompt_receipt_wire_hex\":\"{s}\"," ++
            "\"raw_input_binding_wire_hex\":\"{s}\"," ++
            "\"artifact_manifest_wire_hex\":\"{s}\"," ++
            "\"execution_plan_wire_hex\":\"{s}\"," ++
            "\"residency_binding_wire_hex\":\"{s}\"," ++
            "\"result_envelope_wire_hex\":\"{s}\"," ++
            "\"final_bank_host_bytes\":0," ++
            "\"runtime_self_verified\":true}}\n",
        .{
            &bound_plan_hex,
            &raw_binding_hex,
            &artifact_hex,
            &plan_hex,
            &residency_hex,
            &license_hex,
            &output_hex,
            &boundary_hex,
            &result_envelope_hex,
            &publication_after_hex,
            terminal.publication_state_after.request_epoch,
            terminal.publication_state_after.next_sequence,
            terminal.publication_state_after.visible_results,
            &publication_previous_result_hex,
            &result_hex,
            &sink_transcript_hex,
            &tokenizer_manifest_wire_hex,
            &prompt_receipt_wire_hex,
            &raw_input_binding_wire_hex,
            &artifact_wire_hex,
            &execution_plan_wire_hex,
            &residency_binding_wire_hex,
            &result_envelope_wire_hex,
        },
    );
}

fn runDurableDirectTerminalV1(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    model: *engine.loader.LoadedModel,
    package: engine.model_package_manifest.ManifestV1,
    representation: engine.model_package_manifest.PreparedRepresentationV1,
    raw_text: []const u8,
    raw_text_sha256: [32]u8,
    tokenizer_manifest: engine.tokenizer.Utf8ByteManifestV1,
    artifact_license_sha256: [32]u8,
    request_id_hex: []const u8,
    directory_path: []const u8,
    max_set_bytes: usize,
    bootstrap_only: bool,
    reveal_output: bool,
) !void {
    if (comptime !engine.prepared_text_durable_runtime
        .bootstrap_file_available_v1)
        return error.UnsupportedPlatform;

    const identity = try deriveDurableIdentityV1(
        request_id_hex,
        package.package_sha256,
        representation.representation_sha256,
        artifact_license_sha256,
        raw_text_sha256,
    );
    var directory = try std.fs.openDirAbsolute(
        directory_path,
        .{
            .access_sub_paths = true,
            .iterate = false,
            .no_follow = true,
        },
    );
    defer directory.close();

    const selection_before =
        try classifyDurableSelectionV1(directory);
    if (selection_before.selector) |selector| {
        if (selector.request_epoch != identity.request_epoch or
            !std.mem.eql(
                u8,
                &selector.challenge_sha256,
                &identity.challenge_sha256,
            ))
            return error.DurableRequestMismatch;
    }
    if (bootstrap_only and selection_before.kind == .terminal)
        return error.DurableRequestAlreadyTerminal;

    var runtime: DurableSourceRuntimeV1 = .{};
    try runtime.init(
        identity.source_runtime,
        identity.challenge_sha256,
    );
    var runtime_closed = false;
    defer if (!runtime_closed) {
        _ = runtime.scheduler.close() catch {};
    };

    const options: engine.prepared_text_session.OptionsV1 = .{
        .max_new_tokens = 1,
    };
    const bound_plan_input =
        try engine.prepared_text_raw_input.makeBoundPlanInputV1(
            identity.request_epoch,
            tokenizer_manifest,
            artifact_license_sha256,
        );
    var bootstrap_receipt: ?engine.prepared_text_durable_runtime
        .BootstrapDirectTerminalFileReceiptV1 = null;
    if (selection_before.kind != .terminal) {
        bootstrap_receipt =
            try engine.prepared_text_durable_runtime
                .bootstrapDirectTerminalFileV1(
                allocator,
                .{
                    .model = model,
                    .package = package,
                    .representation = representation,
                    .raw_text = raw_text,
                    .tokenizer_manifest = tokenizer_manifest,
                    .options = options,
                    .scheduling = identity.scheduling,
                    .bound_plan_input = bound_plan_input,
                    .source_runtime = identity.source_runtime,
                    .scheduler = &runtime.scheduler,
                    .file = .{
                        .directory = directory,
                        .storage_epoch = identity.storage_epoch,
                        .max_set_bytes = max_set_bytes,
                    },
                },
            );
    }

    if (bootstrap_only) {
        const receipt = bootstrap_receipt orelse
            return error.InvalidDurableBootstrap;
        try requireDurableRuntimeZeroV1(&runtime);
        _ = try runtime.scheduler.close();
        runtime_closed = true;
        return emitDurableBootstrapV1(
            writer,
            package,
            representation,
            identity,
            selection_before.kind,
            receipt,
            max_set_bytes,
        );
    }

    var fail_stop_context: u8 = 0;
    const advance =
        try engine.prepared_text_durable_runtime
            .advanceDirectTerminalSourceFileV1(
            allocator,
            .{
                .model = model,
                .runtime = .{
                    .bank = &runtime.bank,
                    .scheduler = &runtime.scheduler,
                },
                .step_sink = identity.step_sink,
                .file = .{
                    .directory = directory,
                    .storage_epoch = identity.storage_epoch,
                    .max_set_bytes = max_set_bytes,
                },
                .fail_stop = .{
                    .context = &fail_stop_context,
                    .invoke_fn = durableFailStopV1,
                },
            },
        );
    runtime_closed = true;
    const view =
        try engine.prepared_text_direct_terminal_output
            .inspectDirectoryV1(
            allocator,
            directory,
            .{ .max_set_bytes = max_set_bytes },
        );
    try verifyDurableTerminalV1(
        package,
        representation,
        identity,
        bootstrap_receipt,
        advance,
        view,
    );
    try emitDurableTerminalV1(
        writer,
        package,
        representation,
        identity,
        selection_before.kind,
        bootstrap_receipt,
        advance,
        view,
        max_set_bytes,
        reveal_output,
    );
}

fn deriveDurableIdentityV1(
    request_id_hex: []const u8,
    package_sha256: [32]u8,
    representation_sha256: [32]u8,
    artifact_license_sha256: [32]u8,
    raw_text_sha256: [32]u8,
) !DurableIdentityV1 {
    if (request_id_hex.len != 64)
        return error.InvalidDurableRequestId;
    for (request_id_hex) |character| {
        if (!std.ascii.isDigit(character) and
            !(character >= 'a' and character <= 'f'))
            return error.InvalidDurableRequestId;
    }
    var request_id: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(
        &request_id,
        request_id_hex,
    ) catch return error.InvalidDurableRequestId;

    var challenge_hash = std.crypto.hash.sha2.Sha256.init(.{});
    challenge_hash.update(durable_challenge_domain);
    challenge_hash.update(&request_id);
    challenge_hash.update(&package_sha256);
    challenge_hash.update(&representation_sha256);
    challenge_hash.update(&artifact_license_sha256);
    challenge_hash.update(&raw_text_sha256);
    var challenge_sha256: [32]u8 = undefined;
    challenge_hash.final(&challenge_sha256);

    const runtime_root = durableDerivedRootV1(
        durable_runtime_identity_domain,
        challenge_sha256,
    );
    const scheduling_root = durableDerivedRootV1(
        durable_scheduling_identity_domain,
        challenge_sha256,
    );
    return .{
        .request_id_sha256 = engine.core.model_contract.sha256(&request_id),
        .challenge_sha256 = challenge_sha256,
        .request_epoch = durableU64V1(runtime_root, 0),
        .storage_epoch = durableU64V1(runtime_root, 8),
        .source_runtime = .{
            .bank_epoch = durableU64V1(runtime_root, 16),
            .scheduler_epoch = durableU64V1(runtime_root, 24),
            .coordinator_id = durableU64V1(
                scheduling_root,
                0,
            ),
        },
        .scheduling = .{
            .tenant_key = durableU64V1(scheduling_root, 8),
            .request_key = durableU64V1(
                scheduling_root,
                16,
            ),
            .request_generation = 1,
            .resource_owner_key = durableU64V1(
                scheduling_root,
                24,
            ),
            .weight = 1,
        },
        .step_sink = .{
            .sink_epoch = durableU64V1(challenge_sha256, 0),
            .reservation_id = durableU64V1(challenge_sha256, 8),
        },
    };
}

fn durableDerivedRootV1(
    domain: []const u8,
    challenge_sha256: [32]u8,
) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(domain);
    hash.update(&challenge_sha256);
    var output: [32]u8 = undefined;
    hash.final(&output);
    return output;
}

fn durableU64V1(
    root: [32]u8,
    offset: usize,
) u64 {
    const value = std.mem.readInt(
        u64,
        root[offset .. offset + 8][0..8],
        .little,
    );
    return if (value == 0) 1 else value;
}

fn classifyDurableSelectionV1(
    directory: std.fs.Dir,
) !DurableSelectionFactsV1 {
    var selector_storage: [engine.core.continuation_checkpoint_file.selector_bytes]u8 =
        undefined;
    const selector =
        engine.core.continuation_checkpoint_file
            .readActiveSelectorReadOnlyV1(
            directory,
            &selector_storage,
        ) catch |err| {
            if (err == error.FileNotFound) {
                return .{
                    .kind = .absent,
                    .selector = null,
                };
            }
            return err;
        };
    if (selector.generation ==
        engine.prepared_text_source_lease
            .source_live_set_generation)
        return .{
            .kind = .source_live,
            .selector = selector,
        };
    if (selector.generation ==
        engine.prepared_text_direct_terminal
            .selected_generation)
        return .{
            .kind = .terminal,
            .selector = selector,
        };
    return error.UnsupportedDurableSelection;
}

fn requireDurableRuntimeZeroV1(
    runtime: *DurableSourceRuntimeV1,
) !void {
    const snapshot = try runtime.bank.snapshot();
    if (!snapshot.used.isZero() or
        snapshot.committed_receipts != 0)
        return error.DurableRuntimeAuthorityLeak;
}

fn durableFailStopV1(_: *anyopaque) noreturn {
    std.process.exit(74);
}

fn verifyDurableTerminalV1(
    package: engine.model_package_manifest.ManifestV1,
    representation: engine.model_package_manifest.PreparedRepresentationV1,
    identity: DurableIdentityV1,
    bootstrap_receipt: ?engine.prepared_text_durable_runtime
        .BootstrapDirectTerminalFileReceiptV1,
    receipt: engine.prepared_text_durable_runtime
        .AdvanceDirectTerminalSourceFileReceiptV1,
    view: engine.prepared_text_direct_terminal_output.ViewV1,
) !void {
    try engine.prepared_text_direct_terminal_output
        .validateViewV1(view);
    if (!receipt.ownership_closed or
        receipt.input_generation !=
            engine.prepared_text_source_lease
                .source_live_set_generation or
        receipt.input_sequence != view.publication_next_sequence or
        receipt.output_generation != view.generation or
        receipt.output_sequence !=
            view.publication_next_sequence or
        receipt.output_token != view.output_token or
        !std.mem.eql(
            u8,
            &receipt.checkpoint_sha256,
            &view.selected_set_sha256,
        ) or
        !std.mem.eql(
            u8,
            &receipt.checkpoint_selector_sha256,
            &view.selected_selector_sha256,
        ) or
        !std.mem.eql(
            u8,
            &receipt.terminal_source_contract_sha256,
            &view.terminal_source_contract_sha256,
        ) or
        !std.mem.eql(
            u8,
            &receipt.terminal_semantic_sha256,
            &view.terminal_semantic_sha256,
        ) or
        view.request_epoch != identity.request_epoch or
        !std.mem.eql(
            u8,
            &view.challenge_sha256,
            &identity.challenge_sha256,
        ) or
        !std.mem.eql(
            u8,
            &view.package_sha256,
            &package.package_sha256,
        ) or
        !std.mem.eql(
            u8,
            &view.representation_sha256,
            &representation.representation_sha256,
        ) or
        (bootstrap_receipt == null and
            receipt.disposition != .already_selected))
        return error.InvalidDurableCommittedOutput;
    if (bootstrap_receipt) |bootstrap| {
        if (bootstrap.generation != receipt.input_generation or
            bootstrap.request_epoch != view.request_epoch or
            bootstrap.publication_next_sequence !=
                receipt.input_sequence or
            !std.mem.eql(
                u8,
                &bootstrap.checkpoint_sha256,
                &view.predecessor_set_sha256,
            ) or
            !std.mem.eql(
                u8,
                &bootstrap.selector_sha256,
                &view.predecessor_selector_sha256,
            ) or
            !std.mem.eql(
                u8,
                &bootstrap.terminal_source_contract_sha256,
                &view.terminal_source_contract_sha256,
            ) or
            !std.mem.eql(
                u8,
                &bootstrap.input_archive_sha256,
                &view.input_archive_sha256,
            ))
            return error.InvalidDurableCommittedOutput;
    }
}

fn emitDurableBootstrapV1(
    writer: *std.Io.Writer,
    package: engine.model_package_manifest.ManifestV1,
    representation: engine.model_package_manifest.PreparedRepresentationV1,
    identity: DurableIdentityV1,
    selection_before: DurableSelectionV1,
    receipt: engine.prepared_text_durable_runtime
        .BootstrapDirectTerminalFileReceiptV1,
    max_set_bytes: usize,
) !void {
    const request_id_hex = std.fmt.bytesToHex(
        identity.request_id_sha256,
        .lower,
    );
    const package_hex = std.fmt.bytesToHex(
        package.package_sha256,
        .lower,
    );
    const representation_hex = std.fmt.bytesToHex(
        representation.representation_sha256,
        .lower,
    );
    const challenge_hex = std.fmt.bytesToHex(
        identity.challenge_sha256,
        .lower,
    );
    const checkpoint_hex = std.fmt.bytesToHex(
        receipt.checkpoint_sha256,
        .lower,
    );
    const selector_hex = std.fmt.bytesToHex(
        receipt.selector_sha256,
        .lower,
    );
    const contract_hex = std.fmt.bytesToHex(
        receipt.terminal_source_contract_sha256,
        .lower,
    );
    const input_hex = std.fmt.bytesToHex(
        receipt.input_archive_sha256,
        .lower,
    );
    try writer.print(
        "{{\"schema\":\"glacier.prepared-text-durable-run/v1\"," ++
            "\"operation\":\"bootstrap\"," ++
            "\"profile\":\"ordinary-package-direct-terminal-v1\"," ++
            "\"route\":\"direct-terminal\"," ++
            "\"selection_before\":\"{s}\"," ++
            "\"bootstrap_disposition\":\"{s}\"," ++
            "\"durable_checkpoint\":true," ++
            "\"fresh_process_boundary_ready\":true," ++
            "\"checked_committed_output\":false," ++
            "\"terminal\":false,\"ownership_closed\":true," ++
            "\"request_epoch\":{d},\"generation\":{d}," ++
            "\"publication_next_sequence\":{d}," ++
            "\"max_set_bytes\":{d}," ++
            "\"request_id_sha256\":\"{s}\"," ++
            "\"package_sha256\":\"{s}\"," ++
            "\"representation_sha256\":\"{s}\"," ++
            "\"challenge_sha256\":\"{s}\"," ++
            "\"checkpoint_set_sha256\":\"{s}\"," ++
            "\"checkpoint_selector_sha256\":\"{s}\"," ++
            "\"terminal_source_contract_sha256\":\"{s}\"," ++
            "\"input_archive_sha256\":\"{s}\"}}\n",
        .{
            durableSelectionNameV1(selection_before),
            @tagName(receipt.disposition),
            receipt.request_epoch,
            receipt.generation,
            receipt.publication_next_sequence,
            max_set_bytes,
            &request_id_hex,
            &package_hex,
            &representation_hex,
            &challenge_hex,
            &checkpoint_hex,
            &selector_hex,
            &contract_hex,
            &input_hex,
        },
    );
}

fn emitDurableTerminalV1(
    writer: *std.Io.Writer,
    package: engine.model_package_manifest.ManifestV1,
    representation: engine.model_package_manifest.PreparedRepresentationV1,
    identity: DurableIdentityV1,
    selection_before: DurableSelectionV1,
    bootstrap_receipt: ?engine.prepared_text_durable_runtime
        .BootstrapDirectTerminalFileReceiptV1,
    receipt: engine.prepared_text_durable_runtime
        .AdvanceDirectTerminalSourceFileReceiptV1,
    view: engine.prepared_text_direct_terminal_output.ViewV1,
    max_set_bytes: usize,
    reveal_output: bool,
) !void {
    const request_id_hex = std.fmt.bytesToHex(
        identity.request_id_sha256,
        .lower,
    );
    const package_hex = std.fmt.bytesToHex(
        package.package_sha256,
        .lower,
    );
    const representation_hex = std.fmt.bytesToHex(
        representation.representation_sha256,
        .lower,
    );
    const input_hex = std.fmt.bytesToHex(
        view.input_archive_sha256,
        .lower,
    );
    const contract_hex = std.fmt.bytesToHex(
        view.terminal_source_contract_sha256,
        .lower,
    );
    const semantic_hex = std.fmt.bytesToHex(
        view.terminal_semantic_sha256,
        .lower,
    );
    const output_hex = std.fmt.bytesToHex(
        view.terminal_output_sha256,
        .lower,
    );
    const state_hex = std.fmt.bytesToHex(
        view.terminal_state_sha256,
        .lower,
    );
    const selected_selector_hex = std.fmt.bytesToHex(
        view.selected_selector_sha256,
        .lower,
    );
    const selected_set_hex = std.fmt.bytesToHex(
        view.selected_set_sha256,
        .lower,
    );
    const predecessor_selector_hex = std.fmt.bytesToHex(
        view.predecessor_selector_sha256,
        .lower,
    );
    const predecessor_set_hex = std.fmt.bytesToHex(
        view.predecessor_set_sha256,
        .lower,
    );
    const challenge_hex = std.fmt.bytesToHex(
        view.challenge_sha256,
        .lower,
    );
    const view_hex = std.fmt.bytesToHex(
        view.view_sha256,
        .lower,
    );
    const preexisting_generation_continuation_performed =
        if (bootstrap_receipt) |bootstrap|
            bootstrap.disposition != .created and
                receipt.disposition == .advanced
        else
            false;
    try writer.print(
        "{{\"schema\":\"glacier.prepared-text-durable-run/v1\"," ++
            "\"operation\":\"advance\"," ++
            "\"profile\":\"ordinary-package-direct-terminal-v1\"," ++
            "\"route\":\"direct-terminal\"," ++
            "\"selection_before\":\"{s}\"," ++
            "\"disposition\":\"{s}\",\"bootstrap_disposition\":",
        .{
            durableSelectionNameV1(selection_before),
            @tagName(receipt.disposition),
        },
    );
    if (bootstrap_receipt) |bootstrap| {
        try writer.print(
            "\"{s}\"",
            .{@tagName(bootstrap.disposition)},
        );
    } else {
        try writer.writeAll("null");
    }
    try writer.print(
        ",\"durable_checkpoint\":true," ++
            "\"fresh_process_continuation_supported\":true," ++
            "\"preexisting_generation_continuation_performed\":{s}," ++
            "\"checked_committed_output\":true," ++
            "\"terminal\":true,\"ownership_closed\":true," ++
            "\"model_execution_performed\":{s}," ++
            "\"output_disclosed\":{s}," ++
            "\"output_encoding\":\"token-ids\"," ++
            "\"request_epoch\":{d},\"generation\":{d}," ++
            "\"publication_next_sequence\":{d}," ++
            "\"acknowledgement_count\":0,\"token_count\":1," ++
            "\"max_set_bytes\":{d}," ++
            "\"request_id_sha256\":\"{s}\"," ++
            "\"package_sha256\":\"{s}\"," ++
            "\"representation_sha256\":\"{s}\"," ++
            "\"input_archive_sha256\":\"{s}\"," ++
            "\"terminal_source_contract_sha256\":\"{s}\"," ++
            "\"terminal_semantic_sha256\":\"{s}\"," ++
            "\"terminal_output_sha256\":\"{s}\"," ++
            "\"terminal_state_sha256\":\"{s}\"," ++
            "\"checkpoint_selector_sha256\":\"{s}\"," ++
            "\"checkpoint_set_sha256\":\"{s}\"," ++
            "\"predecessor_selector_sha256\":\"{s}\"," ++
            "\"predecessor_set_sha256\":\"{s}\"," ++
            "\"challenge_sha256\":\"{s}\"," ++
            "\"view_sha256\":\"{s}\",\"output_tokens\":",
        .{
            booleanNameV1(
                preexisting_generation_continuation_performed,
            ),
            booleanNameV1(receipt.disposition == .advanced),
            booleanNameV1(reveal_output),
            view.request_epoch,
            view.generation,
            view.publication_next_sequence,
            max_set_bytes,
            &request_id_hex,
            &package_hex,
            &representation_hex,
            &input_hex,
            &contract_hex,
            &semantic_hex,
            &output_hex,
            &state_hex,
            &selected_selector_hex,
            &selected_set_hex,
            &predecessor_selector_hex,
            &predecessor_set_hex,
            &challenge_hex,
            &view_hex,
        },
    );
    if (reveal_output) {
        try writer.print("[{d}]}}\n", .{view.output_token});
    } else {
        try writer.writeAll("null}\n");
    }
}

fn durableSelectionNameV1(
    selection: DurableSelectionV1,
) []const u8 {
    return switch (selection) {
        .absent => "absent",
        .source_live => "source-live",
        .terminal => "terminal",
    };
}

fn booleanNameV1(value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn usage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        "usage: glacier text-run <model.glrt> " ++
            "(--text <utf8>|--text-file <path>) " ++
            "--license <license-file> [--package <model.glpkg>] " ++
            "[--n 1..64] " ++
            "[--durable-dir <absolute-existing-directory> " ++
            "--request-id <64-lowercase-hex> --n 1 " ++
            "[--bootstrap-only] [--reveal-output] " ++
            "[--max-set-bytes 1..67108864]]\n",
    );
}
