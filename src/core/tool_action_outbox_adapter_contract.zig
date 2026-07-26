//! Credential-free contract between ActionOutbox state and a trusted adapter.
//!
//! Portable values in this module contain no pointers, credential material,
//! transport handles, payload bytes, clocks, or host paths. The process-local
//! `AdapterV1` vtable is deliberately not portable: its opaque context is where
//! an implementation may hold credentials and other private authority.
//!
//! The portable constructors and callback wrappers validate integrity and
//! composition, but cannot prove filesystem durability by themselves. The
//! trusted dispatch driver supplies that ordering boundary. On that path, a
//! dispatch response can close only its exact committed intent. A separate
//! status query may authorize a retry only when the authority atomically
//! reports `not_applied_fenced` through the current attempt generation.
//! Absence, timeout, pending work, unknown state, or a dispatch-path rejection
//! never authorizes retry.

const std = @import("std");
const outbox = @import("tool_action_outbox_record.zig");

pub const Digest = outbox.Digest;
pub const zero_digest = outbox.zero_digest;

pub const descriptor_abi: u64 = 0x4754_4144_0000_0001;
pub const dispatch_request_abi: u64 = 0x4754_4451_0000_0001;
pub const dispatch_evidence_abi: u64 = 0x4754_4445_0000_0001;
pub const status_request_abi: u64 = 0x4754_5351_0000_0001;
pub const status_evidence_abi: u64 = 0x4754_5345_0000_0001;
pub const reference_report_abi: u64 = 0x4754_4152_0000_0001;

pub const capability_stable_idempotency: u64 = 1 << 0;
pub const capability_authoritative_status: u64 = 1 << 1;
pub const capability_generation_fence: u64 = 1 << 2;
pub const capability_exact_terminal_replay: u64 = 1 << 3;
pub const required_capabilities: u64 =
    capability_stable_idempotency |
    capability_authoritative_status |
    capability_generation_fence |
    capability_exact_terminal_replay;
pub const allowed_capabilities: u64 = required_capabilities;

const descriptor_domain =
    "glacier-action-outbox-adapter-descriptor-v1\x00";
const dispatch_request_domain =
    "glacier-action-outbox-adapter-dispatch-request-v1\x00";
const dispatch_evidence_domain =
    "glacier-action-outbox-adapter-dispatch-evidence-v1\x00";
const status_request_domain =
    "glacier-action-outbox-adapter-status-request-v1\x00";
const status_evidence_domain =
    "glacier-action-outbox-adapter-status-evidence-v1\x00";
const reference_report_domain =
    "glacier-action-outbox-adapter-reference-report-v1\x00";

pub const Error = outbox.Error || error{
    InvalidAdapter,
    InvalidBinding,
    InvalidDescriptor,
    InvalidDispatchEvidence,
    InvalidDispatchRequest,
    InvalidReferenceReport,
    InvalidStatusEvidence,
    InvalidStatusRequest,
};

pub const CallbackError = error{
    AuthorityUnavailable,
    CapacityExceeded,
    CredentialRejected,
    RequestRejected,
};

pub const RuntimeError = Error || CallbackError;

/// Public identity of one adapter authority epoch. The namespace and schema
/// roots are public labels and must never be derived from bearer credentials.
pub const DescriptorV1 = struct {
    abi_version: u64 = descriptor_abi,
    adapter_abi: u64 = 0,
    authority_epoch: u64 = 0,
    capability_bits: u64 = required_capabilities,
    authority_namespace_sha256: Digest = zero_digest,
    request_schema_sha256: Digest = zero_digest,
    result_schema_sha256: Digest = zero_digest,
    descriptor_sha256: Digest = zero_digest,
};

pub fn makeDescriptorV1(
    adapter_abi: u64,
    authority_epoch: u64,
    authority_namespace_sha256: Digest,
    request_schema_sha256: Digest,
    result_schema_sha256: Digest,
) Error!DescriptorV1 {
    var result: DescriptorV1 = .{
        .adapter_abi = adapter_abi,
        .authority_epoch = authority_epoch,
        .authority_namespace_sha256 = authority_namespace_sha256,
        .request_schema_sha256 = request_schema_sha256,
        .result_schema_sha256 = result_schema_sha256,
    };
    result.descriptor_sha256 = descriptorSha256V1(result);
    try validateDescriptorV1(result);
    return result;
}

pub fn descriptorSha256V1(value: DescriptorV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(descriptor_domain);
    hashU64(&hash, value.abi_version);
    hashU64(&hash, value.adapter_abi);
    hashU64(&hash, value.authority_epoch);
    hashU64(&hash, value.capability_bits);
    hash.update(&value.authority_namespace_sha256);
    hash.update(&value.request_schema_sha256);
    hash.update(&value.result_schema_sha256);
    return finish(&hash);
}

