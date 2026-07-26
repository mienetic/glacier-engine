//! Canonical append-only records for external tool handoff.
//!
//! This module has no filesystem, network, process, credential, clock, random,
//! allocator, or dispatcher authority. It defines the portable journal and
//! replay rules needed by a later durable store adapter. A committed dispatch
//! intent is uncertain until an acknowledgement or reconciliation record
//! closes it; only `reconciled_not_applied` returns it to ready, and restart
//! alone never permits a retry. A future adapter must authenticate evidence.

const std = @import("std");
const action = @import("tool_action_contract.zig");

pub const Digest = action.Digest;
pub const zero_digest = action.zero_digest;

pub const header_abi: u64 = 0x4754_4f48_0000_0001;
pub const identity_abi: u64 = 0x4754_4f49_0000_0001;
pub const record_abi: u64 = 0x4754_4f52_0000_0001;
pub const closed_anchor_abi: u64 = 0x4754_4f43_0000_0001;

pub const header_magic = "GTAOBXH1";
pub const record_magic = "GTAOBXR1";
pub const commit_magic = "GTAOBCM1";

pub const header_bytes: usize = 320;
pub const record_body_bytes: usize = 704;
pub const commit_footer_bytes: usize = 48;
pub const record_bytes: usize =
    record_body_bytes + commit_footer_bytes;
pub const maximum_supported_actions: usize = 64;
pub const maximum_supported_records: usize = 256;

pub const capability_stable_idempotency: u64 = 1 << 0;
pub const capability_authoritative_reconciliation: u64 = 1 << 1;
pub const required_capabilities: u64 =
    capability_stable_idempotency |
    capability_authoritative_reconciliation;
pub const allowed_capabilities: u64 = required_capabilities;

const header_domain = "glacier-tool-action-outbox-header-v1\x00";
const action_domain = "glacier-tool-action-outbox-identity-v1\x00";
const remote_request_domain =
    "glacier-tool-action-outbox-remote-request-v1\x00";
const dispatch_request_domain =
    "glacier-tool-action-outbox-dispatch-request-v1\x00";
const record_domain = "glacier-tool-action-outbox-record-v1\x00";
const state_domain = "glacier-tool-action-outbox-state-v1\x00";
const ledger_domain = "glacier-tool-action-outbox-ledger-v1\x00";
const closed_anchor_domain =
    "glacier-tool-action-outbox-closed-anchor-v1\x00";

pub const Error = action.Error || error{
    ArithmeticOverflow,
    CapacityExceeded,
    DuplicateAction,
    DuplicateCompensation,
    DuplicateIdempotencyKey,
    DuplicateRemoteRequest,
    InvalidActionIdentity,
    InvalidClosedAnchor,
    InvalidFooter,
    InvalidHeader,
    InvalidLength,
    InvalidLifecycle,
    InvalidRecord,
    InvalidReservedBytes,
    InvalidSequence,
    InvalidTail,
    MissingParent,
    ParentNotSucceeded,
};

pub const HeaderV1 = struct {
    abi_version: u64 = header_abi,
    flags: u64 = 0,
    outbox_epoch: u64 = 0,
    outbox_id: u64 = 0,
    tenant_key: u64 = 0,
    maximum_actions: u64 = 0,
    maximum_records: u64 = 0,
    maximum_payload_bytes: u64 = 0,
    capability_bits: u64 = 0,
    adapter_descriptor_sha256: Digest = zero_digest,
    payload_store_descriptor_sha256: Digest = zero_digest,
    challenge_sha256: Digest = zero_digest,
    header_sha256: Digest = zero_digest,
};

pub fn makeHeaderV1(
    outbox_epoch: u64,
    outbox_id: u64,
    tenant_key: u64,
    maximum_actions: u64,
    maximum_records: u64,
    maximum_payload_bytes: u64,
    adapter_descriptor_sha256: Digest,
    payload_store_descriptor_sha256: Digest,
    challenge_sha256: Digest,
) Error!HeaderV1 {
    var result: HeaderV1 = .{
        .outbox_epoch = outbox_epoch,
        .outbox_id = outbox_id,
        .tenant_key = tenant_key,
        .maximum_actions = maximum_actions,
        .maximum_records = maximum_records,
        .maximum_payload_bytes = maximum_payload_bytes,
        .capability_bits = required_capabilities,
        .adapter_descriptor_sha256 = adapter_descriptor_sha256,
        .payload_store_descriptor_sha256 = payload_store_descriptor_sha256,
        .challenge_sha256 = challenge_sha256,
    };
    result.header_sha256 = headerSha256V1(result);
    try validateHeaderV1(result);
    return result;
}

pub fn headerSha256V1(value: HeaderV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(header_domain);
    hashU64(&hash, value.abi_version);
    hashU64(&hash, value.flags);
    hashU64(&hash, value.outbox_epoch);
    hashU64(&hash, value.outbox_id);
    hashU64(&hash, value.tenant_key);
    hashU64(&hash, value.maximum_actions);
    hashU64(&hash, value.maximum_records);
    hashU64(&hash, value.maximum_payload_bytes);
    hashU64(&hash, value.capability_bits);
    hash.update(&value.adapter_descriptor_sha256);
    hash.update(&value.payload_store_descriptor_sha256);
    hash.update(&value.challenge_sha256);
    return finish(&hash);
}

pub fn validateHeaderV1(value: HeaderV1) Error!void {
    if (value.abi_version != header_abi or value.flags != 0 or
        value.outbox_epoch == 0 or value.outbox_id == 0 or
        value.tenant_key == 0 or value.maximum_actions == 0 or
        value.maximum_actions > maximum_supported_actions or
        value.maximum_records == 0 or
        value.maximum_records > maximum_supported_records or
        value.maximum_records < value.maximum_actions or
        value.maximum_payload_bytes == 0 or
        value.capability_bits != required_capabilities or
        digestIsZero(value.adapter_descriptor_sha256) or
        digestIsZero(value.payload_store_descriptor_sha256) or
        digestIsZero(value.challenge_sha256) or
        !digestEqual(value.header_sha256, headerSha256V1(value)))
        return Error.InvalidHeader;
}

pub fn encodeHeaderV1(
    value: HeaderV1,
    output: []u8,
) Error![]const u8 {
    try validateHeaderV1(value);
    if (output.len < header_bytes) return Error.InvalidLength;
    var encoded: [header_bytes]u8 = [_]u8{0} ** header_bytes;
    @memcpy(encoded[0..8], header_magic);
    writeU64(&encoded, 8, value.abi_version);
    writeU64(&encoded, 16, header_bytes);
    writeU64(&encoded, 24, value.flags);
    writeU64(&encoded, 32, value.outbox_epoch);
    writeU64(&encoded, 40, value.outbox_id);
    writeU64(&encoded, 48, value.tenant_key);
    writeU64(&encoded, 56, value.maximum_actions);
    writeU64(&encoded, 64, value.maximum_records);
    writeU64(&encoded, 72, value.maximum_payload_bytes);
    writeU64(&encoded, 80, value.capability_bits);
    writeDigest(&encoded, 96, value.adapter_descriptor_sha256);
    writeDigest(
        &encoded,
        128,
        value.payload_store_descriptor_sha256,
    );
    writeDigest(&encoded, 160, value.challenge_sha256);
    writeDigest(&encoded, 192, value.header_sha256);
    @memcpy(output[0..header_bytes], &encoded);
    return output[0..header_bytes];
}

pub fn decodeHeaderV1(
    encoded: []const u8,
    expected_header_sha256: Digest,
) Error!HeaderV1 {
    if (encoded.len != header_bytes) return Error.InvalidLength;
    if (!std.mem.eql(u8, encoded[0..8], header_magic) or
        readU64(encoded, 16) != header_bytes or
        !allZero(encoded[88..96]) or
        !allZero(encoded[224..header_bytes]))
        return Error.InvalidReservedBytes;
    const result: HeaderV1 = .{
        .abi_version = readU64(encoded, 8),
        .flags = readU64(encoded, 24),
        .outbox_epoch = readU64(encoded, 32),
        .outbox_id = readU64(encoded, 40),
        .tenant_key = readU64(encoded, 48),
        .maximum_actions = readU64(encoded, 56),
        .maximum_records = readU64(encoded, 64),
        .maximum_payload_bytes = readU64(encoded, 72),
        .capability_bits = readU64(encoded, 80),
        .adapter_descriptor_sha256 = readDigest(encoded, 96),
        .payload_store_descriptor_sha256 = readDigest(encoded, 128),
        .challenge_sha256 = readDigest(encoded, 160),
        .header_sha256 = readDigest(encoded, 192),
    };
    try validateHeaderV1(result);
    if (!digestEqual(result.header_sha256, expected_header_sha256))
        return Error.InvalidHeader;
    return result;
}

