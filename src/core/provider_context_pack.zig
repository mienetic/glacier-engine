//! Lossless, provider-domain-bound context packing.
//!
//! The packer stores no text and performs no tokenization. It removes only
//! exact rendered duplicates whose callers explicitly declare idempotent,
//! preserves one decision for every logical span and emits portable evidence
//! that can be verified without packer state. Separate observations bind raw
//! and packed full-wire token counts without executing a tokenizer in core.

const std = @import("std");

pub const domain_abi: u64 = 0x4750_4344_0000_0001;
pub const policy_abi: u64 = 0x4750_4350_0000_0001;
pub const span_abi: u64 = 0x4750_4353_0000_0001;
pub const decision_abi: u64 = 0x4750_4345_0000_0001;
pub const receipt_abi: u64 = 0x4750_4352_0000_0001;
pub const token_observation_abi: u64 = 0x4750_4354_0000_0001;
pub const reconciliation_abi: u64 = 0x4750_4358_0000_0001;
pub const Digest = [32]u8;
pub const zero_digest: Digest = [_]u8{0} ** 32;
pub const max_supported_spans: u32 = 4096;

const domain_hash_domain = "glacier-provider-context-domain-v1\x00";
const policy_hash_domain = "glacier-provider-context-policy-v1\x00";
const span_hash_domain = "glacier-provider-context-span-v1\x00";
const decision_hash_domain = "glacier-provider-context-decision-v1\x00";
const mapping_initial_domain = "glacier-provider-context-mapping-v1\x00";
const mapping_append_domain = "glacier-provider-context-mapping-append-v1\x00";
const emitted_initial_domain = "glacier-provider-context-emitted-v1\x00";
const emitted_append_domain = "glacier-provider-context-emitted-append-v1\x00";
const receipt_hash_domain = "glacier-provider-context-receipt-v1\x00";
const token_observation_domain =
    "glacier-provider-context-token-observation-v1\x00";
const reconciliation_domain =
    "glacier-provider-context-token-reconciliation-v1\x00";

pub const Error = error{
    InvalidDomain,
    InvalidPolicy,
    InvalidSpan,
    InvalidDecisionStorage,
    CapacityExceeded,
    TokenizationConflict,
    BudgetExceeded,
    TokenCountOverflow,
    InvalidTokenObservation,
    InvalidReconciliation,
};

pub const DomainV1 = struct {
    abi_version: u64 = domain_abi,
    isolation_key: u64 = 0,
    adapter_abi: u64 = 0,
    provider_namespace_sha256: Digest = zero_digest,
    model_sha256: Digest = zero_digest,
    tokenizer_sha256: Digest = zero_digest,
    render_policy_sha256: Digest = zero_digest,
    domain_sha256: Digest = zero_digest,
};

pub fn makeDomainV1(
    isolation_key: u64,
    adapter_abi: u64,
    provider_namespace_sha256: Digest,
    model_sha256: Digest,
    tokenizer_sha256: Digest,
    render_policy_sha256: Digest,
) Error!DomainV1 {
    var domain: DomainV1 = .{
        .isolation_key = isolation_key,
        .adapter_abi = adapter_abi,
        .provider_namespace_sha256 = provider_namespace_sha256,
        .model_sha256 = model_sha256,
        .tokenizer_sha256 = tokenizer_sha256,
        .render_policy_sha256 = render_policy_sha256,
    };
    domain.domain_sha256 = domainSha256(domain);
    if (!domainValidV1(domain)) return Error.InvalidDomain;
    return domain;
}

pub fn domainSha256(domain: DomainV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(domain_hash_domain);
    hashU64(&hash, domain.abi_version);
    hashU64(&hash, domain.isolation_key);
    hashU64(&hash, domain.adapter_abi);
    hash.update(&domain.provider_namespace_sha256);
    hash.update(&domain.model_sha256);
    hash.update(&domain.tokenizer_sha256);
    hash.update(&domain.render_policy_sha256);
    return finish(&hash);
}

pub fn domainValidV1(domain: DomainV1) bool {
    return domain.abi_version == domain_abi and
        domain.isolation_key != 0 and domain.adapter_abi != 0 and
        !isZero(domain.provider_namespace_sha256) and
        !isZero(domain.model_sha256) and
        !isZero(domain.tokenizer_sha256) and
        !isZero(domain.render_policy_sha256) and std.mem.eql(
        u8,
        &domain.domain_sha256,
        &domainSha256(domain),
    );
}

pub const PolicyV1 = struct {
    abi_version: u64 = policy_abi,
    max_spans: u32 = 0,
    max_input_tokens: u64 = 0,
    fixed_overhead_tokens: u64 = 0,
    policy_sha256: Digest = zero_digest,
};

pub fn makePolicyV1(
    max_spans: u32,
    max_input_tokens: u64,
    fixed_overhead_tokens: u64,
) Error!PolicyV1 {
    var policy: PolicyV1 = .{
        .max_spans = max_spans,
        .max_input_tokens = max_input_tokens,
        .fixed_overhead_tokens = fixed_overhead_tokens,
    };
    policy.policy_sha256 = policySha256(policy);
    if (!policyValidV1(policy)) return Error.InvalidPolicy;
    return policy;
}

pub fn policySha256(policy: PolicyV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(policy_hash_domain);
    hashU64(&hash, policy.abi_version);
    hashU32(&hash, policy.max_spans);
    hashU64(&hash, policy.max_input_tokens);
    hashU64(&hash, policy.fixed_overhead_tokens);
    return finish(&hash);
}

pub fn policyValidV1(policy: PolicyV1) bool {
    return policy.abi_version == policy_abi and policy.max_spans != 0 and
        policy.max_spans <= max_supported_spans and
        policy.max_input_tokens != 0 and
        policy.fixed_overhead_tokens <= policy.max_input_tokens and
        std.mem.eql(u8, &policy.policy_sha256, &policySha256(policy));
}

