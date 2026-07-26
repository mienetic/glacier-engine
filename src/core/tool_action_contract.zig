//! Canonical, pointer-free contracts for one credential-free tool action.
//!
//! These records describe proposals, local policy decisions, committed
//! bounded effects, and scheduler-bound delivery. They do not grant filesystem,
//! network, process, clock, random-number, credential, or external side-effect
//! authority.

const std = @import("std");

pub const Digest = [32]u8;
pub const zero_digest: Digest = [_]u8{0} ** 32;

pub const descriptor_abi: u64 = 0x4754_4144_0000_0001;
pub const bounded_add_arguments_abi: u64 = 0x4754_4141_0000_0001;
pub const proposal_abi: u64 = 0x4754_4150_0000_0001;
pub const policy_abi: u64 = 0x4754_4159_0000_0001;
pub const authorization_abi: u64 = 0x4754_4155_0000_0001;
pub const effect_abi: u64 = 0x4754_4145_0000_0001;
pub const delivery_abi: u64 = 0x4754_414c_0000_0001;

pub const capability_bounded_add: u64 = 1 << 0;
pub const allowed_capabilities: u64 = capability_bounded_add;

const descriptor_domain = "glacier-tool-action-descriptor-v1\x00";
const arguments_domain = "glacier-tool-bounded-add-arguments-v1\x00";
const proposal_domain = "glacier-tool-action-proposal-v1\x00";
const policy_domain = "glacier-tool-action-policy-v1\x00";
const authorization_domain = "glacier-tool-authorization-v1\x00";
const effect_output_domain = "glacier-tool-bounded-add-output-v1\x00";
const effect_domain = "glacier-tool-effect-v1\x00";
const terminal_output_domain = "glacier-tool-terminal-output-v1\x00";
const delivery_domain = "glacier-tool-delivery-v1\x00";

pub const Error = error{
    ArithmeticOverflow,
    InvalidArguments,
    InvalidAuthorization,
    InvalidDelivery,
    InvalidDescriptor,
    InvalidEffect,
    InvalidPolicy,
    InvalidProposal,
};

pub const ToolOperationV1 = enum(u8) {
    bounded_add = 1,
};

pub const DescriptorV1 = struct {
    abi_version: u64 = descriptor_abi,
    tool_adapter_abi: u64 = 0,
    operation: ToolOperationV1 = .bounded_add,
    capability_bits: u64 = 0,
    tool_namespace_sha256: Digest = zero_digest,
    argument_schema_sha256: Digest = zero_digest,
    result_schema_sha256: Digest = zero_digest,
    implementation_sha256: Digest = zero_digest,
    descriptor_sha256: Digest = zero_digest,
};

pub fn makeDescriptorV1(
    tool_adapter_abi: u64,
    tool_namespace_sha256: Digest,
    argument_schema_sha256: Digest,
    result_schema_sha256: Digest,
    implementation_sha256: Digest,
) Error!DescriptorV1 {
    var result: DescriptorV1 = .{
        .tool_adapter_abi = tool_adapter_abi,
        .capability_bits = capability_bounded_add,
        .tool_namespace_sha256 = tool_namespace_sha256,
        .argument_schema_sha256 = argument_schema_sha256,
        .result_schema_sha256 = result_schema_sha256,
        .implementation_sha256 = implementation_sha256,
    };
    result.descriptor_sha256 = descriptorSha256V1(result);
    try validateDescriptorV1(result);
    return result;
}

pub fn descriptorSha256V1(value: DescriptorV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(descriptor_domain);
    hashU64(&hash, value.abi_version);
    hashU64(&hash, value.tool_adapter_abi);
    hashU8(&hash, @intFromEnum(value.operation));
    hashU64(&hash, value.capability_bits);
    hash.update(&value.tool_namespace_sha256);
    hash.update(&value.argument_schema_sha256);
    hash.update(&value.result_schema_sha256);
    hash.update(&value.implementation_sha256);
    return finish(&hash);
}

pub fn validateDescriptorV1(value: DescriptorV1) Error!void {
    if (value.abi_version != descriptor_abi or
        value.tool_adapter_abi == 0 or
        value.operation != .bounded_add or
        value.capability_bits != capability_bounded_add or
        digestIsZero(value.tool_namespace_sha256) or
        digestIsZero(value.argument_schema_sha256) or
        digestIsZero(value.result_schema_sha256) or
        digestIsZero(value.implementation_sha256) or
        !digestEqual(
            value.descriptor_sha256,
            descriptorSha256V1(value),
        ))
        return Error.InvalidDescriptor;
}

