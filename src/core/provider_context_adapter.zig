//! Allocation-free execution boundary for provider context renderers and
//! full-wire token counters.
//!
//! Runtime adapters write only into caller-owned private scratch. Core hashes
//! the exact bytes passed to the counter, constructs context observations and
//! returns pointer-free evidence that can be deterministically replayed.

const std = @import("std");
const context_pack = @import("provider_context_pack.zig");

pub const descriptor_abi: u64 = 0x4750_4341_0000_0001;
pub const execution_abi: u64 = 0x4750_4357_0000_0001;
pub const Digest = context_pack.Digest;
pub const zero_digest = context_pack.zero_digest;
pub const max_supported_wire_bytes: u64 = 16 * 1024 * 1024;

const descriptor_domain = "glacier-provider-context-adapter-v1\x00";
const execution_domain = "glacier-provider-context-wire-execution-v1\x00";

pub const capability_deterministic_render: u64 = 1 << 0;
pub const capability_exact_span_binding: u64 = 1 << 1;
pub const capability_full_wire_token_count: u64 = 1 << 2;
pub const capability_pair_execution_identity: u64 = 1 << 3;
pub const required_capabilities: u64 =
    capability_deterministic_render |
    capability_exact_span_binding |
    capability_full_wire_token_count |
    capability_pair_execution_identity;

pub const CallbackError = error{
    WireCapacityExceeded,
    RenderRejected,
    TokenizerRejected,
};

pub const Error = CallbackError || context_pack.Error || error{
    InvalidDescriptor,
    InvalidAdapter,
    InvalidPack,
    InvalidStorage,
    InvalidRenderResult,
    InvalidTokenCount,
    ExecutionConflict,
    InvalidExecution,
};

pub const DescriptorV1 = struct {
    abi_version: u64 = descriptor_abi,
    adapter_abi: u64 = 0,
    provider_namespace_sha256: Digest = zero_digest,
    tokenizer_sha256: Digest = zero_digest,
    render_policy_sha256: Digest = zero_digest,
    capability_bits: u64 = 0,
    max_wire_bytes: u64 = 0,
    descriptor_sha256: Digest = zero_digest,
};

pub fn makeDescriptorV1(
    adapter_abi: u64,
    provider_namespace_sha256: Digest,
    tokenizer_sha256: Digest,
    render_policy_sha256: Digest,
    capability_bits: u64,
    max_wire_bytes: u64,
) Error!DescriptorV1 {
    var descriptor: DescriptorV1 = .{
        .adapter_abi = adapter_abi,
        .provider_namespace_sha256 = provider_namespace_sha256,
        .tokenizer_sha256 = tokenizer_sha256,
        .render_policy_sha256 = render_policy_sha256,
        .capability_bits = capability_bits,
        .max_wire_bytes = max_wire_bytes,
    };
    descriptor.descriptor_sha256 = descriptorSha256(descriptor);
    if (!descriptorValidV1(descriptor)) return Error.InvalidDescriptor;
    return descriptor;
}

pub fn descriptorSha256(descriptor: DescriptorV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(descriptor_domain);
    hashU64(&hash, descriptor.abi_version);
    hashU64(&hash, descriptor.adapter_abi);
    hash.update(&descriptor.provider_namespace_sha256);
    hash.update(&descriptor.tokenizer_sha256);
    hash.update(&descriptor.render_policy_sha256);
    hashU64(&hash, descriptor.capability_bits);
    hashU64(&hash, descriptor.max_wire_bytes);
    return finish(&hash);
}

pub fn descriptorValidV1(descriptor: DescriptorV1) bool {
    return descriptor.abi_version == descriptor_abi and
        descriptor.adapter_abi != 0 and
        !isZero(descriptor.provider_namespace_sha256) and
        !isZero(descriptor.tokenizer_sha256) and
        !isZero(descriptor.render_policy_sha256) and
        descriptor.capability_bits & required_capabilities ==
            required_capabilities and
        descriptor.max_wire_bytes != 0 and
        descriptor.max_wire_bytes <= max_supported_wire_bytes and
        std.mem.eql(
            u8,
            &descriptor.descriptor_sha256,
            &descriptorSha256(descriptor),
        );
}

pub fn descriptorMatchesDomainV1(
    descriptor: DescriptorV1,
    domain: context_pack.DomainV1,
) bool {
    return descriptorValidV1(descriptor) and
        context_pack.domainValidV1(domain) and
        descriptor.adapter_abi == domain.adapter_abi and std.mem.eql(
        u8,
        &descriptor.provider_namespace_sha256,
        &domain.provider_namespace_sha256,
    ) and std.mem.eql(
        u8,
        &descriptor.tokenizer_sha256,
        &domain.tokenizer_sha256,
    ) and std.mem.eql(
        u8,
        &descriptor.render_policy_sha256,
        &domain.render_policy_sha256,
    );
}

pub const RenderResult = struct {
    written: usize,
    render_execution_sha256: Digest,
};

pub const TokenCountResult = struct {
    tokens: u64,
    tokenizer_execution_sha256: Digest,
};

pub const RenderFn = *const fn (
    adapter_context: *anyopaque,
    arm: context_pack.ContextArm,
    spans: []const context_pack.SpanV1,
    decisions: []const context_pack.DecisionV1,
    destination: []u8,
) CallbackError!RenderResult;

pub const CountFn = *const fn (
    adapter_context: *anyopaque,
    wire: []const u8,
) CallbackError!TokenCountResult;