pub const SpanKind = enum(u8) {
    system,
    tool,
    user,
    assistant,
    evidence,
};

pub const ReuseMode = enum(u8) {
    unique,
    idempotent_exact,
};

pub const Retention = enum(u8) {
    required,
    preserved,
};

pub const SpanV1 = struct {
    abi_version: u64 = span_abi,
    sequence: u32 = 0,
    kind: SpanKind = .system,
    reuse_mode: ReuseMode = .unique,
    retention: Retention = .required,
    content_sha256: Digest = zero_digest,
    rendered_sha256: Digest = zero_digest,
    provenance_sha256: Digest = zero_digest,
    token_count: u64 = 0,
    span_sha256: Digest = zero_digest,
};

pub fn makeSpanV1(
    sequence: u32,
    kind: SpanKind,
    reuse_mode: ReuseMode,
    retention: Retention,
    content_sha256: Digest,
    rendered_sha256: Digest,
    provenance_sha256: Digest,
    token_count: u64,
) Error!SpanV1 {
    var span: SpanV1 = .{
        .sequence = sequence,
        .kind = kind,
        .reuse_mode = reuse_mode,
        .retention = retention,
        .content_sha256 = content_sha256,
        .rendered_sha256 = rendered_sha256,
        .provenance_sha256 = provenance_sha256,
        .token_count = token_count,
    };
    span.span_sha256 = spanSha256(span);
    if (!spanValidV1(span)) return Error.InvalidSpan;
    return span;
}

pub fn spanSha256(span: SpanV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(span_hash_domain);
    hashU64(&hash, span.abi_version);
    hashU32(&hash, span.sequence);
    hashU8(&hash, @intFromEnum(span.kind));
    hashU8(&hash, @intFromEnum(span.reuse_mode));
    hashU8(&hash, @intFromEnum(span.retention));
    hash.update(&span.content_sha256);
    hash.update(&span.rendered_sha256);
    hash.update(&span.provenance_sha256);
    hashU64(&hash, span.token_count);
    return finish(&hash);
}

pub fn spanValidV1(span: SpanV1) bool {
    return span.abi_version == span_abi and
        !isZero(span.content_sha256) and !isZero(span.rendered_sha256) and
        !isZero(span.provenance_sha256) and std.mem.eql(
        u8,
        &span.span_sha256,
        &spanSha256(span),
    );
}

pub const DecisionAction = enum(u8) {
    emit,
    alias,
};

pub const DecisionV1 = struct {
    abi_version: u64 = decision_abi,
    sequence: u32 = 0,
    action: DecisionAction = .emit,
    span_sha256: Digest = zero_digest,
    representative_sequence: u32 = 0,
    representative_span_sha256: Digest = zero_digest,
    logical_tokens: u64 = 0,
    emitted_tokens: u64 = 0,
    decision_sha256: Digest = zero_digest,
};

pub fn decisionSha256(decision: DecisionV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(decision_hash_domain);
    hashU64(&hash, decision.abi_version);
    hashU32(&hash, decision.sequence);
    hashU8(&hash, @intFromEnum(decision.action));
    hash.update(&decision.span_sha256);
    hashU32(&hash, decision.representative_sequence);
    hash.update(&decision.representative_span_sha256);
    hashU64(&hash, decision.logical_tokens);
    hashU64(&hash, decision.emitted_tokens);
    return finish(&hash);
}

pub fn decisionValidV1(decision: DecisionV1) bool {
    if (decision.abi_version != decision_abi or
        isZero(decision.span_sha256) or
        isZero(decision.representative_span_sha256)) return false;
    switch (decision.action) {
        .emit => if (decision.representative_sequence != decision.sequence or
            decision.emitted_tokens != decision.logical_tokens) return false,
        .alias => if (decision.representative_sequence >= decision.sequence or
            decision.emitted_tokens != 0) return false,
    }
    return std.mem.eql(
        u8,
        &decision.decision_sha256,
        &decisionSha256(decision),
    );
}

pub const ReceiptV1 = struct {
    abi_version: u64 = receipt_abi,
    domain_sha256: Digest = zero_digest,
    policy_sha256: Digest = zero_digest,
    input_spans: u32 = 0,
    emitted_spans: u32 = 0,
    aliased_spans: u32 = 0,
    required_spans: u32 = 0,
    logical_tokens: u64 = 0,
    emitted_tokens: u64 = 0,
    deduplicated_tokens: u64 = 0,
    mapping_chain_sha256: Digest = zero_digest,
    emitted_chain_sha256: Digest = zero_digest,
    receipt_sha256: Digest = zero_digest,
};

pub fn receiptSha256(receipt: ReceiptV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(receipt_hash_domain);
    hashU64(&hash, receipt.abi_version);
    hash.update(&receipt.domain_sha256);
    hash.update(&receipt.policy_sha256);
    hashU32(&hash, receipt.input_spans);
    hashU32(&hash, receipt.emitted_spans);
    hashU32(&hash, receipt.aliased_spans);
    hashU32(&hash, receipt.required_spans);
    hashU64(&hash, receipt.logical_tokens);
    hashU64(&hash, receipt.emitted_tokens);
    hashU64(&hash, receipt.deduplicated_tokens);
    hash.update(&receipt.mapping_chain_sha256);
    hash.update(&receipt.emitted_chain_sha256);
    return finish(&hash);
}

pub fn receiptValidV1(receipt: ReceiptV1) bool {
    const span_total = std.math.add(
        u32,
        receipt.emitted_spans,
        receipt.aliased_spans,
    ) catch return false;
    const token_total = std.math.add(
        u64,
        receipt.emitted_tokens,
        receipt.deduplicated_tokens,
    ) catch return false;
    return receipt.abi_version == receipt_abi and
        !isZero(receipt.domain_sha256) and !isZero(receipt.policy_sha256) and
        !isZero(receipt.mapping_chain_sha256) and
        !isZero(receipt.emitted_chain_sha256) and
        span_total == receipt.input_spans and
        receipt.required_spans <= receipt.input_spans and
        token_total == receipt.logical_tokens and std.mem.eql(
        u8,
        &receipt.receipt_sha256,
        &receiptSha256(receipt),
    );
}