pub const BoundedAddArgumentsV1 = struct {
    abi_version: u64 = bounded_add_arguments_abi,
    target_key: u64 = 0,
    delta: i64 = 0,
    arguments_sha256: Digest = zero_digest,
};

pub fn makeBoundedAddArgumentsV1(
    target_key: u64,
    delta: i64,
) Error!BoundedAddArgumentsV1 {
    var result: BoundedAddArgumentsV1 = .{
        .target_key = target_key,
        .delta = delta,
    };
    result.arguments_sha256 = boundedAddArgumentsSha256V1(result);
    try validateBoundedAddArgumentsV1(result);
    return result;
}

pub fn boundedAddArgumentsSha256V1(
    value: BoundedAddArgumentsV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(arguments_domain);
    hashU64(&hash, value.abi_version);
    hashU64(&hash, value.target_key);
    hashI64(&hash, value.delta);
    return finish(&hash);
}

pub fn validateBoundedAddArgumentsV1(
    value: BoundedAddArgumentsV1,
) Error!void {
    if (value.abi_version != bounded_add_arguments_abi or
        value.target_key == 0 or value.delta == 0 or
        value.delta == std.math.minInt(i64) or
        !digestEqual(
            value.arguments_sha256,
            boundedAddArgumentsSha256V1(value),
        ))
        return Error.InvalidArguments;
}

pub const ActionProposalV1 = struct {
    abi_version: u64 = proposal_abi,
    tenant_key: u64 = 0,
    action_ordinal: u64 = 0,
    agent_request_sha256: Digest = zero_digest,
    descriptor_sha256: Digest = zero_digest,
    arguments_sha256: Digest = zero_digest,
    idempotency_key_sha256: Digest = zero_digest,
    proposal_sha256: Digest = zero_digest,
};

pub fn makeActionProposalV1(
    tenant_key: u64,
    action_ordinal: u64,
    agent_request_sha256: Digest,
    descriptor: DescriptorV1,
    arguments: BoundedAddArgumentsV1,
    idempotency_key_sha256: Digest,
) Error!ActionProposalV1 {
    try validateDescriptorV1(descriptor);
    try validateBoundedAddArgumentsV1(arguments);
    var result: ActionProposalV1 = .{
        .tenant_key = tenant_key,
        .action_ordinal = action_ordinal,
        .agent_request_sha256 = agent_request_sha256,
        .descriptor_sha256 = descriptor.descriptor_sha256,
        .arguments_sha256 = arguments.arguments_sha256,
        .idempotency_key_sha256 = idempotency_key_sha256,
    };
    result.proposal_sha256 = actionProposalSha256V1(result);
    try validateActionProposalV1(result);
    return result;
}

pub fn actionProposalSha256V1(value: ActionProposalV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(proposal_domain);
    hashU64(&hash, value.abi_version);
    hashU64(&hash, value.tenant_key);
    hashU64(&hash, value.action_ordinal);
    hash.update(&value.agent_request_sha256);
    hash.update(&value.descriptor_sha256);
    hash.update(&value.arguments_sha256);
    hash.update(&value.idempotency_key_sha256);
    return finish(&hash);
}

pub fn validateActionProposalV1(value: ActionProposalV1) Error!void {
    if (value.abi_version != proposal_abi or value.tenant_key == 0 or
        digestIsZero(value.agent_request_sha256) or
        digestIsZero(value.descriptor_sha256) or
        digestIsZero(value.arguments_sha256) or
        digestIsZero(value.idempotency_key_sha256) or
        !digestEqual(value.proposal_sha256, actionProposalSha256V1(value)))
        return Error.InvalidProposal;
}

pub fn validateProposalCompositionV1(
    proposal: ActionProposalV1,
    descriptor: DescriptorV1,
    arguments: BoundedAddArgumentsV1,
) Error!void {
    try validateActionProposalV1(proposal);
    try validateDescriptorV1(descriptor);
    try validateBoundedAddArgumentsV1(arguments);
    if (!digestEqual(
        proposal.descriptor_sha256,
        descriptor.descriptor_sha256,
    ) or !digestEqual(
        proposal.arguments_sha256,
        arguments.arguments_sha256,
    ))
        return Error.InvalidProposal;
}