/// Process-local adapter authority. It is intentionally excluded from
/// portable evidence because function and context pointers are not stable ABI.
pub const AdapterV1 = struct {
    adapter_context: *anyopaque,
    descriptor: DescriptorV1,
    renderFn: RenderFn,
    countFn: CountFn,
};

pub fn adapterValidV1(adapter: AdapterV1) bool {
    return @intFromPtr(adapter.adapter_context) != 0 and
        descriptorValidV1(adapter.descriptor);
}

pub const ExecutionV1 = struct {
    abi_version: u64 = execution_abi,
    descriptor_sha256: Digest = zero_digest,
    domain_sha256: Digest = zero_digest,
    policy_sha256: Digest = zero_digest,
    pack_receipt_sha256: Digest = zero_digest,
    render_execution_sha256: Digest = zero_digest,
    raw_wire_bytes: u64 = 0,
    packed_wire_bytes: u64 = 0,
    raw_observation: context_pack.TokenObservationV1 = .{},
    packed_observation: context_pack.TokenObservationV1 = .{},
    reconciliation: context_pack.ReconciliationV1 = .{},
    execution_sha256: Digest = zero_digest,
};

pub fn executionSha256(execution: ExecutionV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(execution_domain);
    hashU64(&hash, execution.abi_version);
    hash.update(&execution.descriptor_sha256);
    hash.update(&execution.domain_sha256);
    hash.update(&execution.policy_sha256);
    hash.update(&execution.pack_receipt_sha256);
    hash.update(&execution.render_execution_sha256);
    hashU64(&hash, execution.raw_wire_bytes);
    hashU64(&hash, execution.packed_wire_bytes);
    hash.update(&execution.raw_observation.observation_sha256);
    hash.update(&execution.packed_observation.observation_sha256);
    hash.update(&execution.reconciliation.reconciliation_sha256);
    return finish(&hash);
}

pub fn executionValidV1(execution: ExecutionV1) bool {
    return execution.abi_version == execution_abi and
        !isZero(execution.descriptor_sha256) and
        !isZero(execution.domain_sha256) and
        !isZero(execution.policy_sha256) and
        !isZero(execution.pack_receipt_sha256) and
        !isZero(execution.render_execution_sha256) and
        execution.raw_wire_bytes != 0 and
        execution.packed_wire_bytes != 0 and
        execution.packed_wire_bytes <= execution.raw_wire_bytes and
        execution.raw_observation.arm == .raw and
        execution.packed_observation.arm == .packed_context and
        context_pack.tokenObservationValidV1(execution.raw_observation) and
        context_pack.tokenObservationValidV1(
            execution.packed_observation,
        ) and context_pack.reconciliationValidV1(execution.reconciliation) and
        execution.raw_observation.wire_tokens ==
            execution.reconciliation.raw_wire_tokens and
        execution.packed_observation.wire_tokens ==
            execution.reconciliation.packed_wire_tokens and std.mem.eql(
        u8,
        &execution.raw_observation.domain_sha256,
        &execution.domain_sha256,
    ) and std.mem.eql(
        u8,
        &execution.packed_observation.domain_sha256,
        &execution.domain_sha256,
    ) and std.mem.eql(
        u8,
        &execution.reconciliation.domain_sha256,
        &execution.domain_sha256,
    ) and std.mem.eql(
        u8,
        &execution.reconciliation.policy_sha256,
        &execution.policy_sha256,
    ) and std.mem.eql(
        u8,
        &execution.reconciliation.receipt_sha256,
        &execution.pack_receipt_sha256,
    ) and std.mem.eql(
        u8,
        &execution.raw_observation.observation_sha256,
        &execution.reconciliation.raw_observation_sha256,
    ) and std.mem.eql(
        u8,
        &execution.packed_observation.observation_sha256,
        &execution.reconciliation.packed_observation_sha256,
    ) and std.mem.eql(
        u8,
        &execution.raw_observation.tokenizer_execution_sha256,
        &execution.reconciliation.tokenizer_execution_sha256,
    ) and std.mem.eql(
        u8,
        &execution.execution_sha256,
        &executionSha256(execution),
    );
}