pub const ContextArm = enum(u8) {
    raw,
    packed_context,
};

pub const TokenObservationV1 = struct {
    abi_version: u64 = token_observation_abi,
    arm: ContextArm = .raw,
    domain_sha256: Digest = zero_digest,
    context_chain_sha256: Digest = zero_digest,
    wire_sha256: Digest = zero_digest,
    tokenizer_execution_sha256: Digest = zero_digest,
    wire_tokens: u64 = 0,
    observation_sha256: Digest = zero_digest,
};

pub fn makeTokenObservationV1(
    domain: DomainV1,
    receipt: ReceiptV1,
    arm: ContextArm,
    wire_sha256: Digest,
    tokenizer_execution_sha256: Digest,
    wire_tokens: u64,
) Error!TokenObservationV1 {
    if (!domainValidV1(domain) or !receiptValidV1(receipt) or
        !std.mem.eql(
            u8,
            &receipt.domain_sha256,
            &domain.domain_sha256,
        ) or isZero(wire_sha256) or isZero(tokenizer_execution_sha256))
        return Error.InvalidTokenObservation;
    var observation: TokenObservationV1 = .{
        .arm = arm,
        .domain_sha256 = domain.domain_sha256,
        .context_chain_sha256 = switch (arm) {
            .raw => receipt.mapping_chain_sha256,
            .packed_context => receipt.emitted_chain_sha256,
        },
        .wire_sha256 = wire_sha256,
        .tokenizer_execution_sha256 = tokenizer_execution_sha256,
        .wire_tokens = wire_tokens,
    };
    observation.observation_sha256 = tokenObservationSha256(observation);
    if (!tokenObservationMatchesV1(observation, domain, receipt, arm))
        return Error.InvalidTokenObservation;
    return observation;
}

pub fn tokenObservationSha256(observation: TokenObservationV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(token_observation_domain);
    hashU64(&hash, observation.abi_version);
    hashU8(&hash, @intFromEnum(observation.arm));
    hash.update(&observation.domain_sha256);
    hash.update(&observation.context_chain_sha256);
    hash.update(&observation.wire_sha256);
    hash.update(&observation.tokenizer_execution_sha256);
    hashU64(&hash, observation.wire_tokens);
    return finish(&hash);
}

pub fn tokenObservationValidV1(observation: TokenObservationV1) bool {
    return observation.abi_version == token_observation_abi and
        !isZero(observation.domain_sha256) and
        !isZero(observation.context_chain_sha256) and
        !isZero(observation.wire_sha256) and
        !isZero(observation.tokenizer_execution_sha256) and std.mem.eql(
        u8,
        &observation.observation_sha256,
        &tokenObservationSha256(observation),
    );
}

pub fn tokenObservationMatchesV1(
    observation: TokenObservationV1,
    domain: DomainV1,
    receipt: ReceiptV1,
    arm: ContextArm,
) bool {
    if (!tokenObservationValidV1(observation) or
        !domainValidV1(domain) or !receiptValidV1(receipt) or
        observation.arm != arm) return false;
    const expected_chain = switch (arm) {
        .raw => receipt.mapping_chain_sha256,
        .packed_context => receipt.emitted_chain_sha256,
    };
    return std.mem.eql(
        u8,
        &observation.domain_sha256,
        &domain.domain_sha256,
    ) and std.mem.eql(
        u8,
        &receipt.domain_sha256,
        &domain.domain_sha256,
    ) and std.mem.eql(
        u8,
        &observation.context_chain_sha256,
        &expected_chain,
    );
}

pub const ReconciliationV1 = struct {
    abi_version: u64 = reconciliation_abi,
    domain_sha256: Digest = zero_digest,
    policy_sha256: Digest = zero_digest,
    receipt_sha256: Digest = zero_digest,
    raw_observation_sha256: Digest = zero_digest,
    packed_observation_sha256: Digest = zero_digest,
    tokenizer_execution_sha256: Digest = zero_digest,
    raw_wire_tokens: u64 = 0,
    packed_wire_tokens: u64 = 0,
    wire_deduplicated_tokens: u64 = 0,
    max_input_tokens: u64 = 0,
    packed_budget_headroom: u64 = 0,
    reconciliation_sha256: Digest = zero_digest,
};

