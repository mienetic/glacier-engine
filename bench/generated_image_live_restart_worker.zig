//! Fresh-process terminal-latent decode and generated-image publication.

const std = @import("std");
const core = @import("core");
const model = core.model_contract;
const media = core.media_contract;
const resource_bank = core.resource_bank;
const stateful = core.stateful_model_adapter;
const continuation = core.stateful_model_continuation;
const latent = core.latent_step_adapter;
const generated = core.generated_image_publication;

const checkpoint_name = "stateful-model.checkpoint";
const publication_name =
    "stateful-model.state-publication";
const payload_name = "stateful-model.state-payload";
const source_pid_name = "stateful-model.source-pid";
const restore_bank_epoch: u64 = 82_001;

const RuntimeStorage = struct {
    slots: [12]resource_bank.Slot =
        [_]resource_bank.Slot{.{}} ** 12,
    roots: [12]resource_bank.LeaseTreeRootSlot =
        [_]resource_bank.LeaseTreeRootSlot{.{}} ** 12,
    nodes: [24]resource_bank.LeaseNodeSlot =
        [_]resource_bank.LeaseNodeSlot{.{}} ** 24,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const arguments = try std.process.argsAlloc(
        allocator,
    );
    defer std.process.argsFree(allocator, arguments);
    if (arguments.len != 3 or
        !std.mem.eql(u8, arguments[1], "resume"))
        return error.InvalidArguments;
    var directory = try std.fs.openDirAbsolute(
        arguments[2],
        .{},
    );
    defer directory.close();
    try resumeAndPublishV1(&directory);
}