pub const ActionPurposeV1 = enum(u8) {
    primary = 1,
    compensation = 2,
};

pub const ActionIdentityV1 = struct {
    abi_version: u64 = identity_abi,
    purpose: ActionPurposeV1 = .primary,
    action_ordinal: u64 = 0,
    payload_bytes: u64 = 0,
    parent_action_sha256: Digest = zero_digest,
    descriptor_sha256: Digest = zero_digest,
    arguments_sha256: Digest = zero_digest,
    proposal_sha256: Digest = zero_digest,
    policy_sha256: Digest = zero_digest,
    authorization_sha256: Digest = zero_digest,
    idempotency_key_sha256: Digest = zero_digest,
    service_event_sha256: Digest = zero_digest,
    payload_locator_sha256: Digest = zero_digest,
    payload_sha256: Digest = zero_digest,
    action_sha256: Digest = zero_digest,
    stable_remote_request_sha256: Digest = zero_digest,
};

pub fn makeActionIdentityV1(
    header: HeaderV1,
    purpose: ActionPurposeV1,
    parent_action_sha256: Digest,
    descriptor: action.DescriptorV1,
    arguments: action.BoundedAddArgumentsV1,
    proposal: action.ActionProposalV1,
    policy: action.PolicyV1,
    authorization: action.AuthorizationReceiptV1,
    service_event_sha256: Digest,
    payload_locator_sha256: Digest,
    payload_bytes: u64,
    payload_sha256: Digest,
) Error!ActionIdentityV1 {
    try validateHeaderV1(header);
    try action.validateProposalCompositionV1(
        proposal,
        descriptor,
        arguments,
    );
    try action.validateAuthorizationCompositionV1(
        authorization,
        proposal,
        policy,
    );
    if (authorization.kind != .allowed or
        proposal.tenant_key != header.tenant_key or
        policy.tenant_key != header.tenant_key or
        !digestEqual(
            policy.descriptor_sha256,
            descriptor.descriptor_sha256,
        ) or payload_bytes == 0 or
        payload_bytes > header.maximum_payload_bytes or
        digestIsZero(service_event_sha256) or
        digestIsZero(payload_locator_sha256) or
        digestIsZero(payload_sha256) or
        (purpose == .primary and
            !digestIsZero(parent_action_sha256)) or
        (purpose == .compensation and
            digestIsZero(parent_action_sha256)))
        return Error.InvalidActionIdentity;

    var result: ActionIdentityV1 = .{
        .purpose = purpose,
        .action_ordinal = proposal.action_ordinal,
        .payload_bytes = payload_bytes,
        .parent_action_sha256 = parent_action_sha256,
        .descriptor_sha256 = descriptor.descriptor_sha256,
        .arguments_sha256 = arguments.arguments_sha256,
        .proposal_sha256 = proposal.proposal_sha256,
        .policy_sha256 = policy.policy_sha256,
        .authorization_sha256 = authorization.authorization_sha256,
        .idempotency_key_sha256 = proposal.idempotency_key_sha256,
        .service_event_sha256 = service_event_sha256,
        .payload_locator_sha256 = payload_locator_sha256,
        .payload_sha256 = payload_sha256,
    };
    result.action_sha256 = actionIdentitySha256V1(header, result);
    result.stable_remote_request_sha256 =
        stableRemoteRequestSha256V1(header, result);
    try validateActionIdentityV1(header, result);
    return result;
}

pub fn actionIdentitySha256V1(
    header: HeaderV1,
    value: ActionIdentityV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(action_domain);
    hash.update(&header.header_sha256);
    hashU64(&hash, value.abi_version);
    hashU8(&hash, @intFromEnum(value.purpose));
    hashU64(&hash, value.action_ordinal);
    hashU64(&hash, value.payload_bytes);
    hash.update(&value.parent_action_sha256);
    hash.update(&value.descriptor_sha256);
    hash.update(&value.arguments_sha256);
    hash.update(&value.proposal_sha256);
    hash.update(&value.policy_sha256);
    hash.update(&value.authorization_sha256);
    hash.update(&value.idempotency_key_sha256);
    hash.update(&value.service_event_sha256);
    hash.update(&value.payload_locator_sha256);
    hash.update(&value.payload_sha256);
    return finish(&hash);
}

pub fn stableRemoteRequestSha256V1(
    header: HeaderV1,
    value: ActionIdentityV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(remote_request_domain);
    hash.update(&header.header_sha256);
    hash.update(&header.adapter_descriptor_sha256);
    hash.update(&value.action_sha256);
    hash.update(&value.idempotency_key_sha256);
    return finish(&hash);
}

pub fn validateActionIdentityV1(
    header: HeaderV1,
    value: ActionIdentityV1,
) Error!void {
    try validateHeaderV1(header);
    if (value.abi_version != identity_abi or
        value.action_ordinal == 0 or value.payload_bytes == 0 or
        value.payload_bytes > header.maximum_payload_bytes or
        digestIsZero(value.descriptor_sha256) or
        digestIsZero(value.arguments_sha256) or
        digestIsZero(value.proposal_sha256) or
        digestIsZero(value.policy_sha256) or
        digestIsZero(value.authorization_sha256) or
        digestIsZero(value.idempotency_key_sha256) or
        digestIsZero(value.service_event_sha256) or
        digestIsZero(value.payload_locator_sha256) or
        digestIsZero(value.payload_sha256) or
        (value.purpose == .primary and
            !digestIsZero(value.parent_action_sha256)) or
        (value.purpose == .compensation and
            digestIsZero(value.parent_action_sha256)) or
        !digestEqual(
            value.action_sha256,
            actionIdentitySha256V1(header, value),
        ) or !digestEqual(
        value.stable_remote_request_sha256,
        stableRemoteRequestSha256V1(header, value),
    ))
        return Error.InvalidActionIdentity;
}

pub const EventKindV1 = enum(u8) {
    enqueued = 1,
    dispatch_intent = 2,
    ambiguity_observed = 3,
    acknowledged_success = 4,
    acknowledged_failure = 5,
    reconciled_not_applied = 6,
    reconciled_success = 7,
    reconciled_failure = 8,
};

pub const RecordV1 = struct {
    abi_version: u64 = record_abi,
    sequence: u64 = 0,
    kind: EventKindV1 = .enqueued,
    attempt_generation: u64 = 0,
    identity: ActionIdentityV1 = .{},
    previous_action_event_sha256: Digest = zero_digest,
    previous_journal_sha256: Digest = zero_digest,
    dispatch_request_sha256: Digest = zero_digest,
    observation_sha256: Digest = zero_digest,
    result_sha256: Digest = zero_digest,
    record_sha256: Digest = zero_digest,
};

pub fn makeEnqueuedRecordV1(
    header: HeaderV1,
    sequence: u64,
    previous_journal_sha256: Digest,
    identity: ActionIdentityV1,
) Error!RecordV1 {
    try validateActionIdentityV1(header, identity);
    var result: RecordV1 = .{
        .sequence = sequence,
        .kind = .enqueued,
        .identity = identity,
        .previous_journal_sha256 = previous_journal_sha256,
    };
    result.record_sha256 = recordSha256V1(header, result);
    try validateRecordV1(header, result);
    return result;
}