pub const PolicyV1 = struct {
    abi_version: u64 = policy_abi,
    policy_epoch: u64 = 0,
    tenant_key: u64 = 0,
    allow_bounded_add: bool = false,
    maximum_absolute_delta: u64 = 0,
    minimum_value: i64 = 0,
    maximum_value: i64 = 0,
    descriptor_sha256: Digest = zero_digest,
    challenge_sha256: Digest = zero_digest,
    policy_sha256: Digest = zero_digest,
};

pub fn makePolicyV1(
    policy_epoch: u64,
    tenant_key: u64,
    allow_bounded_add: bool,
    maximum_absolute_delta: u64,
    minimum_value: i64,
    maximum_value: i64,
    descriptor: DescriptorV1,
    challenge_sha256: Digest,
) Error!PolicyV1 {
    try validateDescriptorV1(descriptor);
    var result: PolicyV1 = .{
        .policy_epoch = policy_epoch,
        .tenant_key = tenant_key,
        .allow_bounded_add = allow_bounded_add,
        .maximum_absolute_delta = maximum_absolute_delta,
        .minimum_value = minimum_value,
        .maximum_value = maximum_value,
        .descriptor_sha256 = descriptor.descriptor_sha256,
        .challenge_sha256 = challenge_sha256,
    };
    result.policy_sha256 = policySha256V1(result);
    try validatePolicyV1(result);
    return result;
}

pub fn policySha256V1(value: PolicyV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(policy_domain);
    hashU64(&hash, value.abi_version);
    hashU64(&hash, value.policy_epoch);
    hashU64(&hash, value.tenant_key);
    hashU8(&hash, @intFromBool(value.allow_bounded_add));
    hashU64(&hash, value.maximum_absolute_delta);
    hashI64(&hash, value.minimum_value);
    hashI64(&hash, value.maximum_value);
    hash.update(&value.descriptor_sha256);
    hash.update(&value.challenge_sha256);
    return finish(&hash);
}

pub fn validatePolicyV1(value: PolicyV1) Error!void {
    if (value.abi_version != policy_abi or value.policy_epoch == 0 or
        value.tenant_key == 0 or value.maximum_absolute_delta == 0 or
        value.maximum_absolute_delta > std.math.maxInt(i64) or
        value.minimum_value > value.maximum_value or
        digestIsZero(value.descriptor_sha256) or
        digestIsZero(value.challenge_sha256) or
        !digestEqual(value.policy_sha256, policySha256V1(value)))
        return Error.InvalidPolicy;
}

pub const AuthorizationKindV1 = enum(u8) {
    allowed = 1,
    denied = 2,
};

pub const DenialReasonV1 = enum(u8) {
    none = 0,
    tenant_mismatch = 1,
    descriptor_mismatch = 2,
    tool_disabled = 3,
    delta_out_of_range = 4,
    result_out_of_range = 5,
    idempotency_conflict = 6,
};

pub const AuthorizationReceiptV1 = struct {
    abi_version: u64 = authorization_abi,
    kind: AuthorizationKindV1 = .denied,
    reason: DenialReasonV1 = .none,
    proposal_sha256: Digest = zero_digest,
    policy_sha256: Digest = zero_digest,
    observed_before: i64 = 0,
    projected_after: i64 = 0,
    authorization_sha256: Digest = zero_digest,
};

pub fn authorizeBoundedAddV1(
    proposal: ActionProposalV1,
    descriptor: DescriptorV1,
    arguments: BoundedAddArgumentsV1,
    policy: PolicyV1,
    observed_before: i64,
) Error!AuthorizationReceiptV1 {
    try validateProposalCompositionV1(proposal, descriptor, arguments);
    try validatePolicyV1(policy);

    var reason: DenialReasonV1 = .none;
    var projected_after = observed_before;
    if (proposal.tenant_key != policy.tenant_key) {
        reason = .tenant_mismatch;
    } else if (!digestEqual(
        proposal.descriptor_sha256,
        policy.descriptor_sha256,
    )) {
        reason = .descriptor_mismatch;
    } else if (!policy.allow_bounded_add) {
        reason = .tool_disabled;
    } else if (deltaMagnitude(arguments.delta) >
        policy.maximum_absolute_delta)
    {
        reason = .delta_out_of_range;
    } else {
        const maybe_projected = std.math.add(
            i64,
            observed_before,
            arguments.delta,
        ) catch null;
        if (maybe_projected) |value| {
            projected_after = value;
            if (projected_after < policy.minimum_value or
                projected_after > policy.maximum_value)
                reason = .result_out_of_range;
        } else {
            reason = .result_out_of_range;
        }
    }

    return makeAuthorizationReceiptV1(
        proposal,
        policy,
        if (reason == .none) .allowed else .denied,
        reason,
        observed_before,
        if (reason == .none) projected_after else observed_before,
    );
}