pub fn makeReconciliationV1(
    domain: DomainV1,
    policy: PolicyV1,
    receipt: ReceiptV1,
    raw: TokenObservationV1,
    packed_observation: TokenObservationV1,
) Error!ReconciliationV1 {
    if (!domainValidV1(domain)) return Error.InvalidDomain;
    if (!policyValidV1(policy)) return Error.InvalidPolicy;
    if (!receiptValidV1(receipt) or !std.mem.eql(
        u8,
        &receipt.domain_sha256,
        &domain.domain_sha256,
    ) or !std.mem.eql(
        u8,
        &receipt.policy_sha256,
        &policy.policy_sha256,
    )) return Error.InvalidReconciliation;
    if (!tokenObservationMatchesV1(raw, domain, receipt, .raw) or
        !tokenObservationMatchesV1(
            packed_observation,
            domain,
            receipt,
            .packed_context,
        ) or
        !std.mem.eql(
            u8,
            &raw.tokenizer_execution_sha256,
            &packed_observation.tokenizer_execution_sha256,
        )) return Error.InvalidReconciliation;
    if (raw.wire_tokens != receipt.logical_tokens or
        packed_observation.wire_tokens != receipt.emitted_tokens)
        return Error.TokenizationConflict;
    if (packed_observation.wire_tokens > policy.max_input_tokens)
        return Error.BudgetExceeded;
    const wire_deduplicated_tokens = std.math.sub(
        u64,
        raw.wire_tokens,
        packed_observation.wire_tokens,
    ) catch return Error.TokenizationConflict;
    if (wire_deduplicated_tokens != receipt.deduplicated_tokens)
        return Error.TokenizationConflict;
    const packed_budget_headroom = std.math.sub(
        u64,
        policy.max_input_tokens,
        packed_observation.wire_tokens,
    ) catch return Error.BudgetExceeded;
    var reconciliation: ReconciliationV1 = .{
        .domain_sha256 = domain.domain_sha256,
        .policy_sha256 = policy.policy_sha256,
        .receipt_sha256 = receipt.receipt_sha256,
        .raw_observation_sha256 = raw.observation_sha256,
        .packed_observation_sha256 = packed_observation.observation_sha256,
        .tokenizer_execution_sha256 = raw.tokenizer_execution_sha256,
        .raw_wire_tokens = raw.wire_tokens,
        .packed_wire_tokens = packed_observation.wire_tokens,
        .wire_deduplicated_tokens = wire_deduplicated_tokens,
        .max_input_tokens = policy.max_input_tokens,
        .packed_budget_headroom = packed_budget_headroom,
    };
    reconciliation.reconciliation_sha256 = reconciliationSha256(
        reconciliation,
    );
    if (!reconciliationValidV1(reconciliation))
        return Error.InvalidReconciliation;
    return reconciliation;
}

pub fn reconciliationSha256(reconciliation: ReconciliationV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(reconciliation_domain);
    hashU64(&hash, reconciliation.abi_version);
    hash.update(&reconciliation.domain_sha256);
    hash.update(&reconciliation.policy_sha256);
    hash.update(&reconciliation.receipt_sha256);
    hash.update(&reconciliation.raw_observation_sha256);
    hash.update(&reconciliation.packed_observation_sha256);
    hash.update(&reconciliation.tokenizer_execution_sha256);
    hashU64(&hash, reconciliation.raw_wire_tokens);
    hashU64(&hash, reconciliation.packed_wire_tokens);
    hashU64(&hash, reconciliation.wire_deduplicated_tokens);
    hashU64(&hash, reconciliation.max_input_tokens);
    hashU64(&hash, reconciliation.packed_budget_headroom);
    return finish(&hash);
}

pub fn reconciliationValidV1(reconciliation: ReconciliationV1) bool {
    const raw_total = std.math.add(
        u64,
        reconciliation.packed_wire_tokens,
        reconciliation.wire_deduplicated_tokens,
    ) catch return false;
    const budget_total = std.math.add(
        u64,
        reconciliation.packed_wire_tokens,
        reconciliation.packed_budget_headroom,
    ) catch return false;
    return reconciliation.abi_version == reconciliation_abi and
        !isZero(reconciliation.domain_sha256) and
        !isZero(reconciliation.policy_sha256) and
        !isZero(reconciliation.receipt_sha256) and
        !isZero(reconciliation.raw_observation_sha256) and
        !isZero(reconciliation.packed_observation_sha256) and
        !isZero(reconciliation.tokenizer_execution_sha256) and
        raw_total == reconciliation.raw_wire_tokens and
        budget_total == reconciliation.max_input_tokens and std.mem.eql(
        u8,
        &reconciliation.reconciliation_sha256,
        &reconciliationSha256(reconciliation),
    );
}

pub fn verifyReconciliationV1(
    domain: DomainV1,
    policy: PolicyV1,
    receipt: ReceiptV1,
    raw: TokenObservationV1,
    packed_observation: TokenObservationV1,
    reconciliation: ReconciliationV1,
) bool {
    const expected = makeReconciliationV1(
        domain,
        policy,
        receipt,
        raw,
        packed_observation,
    ) catch return false;
    return std.meta.eql(expected, reconciliation);
}

/// Packs exact idempotent duplicates without allocation or semantic dropping.
/// No output decision is written until every input, token count and budget
/// check has passed.
pub fn packV1(
    domain: DomainV1,
    policy: PolicyV1,
    spans: []const SpanV1,
    decisions: []DecisionV1,
) Error!ReceiptV1 {
    if (!domainValidV1(domain)) return Error.InvalidDomain;
    if (!policyValidV1(policy)) return Error.InvalidPolicy;
    if (spans.len > policy.max_spans or spans.len > std.math.maxInt(u32) or
        decisions.len < spans.len) return Error.CapacityExceeded;
    if (slicesOverlap(spans, decisions))
        return Error.InvalidDecisionStorage;
    for (decisions[0..spans.len]) |decision|
        if (!std.meta.eql(decision, DecisionV1{}))
            return Error.InvalidDecisionStorage;

    var logical_tokens: u64 = policy.fixed_overhead_tokens;
    var emitted_tokens: u64 = policy.fixed_overhead_tokens;
    var emitted_spans: u32 = 0;
    var required_spans: u32 = 0;
    for (spans, 0..) |span, index| {
        if (!spanValidV1(span) or span.sequence != index)
            return Error.InvalidSpan;
        const representative = try representativeIndex(spans, index);
        logical_tokens = addTokens(logical_tokens, span.token_count) catch
            return Error.TokenCountOverflow;
        if (representative == index) {
            emitted_tokens = addTokens(emitted_tokens, span.token_count) catch
                return Error.TokenCountOverflow;
            emitted_spans = std.math.add(u32, emitted_spans, 1) catch
                return Error.TokenCountOverflow;
        }
        if (span.retention == .required)
            required_spans = std.math.add(u32, required_spans, 1) catch
                return Error.TokenCountOverflow;
    }
    if (emitted_tokens > policy.max_input_tokens)
        return Error.BudgetExceeded;

    var mapping_chain = initialMappingChainSha256(
        domain,
        policy,
        @intCast(spans.len),
    );
    var emitted_chain = initialEmittedChainSha256(
        domain,
        policy,
    );
    for (spans, 0..) |span, index| {
        const representative = representativeIndex(spans, index) catch
            unreachable;
        const action: DecisionAction = if (representative == index)
            .emit
        else
            .alias;
        var decision: DecisionV1 = .{
            .sequence = @intCast(index),
            .action = action,
            .span_sha256 = span.span_sha256,
            .representative_sequence = @intCast(representative),
            .representative_span_sha256 = spans[representative].span_sha256,
            .logical_tokens = span.token_count,
            .emitted_tokens = if (action == .emit) span.token_count else 0,
        };
        decision.decision_sha256 = decisionSha256(decision);
        decisions[index] = decision;
        mapping_chain = appendMappingChainSha256(
            mapping_chain,
            decision,
        );
        if (action == .emit)
            emitted_chain = appendEmittedChainSha256(
                emitted_chain,
                decision,
            );
    }
    const aliased_spans = std.math.sub(
        u32,
        @intCast(spans.len),
        emitted_spans,
    ) catch unreachable;
    const deduplicated_tokens = std.math.sub(
        u64,
        logical_tokens,
        emitted_tokens,
    ) catch unreachable;
    var receipt: ReceiptV1 = .{
        .domain_sha256 = domain.domain_sha256,
        .policy_sha256 = policy.policy_sha256,
        .input_spans = @intCast(spans.len),
        .emitted_spans = emitted_spans,
        .aliased_spans = aliased_spans,
        .required_spans = required_spans,
        .logical_tokens = logical_tokens,
        .emitted_tokens = emitted_tokens,
        .deduplicated_tokens = deduplicated_tokens,
        .mapping_chain_sha256 = mapping_chain,
        .emitted_chain_sha256 = emitted_chain,
    };
    receipt.receipt_sha256 = receiptSha256(receipt);
    return receipt;
}