pub fn makeTransitionRecordV1(
    header: HeaderV1,
    sequence: u64,
    previous_journal_sha256: Digest,
    state: ActionStateV1,
    kind: EventKindV1,
    attempt_generation: u64,
    observation_sha256: Digest,
    result_sha256: Digest,
) Error!RecordV1 {
    if (!state.occupied or kind == .enqueued)
        return Error.InvalidLifecycle;
    try validateActionIdentityV1(header, state.identity);
    var dispatch_request_sha256 = state.dispatch_request_sha256;
    switch (kind) {
        .enqueued => unreachable,
        .dispatch_intent => {
            if (state.phase != .ready or
                attempt_generation == 0 or
                attempt_generation !=
                    try checkedAdd(state.attempt_generation, 1) or
                !digestIsZero(observation_sha256) or
                !digestIsZero(result_sha256))
                return Error.InvalidLifecycle;
            dispatch_request_sha256 = dispatchRequestSha256V1(
                header,
                state.identity,
                attempt_generation,
            );
        },
        .ambiguity_observed, .reconciled_not_applied => {
            if (state.phase != .uncertain or
                attempt_generation != state.attempt_generation or
                digestIsZero(state.dispatch_request_sha256) or
                digestIsZero(observation_sha256) or
                !digestIsZero(result_sha256))
                return Error.InvalidLifecycle;
        },
        .acknowledged_success,
        .acknowledged_failure,
        .reconciled_success,
        .reconciled_failure,
        => {
            if (state.phase != .uncertain or
                attempt_generation != state.attempt_generation or
                digestIsZero(state.dispatch_request_sha256) or
                digestIsZero(observation_sha256) or
                digestIsZero(result_sha256))
                return Error.InvalidLifecycle;
        },
    }
    var result: RecordV1 = .{
        .sequence = sequence,
        .kind = kind,
        .attempt_generation = attempt_generation,
        .identity = state.identity,
        .previous_action_event_sha256 = state.last_event_sha256,
        .previous_journal_sha256 = previous_journal_sha256,
        .dispatch_request_sha256 = dispatch_request_sha256,
        .observation_sha256 = observation_sha256,
        .result_sha256 = result_sha256,
    };
    result.record_sha256 = recordSha256V1(header, result);
    try validateRecordV1(header, result);
    return result;
}

pub fn dispatchRequestSha256V1(
    header: HeaderV1,
    identity: ActionIdentityV1,
    attempt_generation: u64,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(dispatch_request_domain);
    hash.update(&header.header_sha256);
    hash.update(&identity.stable_remote_request_sha256);
    hashU64(&hash, attempt_generation);
    return finish(&hash);
}

pub fn recordSha256V1(
    header: HeaderV1,
    value: RecordV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(record_domain);
    hash.update(&header.header_sha256);
    hashU64(&hash, value.abi_version);
    hashU64(&hash, value.sequence);
    hashU8(&hash, @intFromEnum(value.kind));
    hashU64(&hash, value.attempt_generation);
    hashIdentity(&hash, value.identity);
    hash.update(&value.previous_action_event_sha256);
    hash.update(&value.previous_journal_sha256);
    hash.update(&value.dispatch_request_sha256);
    hash.update(&value.observation_sha256);
    hash.update(&value.result_sha256);
    return finish(&hash);
}

pub fn validateRecordV1(
    header: HeaderV1,
    value: RecordV1,
) Error!void {
    try validateActionIdentityV1(header, value.identity);
    if (value.abi_version != record_abi or value.sequence == 0 or
        digestIsZero(value.previous_journal_sha256) or
        !digestEqual(
            value.record_sha256,
            recordSha256V1(header, value),
        ))
        return Error.InvalidRecord;
    switch (value.kind) {
        .enqueued => {
            if (value.attempt_generation != 0 or
                !digestIsZero(value.previous_action_event_sha256) or
                !digestIsZero(value.dispatch_request_sha256) or
                !digestIsZero(value.observation_sha256) or
                !digestIsZero(value.result_sha256))
                return Error.InvalidRecord;
        },
        .dispatch_intent => {
            if (value.attempt_generation == 0 or
                digestIsZero(value.previous_action_event_sha256) or
                digestIsZero(value.dispatch_request_sha256) or
                !digestIsZero(value.observation_sha256) or
                !digestIsZero(value.result_sha256))
                return Error.InvalidRecord;
        },
        .ambiguity_observed, .reconciled_not_applied => {
            if (value.attempt_generation == 0 or
                digestIsZero(value.previous_action_event_sha256) or
                digestIsZero(value.dispatch_request_sha256) or
                digestIsZero(value.observation_sha256) or
                !digestIsZero(value.result_sha256))
                return Error.InvalidRecord;
        },
        .acknowledged_success,
        .acknowledged_failure,
        .reconciled_success,
        .reconciled_failure,
        => {
            if (value.attempt_generation == 0 or
                digestIsZero(value.previous_action_event_sha256) or
                digestIsZero(value.dispatch_request_sha256) or
                digestIsZero(value.observation_sha256) or
                digestIsZero(value.result_sha256))
                return Error.InvalidRecord;
        },
    }
}

pub fn encodeRecordV1(
    header: HeaderV1,
    value: RecordV1,
    output: []u8,
) Error![]const u8 {
    try validateRecordV1(header, value);
    if (output.len < record_bytes) return Error.InvalidLength;
    var encoded: [record_bytes]u8 = [_]u8{0} ** record_bytes;
    @memcpy(encoded[0..8], record_magic);
    writeU64(&encoded, 8, value.abi_version);
    writeU64(&encoded, 16, record_body_bytes);
    writeU64(&encoded, 24, value.sequence);
    writeU64(&encoded, 32, @intFromEnum(value.kind));
    writeU64(&encoded, 40, value.attempt_generation);
    writeU64(&encoded, 48, @intFromEnum(value.identity.purpose));
    writeU64(&encoded, 56, value.identity.action_ordinal);
    writeU64(&encoded, 64, value.identity.payload_bytes);

    const identity_digests = [_]Digest{
        value.identity.parent_action_sha256,
        value.identity.descriptor_sha256,
        value.identity.arguments_sha256,
        value.identity.proposal_sha256,
        value.identity.policy_sha256,
        value.identity.authorization_sha256,
        value.identity.idempotency_key_sha256,
        value.identity.service_event_sha256,
        value.identity.payload_locator_sha256,
        value.identity.payload_sha256,
        value.identity.action_sha256,
        value.identity.stable_remote_request_sha256,
    };
    var offset: usize = 80;
    for (identity_digests) |digest| {
        writeDigest(&encoded, offset, digest);
        offset += 32;
    }
    const event_digests = [_]Digest{
        value.previous_action_event_sha256,
        value.previous_journal_sha256,
        value.dispatch_request_sha256,
        value.observation_sha256,
        value.result_sha256,
        value.record_sha256,
    };
    for (event_digests) |digest| {
        writeDigest(&encoded, offset, digest);
        offset += 32;
    }
    @memcpy(
        encoded[record_body_bytes .. record_body_bytes + 8],
        commit_magic,
    );
    writeU64(&encoded, record_body_bytes + 8, value.sequence);
    writeDigest(
        &encoded,
        record_body_bytes + 16,
        value.record_sha256,
    );
    @memcpy(output[0..record_bytes], &encoded);
    return output[0..record_bytes];
}