pub fn validateDescriptorV1(value: DescriptorV1) Error!void {
    if (value.abi_version != descriptor_abi or
        value.adapter_abi == 0 or value.authority_epoch == 0 or
        value.capability_bits != required_capabilities or
        digestIsZero(value.authority_namespace_sha256) or
        digestIsZero(value.request_schema_sha256) or
        digestIsZero(value.result_schema_sha256) or
        !digestEqual(
            value.descriptor_sha256,
            descriptorSha256V1(value),
        ))
        return Error.InvalidDescriptor;
}

pub fn validateDescriptorHeaderBindingV1(
    descriptor: DescriptorV1,
    header: outbox.HeaderV1,
) Error!void {
    try validateDescriptorV1(descriptor);
    try outbox.validateHeaderV1(header);
    if (!digestEqual(
        descriptor.descriptor_sha256,
        header.adapter_descriptor_sha256,
    ))
        return Error.InvalidBinding;
}

/// Exact credential-free envelope intended for one committed dispatch intent.
/// This value validates record composition, not the store commit itself.
pub const DispatchRequestV1 = struct {
    abi_version: u64 = dispatch_request_abi,
    header_sha256: Digest = zero_digest,
    adapter_descriptor_sha256: Digest = zero_digest,
    action_sha256: Digest = zero_digest,
    stable_remote_request_sha256: Digest = zero_digest,
    idempotency_key_sha256: Digest = zero_digest,
    dispatch_request_sha256: Digest = zero_digest,
    attempt_generation: u64 = 0,
    intent_record_sha256: Digest = zero_digest,
    payload_locator_sha256: Digest = zero_digest,
    payload_bytes: u64 = 0,
    payload_sha256: Digest = zero_digest,
    request_sha256: Digest = zero_digest,
};

pub fn makeDispatchRequestV1(
    descriptor: DescriptorV1,
    header: outbox.HeaderV1,
    intent: outbox.RecordV1,
) Error!DispatchRequestV1 {
    try validateDescriptorHeaderBindingV1(descriptor, header);
    try outbox.validateRecordV1(header, intent);
    if (intent.kind != .dispatch_intent)
        return Error.InvalidDispatchRequest;
    var result: DispatchRequestV1 = .{
        .header_sha256 = header.header_sha256,
        .adapter_descriptor_sha256 = descriptor.descriptor_sha256,
        .action_sha256 = intent.identity.action_sha256,
        .stable_remote_request_sha256 = intent.identity.stable_remote_request_sha256,
        .idempotency_key_sha256 = intent.identity.idempotency_key_sha256,
        .dispatch_request_sha256 = intent.dispatch_request_sha256,
        .attempt_generation = intent.attempt_generation,
        .intent_record_sha256 = intent.record_sha256,
        .payload_locator_sha256 = intent.identity.payload_locator_sha256,
        .payload_bytes = intent.identity.payload_bytes,
        .payload_sha256 = intent.identity.payload_sha256,
    };
    result.request_sha256 = dispatchRequestSha256V1(result);
    try validateDispatchRequestCompositionV1(
        descriptor,
        header,
        intent,
        result,
    );
    return result;
}

pub fn dispatchRequestSha256V1(value: DispatchRequestV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(dispatch_request_domain);
    hashU64(&hash, value.abi_version);
    hash.update(&value.header_sha256);
    hash.update(&value.adapter_descriptor_sha256);
    hash.update(&value.action_sha256);
    hash.update(&value.stable_remote_request_sha256);
    hash.update(&value.idempotency_key_sha256);
    hash.update(&value.dispatch_request_sha256);
    hashU64(&hash, value.attempt_generation);
    hash.update(&value.intent_record_sha256);
    hash.update(&value.payload_locator_sha256);
    hashU64(&hash, value.payload_bytes);
    hash.update(&value.payload_sha256);
    return finish(&hash);
}

pub fn validateDispatchRequestV1(
    value: DispatchRequestV1,
) Error!void {
    if (value.abi_version != dispatch_request_abi or
        value.attempt_generation == 0 or value.payload_bytes == 0 or
        digestIsZero(value.header_sha256) or
        digestIsZero(value.adapter_descriptor_sha256) or
        digestIsZero(value.action_sha256) or
        digestIsZero(value.stable_remote_request_sha256) or
        digestIsZero(value.idempotency_key_sha256) or
        digestIsZero(value.dispatch_request_sha256) or
        digestIsZero(value.intent_record_sha256) or
        digestIsZero(value.payload_locator_sha256) or
        digestIsZero(value.payload_sha256) or
        !digestEqual(
            value.request_sha256,
            dispatchRequestSha256V1(value),
        ))
        return Error.InvalidDispatchRequest;
}