/// Reconstructs every mapping and token total without trusting packer state.
pub fn verifyPackV1(
    domain: DomainV1,
    policy: PolicyV1,
    spans: []const SpanV1,
    decisions: []const DecisionV1,
    receipt: ReceiptV1,
) bool {
    if (!domainValidV1(domain) or !policyValidV1(policy) or
        !receiptValidV1(receipt) or spans.len != decisions.len or
        spans.len > policy.max_spans or spans.len > std.math.maxInt(u32) or
        !std.mem.eql(u8, &receipt.domain_sha256, &domain.domain_sha256) or
        !std.mem.eql(u8, &receipt.policy_sha256, &policy.policy_sha256))
        return false;
    var logical_tokens: u64 = policy.fixed_overhead_tokens;
    var emitted_tokens: u64 = policy.fixed_overhead_tokens;
    var emitted_spans: u32 = 0;
    var required_spans: u32 = 0;
    var mapping_chain = initialMappingChainSha256(
        domain,
        policy,
        @intCast(spans.len),
    );
    var emitted_chain = initialEmittedChainSha256(domain, policy);
    for (spans, decisions, 0..) |span, decision, index| {
        if (!spanValidV1(span) or span.sequence != index or
            !decisionValidV1(decision)) return false;
        const representative = representativeIndex(spans, index) catch
            return false;
        const action: DecisionAction = if (representative == index)
            .emit
        else
            .alias;
        var expected: DecisionV1 = .{
            .sequence = @intCast(index),
            .action = action,
            .span_sha256 = span.span_sha256,
            .representative_sequence = @intCast(representative),
            .representative_span_sha256 = spans[representative].span_sha256,
            .logical_tokens = span.token_count,
            .emitted_tokens = if (action == .emit) span.token_count else 0,
        };
        expected.decision_sha256 = decisionSha256(expected);
        if (!std.meta.eql(expected, decision)) return false;
        logical_tokens = addTokens(logical_tokens, span.token_count) catch
            return false;
        if (action == .emit) {
            emitted_tokens = addTokens(emitted_tokens, span.token_count) catch
                return false;
            emitted_spans = std.math.add(u32, emitted_spans, 1) catch
                return false;
            emitted_chain = appendEmittedChainSha256(
                emitted_chain,
                decision,
            );
        }
        if (span.retention == .required)
            required_spans = std.math.add(u32, required_spans, 1) catch
                return false;
        mapping_chain = appendMappingChainSha256(mapping_chain, decision);
    }
    if (emitted_tokens > policy.max_input_tokens) return false;
    const deduplicated_tokens = std.math.sub(
        u64,
        logical_tokens,
        emitted_tokens,
    ) catch return false;
    const aliased_spans = std.math.sub(
        u32,
        @intCast(spans.len),
        emitted_spans,
    ) catch return false;
    var expected_receipt: ReceiptV1 = .{
        .domain_sha256 = domain.domain_sha256,
        .policy_sha256 = policy.policy_sha256,
        .input_spans = @intCast(spans.len),
        .emitted_spans = emitted_spans,
        .aliased_spans = aliased_spans,
        .required_spans = required_spans,
        .logical_tokens = logical_tokens,
        .emitted_tokens = emitted_tokens,
        .deduplicated_tokens = deduplicated_tokens,
        .mapping_chain_sha256 = mapping_chain,
        .emitted_chain_sha256 = emitted_chain,
    };
    expected_receipt.receipt_sha256 = receiptSha256(expected_receipt);
    return std.meta.eql(expected_receipt, receipt);
}

fn representativeIndex(
    spans: []const SpanV1,
    index: usize,
) Error!usize {
    const span = spans[index];
    if (span.reuse_mode == .unique) return index;
    for (spans[0..index], 0..) |candidate, candidate_index| {
        if (candidate.reuse_mode != .idempotent_exact or
            candidate.kind != span.kind or
            !std.mem.eql(
                u8,
                &candidate.content_sha256,
                &span.content_sha256,
            ) or !std.mem.eql(
            u8,
            &candidate.rendered_sha256,
            &span.rendered_sha256,
        )) continue;
        if (candidate.token_count != span.token_count)
            return Error.TokenizationConflict;
        return candidate_index;
    }
    return index;
}