/// Renders and counts raw and packed full wires into private caller-owned
/// scratch. Any callback or reconciliation failure wipes both buffers.
pub fn executePairV1(
    adapter: AdapterV1,
    domain: context_pack.DomainV1,
    policy: context_pack.PolicyV1,
    spans: []const context_pack.SpanV1,
    decisions: []const context_pack.DecisionV1,
    receipt: context_pack.ReceiptV1,
    raw_buffer: []u8,
    packed_buffer: []u8,
) Error!ExecutionV1 {
    if (!adapterValidV1(adapter)) return Error.InvalidAdapter;
    if (!descriptorMatchesDomainV1(adapter.descriptor, domain))
        return Error.InvalidDescriptor;
    if (!context_pack.verifyPackV1(
        domain,
        policy,
        spans,
        decisions,
        receipt,
    )) return Error.InvalidPack;
    const max_wire_bytes: usize = @intCast(
        adapter.descriptor.max_wire_bytes,
    );
    if (raw_buffer.len == 0 or packed_buffer.len == 0 or
        raw_buffer.len > max_wire_bytes or packed_buffer.len > max_wire_bytes)
        return Error.WireCapacityExceeded;
    if (overlap(u8, raw_buffer, u8, packed_buffer) or
        overlap(context_pack.SpanV1, spans, u8, raw_buffer) or
        overlap(context_pack.SpanV1, spans, u8, packed_buffer) or
        overlap(context_pack.DecisionV1, decisions, u8, raw_buffer) or
        overlap(context_pack.DecisionV1, decisions, u8, packed_buffer))
        return Error.InvalidStorage;

    @memset(raw_buffer, 0);
    @memset(packed_buffer, 0);
    errdefer {
        @memset(raw_buffer, 0);
        @memset(packed_buffer, 0);
    }

    const raw_render = try adapter.renderFn(
        adapter.adapter_context,
        .raw,
        spans,
        decisions,
        raw_buffer,
    );
    if (!renderResultValid(raw_render, raw_buffer.len, max_wire_bytes))
        return Error.InvalidRenderResult;
    const raw_wire = raw_buffer[0..raw_render.written];
    const raw_count = try adapter.countFn(adapter.adapter_context, raw_wire);
    if (!tokenCountValid(raw_count)) return Error.InvalidTokenCount;

    const packed_render = try adapter.renderFn(
        adapter.adapter_context,
        .packed_context,
        spans,
        decisions,
        packed_buffer,
    );
    if (!renderResultValid(
        packed_render,
        packed_buffer.len,
        max_wire_bytes,
    )) return Error.InvalidRenderResult;
    const packed_wire = packed_buffer[0..packed_render.written];
    const packed_count = try adapter.countFn(
        adapter.adapter_context,
        packed_wire,
    );
    if (!tokenCountValid(packed_count)) return Error.InvalidTokenCount;
    const execution = try makeExecutionV1(
        adapter.descriptor,
        domain,
        policy,
        spans,
        decisions,
        receipt,
        raw_render,
        wireSha256(raw_wire),
        raw_count,
        packed_render,
        wireSha256(packed_wire),
        packed_count,
    );
    if (!verifyPairExecutionV1(
        adapter.descriptor,
        domain,
        policy,
        spans,
        decisions,
        receipt,
        raw_wire,
        packed_wire,
        execution,
    )) return Error.InvalidExecution;
    return execution;
}

fn makeExecutionV1(
    descriptor: DescriptorV1,
    domain: context_pack.DomainV1,
    policy: context_pack.PolicyV1,
    spans: []const context_pack.SpanV1,
    decisions: []const context_pack.DecisionV1,
    receipt: context_pack.ReceiptV1,
    raw_render: RenderResult,
    raw_wire_sha256: Digest,
    raw_count: TokenCountResult,
    packed_render: RenderResult,
    packed_wire_sha256: Digest,
    packed_count: TokenCountResult,
) Error!ExecutionV1 {
    if (!std.mem.eql(
        u8,
        &raw_render.render_execution_sha256,
        &packed_render.render_execution_sha256,
    )) return Error.ExecutionConflict;
    if (!std.mem.eql(
        u8,
        &raw_count.tokenizer_execution_sha256,
        &packed_count.tokenizer_execution_sha256,
    )) return Error.ExecutionConflict;

    // Detect mutation by an adapter or aliased external state before granting
    // portable evidence over the rendered bytes.
    if (!context_pack.verifyPackV1(
        domain,
        policy,
        spans,
        decisions,
        receipt,
    )) return Error.InvalidPack;
    const raw_observation = try context_pack.makeTokenObservationV1(
        domain,
        receipt,
        .raw,
        raw_wire_sha256,
        raw_count.tokenizer_execution_sha256,
        raw_count.tokens,
    );
    const packed_observation = try context_pack.makeTokenObservationV1(
        domain,
        receipt,
        .packed_context,
        packed_wire_sha256,
        packed_count.tokenizer_execution_sha256,
        packed_count.tokens,
    );
    const reconciliation = try context_pack.makeReconciliationV1(
        domain,
        policy,
        receipt,
        raw_observation,
        packed_observation,
    );
    var execution: ExecutionV1 = .{
        .descriptor_sha256 = descriptor.descriptor_sha256,
        .domain_sha256 = domain.domain_sha256,
        .policy_sha256 = policy.policy_sha256,
        .pack_receipt_sha256 = receipt.receipt_sha256,
        .render_execution_sha256 = raw_render.render_execution_sha256,
        .raw_wire_bytes = @intCast(raw_render.written),
        .packed_wire_bytes = @intCast(packed_render.written),
        .raw_observation = raw_observation,
        .packed_observation = packed_observation,
        .reconciliation = reconciliation,
    };
    execution.execution_sha256 = executionSha256(execution);
    if (!executionValidV1(execution)) return Error.InvalidExecution;
    return execution;
}

