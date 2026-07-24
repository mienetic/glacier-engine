const std = @import("std");
const checkpoint_file = @import("continuation_checkpoint_file.zig");

pub const Digest = [32]u8;

pub const manifest_abi: u64 = 1;
pub const entry_abi: u64 = 1;
pub const entry_table_abi: u64 = 1;
pub const payload_pack_abi: u64 = 1;
pub const manifest_body_bytes: usize = 512;
pub const manifest_bytes: usize = manifest_body_bytes + 32;
pub const entry_body_bytes: usize = 512;
pub const entry_bytes: usize = entry_body_bytes + 32;
pub const archive_object_count: usize = 3;
pub const max_outputs_per_modality: usize = 4;
pub const max_entries: usize = max_outputs_per_modality * 3;

pub const manifest_object_ordinal: u64 = 1;
pub const entry_table_object_ordinal: u64 = 2;
pub const payload_pack_object_ordinal: u64 = 3;

const manifest_magic = "GLGMREG1".*;
const entry_magic = "GLGMOUT1".*;
const manifest_domain =
    "glacier.generated-media-output-registry-manifest.v1";
const entry_domain =
    "glacier.generated-media-output-registry-entry.v1";
const entry_table_domain =
    "glacier.generated-media-output-registry-entry-table.v1";
const payload_domain =
    "glacier.generated-media-output-registry-payload.v1";
const payload_pack_domain =
    "glacier.generated-media-output-registry-payload-pack.v1";
const reference_identity_domain =
    "glacier.generated-media-output-registry-reference-identity.v1";

pub const Error = checkpoint_file.Error || error{
    InvalidManifest,
    InvalidManifestRoot,
    InvalidEntry,
    InvalidEntryRoot,
    InvalidRegistry,
    InvalidPayload,
    InvalidBinding,
    InvalidLineage,
    CapacityExceeded,
    UnsafeDestination,
    ArithmeticOverflow,
    BufferTooSmall,
};

pub const ModalityV1 = enum(u64) {
    image = 1,
    audio = 2,
    video = 3,
};

pub const OutputInputV1 = struct {
    modality: ModalityV1,
    ordinal: u64,
    unit_start: u64,
    unit_count: u64,
    timeline_start: u64,
    timeline_end: u64,
    source_bytes: u64,
    encoding_abi: u64,
    encoded_payload: []const u8,
    artifact_sha256: Digest,
    provenance_sha256: Digest,
    result_sha256: Digest,
    source_output_sha256: Digest,
    media_object_sha256: Digest,
    state_after_sha256: Digest,
    completion_required: bool,
    completed: bool,
    completion_sha256: Digest,
    encoder_implementation_sha256: Digest,
    format_sha256: Digest,
    previous_entry_sha256: Digest,
};

pub const GeneratedMediaOutputEntryV1 = struct {
    modality: ModalityV1,
    ordinal: u64,
    unit_start: u64,
    unit_count: u64,
    unit_end: u64,
    timeline_start: u64,
    timeline_end: u64,
    source_bytes: u64,
    encoding_abi: u64,
    payload_offset: u64,
    payload_bytes: u64,
    completion_required: bool,
    completed: bool,
    artifact_sha256: Digest,
    provenance_sha256: Digest,
    result_sha256: Digest,
    source_output_sha256: Digest,
    media_object_sha256: Digest,
    state_after_sha256: Digest,
    completion_sha256: Digest,
    encoder_implementation_sha256: Digest,
    format_sha256: Digest,
    previous_entry_sha256: Digest,
    payload_sha256: Digest,
    entry_sha256: Digest,
};

pub const GeneratedMediaOutputRegistryManifestV1 = struct {
    request_epoch: u64,
    generation: u64,
    publication_sequence: u64,
    entry_count: u64,
    entry_table_bytes: u64,
    payload_pack_bytes: u64,
    total_source_bytes: u64,
    total_encoded_bytes: u64,
    total_units: u64,
    image_count: u64,
    audio_count: u64,
    video_count: u64,
    image_units: u64,
    audio_units: u64,
    video_units: u64,
    image_encoded_bytes: u64,
    audio_encoded_bytes: u64,
    video_encoded_bytes: u64,
    image_unit_end: u64,
    audio_unit_end: u64,
    video_unit_end: u64,
    image_timeline_end: u64,
    audio_timeline_end: u64,
    video_timeline_end: u64,
    modality_mask: u64,
    entry_table_sha256: Digest,
    payload_pack_sha256: Digest,
    generation_plan_sha256: Digest,
    tenant_scope_sha256: Digest,
    metadata_policy_sha256: Digest,
    challenge_sha256: Digest,
    previous_manifest_sha256: Digest,
    previous_archive_sha256: Digest,
    manifest_sha256: Digest,
};

pub const PreviousGenerationV1 = struct {
    archive_bytes: []const u8,
};

pub const RegistryInputV1 = struct {
    previous: ?PreviousGenerationV1,
    request_epoch: u64,
    generation: u64,
    publication_sequence: u64,
    generation_plan_sha256: Digest,
    tenant_scope_sha256: Digest,
    metadata_policy_sha256: Digest,
    challenge_sha256: Digest,
    outputs: []const OutputInputV1,
};

pub const PreparedArchiveV1 = struct {
    set: checkpoint_file.PreparedSetV1,
    manifest: GeneratedMediaOutputRegistryManifestV1,
};

pub const DecodedArchiveV1 = struct {
    archive_bytes: []const u8,
    archive_sha256: Digest,
    manifest: GeneratedMediaOutputRegistryManifestV1,
    entry_table: []const u8,
    payload_pack: []const u8,

    pub fn previous(self: DecodedArchiveV1) PreviousGenerationV1 {
        return .{ .archive_bytes = self.archive_bytes };
    }

    fn validatedView(
        self: DecodedArchiveV1,
    ) Error!DecodedArchiveV1 {
        const canonical = try decodeArchiveInternalV1(
            self.archive_bytes,
            null,
            true,
        );
        if (!digestEqual(self.archive_sha256, canonical.archive_sha256) or
            !std.meta.eql(self.manifest, canonical.manifest) or
            !std.mem.eql(u8, self.entry_table, canonical.entry_table) or
            !std.mem.eql(u8, self.payload_pack, canonical.payload_pack))
            return Error.InvalidRegistry;
        return canonical;
    }

    fn entryAt(
        self: DecodedArchiveV1,
        index: usize,
    ) Error!GeneratedMediaOutputEntryV1 {
        const count = std.math.cast(
            usize,
            self.manifest.entry_count,
        ) orelse return Error.InvalidRegistry;
        if (count == 0 or count > max_entries)
            return Error.InvalidRegistry;
        const expected_table_bytes = std.math.mul(
            usize,
            count,
            entry_bytes,
        ) catch return Error.InvalidRegistry;
        const manifest_table_bytes = std.math.cast(
            usize,
            self.manifest.entry_table_bytes,
        ) orelse return Error.InvalidRegistry;
        if (manifest_table_bytes != expected_table_bytes or
            self.entry_table.len != expected_table_bytes)
            return Error.InvalidRegistry;
        if (index >= count) return Error.InvalidEntry;
        const start = std.math.mul(
            usize,
            index,
            entry_bytes,
        ) catch return Error.InvalidRegistry;
        const end = std.math.add(
            usize,
            start,
            entry_bytes,
        ) catch return Error.InvalidRegistry;
        if (end > self.entry_table.len) return Error.InvalidRegistry;
        return decodeEntryV1(self.entry_table[start..end]);
    }

    pub fn entry(
        self: DecodedArchiveV1,
        index: usize,
    ) Error!GeneratedMediaOutputEntryV1 {
        const canonical = try self.validatedView();
        return canonical.entryAt(index);
    }

    pub fn payload(
        self: DecodedArchiveV1,
        index: usize,
    ) Error![]const u8 {
        const canonical = try self.validatedView();
        const value = try canonical.entryAt(index);
        const start = std.math.cast(
            usize,
            value.payload_offset,
        ) orelse return Error.InvalidPayload;
        const length = std.math.cast(
            usize,
            value.payload_bytes,
        ) orelse return Error.InvalidPayload;
        const end = std.math.add(
            usize,
            start,
            length,
        ) catch return Error.InvalidPayload;
        if (end > canonical.payload_pack.len) return Error.InvalidPayload;
        const bytes = canonical.payload_pack[start..end];
        const expected_payload = payloadRootV1(
            value.modality,
            value.ordinal,
            value.encoding_abi,
            value.source_output_sha256,
            bytes,
        );
        if (!digestEqual(expected_payload, value.payload_sha256))
            return Error.InvalidPayload;
        return bytes;
    }

    pub fn terminal(
        self: DecodedArchiveV1,
        modality: ModalityV1,
    ) Error!GeneratedMediaOutputEntryV1 {
        const canonical = try self.validatedView();
        var found: ?GeneratedMediaOutputEntryV1 = null;
        const count = std.math.cast(
            usize,
            canonical.manifest.entry_count,
        ) orelse return Error.InvalidRegistry;
        for (0..count) |index| {
            const value = try canonical.entryAt(index);
            if (value.modality == modality) found = value;
        }
        return found orelse Error.InvalidEntry;
    }
};

pub const ReferenceArchivesV1 = struct {
    first: PreparedArchiveV1,
    first_decoded: DecodedArchiveV1,
    second: PreparedArchiveV1,
    second_decoded: DecodedArchiveV1,
};

const ModalitySummaryV1 = struct {
    count: u64 = 0,
    units: u64 = 0,
    encoded_bytes: u64 = 0,
    unit_end: u64 = 0,
    timeline_end: u64 = 0,
};

const RegistrySummaryV1 = struct {
    entry_count: u64 = 0,
    total_source_bytes: u64 = 0,
    total_encoded_bytes: u64 = 0,
    total_units: u64 = 0,
    modality_mask: u64 = 0,
    image: ModalitySummaryV1 = .{},
    audio: ModalitySummaryV1 = .{},
    video: ModalitySummaryV1 = .{},
    entry_table_sha256: Digest = [_]u8{0} ** 32,
    payload_pack_sha256: Digest = [_]u8{0} ** 32,

    fn modality(
        self: *RegistrySummaryV1,
        value: ModalityV1,
    ) *ModalitySummaryV1 {
        return switch (value) {
            .image => &self.image,
            .audio => &self.audio,
            .video => &self.video,
        };
    }
};