fn initialMappingChainSha256(
    domain: DomainV1,
    policy: PolicyV1,
    input_spans: u32,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(mapping_initial_domain);
    hash.update(&domain.domain_sha256);
    hash.update(&policy.policy_sha256);
    hashU32(&hash, input_spans);
    return finish(&hash);
}

fn appendMappingChainSha256(
    previous: Digest,
    decision: DecisionV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(mapping_append_domain);
    hash.update(&previous);
    hash.update(&decision.decision_sha256);
    return finish(&hash);
}

fn initialEmittedChainSha256(
    domain: DomainV1,
    policy: PolicyV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(emitted_initial_domain);
    hash.update(&domain.domain_sha256);
    hash.update(&policy.policy_sha256);
    return finish(&hash);
}

fn appendEmittedChainSha256(
    previous: Digest,
    decision: DecisionV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(emitted_append_domain);
    hash.update(&previous);
    hash.update(&decision.representative_span_sha256);
    hashU64(&hash, decision.emitted_tokens);
    return finish(&hash);
}

fn slicesOverlap(spans: []const SpanV1, decisions: []DecisionV1) bool {
    if (spans.len == 0 or decisions.len == 0) return false;
    const span_start = @intFromPtr(spans.ptr);
    const span_bytes = std.math.mul(usize, spans.len, @sizeOf(SpanV1)) catch
        return true;
    const span_end = std.math.add(usize, span_start, span_bytes) catch
        return true;
    const decision_start = @intFromPtr(decisions.ptr);
    const decision_bytes = std.math.mul(
        usize,
        decisions.len,
        @sizeOf(DecisionV1),
    ) catch return true;
    const decision_end = std.math.add(
        usize,
        decision_start,
        decision_bytes,
    ) catch return true;
    return span_start < decision_end and decision_start < span_end;
}

fn addTokens(left: u64, right: u64) error{Overflow}!u64 {
    return std.math.add(u64, left, right);
}

fn hashU8(hash: *std.crypto.hash.sha2.Sha256, value: u8) void {
    hash.update(&.{value});
}

fn hashU32(hash: *std.crypto.hash.sha2.Sha256, value: u32) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    hash.update(&bytes);
}