pub fn validateDispatchRequestCompositionV1(
    descriptor: DescriptorV1,
    header: outbox.HeaderV1,
    intent: outbox.RecordV1,
    value: DispatchRequestV1,
) Error!void {
    try validateDescriptorHeaderBindingV1(descriptor, header);
    try outbox.validateRecordV1(header, intent);
    try validateDispatchRequestV1(value);
    if (intent.kind != .dispatch_intent or
        !digestEqual(value.header_sha256, header.header_sha256) or
        !digestEqual(
            value.adapter_descriptor_sha256,
            descriptor.descriptor_sha256,
        ) or
        !digestEqual(
            value.action_sha256,
            intent.identity.action_sha256,
        ) or
        !digestEqual(
            value.stable_remote_request_sha256,
            intent.identity.stable_remote_request_sha256,
        ) or
        !digestEqual(
            value.idempotency_key_sha256,
            intent.identity.idempotency_key_sha256,
        ) or
        !digestEqual(
            value.dispatch_request_sha256,
            intent.dispatch_request_sha256,
        ) or value.attempt_generation != intent.attempt_generation or
        !digestEqual(
            value.intent_record_sha256,
            intent.record_sha256,
        ) or
        !digestEqual(
            value.payload_locator_sha256,
            intent.identity.payload_locator_sha256,
        ) or value.payload_bytes != intent.identity.payload_bytes or
        !digestEqual(
            value.payload_sha256,
            intent.identity.payload_sha256,
        ))
        return Error.InvalidBinding;
}

pub const DispatchDispositionV1 = enum(u8) {
    succeeded = 1,
    terminal_failure = 2,
    indeterminate = 3,
    rejected_stale_generation = 4,
};

/// Adapter-verified dispatch-path evidence. Integrity roots do not by
/// themselves establish origin; authority comes from the trusted callback.
pub const DispatchEvidenceV1 = struct {
    abi_version: u64 = dispatch_evidence_abi,
    request_sha256: Digest = zero_digest,
    adapter_descriptor_sha256: Digest = zero_digest,
    authority_epoch: u64 = 0,
    authority_revision: u64 = 0,
    disposition: DispatchDispositionV1 = .indeterminate,
    service_event_sha256: Digest = zero_digest,
    result_sha256: Digest = zero_digest,
    evidence_sha256: Digest = zero_digest,
};

pub fn makeDispatchEvidenceV1(
    descriptor: DescriptorV1,
    request: DispatchRequestV1,
    authority_revision: u64,
    disposition: DispatchDispositionV1,
    service_event_sha256: Digest,
    result_sha256: Digest,
) Error!DispatchEvidenceV1 {
    try validateDescriptorV1(descriptor);
    try validateDispatchRequestV1(request);
    if (!digestEqual(
        descriptor.descriptor_sha256,
        request.adapter_descriptor_sha256,
    ))
        return Error.InvalidBinding;
    var result: DispatchEvidenceV1 = .{
        .request_sha256 = request.request_sha256,
        .adapter_descriptor_sha256 = descriptor.descriptor_sha256,
        .authority_epoch = descriptor.authority_epoch,
        .authority_revision = authority_revision,
        .disposition = disposition,
        .service_event_sha256 = service_event_sha256,
        .result_sha256 = result_sha256,
    };
    result.evidence_sha256 = dispatchEvidenceSha256V1(result);
    try validateDispatchEvidenceV1(descriptor, request, result);
    return result;
}

pub fn dispatchEvidenceSha256V1(
    value: DispatchEvidenceV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(dispatch_evidence_domain);
    hashU64(&hash, value.abi_version);
    hash.update(&value.request_sha256);
    hash.update(&value.adapter_descriptor_sha256);
    hashU64(&hash, value.authority_epoch);
    hashU64(&hash, value.authority_revision);
    hashU8(&hash, @intFromEnum(value.disposition));
    hash.update(&value.service_event_sha256);
    hash.update(&value.result_sha256);
    return finish(&hash);
}

pub fn validateDispatchEvidenceV1(
    descriptor: DescriptorV1,
    request: DispatchRequestV1,
    value: DispatchEvidenceV1,
) Error!void {
    try validateDescriptorV1(descriptor);
    try validateDispatchRequestV1(request);
    const terminal =
        value.disposition == .succeeded or
        value.disposition == .terminal_failure;
    if (value.abi_version != dispatch_evidence_abi or
        value.authority_epoch != descriptor.authority_epoch or
        value.authority_revision == 0 or
        digestIsZero(value.service_event_sha256) or
        (terminal and digestIsZero(value.result_sha256)) or
        (!terminal and !digestIsZero(value.result_sha256)) or
        !digestEqual(value.request_sha256, request.request_sha256) or
        !digestEqual(
            request.adapter_descriptor_sha256,
            descriptor.descriptor_sha256,
        ) or
        !digestEqual(
            value.adapter_descriptor_sha256,
            descriptor.descriptor_sha256,
        ) or
        !digestEqual(
            value.evidence_sha256,
            dispatchEvidenceSha256V1(value),
        ))
        return Error.InvalidDispatchEvidence;
}