const TerminalSetV1 = struct {
    image: ?GeneratedMediaOutputEntryV1 = null,
    audio: ?GeneratedMediaOutputEntryV1 = null,
    video: ?GeneratedMediaOutputEntryV1 = null,

    fn get(
        self: TerminalSetV1,
        modality: ModalityV1,
    ) ?GeneratedMediaOutputEntryV1 {
        return switch (modality) {
            .image => self.image,
            .audio => self.audio,
            .video => self.video,
        };
    }

    fn set(
        self: *TerminalSetV1,
        modality: ModalityV1,
        value: GeneratedMediaOutputEntryV1,
    ) void {
        switch (modality) {
            .image => self.image = value,
            .audio => self.audio = value,
            .video => self.video = value,
        }
    }
};

pub fn requiredScratchBytesV1(
    outputs: []const OutputInputV1,
) Error!usize {
    if (outputs.len == 0) return Error.InvalidRegistry;
    if (outputs.len > max_entries) return Error.CapacityExceeded;
    const table_bytes = std.math.mul(
        usize,
        outputs.len,
        entry_bytes,
    ) catch return Error.ArithmeticOverflow;
    var total = table_bytes;
    for (outputs) |output| {
        total = std.math.add(
            usize,
            total,
            output.encoded_payload.len,
        ) catch return Error.ArithmeticOverflow;
    }
    return total;
}

pub fn encodeArchiveV1(
    input: RegistryInputV1,
    scratch: []u8,
    destination: []u8,
) Error!PreparedArchiveV1 {
    try validateInputEnvelopeV1(input);
    const required_scratch = try requiredScratchBytesV1(input.outputs);
    if (scratch.len < required_scratch) return Error.BufferTooSmall;
    const scratch_output = scratch[0..required_scratch];
    const output_input_bytes = std.mem.sliceAsBytes(input.outputs);
    if (slicesOverlap(scratch_output, destination) or
        slicesOverlap(scratch_output, output_input_bytes) or
        slicesOverlap(destination, output_input_bytes))
        return Error.UnsafeDestination;
    for (input.outputs) |output| {
        if (slicesOverlap(scratch_output, output.encoded_payload) or
            slicesOverlap(destination, output.encoded_payload))
            return Error.UnsafeDestination;
    }
    if (input.previous) |previous| {
        if (slicesOverlap(scratch_output, previous.archive_bytes) or
            slicesOverlap(destination, previous.archive_bytes))
            return Error.UnsafeDestination;
    }

    const previous = if (input.previous) |value|
        try validatePreviousGenerationV1(value)
    else
        null;
    try validateInputLineageV1(input, previous);

    const table_length = std.math.mul(
        usize,
        input.outputs.len,
        entry_bytes,
    ) catch return Error.ArithmeticOverflow;
    const table = scratch_output[0..table_length];
    const pack = scratch_output[table_length..];
    const summary = try encodeEntriesV1(
        input.outputs,
        table,
        pack,
        previous,
    );
    const manifest = try makeManifestV1(input, summary, previous);
    var manifest_storage: [manifest_bytes]u8 = undefined;
    const manifest_wire = try encodeManifestV1(
        manifest,
        &manifest_storage,
    );
    const objects = [_]checkpoint_file.ObjectInputV1{
        .{
            .kind = .extension,
            .ordinal = manifest_object_ordinal,
            .abi_version = manifest_abi,
            .bytes = manifest_wire,
        },
        .{
            .kind = .extension,
            .ordinal = entry_table_object_ordinal,
            .abi_version = entry_table_abi,
            .bytes = table,
        },
        .{
            .kind = .extension,
            .ordinal = payload_pack_object_ordinal,
            .abi_version = payload_pack_abi,
            .bytes = pack,
        },
    };
    const parent = if (previous) |value|
        value.archive_sha256
    else
        [_]u8{0} ** 32;
    const publication_next_sequence = try checkedAdd(
        input.publication_sequence,
        1,
    );
    const set = try checkpoint_file.encodeSetV1(
        .{
            .generation = input.generation,
            .request_epoch = input.request_epoch,
            .publication_next_sequence = publication_next_sequence,
            .parent_checkpoint_sha256 = parent,
            .challenge_sha256 = input.challenge_sha256,
        },
        &objects,
        destination,
    );
    return .{ .set = set, .manifest = manifest };
}

pub fn decodeArchiveV1(
    encoded: []const u8,
    previous: ?PreviousGenerationV1,
) Error!DecodedArchiveV1 {
    const previous_decoded = if (previous) |value|
        try validatePreviousGenerationV1(value)
    else
        null;
    return decodeArchiveInternalV1(
        encoded,
        previous_decoded,
        false,
    );
}

fn decodeArchiveInternalV1(
    encoded: []const u8,
    previous: ?DecodedArchiveV1,
    unresolved_previous_allowed: bool,
) Error!DecodedArchiveV1 {
    const set = checkpoint_file.decodeSetV1(encoded) catch
        return Error.InvalidRegistry;
    if (set.object_count != archive_object_count)
        return Error.InvalidRegistry;
    const manifest_object = set.object(
        .extension,
        manifest_object_ordinal,
    ) catch return Error.InvalidRegistry;
    const table_object = set.object(
        .extension,
        entry_table_object_ordinal,
    ) catch return Error.InvalidRegistry;
    const pack_object = set.object(
        .extension,
        payload_pack_object_ordinal,
    ) catch return Error.InvalidRegistry;
    if (manifest_object.abi_version != manifest_abi or
        table_object.abi_version != entry_table_abi or
        pack_object.abi_version != payload_pack_abi or
        manifest_object.bytes.len != manifest_bytes)
        return Error.InvalidRegistry;

    const manifest = try decodeManifestV1(manifest_object.bytes);
    const table_length = std.math.cast(
        usize,
        manifest.entry_table_bytes,
    ) orelse return Error.InvalidManifest;
    const pack_length = std.math.cast(
        usize,
        manifest.payload_pack_bytes,
    ) orelse return Error.InvalidManifest;
    if (table_object.bytes.len != table_length or
        pack_object.bytes.len != pack_length)
        return Error.InvalidBinding;
    const has_predecessor = !isZero(manifest.previous_archive_sha256);
    if (!unresolved_previous_allowed) {
        if (has_predecessor != (previous != null))
            return Error.InvalidLineage;
    }
    if (set.metadata.generation != manifest.generation or
        set.metadata.request_epoch != manifest.request_epoch or
        set.metadata.publication_next_sequence !=
            try checkedAdd(manifest.publication_sequence, 1) or
        !digestEqual(
            set.metadata.parent_checkpoint_sha256,
            manifest.previous_archive_sha256,
        ) or
        !digestEqual(
            set.metadata.challenge_sha256,
            manifest.challenge_sha256,
        ))
        return Error.InvalidBinding;

    if (previous) |value| {
        try validateManifestLineageV1(manifest, value);
    }
    const summary = try validateEntryTableV1(
        table_object.bytes,
        pack_object.bytes,
        has_predecessor,
        previous,
        unresolved_previous_allowed,
    );
    try validateManifestBindingsV1(
        manifest,
        summary,
        table_object.bytes,
        pack_object.bytes,
    );
    return .{
        .archive_bytes = encoded,
        .archive_sha256 = set.checkpoint_sha256,
        .manifest = manifest,
        .entry_table = table_object.bytes,
        .payload_pack = pack_object.bytes,
    };
}

fn validatePreviousGenerationV1(
    previous: PreviousGenerationV1,
) Error!DecodedArchiveV1 {
    if (previous.archive_bytes.len == 0)
        return Error.InvalidLineage;
    return decodeArchiveInternalV1(
        previous.archive_bytes,
        null,
        true,
    );
}

fn validateInputEnvelopeV1(input: RegistryInputV1) Error!void {
    if (input.request_epoch == 0 or
        input.generation == 0 or
        input.publication_sequence == 0 or
        isZero(input.generation_plan_sha256) or
        isZero(input.tenant_scope_sha256) or
        isZero(input.metadata_policy_sha256) or
        isZero(input.challenge_sha256) or
        input.outputs.len == 0)
        return Error.InvalidRegistry;
    if (input.outputs.len > max_entries)
        return Error.CapacityExceeded;
    var image_count: usize = 0;
    var audio_count: usize = 0;
    var video_count: usize = 0;
    var prior: ?OutputInputV1 = null;
    for (input.outputs) |output| {
        try validateOutputInputV1(output);
        if (prior) |value| {
            if (!inputLessThanV1(value, output))
                return Error.InvalidRegistry;
        }
        switch (output.modality) {
            .image => image_count += 1,
            .audio => audio_count += 1,
            .video => video_count += 1,
        }
        if (image_count > max_outputs_per_modality or
            audio_count > max_outputs_per_modality or
            video_count > max_outputs_per_modality)
            return Error.CapacityExceeded;
        prior = output;
    }
}

fn validateInputLineageV1(
    input: RegistryInputV1,
    previous: ?DecodedArchiveV1,
) Error!void {
    if (previous) |value| {
        if (input.generation != try checkedAdd(
            value.manifest.generation,
            1,
        ) or
            input.publication_sequence != try checkedAdd(
                value.manifest.publication_sequence,
                1,
            ) or
            input.request_epoch != value.manifest.request_epoch or
            !digestEqual(
                input.tenant_scope_sha256,
                value.manifest.tenant_scope_sha256,
            ) or
            !digestEqual(
                input.metadata_policy_sha256,
                value.manifest.metadata_policy_sha256,
            ) or
            !digestEqual(
                input.challenge_sha256,
                value.manifest.challenge_sha256,
            ))
            return Error.InvalidLineage;
    } else if (input.generation != 1) {
        return Error.InvalidLineage;
    }
}

fn encodeEntriesV1(
    outputs: []const OutputInputV1,
    table: []u8,
    pack: []u8,
    previous: ?DecodedArchiveV1,
) Error!RegistrySummaryV1 {
    if (table.len != outputs.len * entry_bytes)
        return Error.InvalidRegistry;
    var summary: RegistrySummaryV1 = .{};
    var current_terminals: TerminalSetV1 = .{};
    const previous_terminals = if (previous) |value|
        try terminalSetV1(value)
    else
        TerminalSetV1{};
    var pack_cursor: usize = 0;
    var prior_input: ?OutputInputV1 = null;
    for (outputs, 0..) |output, index| {
        try validateOutputInputV1(output);
        if (prior_input) |prior| {
            if (!inputLessThanV1(prior, output))
                return Error.InvalidRegistry;
        }
        const payload_end = std.math.add(
            usize,
            pack_cursor,
            output.encoded_payload.len,
        ) catch return Error.ArithmeticOverflow;
        if (payload_end > pack.len) return Error.BufferTooSmall;
        const offset = std.math.cast(
            u64,
            pack_cursor,
        ) orelse return Error.ArithmeticOverflow;
        const entry = try makeEntryV1(output, offset);
        try validateEntryContinuityV1(
            entry,
            current_terminals.get(output.modality),
            previous_terminals.get(output.modality),
            previous != null,
            false,
        );
        @memcpy(pack[pack_cursor..payload_end], output.encoded_payload);
        const entry_start = index * entry_bytes;
        _ = try encodeEntryV1(
            entry,
            table[entry_start .. entry_start + entry_bytes],
        );
        try accumulateEntryV1(&summary, entry);
        current_terminals.set(output.modality, entry);
        pack_cursor = payload_end;
        prior_input = output;
    }
    if (pack_cursor != pack.len) return Error.InvalidPayload;
    if (previous) |value| {
        if (summary.modality_mask != value.manifest.modality_mask)
            return Error.InvalidLineage;
    }
    try validateSummaryCapacityV1(summary);
    summary.entry_table_sha256 = entryTableRootV1(
        summary.entry_count,
        table,
    );
    summary.payload_pack_sha256 = payloadPackRootV1(pack);
    return summary;
}