/// Renders the raw wire, commits its digest/count, wipes the scratch and
/// reuses the same storage for the packed wire. On success only packed bytes
/// remain resident; every error after rendering wipes the entire buffer.
pub fn executeReusedScratchV1(
    adapter: AdapterV1,
    domain: context_pack.DomainV1,
    policy: context_pack.PolicyV1,
    spans: []const context_pack.SpanV1,
    decisions: []const context_pack.DecisionV1,
    receipt: context_pack.ReceiptV1,
    scratch: []u8,
) Error!ExecutionV1 {
    if (!adapterValidV1(adapter)) return Error.InvalidAdapter;
    if (!descriptorMatchesDomainV1(adapter.descriptor, domain))
        return Error.InvalidDescriptor;
    if (!context_pack.verifyPackV1(
        domain,
        policy,
        spans,
        decisions,
        receipt,
    )) return Error.InvalidPack;
    const max_wire_bytes: usize = @intCast(
        adapter.descriptor.max_wire_bytes,
    );
    if (scratch.len == 0 or scratch.len > max_wire_bytes)
        return Error.WireCapacityExceeded;
    if (overlap(context_pack.SpanV1, spans, u8, scratch) or
        overlap(context_pack.DecisionV1, decisions, u8, scratch))
        return Error.InvalidStorage;

    @memset(scratch, 0);
    errdefer @memset(scratch, 0);

    const raw_render = try adapter.renderFn(
        adapter.adapter_context,
        .raw,
        spans,
        decisions,
        scratch,
    );
    if (!renderResultValid(raw_render, scratch.len, max_wire_bytes))
        return Error.InvalidRenderResult;
    const raw_wire_sha256 = wireSha256(scratch[0..raw_render.written]);
    const raw_count = try adapter.countFn(
        adapter.adapter_context,
        scratch[0..raw_render.written],
    );
    if (!tokenCountValid(raw_count)) return Error.InvalidTokenCount;

    // Raw bytes are evidence-only and never dispatched. Remove them before
    // producing the packed wire so peak wire scratch is one declared buffer.
    @memset(scratch, 0);
    const packed_render = try adapter.renderFn(
        adapter.adapter_context,
        .packed_context,
        spans,
        decisions,
        scratch,
    );
    if (!renderResultValid(packed_render, scratch.len, max_wire_bytes))
        return Error.InvalidRenderResult;
    const packed_wire = scratch[0..packed_render.written];
    const packed_count = try adapter.countFn(
        adapter.adapter_context,
        packed_wire,
    );
    if (!tokenCountValid(packed_count)) return Error.InvalidTokenCount;
    const execution = try makeExecutionV1(
        adapter.descriptor,
        domain,
        policy,
        spans,
        decisions,
        receipt,
        raw_render,
        raw_wire_sha256,
        raw_count,
        packed_render,
        wireSha256(packed_wire),
        packed_count,
    );
    if (!verifyRetainedPackedExecutionV1(
        adapter.descriptor,
        domain,
        policy,
        spans,
        decisions,
        receipt,
        packed_wire,
        execution,
    )) return Error.InvalidExecution;
    return execution;
}

/// Verifies portable evidence and the exact retained wires without calling
/// process-local adapter code.
pub fn verifyPairExecutionV1(
    descriptor: DescriptorV1,
    domain: context_pack.DomainV1,
    policy: context_pack.PolicyV1,
    spans: []const context_pack.SpanV1,
    decisions: []const context_pack.DecisionV1,
    receipt: context_pack.ReceiptV1,
    raw_wire: []const u8,
    packed_wire: []const u8,
    execution: ExecutionV1,
) bool {
    if (!verifyExecutionBindingsV1(
        descriptor,
        domain,
        policy,
        spans,
        decisions,
        receipt,
        execution,
    ) or raw_wire.len != execution.raw_wire_bytes or
        packed_wire.len != execution.packed_wire_bytes or
        raw_wire.len > descriptor.max_wire_bytes or
        packed_wire.len > descriptor.max_wire_bytes) return false;
    return std.mem.eql(
        u8,
        &execution.raw_observation.wire_sha256,
        &wireSha256(raw_wire),
    ) and std.mem.eql(
        u8,
        &execution.packed_observation.wire_sha256,
        &wireSha256(packed_wire),
    );
}

fn verifyExecutionBindingsV1(
    descriptor: DescriptorV1,
    domain: context_pack.DomainV1,
    policy: context_pack.PolicyV1,
    spans: []const context_pack.SpanV1,
    decisions: []const context_pack.DecisionV1,
    receipt: context_pack.ReceiptV1,
    execution: ExecutionV1,
) bool {
    if (!executionValidV1(execution) or
        !descriptorMatchesDomainV1(descriptor, domain) or
        !context_pack.verifyPackV1(
            domain,
            policy,
            spans,
            decisions,
            receipt,
        ) or execution.raw_wire_bytes > descriptor.max_wire_bytes or
        execution.packed_wire_bytes > descriptor.max_wire_bytes)
        return false;
    return std.mem.eql(
        u8,
        &execution.descriptor_sha256,
        &descriptor.descriptor_sha256,
    ) and std.mem.eql(
        u8,
        &execution.domain_sha256,
        &domain.domain_sha256,
    ) and std.mem.eql(
        u8,
        &execution.policy_sha256,
        &policy.policy_sha256,
    ) and std.mem.eql(
        u8,
        &execution.pack_receipt_sha256,
        &receipt.receipt_sha256,
    ) and context_pack.tokenObservationMatchesV1(
        execution.raw_observation,
        domain,
        receipt,
        .raw,
    ) and context_pack.tokenObservationMatchesV1(
        execution.packed_observation,
        domain,
        receipt,
        .packed_context,
    ) and context_pack.verifyReconciliationV1(
        domain,
        policy,
        receipt,
        execution.raw_observation,
        execution.packed_observation,
        execution.reconciliation,
    );
}