fn resumeAndPublishV1(
    directory: *std.fs.Dir,
) !void {
    var pid_storage: [32]u8 = undefined;
    const pid_wire = try readBoundedV1(
        directory,
        source_pid_name,
        &pid_storage,
    );
    const source_pid = try std.fmt.parseInt(
        i32,
        pid_wire,
        10,
    );
    const target_pid = std.c.getpid();
    if (source_pid == target_pid)
        return error.ProcessDidNotRestart;
    var checkpoint_storage: [continuation.checkpoint_bytes]u8 = undefined;
    const checkpoint_wire = try readExactV1(
        directory,
        checkpoint_name,
        &checkpoint_storage,
    );
    const checkpoint =
        try continuation.decodeCheckpointV1(
            checkpoint_wire,
        );
    var publication_storage: [stateful.state_publication_bytes]u8 = undefined;
    const publication_wire = try readExactV1(
        directory,
        publication_name,
        &publication_storage,
    );
    var payload_storage: [generated.reference_terminal_latent.len]u8 =
        undefined;
    const payload = try readExactV1(
        directory,
        payload_name,
        &payload_storage,
    );
    var storage: RuntimeStorage = .{};
    var bank =
        try resource_bank.Bank.initWithLeaseTreeStorage(
            &storage.slots,
            &storage.roots,
            &storage.nodes,
            .{},
            restore_bank_epoch,
        );
    var resumed: continuation.ResumeSession = .{};
    try resumed.prepareV1(
        &bank,
        checkpoint_wire,
        publication_wire,
    );
    const reserved = try bank.snapshotV3();
    if (reserved.reserved_unmaterialized_allocations !=
        1 or
        reserved.live_allocations != 0)
        return error.ChargeBeforeMaterializeMissing;
    var restored_state: [generated.reference_terminal_latent.len]u8 =
        undefined;
    try resumed.commitMaterializedV1(
        payload,
        &restored_state,
    );
    const fixture = try latent.makeReferenceFixtureV1();
    const terminal_plan =
        try latent.makeReferencePlanV1(
            fixture.manifest,
            resumed.model_publication,
            resumed.state_publication,
            checkpoint.last_plan_sha256,
        );
    var latent_context: u8 = 1;
    const latent_adapter =
        try latent.referenceAdapterV1(
            fixture.manifest,
            &latent_context,
        );
    var terminal: latent.Session = .{};
    try terminal.initV1(
        &bank,
        83_001,
        &resumed.model_publication,
        &resumed.state_publication,
        fixture.manifest,
        terminal_plan,
        latent_adapter,
    );
    var terminal_candidate_output: [generated.reference_terminal_latent.len]u8 =
        undefined;
    var terminal_candidate_state: [generated.reference_terminal_latent.len]u8 =
        undefined;
    var terminal_output: [generated.reference_terminal_latent.len]u8 =
        undefined;
    var terminal_state: [generated.reference_terminal_latent.len]u8 =
        undefined;
    _ = try terminal.prepareV1(
        &latent.reference_weights,
        &latent.reference_conditioning,
        &restored_state,
        &terminal_candidate_output,
        &terminal_candidate_state,
        &terminal_output,
        &terminal_state,
    );
    const terminal_result =
        try terminal.commitV1();
    if (!std.mem.eql(
        u8,
        &terminal_output,
        &generated.reference_terminal_latent,
    ) or
        resumed.state_publication.current_step !=
            resumed.state_publication.total_steps)
        return error.InvalidTerminalLatent;
    const terminal_state_publication =
        resumed.state_publication;
    try resumed.closeAndRelease();
    try terminal.closeAndRelease();
    const after_terminal = try bank.snapshotV3();
    if (!after_terminal.used.isZero())
        return error.TerminalOwnershipLeak;

    var decoder_context: u8 = 1;
    const decoder = generated.referenceDecoderV1(
        &decoder_context,
    );
    const tenant_scope_sha256 =
        model.sha256("generated image tenant");
    const metadata_policy_sha256 =
        model.sha256("generated image metadata policy");
    const source_provenance_sha256 =
        generated.sourceProvenanceRootV1(
            fixture.manifest,
            checkpoint,
            terminal_plan,
            terminal_result,
            terminal_state_publication,
            model.sha256(
                &generated.reference_decoder_payload,
            ),
            decoder.implementation_sha256,
            tenant_scope_sha256,
            metadata_policy_sha256,
            terminal_result.challenge_sha256,
        );
    const media_object: media.MediaObjectV1 = .{
        .kind = .image,
        .semantic_abi = generated.raw_image_semantic_abi,
        .byte_length = generated.reference_pixels.len,
        .container_id = generated.raw_container_id,
        .codec_id = generated.interleaved_u8_codec_id,
        .axes = .{ 2, 2, 1 },
        .time_base = .{
            .numerator = 0,
            .denominator = 1,
        },
        .tenant_scope_sha256 = tenant_scope_sha256,
        .content_sha256 = model.sha256(&generated.reference_pixels),
        .metadata_policy_sha256 = metadata_policy_sha256,
        .provenance_sha256 = source_provenance_sha256,
    };
    var media_wire: [media.descriptor_bytes]u8 = undefined;
    _ = try media.encodeMediaObjectV1(
        media_object,
        &media_wire,
    );
    const media_root =
        try media.mediaObjectSha256V1(&media_wire);
    var media_publication =
        try media.initializePublicationStateV1(
            terminal_result.request_epoch,
            1,
            .{ .numerator = 1, .denominator = 1 },
            media_root,
            model.sha256(
                "generated image publication genesis",
            ),
        );
    const image_plan =
        try generated.makeGeneratedImagePlanV1(
            fixture.manifest,
            checkpoint,
            terminal_plan,
            terminal_result,
            terminal_state_publication,
            media_object,
            &generated.reference_decoder_payload,
            decoder,
            media_publication,
            model.sha256(
                "generated image plan genesis",
            ),
            model.sha256(
                "generated image result genesis",
            ),
        );
    var image_session: generated.Session = .{};
    try image_session.initV1(
        &bank,
        84_001,
        &media_publication,
        fixture.manifest,
        checkpoint,
        terminal_plan,
        terminal_result,
        terminal_state_publication,
        media_object,
        image_plan,
        &generated.reference_decoder_payload,
        decoder,
    );
    var candidate_output: [generated.reference_pixels.len]u8 = undefined;
    var candidate_provenance: [generated.provenance_bytes]u8 = undefined;
    var candidate_result: [generated.result_bytes]u8 = undefined;
    var visible_output =
        [_]u8{0xa5} **
        generated.reference_pixels.len;
    var visible_provenance =
        [_]u8{0xa5} **
        generated.provenance_bytes;
    var visible_result =
        [_]u8{0xa5} ** generated.result_bytes;
    _ = try image_session.prepareV1(
        &terminal_output,
        &candidate_output,
        &candidate_provenance,
        &candidate_result,
        &visible_output,
        &visible_provenance,
        &visible_result,
    );
    if (!std.mem.allEqual(
        u8,
        &visible_output,
        0xa5,
    ) or
        media_publication.visible_chunks != 0)
        return error.VisibilityAdvancedBeforeCommit;
    try image_session.abortV1();
    if (!std.mem.allEqual(
        u8,
        &candidate_output,
        0,
    ) or
        !std.mem.allEqual(
            u8,
            &visible_output,
            0xa5,
        ) or
        media_publication.visible_chunks != 0)
        return error.CancelledImageBecameVisible;
    _ = try image_session.prepareV1(
        &terminal_output,
        &candidate_output,
        &candidate_provenance,
        &candidate_result,
        &visible_output,
        &visible_provenance,
        &visible_result,
    );
    const image_result =
        try image_session.commitV1();
    const image_provenance =
        try generated.decodeGeneratedImageProvenanceV1(
            &visible_provenance,
        );
    const decoded_result =
        try generated.decodeGeneratedImageResultV1(
            &visible_result,
        );
    try generated.validateGeneratedImageProvenanceBindingsV1(
        image_plan,
        image_provenance,
        media_object,
    );
    if (!std.mem.eql(
        u8,
        &visible_output,
        &generated.reference_pixels,
    ) or
        !std.meta.eql(image_result, decoded_result) or
        media_publication.visible_chunks != 1 or
        media_publication.visible_units != 1)
        return error.InvalidGeneratedImagePublication;
    try image_session.closeAndRelease();
    const final = try bank.snapshotV3();
    if (!final.used.isZero() or
        final.live_allocations != 0 or
        final.active_lease_trees != 0)
        return error.TargetOwnershipLeak;
    const output_hex = std.fmt.bytesToHex(
        image_result.output_sha256,
        .lower,
    );
    const provenance_hex = std.fmt.bytesToHex(
        image_provenance.provenance_sha256,
        .lower,
    );
    const result_hex = std.fmt.bytesToHex(
        image_result.result_sha256,
        .lower,
    );
    var stdout_buffer: [2048]u8 = undefined;
    var stdout_writer =
        std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"schema\":\"glacier.generated-image-live-restart/demo-v1\"," ++
            "\"phase\":\"publish\",\"source_pid\":{d}," ++
            "\"target_pid\":{d},\"process_restart\":true," ++
            "\"restored_step\":1,\"terminal_step\":2," ++
            "\"terminal_latent\":\"6,12,18,24\"," ++
            "\"generated_pixels\":\"24,36,36,24\"," ++
            "\"width\":2,\"height\":2,\"channels\":1," ++
            "\"pixel_bytes\":4,\"visible_images\":1," ++
            "\"duplicate_visible_images\":0," ++
            "\"cancelled_publications\":1," ++
            "\"cancellation_preserved_visibility\":true," ++
            "\"atomic_visibility\":true," ++
            "\"provenance_bound\":true," ++
            "\"terminal_latent_bound\":true," ++
            "\"charge_before_materialize\":true," ++
            "\"final_bank_host_bytes\":0," ++
            "\"final_live_allocations\":0," ++
            "\"final_active_lease_trees\":0," ++
            "\"filesystem_authority\":true," ++
            "\"network_authority\":false," ++
            "\"device_authority\":false," ++
            "\"display_authority\":false," ++
            "\"production_model\":false," ++
            "\"output_sha256\":\"{s}\"," ++
            "\"provenance_sha256\":\"{s}\"," ++
            "\"result_sha256\":\"{s}\"," ++
            "\"verified\":true}}\n",
        .{
            source_pid,
            target_pid,
            &output_hex,
            &provenance_hex,
            &result_hex,
        },
    );
    try stdout.flush();
}

fn readExactV1(
    directory: *std.fs.Dir,
    name: []const u8,
    storage: []u8,
) ![]const u8 {
    const bytes = try readBoundedV1(
        directory,
        name,
        storage,
    );
    if (bytes.len != storage.len)
        return error.InvalidFileLength;
    return bytes;
}

fn readBoundedV1(
    directory: *std.fs.Dir,
    name: []const u8,
    storage: []u8,
) ![]const u8 {
    var file = try directory.openFile(name, .{});
    defer file.close();
    const stat = try file.stat();
    const length = std.math.cast(
        usize,
        stat.size,
    ) orelse return error.InvalidFileLength;
    if (length == 0 or length > storage.len)
        return error.InvalidFileLength;
    const read = try file.readAll(storage[0..length]);
    if (read != length)
        return error.ShortRead;
    return storage[0..length];
}