fn validateEntryTableV1(
    table: []const u8,
    pack: []const u8,
    has_predecessor: bool,
    previous: ?DecodedArchiveV1,
    unresolved_previous_allowed: bool,
) Error!RegistrySummaryV1 {
    if (table.len == 0 or table.len % entry_bytes != 0)
        return Error.InvalidRegistry;
    const count = table.len / entry_bytes;
    if (count > max_entries) return Error.CapacityExceeded;
    var summary: RegistrySummaryV1 = .{};
    var current_terminals: TerminalSetV1 = .{};
    const previous_terminals = if (previous) |value|
        try terminalSetV1(value)
    else
        TerminalSetV1{};
    var previous_entry: ?GeneratedMediaOutputEntryV1 = null;
    var pack_cursor: usize = 0;
    for (0..count) |index| {
        const start = index * entry_bytes;
        const entry = try decodeEntryV1(table[start .. start + entry_bytes]);
        if (previous_entry) |prior| {
            if (!entryLessThanV1(prior, entry))
                return Error.InvalidRegistry;
        }
        const payload_start = std.math.cast(
            usize,
            entry.payload_offset,
        ) orelse return Error.InvalidPayload;
        const payload_length = std.math.cast(
            usize,
            entry.payload_bytes,
        ) orelse return Error.InvalidPayload;
        const payload_end = std.math.add(
            usize,
            payload_start,
            payload_length,
        ) catch return Error.InvalidPayload;
        if (payload_start != pack_cursor or payload_end > pack.len)
            return Error.InvalidPayload;
        const expected_payload = payloadRootV1(
            entry.modality,
            entry.ordinal,
            entry.encoding_abi,
            entry.source_output_sha256,
            pack[payload_start..payload_end],
        );
        if (!digestEqual(expected_payload, entry.payload_sha256))
            return Error.InvalidPayload;
        try validateEntryContinuityV1(
            entry,
            current_terminals.get(entry.modality),
            previous_terminals.get(entry.modality),
            has_predecessor,
            unresolved_previous_allowed,
        );
        try accumulateEntryV1(&summary, entry);
        current_terminals.set(entry.modality, entry);
        previous_entry = entry;
        pack_cursor = payload_end;
    }
    if (pack_cursor != pack.len) return Error.InvalidPayload;
    if (previous) |value| {
        if (summary.modality_mask != value.manifest.modality_mask)
            return Error.InvalidLineage;
    }
    try validateSummaryCapacityV1(summary);
    summary.entry_table_sha256 = entryTableRootV1(
        summary.entry_count,
        table,
    );
    summary.payload_pack_sha256 = payloadPackRootV1(pack);
    return summary;
}

fn validateEntryContinuityV1(
    entry: GeneratedMediaOutputEntryV1,
    current: ?GeneratedMediaOutputEntryV1,
    previous: ?GeneratedMediaOutputEntryV1,
    has_predecessor: bool,
    unresolved_previous_allowed: bool,
) Error!void {
    if (current) |value| {
        if (entry.ordinal != try checkedAdd(value.ordinal, 1) or
            entry.unit_start != value.unit_end or
            entry.timeline_start != value.timeline_end or
            !digestEqual(
                entry.previous_entry_sha256,
                value.entry_sha256,
            ))
            return Error.InvalidLineage;
        return;
    }
    if (previous) |value| {
        if (entry.ordinal != try checkedAdd(value.ordinal, 1) or
            entry.unit_start != value.unit_end or
            entry.timeline_start != value.timeline_end or
            !digestEqual(
                entry.previous_entry_sha256,
                value.entry_sha256,
            ))
            return Error.InvalidLineage;
        return;
    }
    if (has_predecessor) {
        if (!unresolved_previous_allowed or entry.ordinal == 0 or
            entry.unit_start == 0 or entry.timeline_start == 0 or
            isZero(entry.previous_entry_sha256))
            return Error.InvalidLineage;
    } else if (entry.ordinal != 0 or
        entry.unit_start != 0 or
        entry.timeline_start != 0 or
        !isZero(entry.previous_entry_sha256))
        return Error.InvalidLineage;
}

fn terminalSetV1(
    decoded: DecodedArchiveV1,
) Error!TerminalSetV1 {
    var terminals: TerminalSetV1 = .{};
    const count = std.math.cast(
        usize,
        decoded.manifest.entry_count,
    ) orelse return Error.InvalidRegistry;
    for (0..count) |index| {
        const entry = try decoded.entry(index);
        terminals.set(entry.modality, entry);
    }
    return terminals;
}

fn inputLessThanV1(
    left: OutputInputV1,
    right: OutputInputV1,
) bool {
    const left_modality = @intFromEnum(left.modality);
    const right_modality = @intFromEnum(right.modality);
    return left_modality < right_modality or
        (left_modality == right_modality and
            left.ordinal < right.ordinal);
}

fn entryLessThanV1(
    left: GeneratedMediaOutputEntryV1,
    right: GeneratedMediaOutputEntryV1,
) bool {
    const left_modality = @intFromEnum(left.modality);
    const right_modality = @intFromEnum(right.modality);
    return left_modality < right_modality or
        (left_modality == right_modality and
            left.ordinal < right.ordinal);
}

fn accumulateEntryV1(
    summary: *RegistrySummaryV1,
    entry: GeneratedMediaOutputEntryV1,
) Error!void {
    summary.entry_count = try checkedAdd(summary.entry_count, 1);
    summary.total_source_bytes = try checkedAdd(
        summary.total_source_bytes,
        entry.source_bytes,
    );
    summary.total_encoded_bytes = try checkedAdd(
        summary.total_encoded_bytes,
        entry.payload_bytes,
    );
    summary.total_units = try checkedAdd(
        summary.total_units,
        entry.unit_count,
    );
    summary.modality_mask |= modalityBitV1(entry.modality);
    const modality = summary.modality(entry.modality);
    modality.count = try checkedAdd(modality.count, 1);
    modality.units = try checkedAdd(modality.units, entry.unit_count);
    modality.encoded_bytes = try checkedAdd(
        modality.encoded_bytes,
        entry.payload_bytes,
    );
    modality.unit_end = entry.unit_end;
    modality.timeline_end = entry.timeline_end;
}

fn validateSummaryCapacityV1(
    summary: RegistrySummaryV1,
) Error!void {
    if (summary.entry_count == 0 or
        summary.entry_count > max_entries or
        summary.image.count > max_outputs_per_modality or
        summary.audio.count > max_outputs_per_modality or
        summary.video.count > max_outputs_per_modality)
        return Error.CapacityExceeded;
    if (summary.modality_mask == 0 or
        summary.modality_mask & ~@as(u64, 0x7) != 0)
        return Error.InvalidRegistry;
}

fn makeEntryV1(
    input: OutputInputV1,
    payload_offset: u64,
) Error!GeneratedMediaOutputEntryV1 {
    try validateOutputInputV1(input);
    const unit_end = try checkedAdd(input.unit_start, input.unit_count);
    const payload_bytes = std.math.cast(
        u64,
        input.encoded_payload.len,
    ) orelse return Error.ArithmeticOverflow;
    var entry: GeneratedMediaOutputEntryV1 = .{
        .modality = input.modality,
        .ordinal = input.ordinal,
        .unit_start = input.unit_start,
        .unit_count = input.unit_count,
        .unit_end = unit_end,
        .timeline_start = input.timeline_start,
        .timeline_end = input.timeline_end,
        .source_bytes = input.source_bytes,
        .encoding_abi = input.encoding_abi,
        .payload_offset = payload_offset,
        .payload_bytes = payload_bytes,
        .completion_required = input.completion_required,
        .completed = input.completed,
        .artifact_sha256 = input.artifact_sha256,
        .provenance_sha256 = input.provenance_sha256,
        .result_sha256 = input.result_sha256,
        .source_output_sha256 = input.source_output_sha256,
        .media_object_sha256 = input.media_object_sha256,
        .state_after_sha256 = input.state_after_sha256,
        .completion_sha256 = input.completion_sha256,
        .encoder_implementation_sha256 = input.encoder_implementation_sha256,
        .format_sha256 = input.format_sha256,
        .previous_entry_sha256 = input.previous_entry_sha256,
        .payload_sha256 = payloadRootV1(
            input.modality,
            input.ordinal,
            input.encoding_abi,
            input.source_output_sha256,
            input.encoded_payload,
        ),
        .entry_sha256 = [_]u8{0} ** 32,
    };
    entry.entry_sha256 = entryRootV1(entry);
    try validateEntryV1(entry);
    return entry;
}

/// Derives the canonical entry identity for an already validated output
/// mapping. Registry encoding still validates ordering and predecessor
/// continuity for the complete batch.
pub fn deriveEntryV1(
    input: OutputInputV1,
    payload_offset: u64,
) Error!GeneratedMediaOutputEntryV1 {
    return makeEntryV1(input, payload_offset);
}

fn validateOutputInputV1(input: OutputInputV1) Error!void {
    if (input.unit_count == 0 or
        input.timeline_end <= input.timeline_start or
        input.source_bytes == 0 or
        input.encoding_abi == 0 or
        input.encoded_payload.len == 0 or
        isZero(input.artifact_sha256) or
        isZero(input.provenance_sha256) or
        isZero(input.result_sha256) or
        isZero(input.source_output_sha256) or
        isZero(input.media_object_sha256) or
        isZero(input.state_after_sha256) or
        isZero(input.encoder_implementation_sha256) or
        isZero(input.format_sha256))
        return Error.InvalidEntry;
    switch (input.modality) {
        .image => {
            if (input.completion_required or
                !input.completed or
                !isZero(input.completion_sha256))
                return Error.InvalidEntry;
        },
        .audio, .video => {
            if (!input.completion_required or
                !input.completed or
                isZero(input.completion_sha256))
                return Error.InvalidEntry;
        },
    }
    _ = checkedAdd(input.unit_start, input.unit_count) catch
        return Error.ArithmeticOverflow;
}