/// Separate authoritative lookup for the exact currently uncertain attempt.
pub const StatusRequestV1 = struct {
    abi_version: u64 = status_request_abi,
    header_sha256: Digest = zero_digest,
    adapter_descriptor_sha256: Digest = zero_digest,
    action_sha256: Digest = zero_digest,
    stable_remote_request_sha256: Digest = zero_digest,
    idempotency_key_sha256: Digest = zero_digest,
    dispatch_request_sha256: Digest = zero_digest,
    attempt_generation: u64 = 0,
    current_action_event_sha256: Digest = zero_digest,
    query_ordinal: u64 = 0,
    request_sha256: Digest = zero_digest,
};

pub fn makeStatusRequestV1(
    descriptor: DescriptorV1,
    header: outbox.HeaderV1,
    state: outbox.ActionStateV1,
    query_ordinal: u64,
) Error!StatusRequestV1 {
    try validateDescriptorHeaderBindingV1(descriptor, header);
    if (!state.occupied or state.phase != .uncertain or
        state.attempt_generation == 0 or query_ordinal == 0)
        return Error.InvalidStatusRequest;
    var result: StatusRequestV1 = .{
        .header_sha256 = header.header_sha256,
        .adapter_descriptor_sha256 = descriptor.descriptor_sha256,
        .action_sha256 = state.identity.action_sha256,
        .stable_remote_request_sha256 = state.identity.stable_remote_request_sha256,
        .idempotency_key_sha256 = state.identity.idempotency_key_sha256,
        .dispatch_request_sha256 = state.dispatch_request_sha256,
        .attempt_generation = state.attempt_generation,
        .current_action_event_sha256 = state.last_event_sha256,
        .query_ordinal = query_ordinal,
    };
    result.request_sha256 = statusRequestSha256V1(result);
    try validateStatusRequestCompositionV1(
        descriptor,
        header,
        state,
        result,
    );
    return result;
}

pub fn statusRequestSha256V1(value: StatusRequestV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(status_request_domain);
    hashU64(&hash, value.abi_version);
    hash.update(&value.header_sha256);
    hash.update(&value.adapter_descriptor_sha256);
    hash.update(&value.action_sha256);
    hash.update(&value.stable_remote_request_sha256);
    hash.update(&value.idempotency_key_sha256);
    hash.update(&value.dispatch_request_sha256);
    hashU64(&hash, value.attempt_generation);
    hash.update(&value.current_action_event_sha256);
    hashU64(&hash, value.query_ordinal);
    return finish(&hash);
}

pub fn validateStatusRequestV1(value: StatusRequestV1) Error!void {
    if (value.abi_version != status_request_abi or
        value.attempt_generation == 0 or value.query_ordinal == 0 or
        digestIsZero(value.header_sha256) or
        digestIsZero(value.adapter_descriptor_sha256) or
        digestIsZero(value.action_sha256) or
        digestIsZero(value.stable_remote_request_sha256) or
        digestIsZero(value.idempotency_key_sha256) or
        digestIsZero(value.dispatch_request_sha256) or
        digestIsZero(value.current_action_event_sha256) or
        !digestEqual(
            value.request_sha256,
            statusRequestSha256V1(value),
        ))
        return Error.InvalidStatusRequest;
}

pub fn validateStatusRequestCompositionV1(
    descriptor: DescriptorV1,
    header: outbox.HeaderV1,
    state: outbox.ActionStateV1,
    value: StatusRequestV1,
) Error!void {
    try validateDescriptorHeaderBindingV1(descriptor, header);
    try validateStatusRequestV1(value);
    if (!state.occupied or state.phase != .uncertain or
        !digestEqual(value.header_sha256, header.header_sha256) or
        !digestEqual(
            value.adapter_descriptor_sha256,
            descriptor.descriptor_sha256,
        ) or
        !digestEqual(
            value.action_sha256,
            state.identity.action_sha256,
        ) or
        !digestEqual(
            value.stable_remote_request_sha256,
            state.identity.stable_remote_request_sha256,
        ) or
        !digestEqual(
            value.idempotency_key_sha256,
            state.identity.idempotency_key_sha256,
        ) or
        !digestEqual(
            value.dispatch_request_sha256,
            state.dispatch_request_sha256,
        ) or value.attempt_generation != state.attempt_generation or
        !digestEqual(
            value.current_action_event_sha256,
            state.last_event_sha256,
        ))
        return Error.InvalidBinding;
}

pub const StatusDispositionV1 = enum(u8) {
    pending = 1,
    unknown = 2,
    not_applied_fenced = 3,
    succeeded = 4,
    failed = 5,
};