fn hashU64(hash: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

fn finish(hash: *std.crypto.hash.sha2.Sha256) Digest {
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn isZero(digest: Digest) bool {
    return std.mem.eql(u8, &digest, &zero_digest);
}

fn testDigest(seed: u8) Digest {
    var value: Digest = undefined;
    @memset(&value, seed);
    return value;
}

fn testDomain() !DomainV1 {
    return makeDomainV1(
        71,
        0x5445_5354_4354_5801,
        testDigest(0x11),
        testDigest(0x22),
        testDigest(0x33),
        testDigest(0x44),
    );
}

fn testSpan(
    sequence: u32,
    kind: SpanKind,
    reuse_mode: ReuseMode,
    retention: Retention,
    content: u8,
    rendered: u8,
    provenance: u8,
    tokens: u64,
) !SpanV1 {
    return makeSpanV1(
        sequence,
        kind,
        reuse_mode,
        retention,
        testDigest(content),
        testDigest(rendered),
        testDigest(provenance),
        tokens,
    );
}

test "exact idempotent spans pack losslessly under budget" {
    const domain = try testDomain();
    const policy = try makePolicyV1(8, 200, 10);
    const spans = [_]SpanV1{
        try testSpan(0, .system, .idempotent_exact, .required, 1, 11, 21, 60),
        try testSpan(1, .tool, .idempotent_exact, .required, 2, 12, 22, 80),
        try testSpan(2, .tool, .idempotent_exact, .required, 2, 12, 23, 80),
        try testSpan(3, .user, .unique, .preserved, 3, 13, 24, 30),
    };
    var decisions: [spans.len]DecisionV1 = [_]DecisionV1{.{}} ** spans.len;
    const receipt = try packV1(domain, policy, &spans, &decisions);
    try std.testing.expect(verifyPackV1(
        domain,
        policy,
        &spans,
        &decisions,
        receipt,
    ));
    try std.testing.expectEqual(@as(u32, 4), receipt.input_spans);
    try std.testing.expectEqual(@as(u32, 3), receipt.emitted_spans);
    try std.testing.expectEqual(@as(u32, 1), receipt.aliased_spans);
    try std.testing.expectEqual(@as(u32, 3), receipt.required_spans);
    try std.testing.expectEqual(@as(u64, 260), receipt.logical_tokens);
    try std.testing.expectEqual(@as(u64, 180), receipt.emitted_tokens);
    try std.testing.expectEqual(@as(u64, 80), receipt.deduplicated_tokens);
    try std.testing.expectEqual(DecisionAction.alias, decisions[2].action);
    try std.testing.expectEqual(@as(u32, 1), decisions[2].representative_sequence);
    try std.testing.expectEqualSlices(
        u8,
        &spans[1].span_sha256,
        &decisions[2].representative_span_sha256,
    );

    var forged = decisions;
    forged[2].action = .emit;
    forged[2].representative_sequence = 2;
    forged[2].representative_span_sha256 = spans[2].span_sha256;
    forged[2].emitted_tokens = spans[2].token_count;
    forged[2].decision_sha256 = decisionSha256(forged[2]);
    try std.testing.expect(decisionValidV1(forged[2]));
    try std.testing.expect(!verifyPackV1(
        domain,
        policy,
        &spans,
        &forged,
        receipt,
    ));
    var mutated_receipt = receipt;
    mutated_receipt.deduplicated_tokens += 1;
    mutated_receipt.receipt_sha256 = receiptSha256(mutated_receipt);
    try std.testing.expect(!verifyPackV1(
        domain,
        policy,
        &spans,
        &decisions,
        mutated_receipt,
    ));
}

test "role render and unique boundaries prevent accidental aliasing" {
    const domain = try testDomain();
    const policy = try makePolicyV1(8, 500, 0);
    const spans = [_]SpanV1{
        try testSpan(0, .system, .idempotent_exact, .required, 1, 11, 21, 10),
        try testSpan(1, .tool, .idempotent_exact, .required, 1, 11, 22, 10),
        try testSpan(2, .system, .idempotent_exact, .required, 1, 12, 23, 10),
        try testSpan(3, .system, .unique, .required, 1, 11, 24, 10),
        try testSpan(4, .system, .idempotent_exact, .required, 1, 11, 25, 10),
    };
    var decisions: [spans.len]DecisionV1 = [_]DecisionV1{.{}} ** spans.len;
    const receipt = try packV1(domain, policy, &spans, &decisions);
    try std.testing.expectEqual(@as(u32, 4), receipt.emitted_spans);
    try std.testing.expectEqual(DecisionAction.alias, decisions[4].action);
    try std.testing.expectEqual(@as(u32, 0), decisions[4].representative_sequence);

    var foreign_domain = domain;
    foreign_domain.isolation_key += 1;
    foreign_domain.domain_sha256 = domainSha256(foreign_domain);
    try std.testing.expect(domainValidV1(foreign_domain));
    try std.testing.expect(!verifyPackV1(
        foreign_domain,
        policy,
        &spans,
        &decisions,
        receipt,
    ));
}

test "conflict budget and capacity failures leave decisions untouched" {
    const domain = try testDomain();
    const policy = try makePolicyV1(4, 100, 0);
    const conflicting = [_]SpanV1{
        try testSpan(0, .tool, .idempotent_exact, .required, 1, 11, 21, 5),
        try testSpan(1, .tool, .idempotent_exact, .required, 1, 11, 22, 6),
    };
    var decisions: [2]DecisionV1 = .{ .{}, .{} };
    try std.testing.expectError(
        Error.TokenizationConflict,
        packV1(domain, policy, &conflicting, &decisions),
    );
    try std.testing.expectEqual(DecisionV1{}, decisions[0]);
    try std.testing.expectEqual(DecisionV1{}, decisions[1]);

    const over_budget = [_]SpanV1{
        try testSpan(0, .user, .unique, .required, 2, 12, 23, 101),
    };
    try std.testing.expectError(
        Error.BudgetExceeded,
        packV1(domain, policy, &over_budget, decisions[0..1]),
    );
    try std.testing.expectEqual(DecisionV1{}, decisions[0]);
    try std.testing.expectError(
        Error.CapacityExceeded,
        packV1(domain, policy, &conflicting, decisions[0..1]),
    );

    decisions[0].sequence = 1;
    try std.testing.expectError(
        Error.InvalidDecisionStorage,
        packV1(domain, policy, &over_budget, decisions[0..1]),
    );
    decisions[0] = .{};

    var bad_sequence = over_budget;
    bad_sequence[0].sequence = 1;
    bad_sequence[0].span_sha256 = spanSha256(bad_sequence[0]);
    try std.testing.expectError(
        Error.InvalidSpan,
        packV1(domain, policy, &bad_sequence, decisions[0..1]),
    );
    try std.testing.expectEqual(DecisionV1{}, decisions[0]);

    const overflow_policy = try makePolicyV1(2, std.math.maxInt(u64), 0);
    const overflowing = [_]SpanV1{
        try testSpan(
            0,
            .user,
            .unique,
            .required,
            3,
            13,
            24,
            std.math.maxInt(u64),
        ),
        try testSpan(1, .user, .unique, .required, 4, 14, 25, 1),
    };
    try std.testing.expectError(
        Error.TokenCountOverflow,
        packV1(domain, overflow_policy, &overflowing, &decisions),
    );
    try std.testing.expectEqual(DecisionV1{}, decisions[0]);
    try std.testing.expectEqual(DecisionV1{}, decisions[1]);
}

test "full wire observations reconcile exact packed token savings" {
    const domain = try testDomain();
    const policy = try makePolicyV1(8, 200, 10);
    const spans = [_]SpanV1{
        try testSpan(0, .system, .idempotent_exact, .required, 1, 11, 21, 60),
        try testSpan(1, .tool, .idempotent_exact, .required, 2, 12, 22, 80),
        try testSpan(2, .tool, .idempotent_exact, .required, 2, 12, 23, 80),
        try testSpan(3, .user, .unique, .preserved, 3, 13, 24, 30),
    };
    var decisions: [spans.len]DecisionV1 = [_]DecisionV1{.{}} ** spans.len;
    const receipt = try packV1(domain, policy, &spans, &decisions);
    const tokenizer_execution = testDigest(0xa1);
    const raw = try makeTokenObservationV1(
        domain,
        receipt,
        .raw,
        testDigest(0xb1),
        tokenizer_execution,
        260,
    );
    const packed_observation = try makeTokenObservationV1(
        domain,
        receipt,
        .packed_context,
        testDigest(0xb2),
        tokenizer_execution,
        180,
    );
    const reconciliation = try makeReconciliationV1(
        domain,
        policy,
        receipt,
        raw,
        packed_observation,
    );

    try std.testing.expect(tokenObservationMatchesV1(
        raw,
        domain,
        receipt,
        .raw,
    ));
    try std.testing.expect(tokenObservationMatchesV1(
        packed_observation,
        domain,
        receipt,
        .packed_context,
    ));
    try std.testing.expectEqual(@as(u64, 260), reconciliation.raw_wire_tokens);
    try std.testing.expectEqual(@as(u64, 180), reconciliation.packed_wire_tokens);
    try std.testing.expectEqual(
        @as(u64, 80),
        reconciliation.wire_deduplicated_tokens,
    );
    try std.testing.expectEqual(
        @as(u64, 20),
        reconciliation.packed_budget_headroom,
    );
    try std.testing.expect(verifyReconciliationV1(
        domain,
        policy,
        receipt,
        raw,
        packed_observation,
        reconciliation,
    ));

    // A self-consistent reconciliation hash cannot replace reconstruction
    // from the independently supplied observations and pack receipt.
    var forged = reconciliation;
    forged.raw_wire_tokens += 1;
    forged.packed_wire_tokens += 1;
    forged.packed_budget_headroom -= 1;
    forged.reconciliation_sha256 = reconciliationSha256(forged);
    try std.testing.expect(reconciliationValidV1(forged));
    try std.testing.expect(!verifyReconciliationV1(
        domain,
        policy,
        receipt,
        raw,
        packed_observation,
        forged,
    ));
}

test "wire drift arm tokenizer and domain substitutions fail closed" {
    const domain = try testDomain();
    const policy = try makePolicyV1(4, 200, 10);
    const spans = [_]SpanV1{
        try testSpan(0, .system, .idempotent_exact, .required, 1, 11, 21, 60),
        try testSpan(1, .tool, .idempotent_exact, .required, 2, 12, 22, 80),
        try testSpan(2, .tool, .idempotent_exact, .required, 2, 12, 23, 80),
        try testSpan(3, .user, .unique, .preserved, 3, 13, 24, 30),
    };
    var decisions: [spans.len]DecisionV1 = [_]DecisionV1{.{}} ** spans.len;
    const receipt = try packV1(domain, policy, &spans, &decisions);
    const tokenizer_execution = testDigest(0xa1);
    const raw = try makeTokenObservationV1(
        domain,
        receipt,
        .raw,
        testDigest(0xb1),
        tokenizer_execution,
        260,
    );
    const packed_observation = try makeTokenObservationV1(
        domain,
        receipt,
        .packed_context,
        testDigest(0xb2),
        tokenizer_execution,
        180,
    );

    const raw_drift = try makeTokenObservationV1(
        domain,
        receipt,
        .raw,
        testDigest(0xb1),
        tokenizer_execution,
        259,
    );
    try std.testing.expect(tokenObservationValidV1(raw_drift));
    try std.testing.expectError(
        Error.TokenizationConflict,
        makeReconciliationV1(
            domain,
            policy,
            receipt,
            raw_drift,
            packed_observation,
        ),
    );
    const packed_drift = try makeTokenObservationV1(
        domain,
        receipt,
        .packed_context,
        testDigest(0xb2),
        tokenizer_execution,
        181,
    );
    try std.testing.expect(tokenObservationValidV1(packed_drift));
    try std.testing.expectError(
        Error.TokenizationConflict,
        makeReconciliationV1(
            domain,
            policy,
            receipt,
            raw,
            packed_drift,
        ),
    );

    const foreign_tokenizer = try makeTokenObservationV1(
        domain,
        receipt,
        .packed_context,
        testDigest(0xb2),
        testDigest(0xa2),
        180,
    );
    try std.testing.expectError(
        Error.InvalidReconciliation,
        makeReconciliationV1(
            domain,
            policy,
            receipt,
            raw,
            foreign_tokenizer,
        ),
    );
    try std.testing.expectError(
        Error.InvalidReconciliation,
        makeReconciliationV1(
            domain,
            policy,
            receipt,
            packed_observation,
            raw,
        ),
    );

    const foreign_domain = try makeDomainV1(
        72,
        domain.adapter_abi,
        domain.provider_namespace_sha256,
        domain.model_sha256,
        domain.tokenizer_sha256,
        domain.render_policy_sha256,
    );
    var foreign_decisions: [spans.len]DecisionV1 =
        [_]DecisionV1{.{}} ** spans.len;
    const foreign_receipt = try packV1(
        foreign_domain,
        policy,
        &spans,
        &foreign_decisions,
    );
    const foreign_raw = try makeTokenObservationV1(
        foreign_domain,
        foreign_receipt,
        .raw,
        testDigest(0xb1),
        tokenizer_execution,
        260,
    );
    try std.testing.expectError(
        Error.InvalidReconciliation,
        makeReconciliationV1(
            domain,
            policy,
            receipt,
            foreign_raw,
            packed_observation,
        ),
    );

    var foreign_chain = raw;
    foreign_chain.context_chain_sha256 = testDigest(0xc1);
    foreign_chain.observation_sha256 = tokenObservationSha256(foreign_chain);
    try std.testing.expect(tokenObservationValidV1(foreign_chain));
    try std.testing.expect(!tokenObservationMatchesV1(
        foreign_chain,
        domain,
        receipt,
        .raw,
    ));
    try std.testing.expectError(
        Error.InvalidReconciliation,
        makeReconciliationV1(
            domain,
            policy,
            receipt,
            foreign_chain,
            packed_observation,
        ),
    );

    var damaged = raw;
    damaged.wire_sha256[0] ^= 1;
    try std.testing.expect(!tokenObservationValidV1(damaged));
}

test "portable context evidence is pointer-free and bounded" {
    try std.testing.expect(@sizeOf(DomainV1) <= 256);
    try std.testing.expect(@sizeOf(PolicyV1) <= 96);
    try std.testing.expect(@sizeOf(SpanV1) <= 192);
    try std.testing.expect(@sizeOf(DecisionV1) <= 160);
    try std.testing.expect(@sizeOf(ReceiptV1) <= 256);
    try std.testing.expect(@sizeOf(TokenObservationV1) <= 192);
    try std.testing.expect(@sizeOf(ReconciliationV1) <= 320);
    inline for (.{
        DomainV1,
        PolicyV1,
        SpanV1,
        DecisionV1,
        ReceiptV1,
        TokenObservationV1,
        ReconciliationV1,
    }) |Evidence| inline for (std.meta.fields(Evidence)) |field|
        try std.testing.expect(@typeInfo(field.type) != .pointer);
}