pub fn decodeRecordV1(
    header: HeaderV1,
    expected_sequence: u64,
    expected_previous_journal_sha256: Digest,
    encoded: []const u8,
) Error!RecordV1 {
    if (encoded.len != record_bytes) return Error.InvalidLength;
    if (!std.mem.eql(u8, encoded[0..8], record_magic) or
        readU64(encoded, 16) != record_body_bytes or
        !allZero(encoded[72..80]) or
        !allZero(encoded[656..record_body_bytes]))
        return Error.InvalidReservedBytes;
    if (!std.mem.eql(
        u8,
        encoded[record_body_bytes .. record_body_bytes + 8],
        commit_magic,
    ))
        return Error.InvalidFooter;
    const kind_raw = readU64(encoded, 32);
    if (kind_raw > std.math.maxInt(u8))
        return Error.InvalidRecord;
    const kind = std.meta.intToEnum(
        EventKindV1,
        @as(u8, @intCast(kind_raw)),
    ) catch return Error.InvalidRecord;
    const purpose_raw = readU64(encoded, 48);
    if (purpose_raw > std.math.maxInt(u8))
        return Error.InvalidActionIdentity;
    const purpose = std.meta.intToEnum(
        ActionPurposeV1,
        @as(u8, @intCast(purpose_raw)),
    ) catch return Error.InvalidActionIdentity;

    var offset: usize = 80;
    var identity_digests: [12]Digest = undefined;
    for (&identity_digests) |*digest| {
        digest.* = readDigest(encoded, offset);
        offset += 32;
    }
    var event_digests: [6]Digest = undefined;
    for (&event_digests) |*digest| {
        digest.* = readDigest(encoded, offset);
        offset += 32;
    }
    const result: RecordV1 = .{
        .abi_version = readU64(encoded, 8),
        .sequence = readU64(encoded, 24),
        .kind = kind,
        .attempt_generation = readU64(encoded, 40),
        .identity = .{
            .purpose = purpose,
            .action_ordinal = readU64(encoded, 56),
            .payload_bytes = readU64(encoded, 64),
            .parent_action_sha256 = identity_digests[0],
            .descriptor_sha256 = identity_digests[1],
            .arguments_sha256 = identity_digests[2],
            .proposal_sha256 = identity_digests[3],
            .policy_sha256 = identity_digests[4],
            .authorization_sha256 = identity_digests[5],
            .idempotency_key_sha256 = identity_digests[6],
            .service_event_sha256 = identity_digests[7],
            .payload_locator_sha256 = identity_digests[8],
            .payload_sha256 = identity_digests[9],
            .action_sha256 = identity_digests[10],
            .stable_remote_request_sha256 = identity_digests[11],
        },
        .previous_action_event_sha256 = event_digests[0],
        .previous_journal_sha256 = event_digests[1],
        .dispatch_request_sha256 = event_digests[2],
        .observation_sha256 = event_digests[3],
        .result_sha256 = event_digests[4],
        .record_sha256 = event_digests[5],
    };
    try validateRecordV1(header, result);
    if (result.sequence != expected_sequence)
        return Error.InvalidSequence;
    if (!digestEqual(
        result.previous_journal_sha256,
        expected_previous_journal_sha256,
    ))
        return Error.InvalidRecord;
    if (readU64(encoded, record_body_bytes + 8) != result.sequence or
        !digestEqual(
            readDigest(encoded, record_body_bytes + 16),
            result.record_sha256,
        ))
        return Error.InvalidFooter;
    return result;
}

pub const AppendPlanV1 = struct {
    body: []const u8,
    commit_footer: []const u8,
};

pub fn appendPlanV1(
    header: HeaderV1,
    expected_sequence: u64,
    expected_previous_journal_sha256: Digest,
    encoded_record: []const u8,
) Error!AppendPlanV1 {
    _ = try decodeRecordV1(
        header,
        expected_sequence,
        expected_previous_journal_sha256,
        encoded_record,
    );
    return .{
        .body = encoded_record[0..record_body_bytes],
        .commit_footer = encoded_record[record_body_bytes..record_bytes],
    };
}

pub const ActionPhaseV1 = enum(u8) {
    free = 0,
    ready = 1,
    uncertain = 2,
    succeeded = 3,
    failed = 4,
};

pub const ActionStateV1 = struct {
    occupied: bool = false,
    identity: ActionIdentityV1 = .{},
    phase: ActionPhaseV1 = .free,
    attempt_generation: u64 = 0,
    dispatch_request_sha256: Digest = zero_digest,
    observation_sha256: Digest = zero_digest,
    result_sha256: Digest = zero_digest,
    last_event_sha256: Digest = zero_digest,
};

pub const LedgerV1 = struct {
    committed_records: u64 = 0,
    actions_enqueued: u64 = 0,
    primary_actions: u64 = 0,
    compensation_actions: u64 = 0,
    dispatch_intents: u64 = 0,
    safe_retry_dispatches: u64 = 0,
    ambiguity_observations: u64 = 0,
    acknowledged_successes: u64 = 0,
    acknowledged_failures: u64 = 0,
    reconciled_not_applied: u64 = 0,
    reconciled_successes: u64 = 0,
    reconciled_failures: u64 = 0,
    ready_actions: u64 = 0,
    uncertain_actions: u64 = 0,
    succeeded_actions: u64 = 0,
    failed_actions: u64 = 0,
};

pub fn applyRecordV1(
    header: HeaderV1,
    record: RecordV1,
    states: []ActionStateV1,
    ledger: *LedgerV1,
) Error!void {
    try validateRecordV1(header, record);
    const action_capacity: usize =
        @intCast(header.maximum_actions);
    if (states.len < action_capacity)
        return Error.CapacityExceeded;
    const bounded_states = states[0..action_capacity];
    var next_ledger = ledger.*;
    clearPhaseCounts(&next_ledger);
    const expected_sequence =
        try checkedAdd(next_ledger.committed_records, 1);
    if (record.sequence != expected_sequence)
        return Error.InvalidSequence;
    if (expected_sequence > header.maximum_records)
        return Error.CapacityExceeded;
    next_ledger.committed_records = expected_sequence;

    if (record.kind == .enqueued) {
        if (findState(
            bounded_states,
            record.identity.action_sha256,
        ) != null)
            return Error.DuplicateAction;
        for (bounded_states) |state| {
            if (!state.occupied) continue;
            if (digestEqual(
                state.identity.idempotency_key_sha256,
                record.identity.idempotency_key_sha256,
            ))
                return Error.DuplicateIdempotencyKey;
            if (digestEqual(
                state.identity.stable_remote_request_sha256,
                record.identity.stable_remote_request_sha256,
            ))
                return Error.DuplicateRemoteRequest;
            if (record.identity.purpose == .compensation and
                state.identity.purpose == .compensation and
                digestEqual(
                    state.identity.parent_action_sha256,
                    record.identity.parent_action_sha256,
                ))
                return Error.DuplicateCompensation;
        }
        if (record.identity.purpose == .compensation) {
            const parent = findState(
                bounded_states,
                record.identity.parent_action_sha256,
            ) orelse return Error.MissingParent;
            if (parent.identity.purpose != .primary or
                parent.phase != .succeeded)
                return Error.ParentNotSucceeded;
            next_ledger.compensation_actions =
                try checkedAdd(next_ledger.compensation_actions, 1);
        } else {
            next_ledger.primary_actions =
                try checkedAdd(next_ledger.primary_actions, 1);
        }
        const free = findFreeState(bounded_states) orelse
            return Error.CapacityExceeded;
        next_ledger.actions_enqueued =
            try checkedAdd(next_ledger.actions_enqueued, 1);
        free.* = .{
            .occupied = true,
            .identity = record.identity,
            .phase = .ready,
            .last_event_sha256 = record.record_sha256,
        };
        ledger.* = next_ledger;
        return;
    }

    const state = findState(
        bounded_states,
        record.identity.action_sha256,
    ) orelse return Error.InvalidLifecycle;
    if (!std.meta.eql(state.identity, record.identity) or
        !digestEqual(
            state.last_event_sha256,
            record.previous_action_event_sha256,
        ))
        return Error.InvalidLifecycle;

    var next_state = state.*;
    switch (record.kind) {
        .enqueued => unreachable,
        .dispatch_intent => {
            if (state.phase != .ready or
                record.attempt_generation !=
                    try checkedAdd(state.attempt_generation, 1) or
                !digestEqual(
                    record.dispatch_request_sha256,
                    dispatchRequestSha256V1(
                        header,
                        state.identity,
                        record.attempt_generation,
                    ),
                ))
                return Error.InvalidLifecycle;
            if (state.attempt_generation != 0) {
                next_ledger.safe_retry_dispatches = try checkedAdd(
                    next_ledger.safe_retry_dispatches,
                    1,
                );
            }
            next_ledger.dispatch_intents =
                try checkedAdd(next_ledger.dispatch_intents, 1);
            next_state.phase = .uncertain;
            next_state.attempt_generation =
                record.attempt_generation;
            next_state.dispatch_request_sha256 =
                record.dispatch_request_sha256;
            next_state.observation_sha256 = zero_digest;
            next_state.result_sha256 = zero_digest;
        },
        .ambiguity_observed => {
            try requireCurrentAttempt(state.*, record);
            next_ledger.ambiguity_observations = try checkedAdd(
                next_ledger.ambiguity_observations,
                1,
            );
            next_state.observation_sha256 =
                record.observation_sha256;
        },
        .acknowledged_success => {
            try requireCurrentAttempt(state.*, record);
            next_ledger.acknowledged_successes = try checkedAdd(
                next_ledger.acknowledged_successes,
                1,
            );
            closeAction(&next_state, record, .succeeded);
        },
        .acknowledged_failure => {
            try requireCurrentAttempt(state.*, record);
            next_ledger.acknowledged_failures = try checkedAdd(
                next_ledger.acknowledged_failures,
                1,
            );
            closeAction(&next_state, record, .failed);
        },
        .reconciled_not_applied => {
            try requireCurrentAttempt(state.*, record);
            next_ledger.reconciled_not_applied = try checkedAdd(
                next_ledger.reconciled_not_applied,
                1,
            );
            next_state.phase = .ready;
            next_state.dispatch_request_sha256 = zero_digest;
            next_state.observation_sha256 =
                record.observation_sha256;
            next_state.result_sha256 = zero_digest;
        },
        .reconciled_success => {
            try requireCurrentAttempt(state.*, record);
            next_ledger.reconciled_successes = try checkedAdd(
                next_ledger.reconciled_successes,
                1,
            );
            closeAction(&next_state, record, .succeeded);
        },
        .reconciled_failure => {
            try requireCurrentAttempt(state.*, record);
            next_ledger.reconciled_failures = try checkedAdd(
                next_ledger.reconciled_failures,
                1,
            );
            closeAction(&next_state, record, .failed);
        },
    }
    next_state.last_event_sha256 = record.record_sha256;
    state.* = next_state;
    ledger.* = next_ledger;
}