pub const StatusEvidenceV1 = struct {
    abi_version: u64 = status_evidence_abi,
    request_sha256: Digest = zero_digest,
    adapter_descriptor_sha256: Digest = zero_digest,
    authority_epoch: u64 = 0,
    authority_revision: u64 = 0,
    disposition: StatusDispositionV1 = .unknown,
    fence_through_generation: u64 = 0,
    service_event_sha256: Digest = zero_digest,
    result_sha256: Digest = zero_digest,
    evidence_sha256: Digest = zero_digest,
};

pub fn makeStatusEvidenceV1(
    descriptor: DescriptorV1,
    request: StatusRequestV1,
    authority_revision: u64,
    disposition: StatusDispositionV1,
    fence_through_generation: u64,
    service_event_sha256: Digest,
    result_sha256: Digest,
) Error!StatusEvidenceV1 {
    try validateDescriptorV1(descriptor);
    try validateStatusRequestV1(request);
    if (!digestEqual(
        descriptor.descriptor_sha256,
        request.adapter_descriptor_sha256,
    ))
        return Error.InvalidBinding;
    var result: StatusEvidenceV1 = .{
        .request_sha256 = request.request_sha256,
        .adapter_descriptor_sha256 = descriptor.descriptor_sha256,
        .authority_epoch = descriptor.authority_epoch,
        .authority_revision = authority_revision,
        .disposition = disposition,
        .fence_through_generation = fence_through_generation,
        .service_event_sha256 = service_event_sha256,
        .result_sha256 = result_sha256,
    };
    result.evidence_sha256 = statusEvidenceSha256V1(result);
    try validateStatusEvidenceV1(descriptor, request, result);
    return result;
}

pub fn statusEvidenceSha256V1(value: StatusEvidenceV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(status_evidence_domain);
    hashU64(&hash, value.abi_version);
    hash.update(&value.request_sha256);
    hash.update(&value.adapter_descriptor_sha256);
    hashU64(&hash, value.authority_epoch);
    hashU64(&hash, value.authority_revision);
    hashU8(&hash, @intFromEnum(value.disposition));
    hashU64(&hash, value.fence_through_generation);
    hash.update(&value.service_event_sha256);
    hash.update(&value.result_sha256);
    return finish(&hash);
}

pub fn validateStatusEvidenceV1(
    descriptor: DescriptorV1,
    request: StatusRequestV1,
    value: StatusEvidenceV1,
) Error!void {
    try validateDescriptorV1(descriptor);
    try validateStatusRequestV1(request);
    const terminal =
        value.disposition == .succeeded or
        value.disposition == .failed;
    const fenced =
        value.disposition == .not_applied_fenced;
    if (value.abi_version != status_evidence_abi or
        value.authority_epoch != descriptor.authority_epoch or
        value.authority_revision == 0 or
        digestIsZero(value.service_event_sha256) or
        (terminal and digestIsZero(value.result_sha256)) or
        (!terminal and !digestIsZero(value.result_sha256)) or
        (fenced and
            value.fence_through_generation !=
                request.attempt_generation) or
        (!fenced and value.fence_through_generation != 0) or
        !digestEqual(value.request_sha256, request.request_sha256) or
        !digestEqual(
            request.adapter_descriptor_sha256,
            descriptor.descriptor_sha256,
        ) or
        !digestEqual(
            value.adapter_descriptor_sha256,
            descriptor.descriptor_sha256,
        ) or
        !digestEqual(
            value.evidence_sha256,
            statusEvidenceSha256V1(value),
        ))
        return Error.InvalidStatusEvidence;
}

pub const TransitionSpecV1 = struct {
    kind: outbox.EventKindV1,
    attempt_generation: u64,
    observation_sha256: Digest,
    result_sha256: Digest,
};

pub fn transitionFromDispatchV1(
    descriptor: DescriptorV1,
    request: DispatchRequestV1,
    evidence: DispatchEvidenceV1,
) Error!TransitionSpecV1 {
    try validateDispatchEvidenceV1(descriptor, request, evidence);
    return .{
        .kind = switch (evidence.disposition) {
            .succeeded => .acknowledged_success,
            .terminal_failure => .acknowledged_failure,
            .indeterminate,
            .rejected_stale_generation,
            => .ambiguity_observed,
        },
        .attempt_generation = request.attempt_generation,
        .observation_sha256 = evidence.evidence_sha256,
        .result_sha256 = evidence.result_sha256,
    };
}

/// Returns null for pending/unknown observations. Those classifications leave
/// the committed state uncertain and do not manufacture another journal event.
pub fn transitionFromStatusV1(
    descriptor: DescriptorV1,
    request: StatusRequestV1,
    evidence: StatusEvidenceV1,
) Error!?TransitionSpecV1 {
    try validateStatusEvidenceV1(descriptor, request, evidence);
    return switch (evidence.disposition) {
        .pending, .unknown => null,
        .not_applied_fenced => .{
            .kind = .reconciled_not_applied,
            .attempt_generation = request.attempt_generation,
            .observation_sha256 = evidence.evidence_sha256,
            .result_sha256 = zero_digest,
        },
        .succeeded => .{
            .kind = .reconciled_success,
            .attempt_generation = request.attempt_generation,
            .observation_sha256 = evidence.evidence_sha256,
            .result_sha256 = evidence.result_sha256,
        },
        .failed => .{
            .kind = .reconciled_failure,
            .attempt_generation = request.attempt_generation,
            .observation_sha256 = evidence.evidence_sha256,
            .result_sha256 = evidence.result_sha256,
        },
    };
}