/// Build the terminal receipt after `authorizeBoundedAddV1` returned allowed.
/// Context-independent tenant, descriptor, and enablement gates are repeated
/// here so direct callers cannot mint conflicts outside the policy domain.
pub fn denyIdempotencyConflictV1(
    proposal: ActionProposalV1,
    policy: PolicyV1,
    observed_before: i64,
) Error!AuthorizationReceiptV1 {
    try validateActionProposalV1(proposal);
    try validatePolicyV1(policy);
    if (proposal.tenant_key != policy.tenant_key or
        !digestEqual(
            proposal.descriptor_sha256,
            policy.descriptor_sha256,
        ) or !policy.allow_bounded_add)
        return Error.InvalidAuthorization;
    return makeAuthorizationReceiptV1(
        proposal,
        policy,
        .denied,
        .idempotency_conflict,
        observed_before,
        observed_before,
    );
}

fn makeAuthorizationReceiptV1(
    proposal: ActionProposalV1,
    policy: PolicyV1,
    kind: AuthorizationKindV1,
    reason: DenialReasonV1,
    observed_before: i64,
    projected_after: i64,
) Error!AuthorizationReceiptV1 {
    var result: AuthorizationReceiptV1 = .{
        .kind = kind,
        .reason = reason,
        .proposal_sha256 = proposal.proposal_sha256,
        .policy_sha256 = policy.policy_sha256,
        .observed_before = observed_before,
        .projected_after = projected_after,
    };
    result.authorization_sha256 = authorizationSha256V1(result);
    try validateAuthorizationReceiptV1(result);
    return result;
}

pub fn authorizationSha256V1(value: AuthorizationReceiptV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(authorization_domain);
    hashU64(&hash, value.abi_version);
    hashU8(&hash, @intFromEnum(value.kind));
    hashU8(&hash, @intFromEnum(value.reason));
    hash.update(&value.proposal_sha256);
    hash.update(&value.policy_sha256);
    hashI64(&hash, value.observed_before);
    hashI64(&hash, value.projected_after);
    return finish(&hash);
}

pub fn validateAuthorizationReceiptV1(
    value: AuthorizationReceiptV1,
) Error!void {
    const shape_valid = switch (value.kind) {
        .allowed => value.reason == .none,
        .denied => value.reason != .none and
            value.projected_after == value.observed_before,
    };
    if (value.abi_version != authorization_abi or !shape_valid or
        digestIsZero(value.proposal_sha256) or
        digestIsZero(value.policy_sha256) or
        !digestEqual(
            value.authorization_sha256,
            authorizationSha256V1(value),
        ))
        return Error.InvalidAuthorization;
}

pub fn validateAuthorizationCompositionV1(
    value: AuthorizationReceiptV1,
    proposal: ActionProposalV1,
    policy: PolicyV1,
) Error!void {
    try validateAuthorizationReceiptV1(value);
    try validateActionProposalV1(proposal);
    try validatePolicyV1(policy);
    if (!digestEqual(value.proposal_sha256, proposal.proposal_sha256) or
        !digestEqual(value.policy_sha256, policy.policy_sha256))
        return Error.InvalidAuthorization;
}

pub const EffectReceiptV1 = struct {
    abi_version: u64 = effect_abi,
    execution_sequence: u64 = 0,
    target_key: u64 = 0,
    before_value: i64 = 0,
    after_value: i64 = 0,
    idempotency_key_sha256: Digest = zero_digest,
    proposal_sha256: Digest = zero_digest,
    authorization_sha256: Digest = zero_digest,
    output_sha256: Digest = zero_digest,
    effect_sha256: Digest = zero_digest,
};