fn requireCurrentAttempt(
    state: ActionStateV1,
    record: RecordV1,
) Error!void {
    if (state.phase != .uncertain or
        record.attempt_generation != state.attempt_generation or
        !digestEqual(
            record.dispatch_request_sha256,
            state.dispatch_request_sha256,
        ))
        return Error.InvalidLifecycle;
}

fn closeAction(
    state: *ActionStateV1,
    record: RecordV1,
    phase: ActionPhaseV1,
) void {
    state.phase = phase;
    state.observation_sha256 = record.observation_sha256;
    state.result_sha256 = record.result_sha256;
}

pub const RecoveryStatusV1 = enum(u8) {
    clean = 1,
    short_body_tail = 2,
    body_without_footer = 3,
    partial_footer_tail = 4,
};

pub const RecoveryV1 = struct {
    header: HeaderV1,
    records: []RecordV1,
    states: []ActionStateV1,
    status: RecoveryStatusV1,
    committed_bytes: usize,
    discarded_tail_bytes: usize,
    final_chain_sha256: Digest,
    state_sha256: Digest,
    ledger: LedgerV1,
};

pub fn recoverV1(
    encoded: []const u8,
    expected_header_sha256: Digest,
    record_storage: []RecordV1,
    state_storage: []ActionStateV1,
) Error!RecoveryV1 {
    if (encoded.len < header_bytes) return Error.InvalidLength;
    const header = try decodeHeaderV1(
        encoded[0..header_bytes],
        expected_header_sha256,
    );
    if (state_storage.len < header.maximum_actions or
        record_storage.len < header.maximum_records)
        return Error.CapacityExceeded;
    zeroRecords(record_storage);
    zeroStates(state_storage);
    errdefer {
        zeroRecords(record_storage);
        zeroStates(state_storage);
    }
    var ledger: LedgerV1 = .{};
    var final_chain_sha256 = header.header_sha256;
    var offset: usize = header_bytes;
    var record_count: usize = 0;
    var status: RecoveryStatusV1 = .clean;
    while (offset < encoded.len) {
        const remaining = encoded.len - offset;
        if (remaining < record_body_bytes) {
            status = .short_body_tail;
            break;
        }
        if (remaining == record_body_bytes) {
            status = .body_without_footer;
            break;
        }
        if (remaining < record_bytes) {
            status = .partial_footer_tail;
            break;
        }
        if (record_count >= header.maximum_records)
            return Error.CapacityExceeded;
        const record = try decodeRecordV1(
            header,
            @as(u64, @intCast(record_count)) + 1,
            final_chain_sha256,
            encoded[offset .. offset + record_bytes],
        );
        try applyRecordV1(header, record, state_storage, &ledger);
        record_storage[record_count] = record;
        record_count += 1;
        offset += record_bytes;
        final_chain_sha256 = record.record_sha256;
    }
    try finalizeLedgerV1(state_storage, &ledger);
    const occupied = occupiedStateCount(state_storage);
    return .{
        .header = header,
        .records = record_storage[0..record_count],
        .states = state_storage[0..occupied],
        .status = status,
        .committed_bytes = offset,
        .discarded_tail_bytes = encoded.len - offset,
        .final_chain_sha256 = final_chain_sha256,
        .state_sha256 = stateSha256V1(
            header,
            state_storage[0..occupied],
            ledger,
        ),
        .ledger = ledger,
    };
}

pub fn finalizeLedgerV1(
    states: []const ActionStateV1,
    ledger: *LedgerV1,
) Error!void {
    clearPhaseCounts(ledger);
    for (states) |state| {
        if (!state.occupied) continue;
        switch (state.phase) {
            .free => return Error.InvalidLifecycle,
            .ready => ledger.ready_actions =
                try checkedAdd(ledger.ready_actions, 1),
            .uncertain => ledger.uncertain_actions =
                try checkedAdd(ledger.uncertain_actions, 1),
            .succeeded => ledger.succeeded_actions =
                try checkedAdd(ledger.succeeded_actions, 1),
            .failed => ledger.failed_actions =
                try checkedAdd(ledger.failed_actions, 1),
        }
    }
    const purpose_total = try checkedAdd(
        ledger.primary_actions,
        ledger.compensation_actions,
    );
    const open_total = try checkedAdd(
        ledger.ready_actions,
        ledger.uncertain_actions,
    );
    const terminal_total = try checkedAdd(
        ledger.succeeded_actions,
        ledger.failed_actions,
    );
    const phase_total = try checkedAdd(open_total, terminal_total);
    if (ledger.actions_enqueued != purpose_total or
        ledger.actions_enqueued != phase_total)
        return Error.InvalidLifecycle;
}

pub fn stateSha256V1(
    header: HeaderV1,
    states: []const ActionStateV1,
    ledger: LedgerV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(state_domain);
    hash.update(&header.header_sha256);
    hashU64(&hash, states.len);
    for (states) |state| {
        hashU8(&hash, @intFromBool(state.occupied));
        hashIdentity(&hash, state.identity);
        hashU8(&hash, @intFromEnum(state.phase));
        hashU64(&hash, state.attempt_generation);
        hash.update(&state.dispatch_request_sha256);
        hash.update(&state.observation_sha256);
        hash.update(&state.result_sha256);
        hash.update(&state.last_event_sha256);
    }
    hashLedger(&hash, ledger);
    return finish(&hash);
}

pub fn ledgerSha256V1(ledger: LedgerV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(ledger_domain);
    hashLedger(&hash, ledger);
    return finish(&hash);
}

pub const ClosedAnchorV1 = struct {
    abi_version: u64 = closed_anchor_abi,
    header_sha256: Digest = zero_digest,
    committed_bytes: u64 = 0,
    committed_records: u64 = 0,
    final_chain_sha256: Digest = zero_digest,
    state_sha256: Digest = zero_digest,
    ledger_sha256: Digest = zero_digest,
    anchor_sha256: Digest = zero_digest,
};

pub fn makeClosedAnchorV1(
    recovery: RecoveryV1,
) Error!ClosedAnchorV1 {
    if (recovery.status != .clean or
        recovery.discarded_tail_bytes != 0 or
        recovery.ledger.ready_actions != 0 or
        recovery.ledger.uncertain_actions != 0)
        return Error.InvalidClosedAnchor;
    var result: ClosedAnchorV1 = .{
        .header_sha256 = recovery.header.header_sha256,
        .committed_bytes = recovery.committed_bytes,
        .committed_records = recovery.ledger.committed_records,
        .final_chain_sha256 = recovery.final_chain_sha256,
        .state_sha256 = recovery.state_sha256,
        .ledger_sha256 = ledgerSha256V1(recovery.ledger),
    };
    result.anchor_sha256 = closedAnchorSha256V1(result);
    return result;
}