pub const DispatchFn = *const fn (
    adapter_context: *anyopaque,
    request: DispatchRequestV1,
) CallbackError!DispatchEvidenceV1;

pub const StatusFn = *const fn (
    adapter_context: *anyopaque,
    request: StatusRequestV1,
) CallbackError!StatusEvidenceV1;

/// Process-local authority boundary. Opaque context and function pointers are
/// excluded from every portable value. This is API isolation, not an OS
/// sandbox or protection against a hostile process.
pub const AdapterV1 = struct {
    adapter_context: *anyopaque,
    descriptor: DescriptorV1,
    dispatch_fn: DispatchFn,
    status_fn: StatusFn,
};

pub fn validateAdapterV1(adapter: AdapterV1) Error!void {
    try validateDescriptorV1(adapter.descriptor);
    if (@intFromPtr(adapter.adapter_context) == 0)
        return Error.InvalidAdapter;
}

/// Low-level process-local callback invocation. This validates portable
/// bindings but does not prove that an intent is durable; ordered callers must
/// enter through `tool_action_outbox_dispatch_driver`.
pub fn dispatchV1(
    adapter: AdapterV1,
    request: DispatchRequestV1,
) RuntimeError!DispatchEvidenceV1 {
    try validateAdapterV1(adapter);
    try validateDispatchRequestV1(request);
    if (!digestEqual(
        request.adapter_descriptor_sha256,
        adapter.descriptor.descriptor_sha256,
    ))
        return Error.InvalidBinding;
    const evidence = try adapter.dispatch_fn(
        adapter.adapter_context,
        request,
    );
    try validateDispatchEvidenceV1(
        adapter.descriptor,
        request,
        evidence,
    );
    return evidence;
}

/// Low-level process-local callback invocation. This validates portable
/// bindings but does not prove that the request came from authoritative
/// uncertain state; ordered callers must enter through the dispatch driver.
pub fn statusV1(
    adapter: AdapterV1,
    request: StatusRequestV1,
) RuntimeError!StatusEvidenceV1 {
    try validateAdapterV1(adapter);
    try validateStatusRequestV1(request);
    if (!digestEqual(
        request.adapter_descriptor_sha256,
        adapter.descriptor.descriptor_sha256,
    ))
        return Error.InvalidBinding;
    const evidence = try adapter.status_fn(
        adapter.adapter_context,
        request,
    );
    try validateStatusEvidenceV1(
        adapter.descriptor,
        request,
        evidence,
    );
    return evidence;
}