pub fn encodeEntryV1(
    value: GeneratedMediaOutputEntryV1,
    destination: []u8,
) Error![]const u8 {
    try validateEntryV1(value);
    if (destination.len < entry_bytes) return Error.BufferTooSmall;
    const output = destination[0..entry_bytes];
    @memset(output, 0);
    writeEntryBodyV1(value, output[0..entry_body_bytes]);
    @memcpy(output[entry_body_bytes..entry_bytes], &value.entry_sha256);
    return output;
}

pub fn decodeEntryV1(
    encoded: []const u8,
) Error!GeneratedMediaOutputEntryV1 {
    if (encoded.len != entry_bytes or
        !std.mem.eql(u8, encoded[0..8], &entry_magic) or
        readU64(encoded, 8) != entry_abi or
        readU64(encoded, 16) != entry_bytes)
        return Error.InvalidEntry;
    for (encoded[480..entry_body_bytes]) |byte| {
        if (byte != 0) return Error.InvalidEntry;
    }
    const modality = std.meta.intToEnum(
        ModalityV1,
        readU64(encoded, 24),
    ) catch return Error.InvalidEntry;
    const value: GeneratedMediaOutputEntryV1 = .{
        .modality = modality,
        .ordinal = readU64(encoded, 32),
        .unit_start = readU64(encoded, 40),
        .unit_count = readU64(encoded, 48),
        .unit_end = readU64(encoded, 56),
        .timeline_start = readU64(encoded, 64),
        .timeline_end = readU64(encoded, 72),
        .source_bytes = readU64(encoded, 80),
        .encoding_abi = readU64(encoded, 88),
        .payload_offset = readU64(encoded, 96),
        .payload_bytes = readU64(encoded, 104),
        .completion_required = switch (readU64(encoded, 112)) {
            0 => false,
            1 => true,
            else => return Error.InvalidEntry,
        },
        .completed = switch (readU64(encoded, 120)) {
            0 => false,
            1 => true,
            else => return Error.InvalidEntry,
        },
        .artifact_sha256 = encoded[128..160].*,
        .provenance_sha256 = encoded[160..192].*,
        .result_sha256 = encoded[192..224].*,
        .source_output_sha256 = encoded[224..256].*,
        .media_object_sha256 = encoded[256..288].*,
        .state_after_sha256 = encoded[288..320].*,
        .completion_sha256 = encoded[320..352].*,
        .encoder_implementation_sha256 = encoded[352..384].*,
        .format_sha256 = encoded[384..416].*,
        .previous_entry_sha256 = encoded[416..448].*,
        .payload_sha256 = encoded[448..480].*,
        .entry_sha256 = encoded[entry_body_bytes..entry_bytes].*,
    };
    try validateEntryV1(value);
    return value;
}

pub fn validateEntryV1(
    value: GeneratedMediaOutputEntryV1,
) Error!void {
    if (value.unit_count == 0 or
        value.unit_end != try checkedAdd(
            value.unit_start,
            value.unit_count,
        ) or
        value.timeline_end <= value.timeline_start or
        value.source_bytes == 0 or
        value.encoding_abi == 0 or
        value.payload_bytes == 0 or
        isZero(value.artifact_sha256) or
        isZero(value.provenance_sha256) or
        isZero(value.result_sha256) or
        isZero(value.source_output_sha256) or
        isZero(value.media_object_sha256) or
        isZero(value.state_after_sha256) or
        isZero(value.encoder_implementation_sha256) or
        isZero(value.format_sha256) or
        isZero(value.payload_sha256))
        return Error.InvalidEntry;
    _ = checkedAdd(value.payload_offset, value.payload_bytes) catch
        return Error.ArithmeticOverflow;
    switch (value.modality) {
        .image => {
            if (value.completion_required or
                !value.completed or
                !isZero(value.completion_sha256))
                return Error.InvalidEntry;
        },
        .audio, .video => {
            if (!value.completion_required or
                !value.completed or
                isZero(value.completion_sha256))
                return Error.InvalidEntry;
        },
    }
    const expected = entryRootV1(value);
    if (!digestEqual(expected, value.entry_sha256))
        return Error.InvalidEntryRoot;
}

pub fn entryRootV1(
    value: GeneratedMediaOutputEntryV1,
) Digest {
    var body: [entry_body_bytes]u8 = undefined;
    @memset(&body, 0);
    writeEntryBodyV1(value, &body);
    return domainRoot(entry_domain, &body);
}

fn writeEntryBodyV1(
    value: GeneratedMediaOutputEntryV1,
    body: []u8,
) void {
    @memcpy(body[0..8], &entry_magic);
    writeU64(body, 8, entry_abi);
    writeU64(body, 16, entry_bytes);
    writeU64(body, 24, @intFromEnum(value.modality));
    writeU64(body, 32, value.ordinal);
    writeU64(body, 40, value.unit_start);
    writeU64(body, 48, value.unit_count);
    writeU64(body, 56, value.unit_end);
    writeU64(body, 64, value.timeline_start);
    writeU64(body, 72, value.timeline_end);
    writeU64(body, 80, value.source_bytes);
    writeU64(body, 88, value.encoding_abi);
    writeU64(body, 96, value.payload_offset);
    writeU64(body, 104, value.payload_bytes);
    writeU64(body, 112, @intFromBool(value.completion_required));
    writeU64(body, 120, @intFromBool(value.completed));
    @memcpy(body[128..160], &value.artifact_sha256);
    @memcpy(body[160..192], &value.provenance_sha256);
    @memcpy(body[192..224], &value.result_sha256);
    @memcpy(body[224..256], &value.source_output_sha256);
    @memcpy(body[256..288], &value.media_object_sha256);
    @memcpy(body[288..320], &value.state_after_sha256);
    @memcpy(body[320..352], &value.completion_sha256);
    @memcpy(body[352..384], &value.encoder_implementation_sha256);
    @memcpy(body[384..416], &value.format_sha256);
    @memcpy(body[416..448], &value.previous_entry_sha256);
    @memcpy(body[448..480], &value.payload_sha256);
}

fn makeManifestV1(
    input: RegistryInputV1,
    summary: RegistrySummaryV1,
    previous: ?DecodedArchiveV1,
) Error!GeneratedMediaOutputRegistryManifestV1 {
    const table_bytes = std.math.mul(
        u64,
        summary.entry_count,
        entry_bytes,
    ) catch return Error.ArithmeticOverflow;
    var value: GeneratedMediaOutputRegistryManifestV1 = .{
        .request_epoch = input.request_epoch,
        .generation = input.generation,
        .publication_sequence = input.publication_sequence,
        .entry_count = summary.entry_count,
        .entry_table_bytes = table_bytes,
        .payload_pack_bytes = summary.total_encoded_bytes,
        .total_source_bytes = summary.total_source_bytes,
        .total_encoded_bytes = summary.total_encoded_bytes,
        .total_units = summary.total_units,
        .image_count = summary.image.count,
        .audio_count = summary.audio.count,
        .video_count = summary.video.count,
        .image_units = summary.image.units,
        .audio_units = summary.audio.units,
        .video_units = summary.video.units,
        .image_encoded_bytes = summary.image.encoded_bytes,
        .audio_encoded_bytes = summary.audio.encoded_bytes,
        .video_encoded_bytes = summary.video.encoded_bytes,
        .image_unit_end = summary.image.unit_end,
        .audio_unit_end = summary.audio.unit_end,
        .video_unit_end = summary.video.unit_end,
        .image_timeline_end = summary.image.timeline_end,
        .audio_timeline_end = summary.audio.timeline_end,
        .video_timeline_end = summary.video.timeline_end,
        .modality_mask = summary.modality_mask,
        .entry_table_sha256 = summary.entry_table_sha256,
        .payload_pack_sha256 = summary.payload_pack_sha256,
        .generation_plan_sha256 = input.generation_plan_sha256,
        .tenant_scope_sha256 = input.tenant_scope_sha256,
        .metadata_policy_sha256 = input.metadata_policy_sha256,
        .challenge_sha256 = input.challenge_sha256,
        .previous_manifest_sha256 = if (previous) |value|
            value.manifest.manifest_sha256
        else
            [_]u8{0} ** 32,
        .previous_archive_sha256 = if (previous) |value|
            value.archive_sha256
        else
            [_]u8{0} ** 32,
        .manifest_sha256 = [_]u8{0} ** 32,
    };
    value.manifest_sha256 = manifestRootV1(value);
    try validateManifestV1(value);
    return value;
}

pub fn encodeManifestV1(
    value: GeneratedMediaOutputRegistryManifestV1,
    destination: []u8,
) Error![]const u8 {
    try validateManifestV1(value);
    if (destination.len < manifest_bytes) return Error.BufferTooSmall;
    const output = destination[0..manifest_bytes];
    @memset(output, 0);
    writeManifestBodyV1(value, output[0..manifest_body_bytes]);
    @memcpy(
        output[manifest_body_bytes..manifest_bytes],
        &value.manifest_sha256,
    );
    return output;
}

pub fn decodeManifestV1(
    encoded: []const u8,
) Error!GeneratedMediaOutputRegistryManifestV1 {
    if (encoded.len != manifest_bytes or
        !std.mem.eql(u8, encoded[0..8], &manifest_magic) or
        readU64(encoded, 8) != manifest_abi or
        readU64(encoded, 16) != manifest_bytes)
        return Error.InvalidManifest;
    for (encoded[480..manifest_body_bytes]) |byte| {
        if (byte != 0) return Error.InvalidManifest;
    }
    const value: GeneratedMediaOutputRegistryManifestV1 = .{
        .request_epoch = readU64(encoded, 24),
        .generation = readU64(encoded, 32),
        .publication_sequence = readU64(encoded, 40),
        .entry_count = readU64(encoded, 48),
        .entry_table_bytes = readU64(encoded, 56),
        .payload_pack_bytes = readU64(encoded, 64),
        .total_source_bytes = readU64(encoded, 72),
        .total_encoded_bytes = readU64(encoded, 80),
        .total_units = readU64(encoded, 88),
        .image_count = readU64(encoded, 96),
        .audio_count = readU64(encoded, 104),
        .video_count = readU64(encoded, 112),
        .image_units = readU64(encoded, 120),
        .audio_units = readU64(encoded, 128),
        .video_units = readU64(encoded, 136),
        .image_encoded_bytes = readU64(encoded, 144),
        .audio_encoded_bytes = readU64(encoded, 152),
        .video_encoded_bytes = readU64(encoded, 160),
        .image_unit_end = readU64(encoded, 168),
        .audio_unit_end = readU64(encoded, 176),
        .video_unit_end = readU64(encoded, 184),
        .image_timeline_end = readU64(encoded, 192),
        .audio_timeline_end = readU64(encoded, 200),
        .video_timeline_end = readU64(encoded, 208),
        .modality_mask = readU64(encoded, 216),
        .entry_table_sha256 = encoded[224..256].*,
        .payload_pack_sha256 = encoded[256..288].*,
        .generation_plan_sha256 = encoded[288..320].*,
        .tenant_scope_sha256 = encoded[320..352].*,
        .metadata_policy_sha256 = encoded[352..384].*,
        .challenge_sha256 = encoded[384..416].*,
        .previous_manifest_sha256 = encoded[416..448].*,
        .previous_archive_sha256 = encoded[448..480].*,
        .manifest_sha256 = encoded[manifest_body_bytes..manifest_bytes].*,
    };
    try validateManifestV1(value);
    return value;
}