/// Verifies the complete execution receipt and the retained packed wire. The
/// discarded raw wire is recovered only by deterministic adapter replay.
pub fn verifyRetainedPackedExecutionV1(
    descriptor: DescriptorV1,
    domain: context_pack.DomainV1,
    policy: context_pack.PolicyV1,
    spans: []const context_pack.SpanV1,
    decisions: []const context_pack.DecisionV1,
    receipt: context_pack.ReceiptV1,
    packed_wire: []const u8,
    execution: ExecutionV1,
) bool {
    if (!verifyExecutionBindingsV1(
        descriptor,
        domain,
        policy,
        spans,
        decisions,
        receipt,
        execution,
    ) or packed_wire.len != execution.packed_wire_bytes or
        packed_wire.len > descriptor.max_wire_bytes) return false;
    return std.mem.eql(
        u8,
        &execution.packed_observation.wire_sha256,
        &wireSha256(packed_wire),
    );
}

/// Re-runs renderer and tokenizer callbacks into independent scratch, then
/// requires byte-identical wires and byte-identical pointer-free evidence.
pub fn replayPairExecutionV1(
    adapter: AdapterV1,
    domain: context_pack.DomainV1,
    policy: context_pack.PolicyV1,
    spans: []const context_pack.SpanV1,
    decisions: []const context_pack.DecisionV1,
    receipt: context_pack.ReceiptV1,
    expected_raw_wire: []const u8,
    expected_packed_wire: []const u8,
    expected: ExecutionV1,
    raw_scratch: []u8,
    packed_scratch: []u8,
) bool {
    if (!verifyPairExecutionV1(
        adapter.descriptor,
        domain,
        policy,
        spans,
        decisions,
        receipt,
        expected_raw_wire,
        expected_packed_wire,
        expected,
    ) or overlap(u8, expected_raw_wire, u8, raw_scratch) or
        overlap(u8, expected_raw_wire, u8, packed_scratch) or
        overlap(u8, expected_packed_wire, u8, raw_scratch) or
        overlap(u8, expected_packed_wire, u8, packed_scratch)) return false;
    const replay = executePairV1(
        adapter,
        domain,
        policy,
        spans,
        decisions,
        receipt,
        raw_scratch,
        packed_scratch,
    ) catch return false;
    const raw_len: usize = @intCast(replay.raw_wire_bytes);
    const packed_len: usize = @intCast(replay.packed_wire_bytes);
    return std.meta.eql(replay, expected) and
        std.mem.eql(u8, raw_scratch[0..raw_len], expected_raw_wire) and
        std.mem.eql(
            u8,
            packed_scratch[0..packed_len],
            expected_packed_wire,
        );
}

/// Reconstructs both arms through one fresh scratch buffer. Equality of the
/// complete receipt proves the discarded raw digest/count was reproduced;
/// packed bytes must also match the retained dispatch wire.
pub fn replayReusedScratchV1(
    adapter: AdapterV1,
    domain: context_pack.DomainV1,
    policy: context_pack.PolicyV1,
    spans: []const context_pack.SpanV1,
    decisions: []const context_pack.DecisionV1,
    receipt: context_pack.ReceiptV1,
    expected_packed_wire: []const u8,
    expected: ExecutionV1,
    scratch: []u8,
) bool {
    if (!verifyRetainedPackedExecutionV1(
        adapter.descriptor,
        domain,
        policy,
        spans,
        decisions,
        receipt,
        expected_packed_wire,
        expected,
    ) or overlap(u8, expected_packed_wire, u8, scratch)) return false;
    const replay = executeReusedScratchV1(
        adapter,
        domain,
        policy,
        spans,
        decisions,
        receipt,
        scratch,
    ) catch return false;
    const packed_len: usize = @intCast(replay.packed_wire_bytes);
    return std.meta.eql(replay, expected) and std.mem.eql(
        u8,
        scratch[0..packed_len],
        expected_packed_wire,
    );
}

fn renderResultValid(
    result: RenderResult,
    capacity: usize,
    max_wire_bytes: usize,
) bool {
    return result.written != 0 and result.written <= capacity and
        result.written <= max_wire_bytes and
        !isZero(result.render_execution_sha256);
}

fn tokenCountValid(result: TokenCountResult) bool {
    return result.tokens != 0 and
        !isZero(result.tokenizer_execution_sha256);
}

fn wireSha256(wire: []const u8) Digest {
    var digest: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(wire, &digest, .{});
    return digest;
}

fn overlap(
    comptime Left: type,
    left: []const Left,
    comptime Right: type,
    right: []const Right,
) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const left_bytes = std.math.mul(usize, left.len, @sizeOf(Left)) catch
        return true;
    const left_end = std.math.add(usize, left_start, left_bytes) catch
        return true;
    const right_start = @intFromPtr(right.ptr);
    const right_bytes = std.math.mul(
        usize,
        right.len,
        @sizeOf(Right),
    ) catch return true;
    const right_end = std.math.add(
        usize,
        right_start,
        right_bytes,
    ) catch return true;
    return left_start < right_end and right_start < left_end;
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