pub fn closedAnchorSha256V1(value: ClosedAnchorV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(closed_anchor_domain);
    hashU64(&hash, value.abi_version);
    hash.update(&value.header_sha256);
    hashU64(&hash, value.committed_bytes);
    hashU64(&hash, value.committed_records);
    hash.update(&value.final_chain_sha256);
    hash.update(&value.state_sha256);
    hash.update(&value.ledger_sha256);
    return finish(&hash);
}

pub fn verifyClosedV1(
    recovery: RecoveryV1,
    expected: ClosedAnchorV1,
) Error!void {
    const actual = try makeClosedAnchorV1(recovery);
    if (!std.meta.eql(actual, expected) or
        !digestEqual(
            expected.anchor_sha256,
            closedAnchorSha256V1(expected),
        ))
        return Error.InvalidClosedAnchor;
}

fn findState(
    states: []ActionStateV1,
    action_sha256: Digest,
) ?*ActionStateV1 {
    for (states) |*state| {
        if (state.occupied and
            digestEqual(
                state.identity.action_sha256,
                action_sha256,
            ))
            return state;
    }
    return null;
}

fn findFreeState(states: []ActionStateV1) ?*ActionStateV1 {
    for (states) |*state| {
        if (!state.occupied) return state;
    }
    return null;
}

fn occupiedStateCount(states: []const ActionStateV1) usize {
    var result: usize = 0;
    for (states) |state| {
        if (state.occupied) result += 1;
    }
    return result;
}

fn clearPhaseCounts(ledger: *LedgerV1) void {
    ledger.ready_actions = 0;
    ledger.uncertain_actions = 0;
    ledger.succeeded_actions = 0;
    ledger.failed_actions = 0;
}

fn zeroRecords(records: []RecordV1) void {
    for (records) |*record| record.* = .{};
}

fn zeroStates(states: []ActionStateV1) void {
    for (states) |*state| state.* = .{};
}

fn checkedAdd(left: u64, right: u64) Error!u64 {
    return std.math.add(u64, left, right) catch
        Error.ArithmeticOverflow;
}

fn hashIdentity(
    hash: *std.crypto.hash.sha2.Sha256,
    value: ActionIdentityV1,
) void {
    hashU64(hash, value.abi_version);
    hashU8(hash, @intFromEnum(value.purpose));
    hashU64(hash, value.action_ordinal);
    hashU64(hash, value.payload_bytes);
    hash.update(&value.parent_action_sha256);
    hash.update(&value.descriptor_sha256);
    hash.update(&value.arguments_sha256);
    hash.update(&value.proposal_sha256);
    hash.update(&value.policy_sha256);
    hash.update(&value.authorization_sha256);
    hash.update(&value.idempotency_key_sha256);
    hash.update(&value.service_event_sha256);
    hash.update(&value.payload_locator_sha256);
    hash.update(&value.payload_sha256);
    hash.update(&value.action_sha256);
    hash.update(&value.stable_remote_request_sha256);
}

fn hashLedger(
    hash: *std.crypto.hash.sha2.Sha256,
    ledger: LedgerV1,
) void {
    inline for (std.meta.fields(LedgerV1)) |field| {
        hashU64(hash, @field(ledger, field.name));
    }
}

fn writeU64(output: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(u64, output[offset .. offset + 8][0..8], value, .little);
}

fn readU64(input: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, input[offset .. offset + 8][0..8], .little);
}

fn writeDigest(output: []u8, offset: usize, value: Digest) void {
    @memcpy(output[offset .. offset + 32], &value);
}

fn readDigest(input: []const u8, offset: usize) Digest {
    var result: Digest = undefined;
    @memcpy(&result, input[offset .. offset + 32]);
    return result;
}

fn hashU8(hash: *std.crypto.hash.sha2.Sha256, value: u8) void {
    hash.update(&[_]u8{value});
}

fn hashU64(hash: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, value, .little);
    hash.update(&encoded);
}