pub fn makeEffectReceiptV1(
    execution_sequence: u64,
    proposal: ActionProposalV1,
    arguments: BoundedAddArgumentsV1,
    authorization: AuthorizationReceiptV1,
) Error!EffectReceiptV1 {
    try validateActionProposalV1(proposal);
    try validateBoundedAddArgumentsV1(arguments);
    try validateAuthorizationReceiptV1(authorization);
    if (authorization.kind != .allowed or
        !digestEqual(
            proposal.arguments_sha256,
            arguments.arguments_sha256,
        ) or
        !digestEqual(
            authorization.proposal_sha256,
            proposal.proposal_sha256,
        ) or authorization.projected_after !=
        std.math.add(
            i64,
            authorization.observed_before,
            arguments.delta,
        ) catch return Error.InvalidEffect)
        return Error.InvalidEffect;

    var result: EffectReceiptV1 = .{
        .execution_sequence = execution_sequence,
        .target_key = arguments.target_key,
        .before_value = authorization.observed_before,
        .after_value = authorization.projected_after,
        .idempotency_key_sha256 = proposal.idempotency_key_sha256,
        .proposal_sha256 = proposal.proposal_sha256,
        .authorization_sha256 = authorization.authorization_sha256,
    };
    result.output_sha256 = boundedAddOutputSha256V1(
        result.target_key,
        result.before_value,
        result.after_value,
    );
    result.effect_sha256 = effectSha256V1(result);
    try validateEffectReceiptV1(result);
    return result;
}

pub fn boundedAddOutputSha256V1(
    target_key: u64,
    before_value: i64,
    after_value: i64,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(effect_output_domain);
    hashU64(&hash, target_key);
    hashI64(&hash, before_value);
    hashI64(&hash, after_value);
    return finish(&hash);
}

pub fn effectSha256V1(value: EffectReceiptV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(effect_domain);
    hashU64(&hash, value.abi_version);
    hashU64(&hash, value.execution_sequence);
    hashU64(&hash, value.target_key);
    hashI64(&hash, value.before_value);
    hashI64(&hash, value.after_value);
    hash.update(&value.idempotency_key_sha256);
    hash.update(&value.proposal_sha256);
    hash.update(&value.authorization_sha256);
    hash.update(&value.output_sha256);
    return finish(&hash);
}

pub fn validateEffectReceiptV1(value: EffectReceiptV1) Error!void {
    if (value.abi_version != effect_abi or value.execution_sequence == 0 or
        value.target_key == 0 or
        digestIsZero(value.idempotency_key_sha256) or
        digestIsZero(value.proposal_sha256) or
        digestIsZero(value.authorization_sha256) or
        !digestEqual(
            value.output_sha256,
            boundedAddOutputSha256V1(
                value.target_key,
                value.before_value,
                value.after_value,
            ),
        ) or !digestEqual(value.effect_sha256, effectSha256V1(value)))
        return Error.InvalidEffect;
}

pub fn validateEffectCompositionV1(
    value: EffectReceiptV1,
    proposal: ActionProposalV1,
    arguments: BoundedAddArgumentsV1,
    authorization: AuthorizationReceiptV1,
) Error!void {
    try validateEffectReceiptV1(value);
    const expected = try makeEffectReceiptV1(
        value.execution_sequence,
        proposal,
        arguments,
        authorization,
    );
    if (!std.meta.eql(value, expected)) return Error.InvalidEffect;
}

pub const DeliveryDispositionV1 = enum(u8) {
    executed = 1,
    reused = 2,
    denied = 3,
    conflict = 4,
};

pub const DeliveryReceiptV1 = struct {
    abi_version: u64 = delivery_abi,
    disposition: DeliveryDispositionV1 = .denied,
    proposal_sha256: Digest = zero_digest,
    authorization_sha256: Digest = zero_digest,
    idempotency_key_sha256: Digest = zero_digest,
    effect_sha256: Digest = zero_digest,
    service_event_sha256: Digest = zero_digest,
    output_sha256: Digest = zero_digest,
    delivery_sha256: Digest = zero_digest,
};