const TestFixture = struct {
    prefix: []const u8,
    suffix: []const u8,
    fragments: []const []const u8,
    render_execution_sha256: Digest,
    tokenizer_execution_sha256: Digest,
    packed_token_delta: u64 = 0,
    split_render_identity: bool = false,
    split_tokenizer_identity: bool = false,
    reject_render: bool = false,
    count_calls: u32 = 0,

    fn adapter(self: *TestFixture, descriptor: DescriptorV1) AdapterV1 {
        return .{
            .adapter_context = self,
            .descriptor = descriptor,
            .renderFn = render,
            .countFn = count,
        };
    }

    fn render(
        adapter_context: *anyopaque,
        arm: context_pack.ContextArm,
        spans: []const context_pack.SpanV1,
        decisions: []const context_pack.DecisionV1,
        destination: []u8,
    ) CallbackError!RenderResult {
        const self: *TestFixture = @ptrCast(@alignCast(adapter_context));
        if (self.reject_render or spans.len != decisions.len or
            spans.len != self.fragments.len)
            return CallbackError.RenderRejected;
        var cursor: usize = 0;
        try append(destination, &cursor, self.prefix);
        for (spans, decisions, self.fragments) |span, decision, fragment| {
            if (!std.mem.eql(
                u8,
                &span.rendered_sha256,
                &wireSha256(fragment),
            )) return CallbackError.RenderRejected;
            const emit = switch (arm) {
                .raw => true,
                .packed_context => decision.action == .emit,
            };
            if (emit) try append(destination, &cursor, fragment);
        }
        try append(destination, &cursor, self.suffix);
        return .{
            .written = cursor,
            .render_execution_sha256 = if (self.split_render_identity and arm == .packed_context) testDigest(0xe2) else self.render_execution_sha256,
        };
    }

    fn count(
        adapter_context: *anyopaque,
        wire: []const u8,
    ) CallbackError!TokenCountResult {
        const self: *TestFixture = @ptrCast(@alignCast(adapter_context));
        self.count_calls += 1;
        const is_packed_call = self.count_calls % 2 == 0;
        const delta = if (is_packed_call) self.packed_token_delta else 0;
        return .{
            .tokens = std.math.add(
                u64,
                @intCast(wire.len),
                delta,
            ) catch return CallbackError.TokenizerRejected,
            .tokenizer_execution_sha256 = if (self.split_tokenizer_identity and is_packed_call) testDigest(0xf2) else self.tokenizer_execution_sha256,
        };
    }

    fn append(
        destination: []u8,
        cursor: *usize,
        bytes: []const u8,
    ) CallbackError!void {
        const end = std.math.add(usize, cursor.*, bytes.len) catch
            return CallbackError.WireCapacityExceeded;
        if (end > destination.len)
            return CallbackError.WireCapacityExceeded;
        @memcpy(destination[cursor.*..end], bytes);
        cursor.* = end;
    }
};

const TestPack = struct {
    domain: context_pack.DomainV1,
    policy: context_pack.PolicyV1,
    spans: [4]context_pack.SpanV1,
    decisions: [4]context_pack.DecisionV1,
    receipt: context_pack.ReceiptV1,
    descriptor: DescriptorV1,
};

fn testPack() !TestPack {
    const adapter_abi: u64 = 0x5445_5354_4144_5001;
    const provider = testDigest(0x11);
    const tokenizer = testDigest(0x22);
    const render_policy = testDigest(0x33);
    const domain = try context_pack.makeDomainV1(
        71,
        adapter_abi,
        provider,
        testDigest(0x44),
        tokenizer,
        render_policy,
    );
    const policy = try context_pack.makePolicyV1(4, 10, 2);
    const fragments = [_][]const u8{ "AA", "BBB", "BBB", "C" };
    var spans: [4]context_pack.SpanV1 = undefined;
    spans[0] = try context_pack.makeSpanV1(
        0,
        .system,
        .unique,
        .required,
        wireSha256("AA"),
        wireSha256("AA"),
        testDigest(0xa1),
        fragments[0].len,
    );
    spans[1] = try context_pack.makeSpanV1(
        1,
        .tool,
        .idempotent_exact,
        .required,
        wireSha256("BBB"),
        wireSha256("BBB"),
        testDigest(0xa2),
        fragments[1].len,
    );
    spans[2] = try context_pack.makeSpanV1(
        2,
        .tool,
        .idempotent_exact,
        .required,
        wireSha256("BBB"),
        wireSha256("BBB"),
        testDigest(0xa3),
        fragments[2].len,
    );
    spans[3] = try context_pack.makeSpanV1(
        3,
        .user,
        .unique,
        .preserved,
        wireSha256("C"),
        wireSha256("C"),
        testDigest(0xa4),
        fragments[3].len,
    );
    var decisions: [4]context_pack.DecisionV1 = [_]context_pack.DecisionV1{
        .{}, .{}, .{}, .{},
    };
    const receipt = try context_pack.packV1(
        domain,
        policy,
        &spans,
        &decisions,
    );
    const descriptor = try makeDescriptorV1(
        adapter_abi,
        provider,
        tokenizer,
        render_policy,
        required_capabilities,
        64,
    );
    return .{
        .domain = domain,
        .policy = policy,
        .spans = spans,
        .decisions = decisions,
        .receipt = receipt,
        .descriptor = descriptor,
    };
}

fn testFixture() TestFixture {
    const fragments = &[_][]const u8{ "AA", "BBB", "BBB", "C" };
    return .{
        .prefix = "[",
        .suffix = "]",
        .fragments = fragments,
        .render_execution_sha256 = testDigest(0xe1),
        .tokenizer_execution_sha256 = testDigest(0xf1),
    };
}