pub fn validateManifestV1(
    value: GeneratedMediaOutputRegistryManifestV1,
) Error!void {
    const aggregate_count = try checkedAdd(
        try checkedAdd(value.image_count, value.audio_count),
        value.video_count,
    );
    const aggregate_units = try checkedAdd(
        try checkedAdd(value.image_units, value.audio_units),
        value.video_units,
    );
    const aggregate_encoded_bytes = try checkedAdd(
        try checkedAdd(
            value.image_encoded_bytes,
            value.audio_encoded_bytes,
        ),
        value.video_encoded_bytes,
    );
    if (value.request_epoch == 0 or
        value.generation == 0 or
        value.publication_sequence == 0 or
        value.entry_count == 0 or
        value.entry_count > max_entries or
        value.entry_table_bytes !=
            (std.math.mul(
                u64,
                value.entry_count,
                entry_bytes,
            ) catch return Error.ArithmeticOverflow) or
        value.payload_pack_bytes == 0 or
        value.total_source_bytes == 0 or
        value.total_encoded_bytes == 0 or
        value.total_units == 0 or
        value.total_encoded_bytes != value.payload_pack_bytes or
        value.image_count > max_outputs_per_modality or
        value.audio_count > max_outputs_per_modality or
        value.video_count > max_outputs_per_modality or
        value.entry_count != aggregate_count or
        value.total_units != aggregate_units or
        value.total_encoded_bytes != aggregate_encoded_bytes or
        value.modality_mask == 0 or
        value.modality_mask & ~@as(u64, 0x7) != 0 or
        (value.image_count > 0) !=
            (value.modality_mask & modalityBitV1(.image) != 0) or
        (value.audio_count > 0) !=
            (value.modality_mask & modalityBitV1(.audio) != 0) or
        (value.video_count > 0) !=
            (value.modality_mask & modalityBitV1(.video) != 0) or
        !validModalityAggregateV1(
            value.image_count,
            value.image_units,
            value.image_encoded_bytes,
            value.image_unit_end,
            value.image_timeline_end,
        ) or
        !validModalityAggregateV1(
            value.audio_count,
            value.audio_units,
            value.audio_encoded_bytes,
            value.audio_unit_end,
            value.audio_timeline_end,
        ) or
        !validModalityAggregateV1(
            value.video_count,
            value.video_units,
            value.video_encoded_bytes,
            value.video_unit_end,
            value.video_timeline_end,
        ) or
        isZero(value.entry_table_sha256) or
        isZero(value.payload_pack_sha256) or
        isZero(value.generation_plan_sha256) or
        isZero(value.tenant_scope_sha256) or
        isZero(value.metadata_policy_sha256) or
        isZero(value.challenge_sha256) or
        (value.generation == 1 and
            (!isZero(value.previous_manifest_sha256) or
                !isZero(value.previous_archive_sha256))) or
        (value.generation > 1 and
            (isZero(value.previous_manifest_sha256) or
                isZero(value.previous_archive_sha256))))
        return Error.InvalidManifest;
    const expected = manifestRootV1(value);
    if (!digestEqual(expected, value.manifest_sha256))
        return Error.InvalidManifestRoot;
}

fn validModalityAggregateV1(
    count: u64,
    units: u64,
    encoded_bytes: u64,
    unit_end: u64,
    timeline_end: u64,
) bool {
    if (count == 0) {
        return units == 0 and
            encoded_bytes == 0 and
            unit_end == 0 and
            timeline_end == 0;
    }
    return units > 0 and
        encoded_bytes > 0 and
        unit_end > 0 and
        timeline_end > 0;
}

fn validateManifestBindingsV1(
    manifest: GeneratedMediaOutputRegistryManifestV1,
    summary: RegistrySummaryV1,
    table: []const u8,
    pack: []const u8,
) Error!void {
    if (manifest.entry_count != summary.entry_count or
        manifest.entry_table_bytes != table.len or
        manifest.payload_pack_bytes != pack.len or
        manifest.total_source_bytes != summary.total_source_bytes or
        manifest.total_encoded_bytes != summary.total_encoded_bytes or
        manifest.total_units != summary.total_units or
        manifest.image_count != summary.image.count or
        manifest.audio_count != summary.audio.count or
        manifest.video_count != summary.video.count or
        manifest.image_units != summary.image.units or
        manifest.audio_units != summary.audio.units or
        manifest.video_units != summary.video.units or
        manifest.image_encoded_bytes != summary.image.encoded_bytes or
        manifest.audio_encoded_bytes != summary.audio.encoded_bytes or
        manifest.video_encoded_bytes != summary.video.encoded_bytes or
        manifest.image_unit_end != summary.image.unit_end or
        manifest.audio_unit_end != summary.audio.unit_end or
        manifest.video_unit_end != summary.video.unit_end or
        manifest.image_timeline_end != summary.image.timeline_end or
        manifest.audio_timeline_end != summary.audio.timeline_end or
        manifest.video_timeline_end != summary.video.timeline_end or
        manifest.modality_mask != summary.modality_mask or
        !digestEqual(
            manifest.entry_table_sha256,
            summary.entry_table_sha256,
        ) or
        !digestEqual(
            manifest.payload_pack_sha256,
            summary.payload_pack_sha256,
        ))
        return Error.InvalidBinding;
}

fn validateManifestLineageV1(
    manifest: GeneratedMediaOutputRegistryManifestV1,
    previous: DecodedArchiveV1,
) Error!void {
    if (manifest.generation != try checkedAdd(
        previous.manifest.generation,
        1,
    ) or
        manifest.publication_sequence != try checkedAdd(
            previous.manifest.publication_sequence,
            1,
        ) or
        manifest.request_epoch != previous.manifest.request_epoch or
        manifest.modality_mask != previous.manifest.modality_mask or
        !digestEqual(
            manifest.tenant_scope_sha256,
            previous.manifest.tenant_scope_sha256,
        ) or
        !digestEqual(
            manifest.metadata_policy_sha256,
            previous.manifest.metadata_policy_sha256,
        ) or
        !digestEqual(
            manifest.challenge_sha256,
            previous.manifest.challenge_sha256,
        ) or
        !digestEqual(
            manifest.previous_manifest_sha256,
            previous.manifest.manifest_sha256,
        ) or
        !digestEqual(
            manifest.previous_archive_sha256,
            previous.archive_sha256,
        ))
        return Error.InvalidLineage;
}

pub fn manifestRootV1(
    value: GeneratedMediaOutputRegistryManifestV1,
) Digest {
    var body: [manifest_body_bytes]u8 = undefined;
    @memset(&body, 0);
    writeManifestBodyV1(value, &body);
    return domainRoot(manifest_domain, &body);
}

fn writeManifestBodyV1(
    value: GeneratedMediaOutputRegistryManifestV1,
    body: []u8,
) void {
    @memcpy(body[0..8], &manifest_magic);
    writeU64(body, 8, manifest_abi);
    writeU64(body, 16, manifest_bytes);
    writeU64(body, 24, value.request_epoch);
    writeU64(body, 32, value.generation);
    writeU64(body, 40, value.publication_sequence);
    writeU64(body, 48, value.entry_count);
    writeU64(body, 56, value.entry_table_bytes);
    writeU64(body, 64, value.payload_pack_bytes);
    writeU64(body, 72, value.total_source_bytes);
    writeU64(body, 80, value.total_encoded_bytes);
    writeU64(body, 88, value.total_units);
    writeU64(body, 96, value.image_count);
    writeU64(body, 104, value.audio_count);
    writeU64(body, 112, value.video_count);
    writeU64(body, 120, value.image_units);
    writeU64(body, 128, value.audio_units);
    writeU64(body, 136, value.video_units);
    writeU64(body, 144, value.image_encoded_bytes);
    writeU64(body, 152, value.audio_encoded_bytes);
    writeU64(body, 160, value.video_encoded_bytes);
    writeU64(body, 168, value.image_unit_end);
    writeU64(body, 176, value.audio_unit_end);
    writeU64(body, 184, value.video_unit_end);
    writeU64(body, 192, value.image_timeline_end);
    writeU64(body, 200, value.audio_timeline_end);
    writeU64(body, 208, value.video_timeline_end);
    writeU64(body, 216, value.modality_mask);
    @memcpy(body[224..256], &value.entry_table_sha256);
    @memcpy(body[256..288], &value.payload_pack_sha256);
    @memcpy(body[288..320], &value.generation_plan_sha256);
    @memcpy(body[320..352], &value.tenant_scope_sha256);
    @memcpy(body[352..384], &value.metadata_policy_sha256);
    @memcpy(body[384..416], &value.challenge_sha256);
    @memcpy(body[416..448], &value.previous_manifest_sha256);
    @memcpy(body[448..480], &value.previous_archive_sha256);
}

pub fn entryTableRootV1(
    count: u64,
    bytes: []const u8,
) Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(entry_table_domain);
    const count_wire = hashU64(count);
    hasher.update(&count_wire);
    const length_wire = hashU64(bytes.len);
    hasher.update(&length_wire);
    hasher.update(bytes);
    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

pub fn payloadPackRootV1(bytes: []const u8) Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(payload_pack_domain);
    const length_wire = hashU64(bytes.len);
    hasher.update(&length_wire);
    hasher.update(bytes);
    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

pub fn payloadRootV1(
    modality: ModalityV1,
    ordinal: u64,
    encoding_abi: u64,
    source_output_sha256: Digest,
    bytes: []const u8,
) Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(payload_domain);
    const modality_wire = hashU64(@intFromEnum(modality));
    hasher.update(&modality_wire);
    const ordinal_wire = hashU64(ordinal);
    hasher.update(&ordinal_wire);
    const abi_wire = hashU64(encoding_abi);
    hasher.update(&abi_wire);
    const length_wire = hashU64(bytes.len);
    hasher.update(&length_wire);
    hasher.update(&source_output_sha256);
    hasher.update(bytes);
    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