pub fn portableTypeHasPointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => true,
        .array => |info| portableTypeHasPointer(info.child),
        .optional => |info| portableTypeHasPointer(info.child),
        .@"struct" => |info| blk: {
            inline for (info.fields) |field| {
                if (portableTypeHasPointer(field.type))
                    break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn hashU8(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u8,
) void {
    hash.update(&.{value});
}

fn hashU64(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u64,
) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

fn finish(hash: *std.crypto.hash.sha2.Sha256) Digest {
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn digest(value: []const u8) Digest {
    var result: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(value, &result, .{});
    return result;
}

fn digestIsZero(value: Digest) bool {
    return digestEqual(value, zero_digest);
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

const action = @import("tool_action_contract.zig");

const TestFixture = struct {
    descriptor: DescriptorV1,
    header: outbox.HeaderV1,
    intent: outbox.RecordV1,
    state: outbox.ActionStateV1,
};

pub const ReferenceReportV1 = struct {
    abi_version: u64 = reference_report_abi,
    descriptor_sha256: Digest = zero_digest,
    header_sha256: Digest = zero_digest,
    action_sha256: Digest = zero_digest,
    stable_remote_request_sha256: Digest = zero_digest,
    intent_record_sha256: Digest = zero_digest,
    outbox_dispatch_request_sha256: Digest = zero_digest,
    adapter_dispatch_request_sha256: Digest = zero_digest,
    status_request_sha256: Digest = zero_digest,
    dispatch_evidence_sha256: Digest = zero_digest,
    status_evidence_sha256: Digest = zero_digest,
    report_sha256: Digest = zero_digest,
};

fn testFixture() !TestFixture {
    const descriptor = try makeDescriptorV1(
        17,
        3,
        digest("fake authority namespace"),
        digest("fake request schema"),
        digest("fake result schema"),
    );
    const header = try outbox.makeHeaderV1(
        7,
        9,
        41,
        2,
        8,
        4096,
        descriptor.descriptor_sha256,
        digest("payload store"),
        digest("header challenge"),
    );
    const tool_descriptor = try action.makeDescriptorV1(
        4,
        digest("tool namespace"),
        digest("argument schema"),
        digest("result schema"),
        digest("implementation"),
    );
    const arguments = try action.makeBoundedAddArgumentsV1(88, 2);
    const proposal = try action.makeActionProposalV1(
        41,
        1,
        digest("agent request"),
        tool_descriptor,
        arguments,
        digest("idempotency"),
    );
    const policy = try action.makePolicyV1(
        2,
        41,
        true,
        8,
        -10,
        10,
        tool_descriptor,
        digest("policy"),
    );
    const authorization = try action.authorizeBoundedAddV1(
        proposal,
        tool_descriptor,
        arguments,
        policy,
        1,
    );
    const identity = try outbox.makeActionIdentityV1(
        header,
        .primary,
        zero_digest,
        tool_descriptor,
        arguments,
        proposal,
        policy,
        authorization,
        digest("service event"),
        digest("payload locator"),
        32,
        digest("payload"),
    );
    const enqueued = try outbox.makeEnqueuedRecordV1(
        header,
        1,
        header.header_sha256,
        identity,
    );
    var states = [_]outbox.ActionStateV1{.{}} ** 2;
    var ledger: outbox.LedgerV1 = .{};
    try outbox.applyRecordV1(header, enqueued, &states, &ledger);
    const intent = try outbox.makeTransitionRecordV1(
        header,
        2,
        enqueued.record_sha256,
        states[0],
        .dispatch_intent,
        1,
        zero_digest,
        zero_digest,
    );
    try outbox.applyRecordV1(header, intent, &states, &ledger);
    return .{
        .descriptor = descriptor,
        .header = header,
        .intent = intent,
        .state = states[0],
    };
}

pub fn referenceReportV1() Error!ReferenceReportV1 {
    const fixture = try testFixture();
    const dispatch_request = try makeDispatchRequestV1(
        fixture.descriptor,
        fixture.header,
        fixture.intent,
    );
    const dispatch_evidence = try makeDispatchEvidenceV1(
        fixture.descriptor,
        dispatch_request,
        1,
        .succeeded,
        digest("remote event"),
        digest("result"),
    );
    const status_request = try makeStatusRequestV1(
        fixture.descriptor,
        fixture.header,
        fixture.state,
        1,
    );
    const status_evidence = try makeStatusEvidenceV1(
        fixture.descriptor,
        status_request,
        2,
        .not_applied_fenced,
        status_request.attempt_generation,
        digest("fence receipt"),
        zero_digest,
    );
    var result: ReferenceReportV1 = .{
        .descriptor_sha256 = fixture.descriptor.descriptor_sha256,
        .header_sha256 = fixture.header.header_sha256,
        .action_sha256 = fixture.intent.identity.action_sha256,
        .stable_remote_request_sha256 = fixture.intent.identity.stable_remote_request_sha256,
        .intent_record_sha256 = fixture.intent.record_sha256,
        .outbox_dispatch_request_sha256 = fixture.intent.dispatch_request_sha256,
        .adapter_dispatch_request_sha256 = dispatch_request.request_sha256,
        .status_request_sha256 = status_request.request_sha256,
        .dispatch_evidence_sha256 = dispatch_evidence.evidence_sha256,
        .status_evidence_sha256 = status_evidence.evidence_sha256,
    };
    result.report_sha256 = referenceReportSha256V1(result);
    try validateReferenceReportV1(result);
    return result;
}

pub fn referenceReportSha256V1(
    value: ReferenceReportV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(reference_report_domain);
    hashU64(&hash, value.abi_version);
    hash.update(&value.descriptor_sha256);
    hash.update(&value.header_sha256);
    hash.update(&value.action_sha256);
    hash.update(&value.stable_remote_request_sha256);
    hash.update(&value.intent_record_sha256);
    hash.update(&value.outbox_dispatch_request_sha256);
    hash.update(&value.adapter_dispatch_request_sha256);
    hash.update(&value.status_request_sha256);
    hash.update(&value.dispatch_evidence_sha256);
    hash.update(&value.status_evidence_sha256);
    return finish(&hash);
}

pub fn validateReferenceReportV1(
    value: ReferenceReportV1,
) Error!void {
    if (value.abi_version != reference_report_abi or
        digestIsZero(value.descriptor_sha256) or
        digestIsZero(value.header_sha256) or
        digestIsZero(value.action_sha256) or
        digestIsZero(value.stable_remote_request_sha256) or
        digestIsZero(value.intent_record_sha256) or
        digestIsZero(value.outbox_dispatch_request_sha256) or
        digestIsZero(value.adapter_dispatch_request_sha256) or
        digestIsZero(value.status_request_sha256) or
        digestIsZero(value.dispatch_evidence_sha256) or
        digestIsZero(value.status_evidence_sha256) or
        !digestEqual(
            value.report_sha256,
            referenceReportSha256V1(value),
        ))
        return Error.InvalidReferenceReport;
}

test "descriptor is pinned by the outbox header" {
    const fixture = try testFixture();
    try validateDescriptorHeaderBindingV1(
        fixture.descriptor,
        fixture.header,
    );
    var foreign = fixture.descriptor;
    foreign.authority_epoch += 1;
    foreign.descriptor_sha256 = descriptorSha256V1(foreign);
    try std.testing.expectError(
        Error.InvalidBinding,
        validateDescriptorHeaderBindingV1(foreign, fixture.header),
    );
}

test "dispatch evidence maps only to the exact intent path" {
    const fixture = try testFixture();
    const request = try makeDispatchRequestV1(
        fixture.descriptor,
        fixture.header,
        fixture.intent,
    );
    const evidence = try makeDispatchEvidenceV1(
        fixture.descriptor,
        request,
        1,
        .succeeded,
        digest("remote event"),
        digest("result"),
    );
    const transition = try transitionFromDispatchV1(
        fixture.descriptor,
        request,
        evidence,
    );
    try std.testing.expectEqual(
        outbox.EventKindV1.acknowledged_success,
        transition.kind,
    );
    try std.testing.expectEqual(
        request.attempt_generation,
        transition.attempt_generation,
    );
    var foreign_request = request;
    foreign_request.adapter_descriptor_sha256 =
        digest("foreign adapter");
    foreign_request.request_sha256 =
        dispatchRequestSha256V1(foreign_request);
    var rebound_evidence = evidence;
    rebound_evidence.request_sha256 =
        foreign_request.request_sha256;
    rebound_evidence.evidence_sha256 =
        dispatchEvidenceSha256V1(rebound_evidence);
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateDispatchEvidenceV1(
            fixture.descriptor,
            foreign_request,
            rebound_evidence,
        ),
    );
}

test "only fenced authoritative status permits safe retry" {
    const fixture = try testFixture();
    const request = try makeStatusRequestV1(
        fixture.descriptor,
        fixture.header,
        fixture.state,
        1,
    );
    const pending = try makeStatusEvidenceV1(
        fixture.descriptor,
        request,
        1,
        .pending,
        0,
        digest("pending"),
        zero_digest,
    );
    try std.testing.expect(
        try transitionFromStatusV1(
            fixture.descriptor,
            request,
            pending,
        ) == null,
    );
    const fenced = try makeStatusEvidenceV1(
        fixture.descriptor,
        request,
        2,
        .not_applied_fenced,
        request.attempt_generation,
        digest("fence receipt"),
        zero_digest,
    );
    const transition = (try transitionFromStatusV1(
        fixture.descriptor,
        request,
        fenced,
    )).?;
    try std.testing.expectEqual(
        outbox.EventKindV1.reconciled_not_applied,
        transition.kind,
    );
    var forged = fenced;
    forged.fence_through_generation += 1;
    forged.evidence_sha256 = statusEvidenceSha256V1(forged);
    try std.testing.expectError(
        Error.InvalidStatusEvidence,
        transitionFromStatusV1(
            fixture.descriptor,
            request,
            forged,
        ),
    );
    var foreign_request = request;
    foreign_request.adapter_descriptor_sha256 =
        digest("foreign adapter");
    foreign_request.request_sha256 =
        statusRequestSha256V1(foreign_request);
    var rebound_evidence = fenced;
    rebound_evidence.request_sha256 =
        foreign_request.request_sha256;
    rebound_evidence.evidence_sha256 =
        statusEvidenceSha256V1(rebound_evidence);
    try std.testing.expectError(
        Error.InvalidStatusEvidence,
        validateStatusEvidenceV1(
            fixture.descriptor,
            foreign_request,
            rebound_evidence,
        ),
    );
}

test "portable adapter contract values contain no pointers" {
    inline for (.{
        DescriptorV1,
        DispatchRequestV1,
        DispatchEvidenceV1,
        StatusRequestV1,
        StatusEvidenceV1,
        TransitionSpecV1,
    }) |T| {
        try std.testing.expect(!portableTypeHasPointer(T));
    }
    try std.testing.expect(portableTypeHasPointer(AdapterV1));
}

test "reference adapter report is deterministic and mutation rejecting" {
    const first = try referenceReportV1();
    const second = try referenceReportV1();
    try std.testing.expectEqualDeep(first, second);
    var mutated = first;
    mutated.status_evidence_sha256[0] ^= 1;
    try std.testing.expectError(
        Error.InvalidReferenceReport,
        validateReferenceReportV1(mutated),
    );
}