pub fn makeDeliveryReceiptV1(
    disposition: DeliveryDispositionV1,
    proposal: ActionProposalV1,
    authorization: AuthorizationReceiptV1,
    maybe_effect: ?EffectReceiptV1,
    service_event_sha256: Digest,
) Error!DeliveryReceiptV1 {
    try validateActionProposalV1(proposal);
    try validateAuthorizationReceiptV1(authorization);
    if (!digestEqual(
        proposal.proposal_sha256,
        authorization.proposal_sha256,
    ) or digestIsZero(service_event_sha256))
        return Error.InvalidDelivery;

    const effect_sha256: Digest = if (maybe_effect) |effect| blk: {
        try validateEffectReceiptV1(effect);
        if (!digestEqual(
            effect.idempotency_key_sha256,
            proposal.idempotency_key_sha256,
        )) return Error.InvalidDelivery;
        break :blk effect.effect_sha256;
    } else zero_digest;

    const output_sha256: Digest = switch (disposition) {
        .executed, .reused => if (maybe_effect) |effect| blk: {
            if (authorization.kind != .allowed or
                !digestEqual(
                    effect.proposal_sha256,
                    proposal.proposal_sha256,
                ) or !digestEqual(
                effect.authorization_sha256,
                authorization.authorization_sha256,
            ))
                return Error.InvalidDelivery;
            break :blk effect.output_sha256;
        } else return Error.InvalidDelivery,
        .denied => blk: {
            if (authorization.kind != .denied or
                authorization.reason == .idempotency_conflict or
                maybe_effect != null)
                return Error.InvalidDelivery;
            break :blk terminalOutputSha256V1(
                disposition,
                proposal,
                authorization,
                zero_digest,
            );
        },
        .conflict => if (maybe_effect) |effect| blk: {
            if (authorization.kind != .denied or
                authorization.reason != .idempotency_conflict or
                digestEqual(
                    effect.proposal_sha256,
                    proposal.proposal_sha256,
                ))
                return Error.InvalidDelivery;
            break :blk terminalOutputSha256V1(
                disposition,
                proposal,
                authorization,
                effect.effect_sha256,
            );
        } else return Error.InvalidDelivery,
    };

    var result: DeliveryReceiptV1 = .{
        .disposition = disposition,
        .proposal_sha256 = proposal.proposal_sha256,
        .authorization_sha256 = authorization.authorization_sha256,
        .idempotency_key_sha256 = proposal.idempotency_key_sha256,
        .effect_sha256 = effect_sha256,
        .service_event_sha256 = service_event_sha256,
        .output_sha256 = output_sha256,
    };
    result.delivery_sha256 = deliverySha256V1(result);
    try validateDeliveryReceiptV1(result);
    return result;
}

pub fn deliverySha256V1(value: DeliveryReceiptV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(delivery_domain);
    hashU64(&hash, value.abi_version);
    hashU8(&hash, @intFromEnum(value.disposition));
    hash.update(&value.proposal_sha256);
    hash.update(&value.authorization_sha256);
    hash.update(&value.idempotency_key_sha256);
    hash.update(&value.effect_sha256);
    hash.update(&value.service_event_sha256);
    hash.update(&value.output_sha256);
    return finish(&hash);
}

pub fn validateDeliveryReceiptV1(value: DeliveryReceiptV1) Error!void {
    const effect_shape = switch (value.disposition) {
        .executed, .reused, .conflict => !digestIsZero(value.effect_sha256),
        .denied => digestIsZero(value.effect_sha256),
    };
    if (value.abi_version != delivery_abi or !effect_shape or
        digestIsZero(value.proposal_sha256) or
        digestIsZero(value.authorization_sha256) or
        digestIsZero(value.idempotency_key_sha256) or
        digestIsZero(value.service_event_sha256) or
        digestIsZero(value.output_sha256) or
        !digestEqual(value.delivery_sha256, deliverySha256V1(value)))
        return Error.InvalidDelivery;
}

pub fn validateDeliveryCompositionV1(
    value: DeliveryReceiptV1,
    proposal: ActionProposalV1,
    authorization: AuthorizationReceiptV1,
    maybe_effect: ?EffectReceiptV1,
    service_event_sha256: Digest,
) Error!void {
    try validateDeliveryReceiptV1(value);
    const expected = try makeDeliveryReceiptV1(
        value.disposition,
        proposal,
        authorization,
        maybe_effect,
        service_event_sha256,
    );
    if (!std.meta.eql(value, expected)) return Error.InvalidDelivery;
}