fn modalityBitV1(modality: ModalityV1) u64 {
    return @as(u64, 1) << @intCast(@intFromEnum(modality) - 1);
}

fn domainRoot(
    domain: []const u8,
    bytes: []const u8,
) Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(domain);
    const length_wire = hashU64(bytes.len);
    hasher.update(&length_wire);
    hasher.update(bytes);
    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

fn referenceIdentityRootV1(label: []const u8) Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(reference_identity_domain);
    const length_wire = hashU64(label.len);
    hasher.update(&length_wire);
    hasher.update(label);
    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

fn checkedAdd(left: u64, right: u64) Error!u64 {
    return std.math.add(u64, left, right) catch
        return Error.ArithmeticOverflow;
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

fn isZero(value: Digest) bool {
    return std.mem.allEqual(u8, &value, 0);
}

fn hashU64(value: anytype) [8]u8 {
    const converted = std.math.cast(u64, value) orelse
        @panic("value does not fit u64");
    var output: [8]u8 = undefined;
    std.mem.writeInt(u64, &output, converted, .little);
    return output;
}

fn writeU64(bytes: []u8, offset: usize, value: anytype) void {
    const converted = std.math.cast(u64, value) orelse
        @panic("value does not fit u64");
    std.mem.writeInt(
        u64,
        bytes[offset .. offset + 8][0..8],
        converted,
        .little,
    );
}

fn readU64(bytes: []const u8, offset: usize) u64 {
    return std.mem.readInt(
        u64,
        bytes[offset .. offset + 8][0..8],
        .little,
    );
}

fn slicesOverlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
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
    return left_start < right_end and right_start < left_end;
}

pub fn makeReferenceArchivesV1(
    first_scratch: []u8,
    first_archive: []u8,
    second_scratch: []u8,
    second_archive: []u8,
) Error!ReferenceArchivesV1 {
    const buffers = [_][]u8{
        first_scratch,
        first_archive,
        second_scratch,
        second_archive,
    };
    for (buffers, 0..) |left, left_index| {
        for (buffers[left_index + 1 ..]) |right| {
            if (slicesOverlap(left, right))
                return Error.UnsafeDestination;
        }
    }

    var first_outputs = referenceFirstOutputsV1();
    try linkReferenceOutputsV1(&first_outputs, .{});
    const common = referenceCommonV1();
    const first = try encodeArchiveV1(
        .{
            .previous = null,
            .request_epoch = 23,
            .generation = 1,
            .publication_sequence = 1,
            .generation_plan_sha256 = referenceIdentityRootV1("generation-plan-one"),
            .tenant_scope_sha256 = common.tenant_scope_sha256,
            .metadata_policy_sha256 = common.metadata_policy_sha256,
            .challenge_sha256 = common.challenge_sha256,
            .outputs = &first_outputs,
        },
        first_scratch,
        first_archive,
    );
    const first_decoded = try decodeArchiveV1(first.set.bytes, null);

    var second_outputs = referenceSecondOutputsV1();
    try linkReferenceOutputsV1(
        &second_outputs,
        try terminalSetV1(first_decoded),
    );
    const second = try encodeArchiveV1(
        .{
            .previous = first_decoded.previous(),
            .request_epoch = 23,
            .generation = 2,
            .publication_sequence = 2,
            .generation_plan_sha256 = referenceIdentityRootV1("generation-plan-two"),
            .tenant_scope_sha256 = common.tenant_scope_sha256,
            .metadata_policy_sha256 = common.metadata_policy_sha256,
            .challenge_sha256 = common.challenge_sha256,
            .outputs = &second_outputs,
        },
        second_scratch,
        second_archive,
    );
    const second_decoded = try decodeArchiveV1(
        second.set.bytes,
        first_decoded.previous(),
    );
    return .{
        .first = first,
        .first_decoded = first_decoded,
        .second = second,
        .second_decoded = second_decoded,
    };
}

const ReferenceCommonV1 = struct {
    tenant_scope_sha256: Digest,
    metadata_policy_sha256: Digest,
    challenge_sha256: Digest,
};

fn referenceCommonV1() ReferenceCommonV1 {
    return .{
        .tenant_scope_sha256 = referenceIdentityRootV1("tenant-scope"),
        .metadata_policy_sha256 = referenceIdentityRootV1("metadata-policy"),
        .challenge_sha256 = referenceIdentityRootV1("challenge"),
    };
}

fn referenceFirstOutputsV1() [7]OutputInputV1 {
    return .{
        referenceOutputV1(
            .image,
            0,
            0,
            1,
            0,
            100,
            101,
            "one",
        ),
        referenceOutputV1(
            .image,
            1,
            1,
            2,
            100,
            260,
            102,
            "one",
        ),
        referenceOutputV1(
            .audio,
            0,
            0,
            160,
            0,
            160,
            201,
            "one",
        ),
        referenceOutputV1(
            .audio,
            1,
            160,
            240,
            160,
            400,
            202,
            "one",
        ),
        referenceOutputV1(
            .audio,
            2,
            400,
            80,
            400,
            480,
            203,
            "one",
        ),
        referenceOutputV1(
            .video,
            0,
            0,
            1,
            0,
            33,
            301,
            "one",
        ),
        referenceOutputV1(
            .video,
            1,
            1,
            2,
            33,
            99,
            302,
            "one",
        ),
    };
}

fn referenceSecondOutputsV1() [7]OutputInputV1 {
    return .{
        referenceOutputV1(
            .image,
            2,
            3,
            2,
            260,
            450,
            103,
            "two",
        ),
        referenceOutputV1(
            .image,
            3,
            5,
            1,
            450,
            600,
            104,
            "two",
        ),
        referenceOutputV1(
            .audio,
            3,
            480,
            120,
            480,
            600,
            204,
            "two",
        ),
        referenceOutputV1(
            .audio,
            4,
            600,
            200,
            600,
            800,
            205,
            "two",
        ),
        referenceOutputV1(
            .video,
            2,
            3,
            1,
            99,
            132,
            303,
            "two",
        ),
        referenceOutputV1(
            .video,
            3,
            4,
            1,
            132,
            165,
            304,
            "two",
        ),
        referenceOutputV1(
            .video,
            4,
            5,
            2,
            165,
            231,
            305,
            "two",
        ),
    };
}

fn referenceOutputV1(
    modality: ModalityV1,
    ordinal: u64,
    unit_start: u64,
    unit_count: u64,
    timeline_start: u64,
    timeline_end: u64,
    source_bytes: u64,
    generation_word: []const u8,
) OutputInputV1 {
    const name = @tagName(modality);
    var payload_storage: [64]u8 = undefined;
    const payload = std.fmt.bufPrint(
        &payload_storage,
        "{s}-{d}-generation-{s}",
        .{ name, ordinal, generation_word },
    ) catch unreachable;
    const payload_value = referencePayloadV1(
        modality,
        ordinal,
        generation_word,
    );
    std.debug.assert(std.mem.eql(u8, payload, payload_value));
    return .{
        .modality = modality,
        .ordinal = ordinal,
        .unit_start = unit_start,
        .unit_count = unit_count,
        .timeline_start = timeline_start,
        .timeline_end = timeline_end,
        .source_bytes = source_bytes,
        .encoding_abi = @intFromEnum(modality),
        .encoded_payload = payload_value,
        .artifact_sha256 = referenceFieldRootV1("artifact", modality, ordinal),
        .provenance_sha256 = referenceFieldRootV1("provenance", modality, ordinal),
        .result_sha256 = referenceFieldRootV1("result", modality, ordinal),
        .source_output_sha256 = referenceFieldRootV1("source-output", modality, ordinal),
        .media_object_sha256 = referenceFieldRootV1("media-object", modality, ordinal),
        .state_after_sha256 = referenceFieldRootV1("state-after", modality, ordinal),
        .completion_required = modality != .image,
        .completed = true,
        .completion_sha256 = if (modality == .image)
            [_]u8{0} ** 32
        else
            referenceFieldRootV1("completion", modality, ordinal),
        .encoder_implementation_sha256 = referenceStableRootV1("encoder", modality),
        .format_sha256 = referenceStableRootV1("format", modality),
        .previous_entry_sha256 = [_]u8{0} ** 32,
    };
}

fn referencePayloadV1(
    modality: ModalityV1,
    ordinal: u64,
    generation_word: []const u8,
) []const u8 {
    if (std.mem.eql(u8, generation_word, "one")) {
        return switch (modality) {
            .image => switch (ordinal) {
                0 => "image-0-generation-one",
                1 => "image-1-generation-one",
                else => unreachable,
            },
            .audio => switch (ordinal) {
                0 => "audio-0-generation-one",
                1 => "audio-1-generation-one",
                2 => "audio-2-generation-one",
                else => unreachable,
            },
            .video => switch (ordinal) {
                0 => "video-0-generation-one",
                1 => "video-1-generation-one",
                else => unreachable,
            },
        };
    }
    std.debug.assert(std.mem.eql(u8, generation_word, "two"));
    return switch (modality) {
        .image => switch (ordinal) {
            2 => "image-2-generation-two",
            3 => "image-3-generation-two",
            else => unreachable,
        },
        .audio => switch (ordinal) {
            3 => "audio-3-generation-two",
            4 => "audio-4-generation-two",
            else => unreachable,
        },
        .video => switch (ordinal) {
            2 => "video-2-generation-two",
            3 => "video-3-generation-two",
            4 => "video-4-generation-two",
            else => unreachable,
        },
    };
}

fn referenceFieldRootV1(
    field: []const u8,
    modality: ModalityV1,
    ordinal: u64,
) Digest {
    var label_storage: [96]u8 = undefined;
    const label = std.fmt.bufPrint(
        &label_storage,
        "{s}-{s}-{d}",
        .{ field, @tagName(modality), ordinal },
    ) catch unreachable;
    return referenceIdentityRootV1(label);
}

fn referenceStableRootV1(
    field: []const u8,
    modality: ModalityV1,
) Digest {
    var label_storage: [64]u8 = undefined;
    const label = std.fmt.bufPrint(
        &label_storage,
        "{s}-{s}",
        .{ field, @tagName(modality) },
    ) catch unreachable;
    return referenceIdentityRootV1(label);
}

fn linkReferenceOutputsV1(
    outputs: []OutputInputV1,
    initial_terminals: TerminalSetV1,
) Error!void {
    var terminals = initial_terminals;
    var payload_offset: u64 = 0;
    for (outputs) |*output| {
        output.previous_entry_sha256 =
            if (terminals.get(output.modality)) |value|
                value.entry_sha256
            else
                [_]u8{0} ** 32;
        const entry = try makeEntryV1(output.*, payload_offset);
        terminals.set(output.modality, entry);
        payload_offset = try checkedAdd(
            payload_offset,
            entry.payload_bytes,
        );
    }
}