test "adapter renders counts reconciles and replays exact wires" {
    const pack = try testPack();
    var fixture = testFixture();
    var raw_buffer: [64]u8 = undefined;
    var packed_buffer: [64]u8 = undefined;
    const execution = try executePairV1(
        fixture.adapter(pack.descriptor),
        pack.domain,
        pack.policy,
        &pack.spans,
        &pack.decisions,
        pack.receipt,
        &raw_buffer,
        &packed_buffer,
    );
    try std.testing.expectEqual(@as(u64, 11), execution.raw_wire_bytes);
    try std.testing.expectEqual(@as(u64, 8), execution.packed_wire_bytes);
    try std.testing.expectEqual(
        @as(u64, 11),
        execution.reconciliation.raw_wire_tokens,
    );
    try std.testing.expectEqual(
        @as(u64, 8),
        execution.reconciliation.packed_wire_tokens,
    );
    try std.testing.expectEqual(
        @as(u64, 3),
        execution.reconciliation.wire_deduplicated_tokens,
    );
    try std.testing.expectEqualStrings(
        "[AABBBBBBC]",
        raw_buffer[0..execution.raw_wire_bytes],
    );
    try std.testing.expectEqualStrings(
        "[AABBBC]",
        packed_buffer[0..execution.packed_wire_bytes],
    );
    try std.testing.expect(verifyPairExecutionV1(
        pack.descriptor,
        pack.domain,
        pack.policy,
        &pack.spans,
        &pack.decisions,
        pack.receipt,
        raw_buffer[0..execution.raw_wire_bytes],
        packed_buffer[0..execution.packed_wire_bytes],
        execution,
    ));

    var replay_fixture = testFixture();
    var raw_scratch: [64]u8 = undefined;
    var packed_scratch: [64]u8 = undefined;
    try std.testing.expect(replayPairExecutionV1(
        replay_fixture.adapter(pack.descriptor),
        pack.domain,
        pack.policy,
        &pack.spans,
        &pack.decisions,
        pack.receipt,
        raw_buffer[0..execution.raw_wire_bytes],
        packed_buffer[0..execution.packed_wire_bytes],
        execution,
        &raw_scratch,
        &packed_scratch,
    ));
    try std.testing.expect(!replayPairExecutionV1(
        replay_fixture.adapter(pack.descriptor),
        pack.domain,
        pack.policy,
        &pack.spans,
        &pack.decisions,
        pack.receipt,
        raw_buffer[0..execution.raw_wire_bytes],
        packed_buffer[0..execution.packed_wire_bytes],
        execution,
        &raw_buffer,
        &packed_scratch,
    ));

    var reused_fixture = testFixture();
    var reused_scratch: [64]u8 = undefined;
    const reused_execution = try executeReusedScratchV1(
        reused_fixture.adapter(pack.descriptor),
        pack.domain,
        pack.policy,
        &pack.spans,
        &pack.decisions,
        pack.receipt,
        &reused_scratch,
    );
    try std.testing.expectEqual(execution, reused_execution);
    try std.testing.expectEqual(
        raw_buffer.len + packed_buffer.len,
        reused_scratch.len * 2,
    );
    try std.testing.expectEqualStrings(
        "[AABBBC]",
        reused_scratch[0..reused_execution.packed_wire_bytes],
    );
    try std.testing.expect(verifyRetainedPackedExecutionV1(
        pack.descriptor,
        pack.domain,
        pack.policy,
        &pack.spans,
        &pack.decisions,
        pack.receipt,
        reused_scratch[0..reused_execution.packed_wire_bytes],
        reused_execution,
    ));
    var reused_replay_fixture = testFixture();
    var reused_replay_scratch: [64]u8 = undefined;
    try std.testing.expect(replayReusedScratchV1(
        reused_replay_fixture.adapter(pack.descriptor),
        pack.domain,
        pack.policy,
        &pack.spans,
        &pack.decisions,
        pack.receipt,
        reused_scratch[0..reused_execution.packed_wire_bytes],
        reused_execution,
        &reused_replay_scratch,
    ));
    try std.testing.expect(!replayReusedScratchV1(
        reused_replay_fixture.adapter(pack.descriptor),
        pack.domain,
        pack.policy,
        &pack.spans,
        &pack.decisions,
        pack.receipt,
        reused_scratch[0..reused_execution.packed_wire_bytes],
        reused_execution,
        &reused_scratch,
    ));

    var forged = execution;
    forged.raw_wire_bytes += 1;
    forged.execution_sha256 = executionSha256(forged);
    try std.testing.expect(executionValidV1(forged));
    try std.testing.expect(!verifyPairExecutionV1(
        pack.descriptor,
        pack.domain,
        pack.policy,
        &pack.spans,
        &pack.decisions,
        pack.receipt,
        raw_buffer[0..execution.raw_wire_bytes],
        packed_buffer[0..execution.packed_wire_bytes],
        forged,
    ));
}