pub fn terminalOutputSha256V1(
    disposition: DeliveryDispositionV1,
    proposal: ActionProposalV1,
    authorization: AuthorizationReceiptV1,
    effect_sha256: Digest,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(terminal_output_domain);
    hashU8(&hash, @intFromEnum(disposition));
    hash.update(&proposal.proposal_sha256);
    hash.update(&authorization.authorization_sha256);
    hash.update(&effect_sha256);
    return finish(&hash);
}

fn deltaMagnitude(value: i64) u64 {
    std.debug.assert(value != std.math.minInt(i64));
    return if (value < 0)
        @intCast(-value)
    else
        @intCast(value);
}

fn hashU8(hash: anytype, value: u8) void {
    hash.update(&.{value});
}

fn hashU64(hash: anytype, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

fn hashI64(hash: anytype, value: i64) void {
    hashU64(hash, @bitCast(value));
}

fn finish(hash: anytype) Digest {
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn digestIsZero(value: Digest) bool {
    return std.mem.eql(u8, &value, &zero_digest);
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

fn testDigest(byte: u8) Digest {
    return [_]u8{byte} ** 32;
}

fn containsPointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => true,
        .array => |info| containsPointer(info.child),
        .optional => |info| containsPointer(info.child),
        .@"struct" => |info| blk: {
            inline for (info.fields) |field|
                if (containsPointer(field.type)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

test "tool action portable records are pointer free and compose exactly" {
    const testing = std.testing;
    try testing.expect(!containsPointer(DescriptorV1));
    try testing.expect(!containsPointer(BoundedAddArgumentsV1));
    try testing.expect(!containsPointer(ActionProposalV1));
    try testing.expect(!containsPointer(PolicyV1));
    try testing.expect(!containsPointer(AuthorizationReceiptV1));
    try testing.expect(!containsPointer(EffectReceiptV1));
    try testing.expect(!containsPointer(DeliveryReceiptV1));

    const descriptor = try makeDescriptorV1(
        0x544f_4f4c,
        testDigest(0x11),
        testDigest(0x12),
        testDigest(0x13),
        testDigest(0x14),
    );
    const arguments = try makeBoundedAddArgumentsV1(7, 4);
    const proposal = try makeActionProposalV1(
        41,
        0,
        testDigest(0x21),
        descriptor,
        arguments,
        testDigest(0x22),
    );
    const policy = try makePolicyV1(
        1,
        41,
        true,
        8,
        -16,
        16,
        descriptor,
        testDigest(0x31),
    );
    const authorization = try authorizeBoundedAddV1(
        proposal,
        descriptor,
        arguments,
        policy,
        2,
    );
    try testing.expectEqual(AuthorizationKindV1.allowed, authorization.kind);
    try testing.expectEqual(@as(i64, 6), authorization.projected_after);
    const effect = try makeEffectReceiptV1(
        1,
        proposal,
        arguments,
        authorization,
    );
    const substituted_target = try makeBoundedAddArgumentsV1(4, 2);
    try testing.expectError(
        Error.InvalidEffect,
        makeEffectReceiptV1(
            1,
            proposal,
            substituted_target,
            authorization,
        ),
    );
    const delivery = try makeDeliveryReceiptV1(
        .executed,
        proposal,
        authorization,
        effect,
        testDigest(0x41),
    );
    try validateDeliveryCompositionV1(
        delivery,
        proposal,
        authorization,
        effect,
        testDigest(0x41),
    );
}

test "tool action local policy denies without constructing an effect" {
    const testing = std.testing;
    const descriptor = try makeDescriptorV1(
        9,
        testDigest(0x51),
        testDigest(0x52),
        testDigest(0x53),
        testDigest(0x54),
    );
    const arguments = try makeBoundedAddArgumentsV1(1, 9);
    const proposal = try makeActionProposalV1(
        7,
        2,
        testDigest(0x55),
        descriptor,
        arguments,
        testDigest(0x56),
    );
    const policy = try makePolicyV1(
        3,
        7,
        true,
        4,
        -10,
        10,
        descriptor,
        testDigest(0x57),
    );
    const authorization = try authorizeBoundedAddV1(
        proposal,
        descriptor,
        arguments,
        policy,
        0,
    );
    try testing.expectEqual(AuthorizationKindV1.denied, authorization.kind);
    try testing.expectEqual(
        DenialReasonV1.delta_out_of_range,
        authorization.reason,
    );
    try testing.expectError(
        Error.InvalidEffect,
        makeEffectReceiptV1(1, proposal, arguments, authorization),
    );
    const delivery = try makeDeliveryReceiptV1(
        .denied,
        proposal,
        authorization,
        null,
        testDigest(0x58),
    );
    try testing.expect(digestIsZero(delivery.effect_sha256));

    const foreign = try makeActionProposalV1(
        8,
        3,
        testDigest(0x59),
        descriptor,
        arguments,
        testDigest(0x5a),
    );
    try testing.expectError(
        Error.InvalidAuthorization,
        denyIdempotencyConflictV1(foreign, policy, 0),
    );

    const other_descriptor = try makeDescriptorV1(
        10,
        testDigest(0x5b),
        testDigest(0x5c),
        testDigest(0x5d),
        testDigest(0x5e),
    );
    const other_proposal = try makeActionProposalV1(
        7,
        4,
        testDigest(0x5f),
        other_descriptor,
        arguments,
        testDigest(0x60),
    );
    try testing.expectError(
        Error.InvalidAuthorization,
        denyIdempotencyConflictV1(other_proposal, policy, 0),
    );

    const disabled_policy = try makePolicyV1(
        4,
        7,
        false,
        4,
        -10,
        10,
        descriptor,
        testDigest(0x61),
    );
    try testing.expectError(
        Error.InvalidAuthorization,
        denyIdempotencyConflictV1(proposal, disabled_policy, 0),
    );
}

test "tool action resealed substitutions fail composition validation" {
    const testing = std.testing;
    const descriptor = try makeDescriptorV1(
        10,
        testDigest(0x61),
        testDigest(0x62),
        testDigest(0x63),
        testDigest(0x64),
    );
    const arguments = try makeBoundedAddArgumentsV1(3, 2);
    const proposal = try makeActionProposalV1(
        5,
        1,
        testDigest(0x65),
        descriptor,
        arguments,
        testDigest(0x66),
    );
    const policy = try makePolicyV1(
        1,
        5,
        true,
        8,
        -20,
        20,
        descriptor,
        testDigest(0x67),
    );
    const authorization = try authorizeBoundedAddV1(
        proposal,
        descriptor,
        arguments,
        policy,
        1,
    );
    const effect = try makeEffectReceiptV1(
        1,
        proposal,
        arguments,
        authorization,
    );
    const delivery = try makeDeliveryReceiptV1(
        .executed,
        proposal,
        authorization,
        effect,
        testDigest(0x68),
    );

    var changed_arguments = try makeBoundedAddArgumentsV1(3, 3);
    var changed_proposal = proposal;
    changed_proposal.arguments_sha256 = changed_arguments.arguments_sha256;
    changed_proposal.proposal_sha256 =
        actionProposalSha256V1(changed_proposal);
    try testing.expectError(
        Error.InvalidProposal,
        validateProposalCompositionV1(
            changed_proposal,
            descriptor,
            arguments,
        ),
    );

    var changed_effect = effect;
    changed_effect.after_value += 1;
    changed_effect.output_sha256 = boundedAddOutputSha256V1(
        changed_effect.target_key,
        changed_effect.before_value,
        changed_effect.after_value,
    );
    changed_effect.effect_sha256 = effectSha256V1(changed_effect);
    try testing.expectError(
        Error.InvalidEffect,
        validateEffectCompositionV1(
            changed_effect,
            proposal,
            arguments,
            authorization,
        ),
    );

    var changed_target = effect;
    changed_target.target_key += 1;
    changed_target.output_sha256 = boundedAddOutputSha256V1(
        changed_target.target_key,
        changed_target.before_value,
        changed_target.after_value,
    );
    changed_target.effect_sha256 = effectSha256V1(changed_target);
    try testing.expectError(
        Error.InvalidEffect,
        validateEffectCompositionV1(
            changed_target,
            proposal,
            arguments,
            authorization,
        ),
    );

    var changed_delivery = delivery;
    changed_delivery.service_event_sha256 = testDigest(0x69);
    changed_delivery.delivery_sha256 = deliverySha256V1(changed_delivery);
    try testing.expectError(
        Error.InvalidDelivery,
        validateDeliveryCompositionV1(
            changed_delivery,
            proposal,
            authorization,
            effect,
            testDigest(0x68),
        ),
    );

    _ = &changed_arguments;
}