test "generated media output registry is canonical and mutation complete" {
    const testing = std.testing;
    var first_scratch: [16 * 1024]u8 = undefined;
    var first_archive: [32 * 1024]u8 = undefined;
    var second_scratch: [16 * 1024]u8 = undefined;
    var second_archive: [32 * 1024]u8 = undefined;
    const references = try makeReferenceArchivesV1(
        &first_scratch,
        &first_archive,
        &second_scratch,
        &second_archive,
    );
    try testing.expectEqual(@as(u64, 7), references.first.manifest.entry_count);
    try testing.expectEqual(@as(u64, 2), references.first.manifest.image_count);
    try testing.expectEqual(@as(u64, 3), references.first.manifest.audio_count);
    try testing.expectEqual(@as(u64, 2), references.first.manifest.video_count);
    try testing.expectEqual(@as(u64, 2), references.second.manifest.image_count);
    try testing.expectEqual(@as(u64, 2), references.second.manifest.audio_count);
    try testing.expectEqual(@as(u64, 3), references.second.manifest.video_count);
    try testing.expectEqualStrings(
        "audio-2-generation-one",
        try references.first_decoded.payload(4),
    );
    try testing.expectEqualStrings(
        "video-4-generation-two",
        try references.second_decoded.payload(6),
    );

    var mutation: [32 * 1024]u8 = undefined;
    const original = references.second.set.bytes;
    @memcpy(mutation[0..original.len], original);
    for (0..original.len) |index| {
        mutation[index] ^= 0x01;
        try expectDecodeFailureV1(
            mutation[0..original.len],
            references.first_decoded.previous(),
        );
        mutation[index] ^= 0x01;
    }
    @memcpy(mutation[0..original.len], original);
    mutation[original.len] = 0;
    try expectDecodeFailureV1(
        mutation[0 .. original.len + 1],
        references.first_decoded.previous(),
    );
    try expectDecodeFailureV1(
        original[0 .. original.len - 1],
        references.first_decoded.previous(),
    );
}

test "decoded registry accessors reject forged or truncated views" {
    const testing = std.testing;
    var first_scratch: [16 * 1024]u8 = undefined;
    var first_archive: [32 * 1024]u8 = undefined;
    var second_scratch: [16 * 1024]u8 = undefined;
    var second_archive: [32 * 1024]u8 = undefined;
    const references = try makeReferenceArchivesV1(
        &first_scratch,
        &first_archive,
        &second_scratch,
        &second_archive,
    );

    try testing.expectError(
        Error.InvalidEntry,
        references.first_decoded.entry(7),
    );

    var truncated_table = references.first_decoded;
    truncated_table.entry_table = truncated_table.entry_table[0..0];
    try testing.expectError(
        Error.InvalidRegistry,
        truncated_table.entry(0),
    );
    try testing.expectError(
        Error.InvalidRegistry,
        truncated_table.payload(0),
    );
    try testing.expectError(
        Error.InvalidRegistry,
        truncated_table.terminal(.image),
    );

    var impossible_count = references.first_decoded;
    impossible_count.manifest.entry_count = std.math.maxInt(u64);
    impossible_count.manifest.entry_table_bytes = std.math.maxInt(u64);
    try testing.expectError(
        Error.InvalidRegistry,
        impossible_count.entry(0),
    );
    try testing.expectError(
        Error.InvalidRegistry,
        impossible_count.terminal(.video),
    );

    var truncated_pack = references.first_decoded;
    truncated_pack.payload_pack = truncated_pack.payload_pack[0..0];
    try testing.expectError(
        Error.InvalidRegistry,
        truncated_pack.payload(0),
    );

    try testing.expectEqual(
        references.first_decoded.entry_table.len,
        references.second_decoded.entry_table.len,
    );
    var foreign_table = references.first_decoded;
    foreign_table.entry_table = references.second_decoded.entry_table;
    try testing.expectError(
        Error.InvalidRegistry,
        foreign_table.entry(0),
    );
    try testing.expectError(
        Error.InvalidRegistry,
        foreign_table.terminal(.audio),
    );

    try testing.expectEqual(
        references.first_decoded.payload_pack.len,
        references.second_decoded.payload_pack.len,
    );
    var foreign_pack = references.first_decoded;
    foreign_pack.payload_pack = references.second_decoded.payload_pack;
    try testing.expectError(
        Error.InvalidRegistry,
        foreign_pack.payload(0),
    );
}

test "registry roots match the independent reference chain" {
    const testing = std.testing;
    var first_scratch: [16 * 1024]u8 = undefined;
    var first_archive: [32 * 1024]u8 = undefined;
    var second_scratch: [16 * 1024]u8 = undefined;
    var second_archive: [32 * 1024]u8 = undefined;
    const references = try makeReferenceArchivesV1(
        &first_scratch,
        &first_archive,
        &second_scratch,
        &second_archive,
    );
    const first_manifest = try digestFromHexV1(
        "289a212c944c8f80f487786314288ee23832af3ddd1e683688503178e381c840",
    );
    const first_archive_root = try digestFromHexV1(
        "b526e7084aaaa54997a546a172cac3147b85333a16c2b45cee8525caf658f43d",
    );
    const second_manifest = try digestFromHexV1(
        "70a6a92d8dc01ed3696195ca8064e7b066be6ffde9a907a7c2d38d5c61bd6388",
    );
    const second_archive_root = try digestFromHexV1(
        "e1cda1d7c618afdb561a6447d62060700cbbc89b34929769ed53533ba96cba75",
    );
    try testing.expectEqualSlices(
        u8,
        &first_manifest,
        &references.first.manifest.manifest_sha256,
    );
    try testing.expectEqualSlices(
        u8,
        &first_archive_root,
        &references.first.set.checkpoint_sha256,
    );
    try testing.expectEqualSlices(
        u8,
        &second_manifest,
        &references.second.manifest.manifest_sha256,
    );
    try testing.expectEqualSlices(
        u8,
        &second_archive_root,
        &references.second.set.checkpoint_sha256,
    );
}

test "registry enforces bounded modality counts and exact continuity" {
    const testing = std.testing;
    var outputs: [12]OutputInputV1 = undefined;
    var cursor: usize = 0;
    for ([_]ModalityV1{ .image, .audio, .video }) |modality| {
        for (0..max_outputs_per_modality) |ordinal| {
            outputs[cursor] = boundaryOutputV1(
                modality,
                ordinal,
            );
            cursor += 1;
        }
    }
    try linkReferenceOutputsV1(&outputs, .{});
    const common = referenceCommonV1();
    var scratch: [24 * 1024]u8 = undefined;
    var archive: [32 * 1024]u8 = undefined;
    const prepared = try encodeArchiveV1(
        .{
            .previous = null,
            .request_epoch = 31,
            .generation = 1,
            .publication_sequence = 1,
            .generation_plan_sha256 = referenceIdentityRootV1("boundary-plan"),
            .tenant_scope_sha256 = common.tenant_scope_sha256,
            .metadata_policy_sha256 = common.metadata_policy_sha256,
            .challenge_sha256 = common.challenge_sha256,
            .outputs = &outputs,
        },
        &scratch,
        &archive,
    );
    try testing.expectEqual(@as(u64, 12), prepared.manifest.entry_count);

    var too_many: [13]OutputInputV1 = undefined;
    @memcpy(too_many[0..12], &outputs);
    too_many[12] = outputs[11];
    try testing.expectError(
        Error.CapacityExceeded,
        encodeArchiveV1(
            .{
                .previous = null,
                .request_epoch = 31,
                .generation = 1,
                .publication_sequence = 1,
                .generation_plan_sha256 = referenceIdentityRootV1("boundary-plan"),
                .tenant_scope_sha256 = common.tenant_scope_sha256,
                .metadata_policy_sha256 = common.metadata_policy_sha256,
                .challenge_sha256 = common.challenge_sha256,
                .outputs = &too_many,
            },
            &scratch,
            &archive,
        ),
    );

    var image_only: [5]OutputInputV1 = undefined;
    for (0..5) |ordinal| {
        image_only[ordinal] = boundaryOutputV1(.image, ordinal);
    }
    try linkReferenceOutputsV1(&image_only, .{});
    try testing.expectError(
        Error.CapacityExceeded,
        encodeArchiveV1(
            .{
                .previous = null,
                .request_epoch = 31,
                .generation = 1,
                .publication_sequence = 1,
                .generation_plan_sha256 = referenceIdentityRootV1("boundary-plan"),
                .tenant_scope_sha256 = common.tenant_scope_sha256,
                .metadata_policy_sha256 = common.metadata_policy_sha256,
                .challenge_sha256 = common.challenge_sha256,
                .outputs = &image_only,
            },
            &scratch,
            &archive,
        ),
    );

    var broken = referenceFirstOutputsV1();
    try linkReferenceOutputsV1(&broken, .{});
    broken[1].unit_start += 1;
    try expectEncodeFailureV1(&broken);
    broken = referenceFirstOutputsV1();
    try linkReferenceOutputsV1(&broken, .{});
    broken[3].timeline_start += 1;
    try expectEncodeFailureV1(&broken);
    broken = referenceFirstOutputsV1();
    try linkReferenceOutputsV1(&broken, .{});
    broken[2].completed = false;
    try expectEncodeFailureV1(&broken);
    broken = referenceFirstOutputsV1();
    try linkReferenceOutputsV1(&broken, .{});
    broken[0].completion_required = true;
    try expectEncodeFailureV1(&broken);
}

test "registry reports checked arithmetic overflow" {
    const testing = std.testing;
    var scratch: [16 * 1024]u8 = undefined;
    var archive: [32 * 1024]u8 = undefined;

    var unit_overflow = [_]OutputInputV1{
        boundaryOutputV1(.image, 0),
    };
    unit_overflow[0].unit_start = std.math.maxInt(u64);
    try testing.expectError(
        Error.ArithmeticOverflow,
        encodeArchiveV1(
            referenceInitialInputV1(&unit_overflow),
            &scratch,
            &archive,
        ),
    );

    var valid = [_]OutputInputV1{
        boundaryOutputV1(.image, 0),
    };
    try linkReferenceOutputsV1(&valid, .{});
    var publication_overflow = referenceInitialInputV1(&valid);
    publication_overflow.publication_sequence = std.math.maxInt(u64);
    try testing.expectError(
        Error.ArithmeticOverflow,
        encodeArchiveV1(
            publication_overflow,
            &scratch,
            &archive,
        ),
    );

    var aggregate_overflow = [_]OutputInputV1{
        boundaryOutputV1(.image, 0),
        boundaryOutputV1(.image, 1),
    };
    aggregate_overflow[0].source_bytes = std.math.maxInt(u64);
    try linkReferenceOutputsV1(&aggregate_overflow, .{});
    try testing.expectError(
        Error.ArithmeticOverflow,
        encodeArchiveV1(
            referenceInitialInputV1(&aggregate_overflow),
            &scratch,
            &archive,
        ),
    );
}