fn finish(hash: *std.crypto.hash.sha2.Sha256) Digest {
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

fn digestIsZero(value: Digest) bool {
    return allZero(&value);
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

fn containsPointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => true,
        .array => |info| containsPointer(info.child),
        .optional => |info| containsPointer(info.child),
        .@"struct" => |info| blk: {
            inline for (info.fields) |field| {
                if (containsPointer(field.type)) break :blk true;
            }
            break :blk false;
        },
        .@"union" => |info| blk: {
            inline for (info.fields) |field| {
                if (containsPointer(field.type)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn testDigest(label: []const u8) Digest {
    var result: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(label, &result, .{});
    return result;
}

const TestAction = struct {
    descriptor: action.DescriptorV1,
    arguments: action.BoundedAddArgumentsV1,
    proposal: action.ActionProposalV1,
    policy: action.PolicyV1,
    authorization: action.AuthorizationReceiptV1,
};

fn testHeader() !HeaderV1 {
    return makeHeaderV1(
        7,
        9,
        41,
        4,
        32,
        4096,
        testDigest("adapter"),
        testDigest("payload store"),
        testDigest("outbox challenge"),
    );
}

fn testAction(
    ordinal: u64,
    idempotency_label: []const u8,
    delta: i64,
    before: i64,
) !TestAction {
    const descriptor = try action.makeDescriptorV1(
        3,
        testDigest("tool namespace"),
        testDigest("arguments schema"),
        testDigest("result schema"),
        testDigest("implementation"),
    );
    const arguments = try action.makeBoundedAddArgumentsV1(
        88,
        delta,
    );
    const proposal = try action.makeActionProposalV1(
        41,
        ordinal,
        testDigest("agent request"),
        descriptor,
        arguments,
        testDigest(idempotency_label),
    );
    const policy = try action.makePolicyV1(
        5,
        41,
        true,
        16,
        -100,
        100,
        descriptor,
        testDigest("policy challenge"),
    );
    const authorization = try action.authorizeBoundedAddV1(
        proposal,
        descriptor,
        arguments,
        policy,
        before,
    );
    return .{
        .descriptor = descriptor,
        .arguments = arguments,
        .proposal = proposal,
        .policy = policy,
        .authorization = authorization,
    };
}

fn testIdentity(
    header: HeaderV1,
    purpose: ActionPurposeV1,
    parent: Digest,
    input: TestAction,
    suffix: []const u8,
) !ActionIdentityV1 {
    return makeActionIdentityV1(
        header,
        purpose,
        parent,
        input.descriptor,
        input.arguments,
        input.proposal,
        input.policy,
        input.authorization,
        testDigest("service event"),
        testDigest(suffix),
        32,
        testDigest("payload bytes"),
    );
}

const TestJournal = struct {
    header: HeaderV1,
    bytes: [header_bytes + 16 * record_bytes]u8,
    length: usize,
    states: [4]ActionStateV1,
    ledger: LedgerV1,
    final_chain_sha256: Digest,
    records: [16]RecordV1,
    record_count: usize,

    fn init(header: HeaderV1) !TestJournal {
        var result: TestJournal = .{
            .header = header,
            .bytes = undefined,
            .length = header_bytes,
            .states = [_]ActionStateV1{.{}} ** 4,
            .ledger = .{},
            .final_chain_sha256 = header.header_sha256,
            .records = [_]RecordV1{.{}} ** 16,
            .record_count = 0,
        };
        @memset(&result.bytes, 0);
        _ = try encodeHeaderV1(
            header,
            result.bytes[0..header_bytes],
        );
        return result;
    }

    fn append(self: *TestJournal, record: RecordV1) !void {
        try applyRecordV1(
            self.header,
            record,
            &self.states,
            &self.ledger,
        );
        _ = try encodeRecordV1(
            self.header,
            record,
            self.bytes[self.length .. self.length + record_bytes],
        );
        self.records[self.record_count] = record;
        self.record_count += 1;
        self.length += record_bytes;
        self.final_chain_sha256 = record.record_sha256;
    }

    fn enqueue(
        self: *TestJournal,
        identity: ActionIdentityV1,
    ) !void {
        try self.append(try makeEnqueuedRecordV1(
            self.header,
            self.record_count + 1,
            self.final_chain_sha256,
            identity,
        ));
    }

    fn transition(
        self: *TestJournal,
        action_sha256: Digest,
        kind: EventKindV1,
        attempt_generation: u64,
        observation_sha256: Digest,
        result_sha256: Digest,
    ) !void {
        const state = findState(
            &self.states,
            action_sha256,
        ) orelse return Error.InvalidLifecycle;
        try self.append(try makeTransitionRecordV1(
            self.header,
            self.record_count + 1,
            self.final_chain_sha256,
            state.*,
            kind,
            attempt_generation,
            observation_sha256,
            result_sha256,
        ));
    }
};

fn referenceJournal() !TestJournal {
    const header = try testHeader();
    const primary_input = try testAction(1, "primary key", 3, 0);
    const primary = try testIdentity(
        header,
        .primary,
        zero_digest,
        primary_input,
        "primary payload",
    );
    var journal = try TestJournal.init(header);
    try journal.enqueue(primary);
    try journal.transition(
        primary.action_sha256,
        .dispatch_intent,
        1,
        zero_digest,
        zero_digest,
    );
    try journal.transition(
        primary.action_sha256,
        .ambiguity_observed,
        1,
        testDigest("timeout observation"),
        zero_digest,
    );
    try journal.transition(
        primary.action_sha256,
        .reconciled_not_applied,
        1,
        testDigest("not applied evidence"),
        zero_digest,
    );
    try journal.transition(
        primary.action_sha256,
        .dispatch_intent,
        2,
        zero_digest,
        zero_digest,
    );
    try journal.transition(
        primary.action_sha256,
        .acknowledged_success,
        2,
        testDigest("success acknowledgement"),
        testDigest("primary result"),
    );

    const compensation_input =
        try testAction(2, "compensation key", -3, 3);
    const compensation = try testIdentity(
        header,
        .compensation,
        primary.action_sha256,
        compensation_input,
        "compensation payload",
    );
    try journal.enqueue(compensation);
    try journal.transition(
        compensation.action_sha256,
        .dispatch_intent,
        1,
        zero_digest,
        zero_digest,
    );
    try journal.transition(
        compensation.action_sha256,
        .ambiguity_observed,
        1,
        testDigest("compensation timeout"),
        zero_digest,
    );
    try journal.transition(
        compensation.action_sha256,
        .reconciled_success,
        1,
        testDigest("compensation status"),
        testDigest("compensation result"),
    );
    try finalizeLedgerV1(&journal.states, &journal.ledger);
    return journal;
}

test "action outbox replay holds ambiguity until authoritative resolution" {
    var journal = try referenceJournal();
    var records: [32]RecordV1 = [_]RecordV1{.{}} ** 32;
    var states: [4]ActionStateV1 =
        [_]ActionStateV1{.{}} ** 4;
    const recovered = try recoverV1(
        journal.bytes[0..journal.length],
        journal.header.header_sha256,
        &records,
        &states,
    );
    try std.testing.expectEqual(RecoveryStatusV1.clean, recovered.status);
    try std.testing.expectEqual(@as(u64, 10), recovered.ledger.committed_records);
    try std.testing.expectEqual(@as(u64, 2), recovered.ledger.actions_enqueued);
    try std.testing.expectEqual(@as(u64, 1), recovered.ledger.primary_actions);
    try std.testing.expectEqual(@as(u64, 1), recovered.ledger.compensation_actions);
    try std.testing.expectEqual(@as(u64, 3), recovered.ledger.dispatch_intents);
    try std.testing.expectEqual(@as(u64, 1), recovered.ledger.safe_retry_dispatches);
    try std.testing.expectEqual(@as(u64, 2), recovered.ledger.ambiguity_observations);
    try std.testing.expectEqual(@as(u64, 1), recovered.ledger.acknowledged_successes);
    try std.testing.expectEqual(@as(u64, 1), recovered.ledger.reconciled_not_applied);
    try std.testing.expectEqual(@as(u64, 1), recovered.ledger.reconciled_successes);
    try std.testing.expectEqual(@as(u64, 2), recovered.ledger.succeeded_actions);
    try std.testing.expectEqual(@as(u64, 0), recovered.ledger.ready_actions);
    try std.testing.expectEqual(@as(u64, 0), recovered.ledger.uncertain_actions);
    try std.testing.expect(digestEqual(
        journal.records[1].identity.stable_remote_request_sha256,
        journal.records[4].identity.stable_remote_request_sha256,
    ));
    try std.testing.expect(!digestEqual(
        journal.records[1].dispatch_request_sha256,
        journal.records[4].dispatch_request_sha256,
    ));
    try std.testing.expect(!digestEqual(
        recovered.states[0].identity.idempotency_key_sha256,
        recovered.states[1].identity.idempotency_key_sha256,
    ));
    const anchor = try makeClosedAnchorV1(recovered);
    try verifyClosedV1(recovered, anchor);
}

test "uncertain dispatch cannot retry and compensation requires succeeded parent" {
    const header = try testHeader();
    const primary_input = try testAction(1, "primary key", 3, 0);
    const primary = try testIdentity(
        header,
        .primary,
        zero_digest,
        primary_input,
        "primary payload",
    );
    var journal = try TestJournal.init(header);
    try journal.enqueue(primary);
    try journal.transition(
        primary.action_sha256,
        .dispatch_intent,
        1,
        zero_digest,
        zero_digest,
    );
    const uncertain = findState(
        &journal.states,
        primary.action_sha256,
    ).?.*;
    try std.testing.expectError(
        Error.InvalidLifecycle,
        makeTransitionRecordV1(
            header,
            3,
            journal.final_chain_sha256,
            uncertain,
            .dispatch_intent,
            2,
            zero_digest,
            zero_digest,
        ),
    );

    const compensation_input =
        try testAction(2, "compensation key", -3, 3);
    const compensation = try testIdentity(
        header,
        .compensation,
        primary.action_sha256,
        compensation_input,
        "compensation payload",
    );
    const record = try makeEnqueuedRecordV1(
        header,
        3,
        journal.final_chain_sha256,
        compensation,
    );
    try std.testing.expectError(
        Error.ParentNotSucceeded,
        applyRecordV1(
            header,
            record,
            &journal.states,
            &journal.ledger,
        ),
    );
}

test "duplicate identities and idempotency keys fail before mutation" {
    const header = try testHeader();
    const first_input = try testAction(1, "shared key", 3, 0);
    const first = try testIdentity(
        header,
        .primary,
        zero_digest,
        first_input,
        "first payload",
    );
    var journal = try TestJournal.init(header);
    try journal.enqueue(first);
    const before_states = journal.states;
    const before_ledger = journal.ledger;
    const duplicate = try makeEnqueuedRecordV1(
        header,
        2,
        journal.final_chain_sha256,
        first,
    );
    try std.testing.expectError(
        Error.DuplicateAction,
        applyRecordV1(
            header,
            duplicate,
            &journal.states,
            &journal.ledger,
        ),
    );
    try std.testing.expectEqualDeep(before_states, journal.states);
    try std.testing.expectEqualDeep(before_ledger, journal.ledger);

    const second_input = try testAction(2, "shared key", 4, 0);
    const second = try testIdentity(
        header,
        .primary,
        zero_digest,
        second_input,
        "second payload",
    );
    const same_key = try makeEnqueuedRecordV1(
        header,
        2,
        journal.final_chain_sha256,
        second,
    );
    try std.testing.expectError(
        Error.DuplicateIdempotencyKey,
        applyRecordV1(
            header,
            same_key,
            &journal.states,
            &journal.ledger,
        ),
    );
    try std.testing.expectEqualDeep(before_states, journal.states);
    try std.testing.expectEqualDeep(before_ledger, journal.ledger);
}

test "declared capacities bound oversized caller storage" {
    const header = try makeHeaderV1(
        7,
        9,
        41,
        1,
        2,
        4096,
        testDigest("adapter"),
        testDigest("payload store"),
        testDigest("bounded capacity challenge"),
    );
    const first_input = try testAction(1, "first bounded key", 3, 0);
    const first = try testIdentity(
        header,
        .primary,
        zero_digest,
        first_input,
        "first bounded payload",
    );
    const second_input = try testAction(2, "second bounded key", 4, 0);
    const second = try testIdentity(
        header,
        .primary,
        zero_digest,
        second_input,
        "second bounded payload",
    );
    var states: [4]ActionStateV1 =
        [_]ActionStateV1{.{}} ** 4;
    var ledger: LedgerV1 = .{};
    const first_record = try makeEnqueuedRecordV1(
        header,
        1,
        header.header_sha256,
        first,
    );
    try applyRecordV1(
        header,
        first_record,
        &states,
        &ledger,
    );

    const before_action_overflow = states;
    const before_action_ledger = ledger;
    const second_record = try makeEnqueuedRecordV1(
        header,
        2,
        first_record.record_sha256,
        second,
    );
    try std.testing.expectError(
        Error.CapacityExceeded,
        applyRecordV1(
            header,
            second_record,
            &states,
            &ledger,
        ),
    );
    try std.testing.expectEqualDeep(
        before_action_overflow,
        states,
    );
    try std.testing.expectEqualDeep(
        before_action_ledger,
        ledger,
    );

    const first_state = findState(
        states[0..1],
        first.action_sha256,
    ).?.*;
    const dispatch = try makeTransitionRecordV1(
        header,
        2,
        first_record.record_sha256,
        first_state,
        .dispatch_intent,
        1,
        zero_digest,
        zero_digest,
    );
    try applyRecordV1(
        header,
        dispatch,
        &states,
        &ledger,
    );

    const before_record_overflow = states;
    const before_record_ledger = ledger;
    const uncertain = findState(
        states[0..1],
        first.action_sha256,
    ).?.*;
    const overflow = try makeTransitionRecordV1(
        header,
        3,
        dispatch.record_sha256,
        uncertain,
        .ambiguity_observed,
        1,
        testDigest("record capacity observation"),
        zero_digest,
    );
    try std.testing.expectError(
        Error.CapacityExceeded,
        applyRecordV1(
            header,
            overflow,
            &states,
            &ledger,
        ),
    );
    try std.testing.expectEqualDeep(
        before_record_overflow,
        states,
    );
    try std.testing.expectEqualDeep(
        before_record_ledger,
        ledger,
    );
}

test "one primary action accepts at most one compensation child" {
    var journal = try referenceJournal();
    const second_input = try testAction(
        3,
        "second compensation key",
        -2,
        3,
    );
    const second = try testIdentity(
        journal.header,
        .compensation,
        journal.records[0].identity.action_sha256,
        second_input,
        "second compensation payload",
    );
    const record = try makeEnqueuedRecordV1(
        journal.header,
        journal.record_count + 1,
        journal.final_chain_sha256,
        second,
    );
    const before_states = journal.states;
    const before_ledger = journal.ledger;
    try std.testing.expectError(
        Error.DuplicateCompensation,
        applyRecordV1(
            journal.header,
            record,
            &journal.states,
            &journal.ledger,
        ),
    );
    try std.testing.expectEqualDeep(before_states, journal.states);
    try std.testing.expectEqualDeep(before_ledger, journal.ledger);
}

test "failure records close actions and terminal phases never reopen" {
    const header = try testHeader();
    const acknowledged_input = try testAction(
        1,
        "acknowledged failure key",
        3,
        0,
    );
    const acknowledged = try testIdentity(
        header,
        .primary,
        zero_digest,
        acknowledged_input,
        "acknowledged failure payload",
    );
    var journal = try TestJournal.init(header);
    try journal.enqueue(acknowledged);
    try journal.transition(
        acknowledged.action_sha256,
        .dispatch_intent,
        1,
        zero_digest,
        zero_digest,
    );
    try journal.transition(
        acknowledged.action_sha256,
        .acknowledged_failure,
        1,
        testDigest("failure acknowledgement"),
        testDigest("failure result"),
    );
    const failed = findState(
        &journal.states,
        acknowledged.action_sha256,
    ).?.*;
    try std.testing.expectEqual(ActionPhaseV1.failed, failed.phase);
    try std.testing.expectError(
        Error.InvalidLifecycle,
        makeTransitionRecordV1(
            header,
            journal.record_count + 1,
            journal.final_chain_sha256,
            failed,
            .dispatch_intent,
            2,
            zero_digest,
            zero_digest,
        ),
    );

    const reconciled_input = try testAction(
        2,
        "reconciled failure key",
        4,
        0,
    );
    const reconciled = try testIdentity(
        header,
        .primary,
        zero_digest,
        reconciled_input,
        "reconciled failure payload",
    );
    try journal.enqueue(reconciled);
    try journal.transition(
        reconciled.action_sha256,
        .dispatch_intent,
        1,
        zero_digest,
        zero_digest,
    );
    try journal.transition(
        reconciled.action_sha256,
        .reconciled_failure,
        1,
        testDigest("reconciled failure observation"),
        testDigest("reconciled failure result"),
    );
    try finalizeLedgerV1(&journal.states, &journal.ledger);
    try std.testing.expectEqual(
        @as(u64, 1),
        journal.ledger.acknowledged_failures,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        journal.ledger.reconciled_failures,
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        journal.ledger.failed_actions,
    );
}

test "record mutation and every incomplete tail boundary fail closed" {
    var journal = try referenceJournal();
    var mutated: [record_bytes]u8 = undefined;
    const source = journal.bytes[header_bytes .. header_bytes + record_bytes];
    const append_plan = try appendPlanV1(
        journal.header,
        1,
        journal.header.header_sha256,
        source,
    );
    try std.testing.expectEqual(
        record_body_bytes,
        append_plan.body.len,
    );
    try std.testing.expectEqual(
        commit_footer_bytes,
        append_plan.commit_footer.len,
    );
    @memcpy(&mutated, source);
    mutated[72] = 1;
    try std.testing.expectError(
        Error.InvalidReservedBytes,
        appendPlanV1(
            journal.header,
            1,
            journal.header.header_sha256,
            &mutated,
        ),
    );
    for (0..record_bytes) |index| {
        @memcpy(&mutated, source);
        mutated[index] ^= 1;
        if (decodeRecordV1(
            journal.header,
            1,
            journal.header.header_sha256,
            &mutated,
        )) |_| {
            return error.TestUnexpectedResult;
        } else |_| {}
    }

    var records: [32]RecordV1 = [_]RecordV1{.{}} ** 32;
    var states: [4]ActionStateV1 =
        [_]ActionStateV1{.{}} ** 4;
    const final_record_start = journal.length - record_bytes;
    for (final_record_start..journal.length) |cut| {
        const recovered = try recoverV1(
            journal.bytes[0..cut],
            journal.header.header_sha256,
            &records,
            &states,
        );
        const tail = cut - final_record_start;
        const expected: RecoveryStatusV1 =
            if (tail == 0)
                .clean
            else if (tail < record_body_bytes)
                .short_body_tail
            else if (tail == record_body_bytes)
                .body_without_footer
            else
                .partial_footer_tail;
        try std.testing.expectEqual(expected, recovered.status);
        try std.testing.expectEqual(
            final_record_start,
            recovered.committed_bytes,
        );
        try std.testing.expectEqual(
            tail,
            recovered.discarded_tail_bytes,
        );
        try std.testing.expectEqual(@as(u64, 9), recovered.ledger.committed_records);
        try std.testing.expectEqual(@as(u64, 1), recovered.ledger.uncertain_actions);
    }
}

test "portable outbox records contain no pointers" {
    try std.testing.expect(!containsPointer(HeaderV1));
    try std.testing.expect(!containsPointer(ActionIdentityV1));
    try std.testing.expect(!containsPointer(RecordV1));
    try std.testing.expect(!containsPointer(ActionStateV1));
    try std.testing.expect(!containsPointer(LedgerV1));
    try std.testing.expect(!containsPointer(ClosedAnchorV1));
    try std.testing.expectEqual(@as(usize, 320), header_bytes);
    try std.testing.expectEqual(@as(usize, 704), record_body_bytes);
    try std.testing.expectEqual(@as(usize, 48), commit_footer_bytes);
}