test "drift and split execution identities wipe private scratch" {
    const pack = try testPack();
    var raw_buffer: [64]u8 = [_]u8{0xaa} ** 64;
    var packed_buffer: [64]u8 = [_]u8{0xbb} ** 64;

    var drift = testFixture();
    drift.packed_token_delta = 1;
    try std.testing.expectError(
        context_pack.Error.TokenizationConflict,
        executePairV1(
            drift.adapter(pack.descriptor),
            pack.domain,
            pack.policy,
            &pack.spans,
            &pack.decisions,
            pack.receipt,
            &raw_buffer,
            &packed_buffer,
        ),
    );
    try std.testing.expect(std.mem.allEqual(u8, &raw_buffer, 0));
    try std.testing.expect(std.mem.allEqual(u8, &packed_buffer, 0));

    var reused_drift = testFixture();
    reused_drift.packed_token_delta = 1;
    var reused_scratch: [64]u8 = [_]u8{0xcc} ** 64;
    try std.testing.expectError(
        context_pack.Error.TokenizationConflict,
        executeReusedScratchV1(
            reused_drift.adapter(pack.descriptor),
            pack.domain,
            pack.policy,
            &pack.spans,
            &pack.decisions,
            pack.receipt,
            &reused_scratch,
        ),
    );
    try std.testing.expect(std.mem.allEqual(u8, &reused_scratch, 0));

    var split_tokens = testFixture();
    split_tokens.split_tokenizer_identity = true;
    try std.testing.expectError(
        Error.ExecutionConflict,
        executePairV1(
            split_tokens.adapter(pack.descriptor),
            pack.domain,
            pack.policy,
            &pack.spans,
            &pack.decisions,
            pack.receipt,
            &raw_buffer,
            &packed_buffer,
        ),
    );
    try std.testing.expect(std.mem.allEqual(u8, &raw_buffer, 0));
    try std.testing.expect(std.mem.allEqual(u8, &packed_buffer, 0));

    var split_render = testFixture();
    split_render.split_render_identity = true;
    try std.testing.expectError(
        Error.ExecutionConflict,
        executePairV1(
            split_render.adapter(pack.descriptor),
            pack.domain,
            pack.policy,
            &pack.spans,
            &pack.decisions,
            pack.receipt,
            &raw_buffer,
            &packed_buffer,
        ),
    );
    try std.testing.expect(std.mem.allEqual(u8, &raw_buffer, 0));
    try std.testing.expect(std.mem.allEqual(u8, &packed_buffer, 0));
}

test "descriptor storage capacity and wire mutations fail closed" {
    const pack = try testPack();
    var fixture = testFixture();
    var shared: [64]u8 = [_]u8{0xcc} ** 64;
    try std.testing.expectError(
        Error.InvalidStorage,
        executePairV1(
            fixture.adapter(pack.descriptor),
            pack.domain,
            pack.policy,
            &pack.spans,
            &pack.decisions,
            pack.receipt,
            shared[0..32],
            shared[16..48],
        ),
    );
    try std.testing.expect(std.mem.allEqual(u8, &shared, 0xcc));

    var small_raw: [4]u8 = undefined;
    var compact_buffer: [64]u8 = undefined;
    try std.testing.expectError(
        CallbackError.WireCapacityExceeded,
        executePairV1(
            fixture.adapter(pack.descriptor),
            pack.domain,
            pack.policy,
            &pack.spans,
            &pack.decisions,
            pack.receipt,
            &small_raw,
            &compact_buffer,
        ),
    );
    try std.testing.expect(std.mem.allEqual(u8, &small_raw, 0));
    try std.testing.expect(std.mem.allEqual(u8, &compact_buffer, 0));

    var foreign_domain = pack.domain;
    foreign_domain.isolation_key += 1;
    foreign_domain.domain_sha256 = context_pack.domainSha256(foreign_domain);
    try std.testing.expectError(
        Error.InvalidPack,
        executePairV1(
            fixture.adapter(pack.descriptor),
            foreign_domain,
            pack.policy,
            &pack.spans,
            &pack.decisions,
            pack.receipt,
            &shared,
            &compact_buffer,
        ),
    );

    var foreign_tokenizer_domain = pack.domain;
    foreign_tokenizer_domain.tokenizer_sha256 = testDigest(0x99);
    foreign_tokenizer_domain.domain_sha256 = context_pack.domainSha256(
        foreign_tokenizer_domain,
    );
    try std.testing.expect(context_pack.domainValidV1(
        foreign_tokenizer_domain,
    ));
    try std.testing.expect(!descriptorMatchesDomainV1(
        pack.descriptor,
        foreign_tokenizer_domain,
    ));
    try std.testing.expectError(
        Error.InvalidDescriptor,
        executePairV1(
            fixture.adapter(pack.descriptor),
            foreign_tokenizer_domain,
            pack.policy,
            &pack.spans,
            &pack.decisions,
            pack.receipt,
            &shared,
            &compact_buffer,
        ),
    );

    var weak_descriptor = pack.descriptor;
    weak_descriptor.capability_bits &= ~capability_exact_span_binding;
    weak_descriptor.descriptor_sha256 = descriptorSha256(weak_descriptor);
    try std.testing.expect(!descriptorValidV1(weak_descriptor));

    var raw_buffer: [64]u8 = undefined;
    const execution = try executePairV1(
        fixture.adapter(pack.descriptor),
        pack.domain,
        pack.policy,
        &pack.spans,
        &pack.decisions,
        pack.receipt,
        &raw_buffer,
        &compact_buffer,
    );
    raw_buffer[1] ^= 1;
    try std.testing.expect(!verifyPairExecutionV1(
        pack.descriptor,
        pack.domain,
        pack.policy,
        &pack.spans,
        &pack.decisions,
        pack.receipt,
        raw_buffer[0..execution.raw_wire_bytes],
        compact_buffer[0..execution.packed_wire_bytes],
        execution,
    ));
}

test "portable adapter evidence is pointer-free and bounded" {
    try std.testing.expect(@sizeOf(DescriptorV1) <= 192);
    try std.testing.expect(@sizeOf(ExecutionV1) <= 1024);
    inline for (.{ DescriptorV1, ExecutionV1 }) |Evidence|
        inline for (std.meta.fields(Evidence)) |field|
            try std.testing.expect(@typeInfo(field.type) != .pointer);
}