test "registry rejects a canonical but foreign predecessor" {
    var first_scratch: [16 * 1024]u8 = undefined;
    var first_archive: [32 * 1024]u8 = undefined;
    var second_scratch: [16 * 1024]u8 = undefined;
    var second_archive: [32 * 1024]u8 = undefined;
    const references = try makeReferenceArchivesV1(
        &first_scratch,
        &first_archive,
        &second_scratch,
        &second_archive,
    );

    var alternate_outputs = referenceFirstOutputsV1();
    alternate_outputs[0].artifact_sha256 =
        referenceIdentityRootV1("foreign-artifact");
    try linkReferenceOutputsV1(&alternate_outputs, .{});
    const common = referenceCommonV1();
    var alternate_scratch: [16 * 1024]u8 = undefined;
    var alternate_archive: [32 * 1024]u8 = undefined;
    const alternate = try encodeArchiveV1(
        .{
            .previous = null,
            .request_epoch = 23,
            .generation = 1,
            .publication_sequence = 1,
            .generation_plan_sha256 = referenceIdentityRootV1("generation-plan-one"),
            .tenant_scope_sha256 = common.tenant_scope_sha256,
            .metadata_policy_sha256 = common.metadata_policy_sha256,
            .challenge_sha256 = common.challenge_sha256,
            .outputs = &alternate_outputs,
        },
        &alternate_scratch,
        &alternate_archive,
    );
    const alternate_decoded = try decodeArchiveV1(
        alternate.set.bytes,
        null,
    );
    try expectDecodeFailureV1(
        references.second.set.bytes,
        alternate_decoded.previous(),
    );
}

test "reference archive storage must remain distinct" {
    const testing = std.testing;
    var shared: [32 * 1024]u8 = undefined;
    var second_scratch: [16 * 1024]u8 = undefined;
    var second_archive: [32 * 1024]u8 = undefined;
    try testing.expectError(
        Error.UnsafeDestination,
        makeReferenceArchivesV1(
            shared[0 .. 16 * 1024],
            &shared,
            &second_scratch,
            &second_archive,
        ),
    );
}

test "registry rejects every mutable buffer alias" {
    const testing = std.testing;
    var initial_outputs = referenceFirstOutputsV1();
    try linkReferenceOutputsV1(&initial_outputs, .{});

    var scratch_destination: [40 * 1024]u8 = undefined;
    try testing.expectError(
        Error.UnsafeDestination,
        encodeArchiveV1(
            referenceInitialInputV1(&initial_outputs),
            scratch_destination[0 .. 16 * 1024],
            scratch_destination[2 * 1024 .. 34 * 1024],
        ),
    );

    var descriptor_scratch: [24 * 1024]u8 align(@alignOf(OutputInputV1)) =
        undefined;
    const scratch_descriptor_bytes =
        descriptor_scratch[0 .. initial_outputs.len * @sizeOf(OutputInputV1)];
    const scratch_descriptors = std.mem.bytesAsSlice(
        OutputInputV1,
        scratch_descriptor_bytes,
    );
    @memcpy(scratch_descriptors, &initial_outputs);
    var separate_archive: [32 * 1024]u8 = undefined;
    try testing.expectError(
        Error.UnsafeDestination,
        encodeArchiveV1(
            referenceInitialInputV1(scratch_descriptors),
            &descriptor_scratch,
            &separate_archive,
        ),
    );

    var descriptor_destination: [32 * 1024]u8 align(@alignOf(OutputInputV1)) =
        undefined;
    const destination_descriptor_bytes =
        descriptor_destination[0 .. initial_outputs.len * @sizeOf(OutputInputV1)];
    const destination_descriptors = std.mem.bytesAsSlice(
        OutputInputV1,
        destination_descriptor_bytes,
    );
    @memcpy(destination_descriptors, &initial_outputs);
    var separate_scratch: [16 * 1024]u8 = undefined;
    try testing.expectError(
        Error.UnsafeDestination,
        encodeArchiveV1(
            referenceInitialInputV1(destination_descriptors),
            &separate_scratch,
            &descriptor_destination,
        ),
    );

    const alias_payload = "alias-payload";
    var payload_scratch: [16 * 1024]u8 = undefined;
    @memcpy(payload_scratch[0..alias_payload.len], alias_payload);
    var scratch_payload_outputs = [_]OutputInputV1{
        boundaryOutputV1(.image, 0),
    };
    scratch_payload_outputs[0].encoded_payload =
        payload_scratch[0..alias_payload.len];
    try linkReferenceOutputsV1(&scratch_payload_outputs, .{});
    try testing.expectError(
        Error.UnsafeDestination,
        encodeArchiveV1(
            referenceInitialInputV1(&scratch_payload_outputs),
            &payload_scratch,
            &separate_archive,
        ),
    );

    var payload_destination: [32 * 1024]u8 = undefined;
    @memcpy(payload_destination[0..alias_payload.len], alias_payload);
    var destination_payload_outputs = [_]OutputInputV1{
        boundaryOutputV1(.image, 0),
    };
    destination_payload_outputs[0].encoded_payload =
        payload_destination[0..alias_payload.len];
    try linkReferenceOutputsV1(&destination_payload_outputs, .{});
    try testing.expectError(
        Error.UnsafeDestination,
        encodeArchiveV1(
            referenceInitialInputV1(&destination_payload_outputs),
            &separate_scratch,
            &payload_destination,
        ),
    );

    var first_scratch: [16 * 1024]u8 = undefined;
    var first_archive: [32 * 1024]u8 = undefined;
    var second_scratch: [16 * 1024]u8 = undefined;
    var second_archive: [32 * 1024]u8 = undefined;
    const references = try makeReferenceArchivesV1(
        &first_scratch,
        &first_archive,
        &second_scratch,
        &second_archive,
    );
    var successor_outputs = referenceSecondOutputsV1();
    try linkReferenceOutputsV1(
        &successor_outputs,
        try terminalSetV1(references.first_decoded),
    );
    try testing.expectError(
        Error.UnsafeDestination,
        encodeArchiveV1(
            referenceSuccessorInputV1(
                references.first_decoded.previous(),
                &successor_outputs,
            ),
            &first_archive,
            &separate_archive,
        ),
    );
    try testing.expectError(
        Error.UnsafeDestination,
        encodeArchiveV1(
            referenceSuccessorInputV1(
                references.first_decoded.previous(),
                &successor_outputs,
            ),
            &separate_scratch,
            &first_archive,
        ),
    );
}

fn referenceInitialInputV1(
    outputs: []const OutputInputV1,
) RegistryInputV1 {
    const common = referenceCommonV1();
    return .{
        .previous = null,
        .request_epoch = 23,
        .generation = 1,
        .publication_sequence = 1,
        .generation_plan_sha256 = referenceIdentityRootV1("generation-plan-one"),
        .tenant_scope_sha256 = common.tenant_scope_sha256,
        .metadata_policy_sha256 = common.metadata_policy_sha256,
        .challenge_sha256 = common.challenge_sha256,
        .outputs = outputs,
    };
}

fn referenceSuccessorInputV1(
    previous: PreviousGenerationV1,
    outputs: []const OutputInputV1,
) RegistryInputV1 {
    const common = referenceCommonV1();
    return .{
        .previous = previous,
        .request_epoch = 23,
        .generation = 2,
        .publication_sequence = 2,
        .generation_plan_sha256 = referenceIdentityRootV1("generation-plan-two"),
        .tenant_scope_sha256 = common.tenant_scope_sha256,
        .metadata_policy_sha256 = common.metadata_policy_sha256,
        .challenge_sha256 = common.challenge_sha256,
        .outputs = outputs,
    };
}

fn boundaryOutputV1(
    modality: ModalityV1,
    ordinal: usize,
) OutputInputV1 {
    const ordinal_u64 = std.math.cast(u64, ordinal) orelse unreachable;
    return .{
        .modality = modality,
        .ordinal = ordinal_u64,
        .unit_start = ordinal_u64,
        .unit_count = 1,
        .timeline_start = ordinal_u64,
        .timeline_end = ordinal_u64 + 1,
        .source_bytes = ordinal_u64 + 1,
        .encoding_abi = @intFromEnum(modality),
        .encoded_payload = "bounded-output",
        .artifact_sha256 = referenceFieldRootV1("artifact", modality, ordinal_u64),
        .provenance_sha256 = referenceFieldRootV1("provenance", modality, ordinal_u64),
        .result_sha256 = referenceFieldRootV1("result", modality, ordinal_u64),
        .source_output_sha256 = referenceFieldRootV1("source-output", modality, ordinal_u64),
        .media_object_sha256 = referenceFieldRootV1("media-object", modality, ordinal_u64),
        .state_after_sha256 = referenceFieldRootV1("state-after", modality, ordinal_u64),
        .completion_required = modality != .image,
        .completed = true,
        .completion_sha256 = if (modality == .image)
            [_]u8{0} ** 32
        else
            referenceFieldRootV1("completion", modality, ordinal_u64),
        .encoder_implementation_sha256 = referenceStableRootV1("encoder", modality),
        .format_sha256 = referenceStableRootV1("format", modality),
        .previous_entry_sha256 = [_]u8{0} ** 32,
    };
}

fn expectEncodeFailureV1(
    outputs: []const OutputInputV1,
) !void {
    const testing = std.testing;
    const common = referenceCommonV1();
    var scratch: [16 * 1024]u8 = undefined;
    var archive: [32 * 1024]u8 = undefined;
    if (encodeArchiveV1(
        .{
            .previous = null,
            .request_epoch = 23,
            .generation = 1,
            .publication_sequence = 1,
            .generation_plan_sha256 = referenceIdentityRootV1("generation-plan-one"),
            .tenant_scope_sha256 = common.tenant_scope_sha256,
            .metadata_policy_sha256 = common.metadata_policy_sha256,
            .challenge_sha256 = common.challenge_sha256,
            .outputs = outputs,
        },
        &scratch,
        &archive,
    )) |_| {
        return testing.expect(false);
    } else |_| {}
}

fn expectDecodeFailureV1(
    encoded: []const u8,
    previous: ?PreviousGenerationV1,
) !void {
    const testing = std.testing;
    if (decodeArchiveV1(encoded, previous)) |_| {
        return testing.expect(false);
    } else |_| {}
}

fn digestFromHexV1(encoded: []const u8) !Digest {
    if (encoded.len != 64) return Error.InvalidRegistry;
    var output: Digest = undefined;
    _ = try std.fmt.hexToBytes(&output, encoded);
    return output;
}
