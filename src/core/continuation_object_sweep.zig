//! Capability-scoped prepare/abort journal for continuation-object sweeps.
//!
//! A sweep grant pins one exact store snapshot and one exact collection-plan
//! root. Prepare regenerates that plan from the original root and lease
//! evidence before staging its collectible totals. Abort requires the same
//! snapshot. A separately scoped commit grant can then authorize the exact
//! regenerated retired-target set. Prepare and abort never mutate payloads;
//! commit completes every fallible check before its deallocation suffix.

const std = @import("std");
const capsule = @import("continuation_capsule.zig");
const bundle = @import("continuation_bundle.zig");
const object_store = @import("continuation_object_store.zig");

pub const Digest = capsule.Digest;
pub const zero_digest = capsule.zero_digest;

const grant_domain =
    "glacier-continuation-store-sweep-grant-v1\x00";
const prepare_domain =
    "glacier-continuation-store-sweep-prepare-v1\x00";
const abort_domain =
    "glacier-continuation-store-sweep-abort-v1\x00";
const commit_grant_domain =
    "glacier-continuation-store-sweep-commit-grant-v1\x00";
const commit_domain =
    "glacier-continuation-store-sweep-commit-v1\x00";

pub const Error = object_store.Error || error{
    InvalidSweepGrant,
    SweepScopeMismatch,
    SweepSnapshotMismatch,
    SweepPlanMismatch,
    SweepBudgetExceeded,
    NothingToSweep,
    InvalidSweepJournal,
    SweepAlreadyPrepared,
    SweepNotPrepared,
    InvalidSweepCommitGrant,
    SweepCommitScopeMismatch,
    SweepCommitJournalMismatch,
    SweepCommitBudgetExceeded,
    InvalidSweepCommitReceipt,
};

pub const GrantV1 = struct {
    authority_epoch: u64,
    tenant_scope_sha256: Digest,
    bundle_sha256: Digest,
    store_grant_sha256: Digest,
    expected_snapshot_sha256: Digest,
    collection_plan_sha256: Digest,
    max_staged_entries: u64,
    max_staged_bytes: u64,
    challenge_sha256: Digest,
};

pub const JournalState = enum(u64) {
    empty = 0,
    prepared = 1,
    aborted = 2,
};

pub const JournalV1 = struct {
    state: JournalState = .empty,
    sweep_grant_sha256: Digest = zero_digest,
    collection_plan_sha256: Digest = zero_digest,
    snapshot_sha256: Digest = zero_digest,
    staged_entries: u64 = 0,
    staged_bytes: u64 = 0,
    prepare_sha256: Digest = zero_digest,
    abort_sha256: Digest = zero_digest,
};

pub const CommitGrantV1 = struct {
    authority_epoch: u64,
    tenant_scope_sha256: Digest,
    bundle_sha256: Digest,
    store_grant_sha256: Digest,
    sweep_grant_sha256: Digest,
    prepare_sha256: Digest,
    expected_snapshot_sha256: Digest,
    collection_plan_sha256: Digest,
    max_freed_entries: u64,
    max_freed_bytes: u64,
    challenge_sha256: Digest,
};

pub const PrepareReceiptV1 = struct {
    sweep_grant_sha256: Digest,
    collection_plan_sha256: Digest,
    snapshot_sha256: Digest,
    staged_entries: u64,
    staged_bytes: u64,
    prepare_sha256: Digest,
};

pub const AbortReceiptV1 = struct {
    sweep_grant_sha256: Digest,
    collection_plan_sha256: Digest,
    snapshot_sha256: Digest,
    staged_entries: u64,
    staged_bytes: u64,
    prepare_sha256: Digest,
    abort_sha256: Digest,
};

pub const PrepareResultV1 = struct {
    journal: JournalV1,
    receipt: PrepareReceiptV1,
    collection_receipt: object_store.CollectionReceiptV1,
};

pub const AbortResultV1 = struct {
    journal: JournalV1,
    receipt: AbortReceiptV1,
};

pub const CommitReceiptV1 = struct {
    commit_grant_sha256: Digest,
    sweep_grant_sha256: Digest,
    prepare_sha256: Digest,
    collection_plan_sha256: Digest,
    targets_sha256: Digest,
    snapshot_before_sha256: Digest,
    snapshot_after_sha256: Digest,
    store_commit_sha256: Digest,
    freed_entries: u64,
    freed_payload_bytes: u64,
    freed_index_bytes: u64,
    freed_repair_count: u64,
    allocator_deallocation_calls: u64,
    commit_sha256: Digest,
};

pub const CommitResultV1 = struct {
    receipt: CommitReceiptV1,
    store_receipt: object_store.RetiredCommitReceiptV1,
};

pub fn grantRootV1(grant: GrantV1) Error!Digest {
    try validateGrantV1(grant);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(grant_domain);
    hashU64(&hash, grant.authority_epoch);
    hash.update(&grant.tenant_scope_sha256);
    hash.update(&grant.bundle_sha256);
    hash.update(&grant.store_grant_sha256);
    hash.update(&grant.expected_snapshot_sha256);
    hash.update(&grant.collection_plan_sha256);
    hashU64(&hash, grant.max_staged_entries);
    hashU64(&hash, grant.max_staged_bytes);
    hash.update(&grant.challenge_sha256);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

pub fn commitGrantRootV1(grant: CommitGrantV1) Error!Digest {
    try validateCommitGrantV1(grant);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(commit_grant_domain);
    hashU64(&hash, grant.authority_epoch);
    hash.update(&grant.tenant_scope_sha256);
    hash.update(&grant.bundle_sha256);
    hash.update(&grant.store_grant_sha256);
    hash.update(&grant.sweep_grant_sha256);
    hash.update(&grant.prepare_sha256);
    hash.update(&grant.expected_snapshot_sha256);
    hash.update(&grant.collection_plan_sha256);
    hashU64(&hash, grant.max_freed_entries);
    hashU64(&hash, grant.max_freed_bytes);
    hash.update(&grant.challenge_sha256);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

pub fn commitRootV1(receipt: CommitReceiptV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(commit_domain);
    hash.update(&receipt.commit_grant_sha256);
    hash.update(&receipt.sweep_grant_sha256);
    hash.update(&receipt.prepare_sha256);
    hash.update(&receipt.collection_plan_sha256);
    hash.update(&receipt.targets_sha256);
    hash.update(&receipt.snapshot_before_sha256);
    hash.update(&receipt.snapshot_after_sha256);
    hash.update(&receipt.store_commit_sha256);
    hashU64(&hash, receipt.freed_entries);
    hashU64(&hash, receipt.freed_payload_bytes);
    hashU64(&hash, receipt.freed_index_bytes);
    hashU64(&hash, receipt.freed_repair_count);
    hashU64(&hash, receipt.allocator_deallocation_calls);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

pub fn prepareRootV1(receipt: PrepareReceiptV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(prepare_domain);
    hash.update(&receipt.sweep_grant_sha256);
    hash.update(&receipt.collection_plan_sha256);
    hash.update(&receipt.snapshot_sha256);
    hashU64(&hash, receipt.staged_entries);
    hashU64(&hash, receipt.staged_bytes);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

pub fn abortRootV1(receipt: AbortReceiptV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(abort_domain);
    hash.update(&receipt.sweep_grant_sha256);
    hash.update(&receipt.collection_plan_sha256);
    hash.update(&receipt.snapshot_sha256);
    hashU64(&hash, receipt.staged_entries);
    hashU64(&hash, receipt.staged_bytes);
    hash.update(&receipt.prepare_sha256);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

pub fn prepareV1(
    store: *object_store.Store,
    sweep_grant: GrantV1,
    collection_grant: object_store.CollectionGrantV1,
    root_references: []const bundle.BlobRefV1,
    lease_receipts: []const object_store.LeaseReceiptV1,
    current: JournalV1,
) Error!PrepareResultV1 {
    try ensureEmptyJournalV1(current);
    const sweep_grant_root = try ensureGrantV1(store, sweep_grant);
    if (!std.mem.eql(
        u8,
        &collection_grant.expected_snapshot_sha256,
        &sweep_grant.expected_snapshot_sha256,
    )) return Error.SweepSnapshotMismatch;

    var decisions: [object_store.default_capacity]object_store.CollectionDecisionV1 =
        undefined;
    const collection_receipt = try store.planCollectionV1(
        collection_grant,
        root_references,
        lease_receipts,
        &decisions,
    );
    if (!std.mem.eql(
        u8,
        &collection_receipt.snapshot_sha256,
        &sweep_grant.expected_snapshot_sha256,
    )) return Error.SweepSnapshotMismatch;
    if (!std.mem.eql(
        u8,
        &collection_receipt.plan_sha256,
        &sweep_grant.collection_plan_sha256,
    )) return Error.SweepPlanMismatch;
    if (collection_receipt.collectible_entries == 0 or
        collection_receipt.collectible_bytes == 0)
        return Error.NothingToSweep;
    if (collection_receipt.collectible_entries >
        sweep_grant.max_staged_entries or
        collection_receipt.collectible_bytes > sweep_grant.max_staged_bytes)
        return Error.SweepBudgetExceeded;

    const snapshot_after = try store.auditSnapshotRootV2();
    if (!std.mem.eql(
        u8,
        &snapshot_after,
        &sweep_grant.expected_snapshot_sha256,
    )) return Error.SweepSnapshotMismatch;

    var receipt: PrepareReceiptV1 = .{
        .sweep_grant_sha256 = sweep_grant_root,
        .collection_plan_sha256 = collection_receipt.plan_sha256,
        .snapshot_sha256 = snapshot_after,
        .staged_entries = collection_receipt.collectible_entries,
        .staged_bytes = collection_receipt.collectible_bytes,
        .prepare_sha256 = zero_digest,
    };
    receipt.prepare_sha256 = prepareRootV1(receipt);
    const journal: JournalV1 = .{
        .state = .prepared,
        .sweep_grant_sha256 = receipt.sweep_grant_sha256,
        .collection_plan_sha256 = receipt.collection_plan_sha256,
        .snapshot_sha256 = receipt.snapshot_sha256,
        .staged_entries = receipt.staged_entries,
        .staged_bytes = receipt.staged_bytes,
        .prepare_sha256 = receipt.prepare_sha256,
        .abort_sha256 = zero_digest,
    };
    return .{
        .journal = journal,
        .receipt = receipt,
        .collection_receipt = collection_receipt,
    };
}

pub fn abortV1(
    store: *object_store.Store,
    sweep_grant: GrantV1,
    current: JournalV1,
) Error!AbortResultV1 {
    const sweep_grant_root = try ensureGrantV1(store, sweep_grant);
    try verifyPreparedJournalV1(sweep_grant, sweep_grant_root, current);
    const snapshot = try store.auditSnapshotRootV2();
    if (!std.mem.eql(
        u8,
        &snapshot,
        &sweep_grant.expected_snapshot_sha256,
    )) return Error.SweepSnapshotMismatch;

    var receipt: AbortReceiptV1 = .{
        .sweep_grant_sha256 = current.sweep_grant_sha256,
        .collection_plan_sha256 = current.collection_plan_sha256,
        .snapshot_sha256 = snapshot,
        .staged_entries = current.staged_entries,
        .staged_bytes = current.staged_bytes,
        .prepare_sha256 = current.prepare_sha256,
        .abort_sha256 = zero_digest,
    };
    receipt.abort_sha256 = abortRootV1(receipt);
    var journal = current;
    journal.state = .aborted;
    journal.abort_sha256 = receipt.abort_sha256;
    return .{ .journal = journal, .receipt = receipt };
}

pub fn commitV1(
    store: *object_store.Store,
    sweep_grant: GrantV1,
    commit_grant: CommitGrantV1,
    collection_grant: object_store.CollectionGrantV1,
    root_references: []const bundle.BlobRefV1,
    lease_receipts: []const object_store.LeaseReceiptV1,
    current: JournalV1,
) Error!CommitResultV1 {
    const sweep_grant_root = try ensureGrantV1(store, sweep_grant);
    try verifyPreparedJournalV1(sweep_grant, sweep_grant_root, current);
    const commit_grant_root = try ensureCommitGrantV1(
        store,
        sweep_grant,
        sweep_grant_root,
        commit_grant,
        current,
    );
    if (!std.mem.eql(
        u8,
        &collection_grant.expected_snapshot_sha256,
        &current.snapshot_sha256,
    )) return Error.SweepCommitJournalMismatch;

    var decisions: [object_store.default_capacity]object_store.CollectionDecisionV1 =
        undefined;
    const plan = try store.planCollectionV1(
        collection_grant,
        root_references,
        lease_receipts,
        &decisions,
    );
    if (!std.mem.eql(u8, &plan.plan_sha256, &current.collection_plan_sha256) or
        !std.mem.eql(u8, &plan.plan_sha256, &commit_grant.collection_plan_sha256) or
        !std.mem.eql(u8, &plan.snapshot_sha256, &current.snapshot_sha256))
        return Error.SweepCommitJournalMismatch;

    const decision_count = std.math.cast(
        usize,
        plan.occupied_entries,
    ) orelse return Error.SweepCommitBudgetExceeded;
    var targets: [object_store.default_capacity]bundle.BlobRefV1 = undefined;
    var target_count: usize = 0;
    var target_bytes: u64 = 0;
    for (decisions[0..decision_count]) |decision| {
        if (decision.class != .collectible) continue;
        if (target_count >= targets.len)
            return Error.SweepCommitBudgetExceeded;
        targets[target_count] = decision.target;
        target_count += 1;
        target_bytes = std.math.add(
            u64,
            target_bytes,
            decision.target.byte_length,
        ) catch return Error.SweepCommitBudgetExceeded;
    }
    const target_count_u64 = std.math.cast(u64, target_count) orelse
        return Error.SweepCommitBudgetExceeded;
    if (target_count_u64 != current.staged_entries or
        target_bytes != current.staged_bytes or
        target_count_u64 != plan.collectible_entries or
        target_bytes != plan.collectible_bytes)
        return Error.SweepCommitJournalMismatch;
    if (target_count_u64 > commit_grant.max_freed_entries or
        target_bytes > commit_grant.max_freed_bytes)
        return Error.SweepCommitBudgetExceeded;
    object_store.sortRootReferencesV1(targets[0..target_count]);
    const permit: object_store.RetiredCommitPermitV1 = .{
        .authority_epoch = commit_grant.authority_epoch,
        .tenant_scope_sha256 = commit_grant.tenant_scope_sha256,
        .bundle_sha256 = commit_grant.bundle_sha256,
        .store_grant_sha256 = commit_grant.store_grant_sha256,
        .expected_snapshot_sha256 = commit_grant.expected_snapshot_sha256,
        .authorization_sha256 = commit_grant_root,
        .max_freed_entries = commit_grant.max_freed_entries,
        .max_freed_bytes = commit_grant.max_freed_bytes,
    };
    const store_receipt = try store.commitRetiredV1(
        permit,
        targets[0..target_count],
    );
    var receipt: CommitReceiptV1 = .{
        .commit_grant_sha256 = commit_grant_root,
        .sweep_grant_sha256 = sweep_grant_root,
        .prepare_sha256 = current.prepare_sha256,
        .collection_plan_sha256 = current.collection_plan_sha256,
        .targets_sha256 = store_receipt.targets_sha256,
        .snapshot_before_sha256 = store_receipt.snapshot_before_sha256,
        .snapshot_after_sha256 = store_receipt.snapshot_after_sha256,
        .store_commit_sha256 = store_receipt.commit_sha256,
        .freed_entries = store_receipt.freed_entries,
        .freed_payload_bytes = store_receipt.freed_payload_bytes,
        .freed_index_bytes = store_receipt.freed_index_bytes,
        .freed_repair_count = store_receipt.freed_repair_count,
        .allocator_deallocation_calls = store_receipt.allocator_deallocation_calls,
        .commit_sha256 = zero_digest,
    };
    receipt.commit_sha256 = commitRootV1(receipt);
    return .{ .receipt = receipt, .store_receipt = store_receipt };
}

pub fn verifyCommitReceiptV1(
    commit_grant: CommitGrantV1,
    receipt: CommitReceiptV1,
    store_receipt: object_store.RetiredCommitReceiptV1,
) Error!void {
    const commit_grant_root = try commitGrantRootV1(commit_grant);
    object_store.verifyRetiredCommitReceiptV1(store_receipt) catch
        return Error.InvalidSweepCommitReceipt;
    if (!std.mem.eql(
        u8,
        &receipt.commit_grant_sha256,
        &commit_grant_root,
    ) or !std.mem.eql(
        u8,
        &receipt.sweep_grant_sha256,
        &commit_grant.sweep_grant_sha256,
    ) or !std.mem.eql(
        u8,
        &receipt.prepare_sha256,
        &commit_grant.prepare_sha256,
    ) or !std.mem.eql(
        u8,
        &receipt.collection_plan_sha256,
        &commit_grant.collection_plan_sha256,
    ) or !std.mem.eql(
        u8,
        &receipt.snapshot_before_sha256,
        &commit_grant.expected_snapshot_sha256,
    ) or !std.mem.eql(
        u8,
        &store_receipt.authorization_sha256,
        &commit_grant_root,
    ) or !std.mem.eql(
        u8,
        &store_receipt.commit_sha256,
        &object_store.retiredCommitReceiptRootV1(store_receipt),
    ) or !std.mem.eql(
        u8,
        &receipt.targets_sha256,
        &store_receipt.targets_sha256,
    ) or !std.mem.eql(
        u8,
        &receipt.snapshot_before_sha256,
        &store_receipt.snapshot_before_sha256,
    ) or !std.mem.eql(
        u8,
        &receipt.snapshot_after_sha256,
        &store_receipt.snapshot_after_sha256,
    ) or !std.mem.eql(
        u8,
        &receipt.store_commit_sha256,
        &store_receipt.commit_sha256,
    ) or receipt.freed_entries != store_receipt.freed_entries or
        receipt.freed_payload_bytes != store_receipt.freed_payload_bytes or
        receipt.freed_index_bytes != store_receipt.freed_index_bytes or
        receipt.freed_repair_count != store_receipt.freed_repair_count or
        receipt.allocator_deallocation_calls !=
            store_receipt.allocator_deallocation_calls or
        receipt.freed_entries > commit_grant.max_freed_entries or
        receipt.freed_payload_bytes > commit_grant.max_freed_bytes or
        !std.mem.eql(
            u8,
            &receipt.commit_sha256,
            &commitRootV1(receipt),
        )) return Error.InvalidSweepCommitReceipt;
}

pub fn verifyJournalV1(
    sweep_grant: GrantV1,
    journal: JournalV1,
) Error!void {
    const sweep_grant_root = try grantRootV1(sweep_grant);
    switch (journal.state) {
        .empty => try ensureEmptyJournalV1(journal),
        .prepared => try verifyPreparedJournalV1(
            sweep_grant,
            sweep_grant_root,
            journal,
        ),
        .aborted => {
            if (isZero(journal.abort_sha256))
                return Error.InvalidSweepJournal;
            var prepared = journal;
            prepared.state = .prepared;
            prepared.abort_sha256 = zero_digest;
            try verifyPreparedJournalV1(
                sweep_grant,
                sweep_grant_root,
                prepared,
            );
            const abort_receipt: AbortReceiptV1 = .{
                .sweep_grant_sha256 = journal.sweep_grant_sha256,
                .collection_plan_sha256 = journal.collection_plan_sha256,
                .snapshot_sha256 = journal.snapshot_sha256,
                .staged_entries = journal.staged_entries,
                .staged_bytes = journal.staged_bytes,
                .prepare_sha256 = journal.prepare_sha256,
                .abort_sha256 = journal.abort_sha256,
            };
            if (!std.mem.eql(
                u8,
                &abortRootV1(abort_receipt),
                &journal.abort_sha256,
            )) return Error.InvalidSweepJournal;
        },
    }
}

fn ensureGrantV1(
    store: *const object_store.Store,
    grant: GrantV1,
) Error!Digest {
    const root = try grantRootV1(grant);
    if (store.closed) return Error.StoreClosed;
    if (grant.authority_epoch != store.grant.authority_epoch or
        !std.mem.eql(
            u8,
            &grant.tenant_scope_sha256,
            &store.grant.tenant_scope_sha256,
        ) or
        !std.mem.eql(
            u8,
            &grant.bundle_sha256,
            &store.grant.bundle_sha256,
        ) or
        !std.mem.eql(
            u8,
            &grant.store_grant_sha256,
            &store.grant_sha256,
        )) return Error.SweepScopeMismatch;
    return root;
}

fn ensureCommitGrantV1(
    store: *const object_store.Store,
    sweep_grant: GrantV1,
    sweep_grant_sha256: Digest,
    commit_grant: CommitGrantV1,
    journal: JournalV1,
) Error!Digest {
    const root = try commitGrantRootV1(commit_grant);
    if (store.closed) return Error.StoreClosed;
    if (commit_grant.authority_epoch != store.grant.authority_epoch or
        !std.mem.eql(
            u8,
            &commit_grant.tenant_scope_sha256,
            &store.grant.tenant_scope_sha256,
        ) or
        !std.mem.eql(
            u8,
            &commit_grant.bundle_sha256,
            &store.grant.bundle_sha256,
        ) or
        !std.mem.eql(
            u8,
            &commit_grant.store_grant_sha256,
            &store.grant_sha256,
        )) return Error.SweepCommitScopeMismatch;
    if (!std.mem.eql(
        u8,
        &commit_grant.sweep_grant_sha256,
        &sweep_grant_sha256,
    ) or !std.mem.eql(
        u8,
        &commit_grant.prepare_sha256,
        &journal.prepare_sha256,
    ) or !std.mem.eql(
        u8,
        &commit_grant.expected_snapshot_sha256,
        &journal.snapshot_sha256,
    ) or !std.mem.eql(
        u8,
        &commit_grant.collection_plan_sha256,
        &journal.collection_plan_sha256,
    ) or commit_grant.max_freed_entries > sweep_grant.max_staged_entries or
        commit_grant.max_freed_bytes > sweep_grant.max_staged_bytes)
        return Error.SweepCommitJournalMismatch;
    return root;
}

fn validateGrantV1(grant: GrantV1) Error!void {
    if (grant.authority_epoch == 0 or
        isZero(grant.tenant_scope_sha256) or
        isZero(grant.bundle_sha256) or
        isZero(grant.store_grant_sha256) or
        isZero(grant.expected_snapshot_sha256) or
        isZero(grant.collection_plan_sha256) or
        grant.max_staged_entries == 0 or
        grant.max_staged_bytes == 0 or
        isZero(grant.challenge_sha256))
        return Error.InvalidSweepGrant;
}

fn validateCommitGrantV1(grant: CommitGrantV1) Error!void {
    if (grant.authority_epoch == 0 or
        isZero(grant.tenant_scope_sha256) or
        isZero(grant.bundle_sha256) or
        isZero(grant.store_grant_sha256) or
        isZero(grant.sweep_grant_sha256) or
        isZero(grant.prepare_sha256) or
        isZero(grant.expected_snapshot_sha256) or
        isZero(grant.collection_plan_sha256) or
        grant.max_freed_entries == 0 or
        grant.max_freed_bytes == 0 or
        isZero(grant.challenge_sha256))
        return Error.InvalidSweepCommitGrant;
}

fn ensureEmptyJournalV1(journal: JournalV1) Error!void {
    if (journal.state != .empty)
        return Error.SweepAlreadyPrepared;
    if (!isZero(journal.sweep_grant_sha256) or
        !isZero(journal.collection_plan_sha256) or
        !isZero(journal.snapshot_sha256) or
        journal.staged_entries != 0 or
        journal.staged_bytes != 0 or
        !isZero(journal.prepare_sha256) or
        !isZero(journal.abort_sha256))
        return Error.InvalidSweepJournal;
}

fn verifyPreparedJournalV1(
    grant: GrantV1,
    sweep_grant_root: Digest,
    journal: JournalV1,
) Error!void {
    if (journal.state != .prepared)
        return Error.SweepNotPrepared;
    if (isZero(journal.abort_sha256) == false or
        journal.staged_entries == 0 or
        journal.staged_bytes == 0 or
        journal.staged_entries > grant.max_staged_entries or
        journal.staged_bytes > grant.max_staged_bytes or
        !std.mem.eql(
            u8,
            &journal.sweep_grant_sha256,
            &sweep_grant_root,
        ) or
        !std.mem.eql(
            u8,
            &journal.collection_plan_sha256,
            &grant.collection_plan_sha256,
        ) or
        !std.mem.eql(
            u8,
            &journal.snapshot_sha256,
            &grant.expected_snapshot_sha256,
        )) return Error.InvalidSweepJournal;
    const receipt: PrepareReceiptV1 = .{
        .sweep_grant_sha256 = journal.sweep_grant_sha256,
        .collection_plan_sha256 = journal.collection_plan_sha256,
        .snapshot_sha256 = journal.snapshot_sha256,
        .staged_entries = journal.staged_entries,
        .staged_bytes = journal.staged_bytes,
        .prepare_sha256 = journal.prepare_sha256,
    };
    if (!std.mem.eql(
        u8,
        &prepareRootV1(receipt),
        &journal.prepare_sha256,
    )) return Error.InvalidSweepJournal;
}

fn hashU64(hash: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

fn isZero(value: Digest) bool {
    return std.mem.allEqual(u8, &value, 0);
}

const TestBundleFixture = struct {
    objects: capsule.ObjectsV1,
    capsule_config: capsule.ConfigV1,
    capsule_wire: []const u8,
    bundle_config: bundle.ConfigV1,
    bundle_wire: []const u8,
    decoded: bundle.DecodedV1,
};

const TestCollectionFixture = struct {
    roots: [capsule.object_count - 1]bundle.BlobRefV1,
    leases: [1]object_store.LeaseReceiptV1,
    grant: object_store.CollectionGrantV1,
    receipt: object_store.CollectionReceiptV1,
};

test "sweep journal prepares and aborts exact plan without store mutation" {
    var capsule_storage: [capsule.encoded_bytes]u8 = undefined;
    var bundle_storage: [bundle.encoded_bytes]u8 = undefined;
    const fixture = try testBundleFixture(
        &capsule_storage,
        &bundle_storage,
    );
    const store_grant = testStoreGrant(
        try bundle.envelopeRootV1(fixture.bundle_wire),
    );
    var allocator_storage: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_storage);
    var store = try object_store.Store.initV1(
        fba.allocator(),
        store_grant,
        store_grant.authority_epoch,
    );
    defer store.deinit();
    _ = try store.importBundleV1(
        fixture.bundle_wire,
        fixture.bundle_config,
        fixture.capsule_wire,
        fixture.objects,
    );
    const collection = try testCollectionFixture(
        &store,
        fixture,
        store_grant,
    );
    const sweep_grant = testSweepGrant(
        store_grant,
        collection.grant.expected_snapshot_sha256,
        collection.receipt.plan_sha256,
    );
    const snapshot_before = try store.auditSnapshotRootV2();
    const payload_before = store.payload_bytes;
    const allocator_before = fba.end_index;
    const current: JournalV1 = .{};
    const prepared = try prepareV1(
        &store,
        sweep_grant,
        collection.grant,
        &collection.roots,
        &collection.leases,
        current,
    );
    try std.testing.expectEqual(JournalState.prepared, prepared.journal.state);
    try std.testing.expectEqual(@as(u64, 1), prepared.receipt.staged_entries);
    try std.testing.expectEqual(@as(u64, 30), prepared.receipt.staged_bytes);
    try std.testing.expectEqualSlices(
        u8,
        &collection.receipt.plan_sha256,
        &prepared.collection_receipt.plan_sha256,
    );
    try verifyJournalV1(sweep_grant, prepared.journal);
    try std.testing.expectEqualSlices(
        u8,
        &snapshot_before,
        &(try store.auditSnapshotRootV2()),
    );
    try std.testing.expectEqual(payload_before, store.payload_bytes);
    try std.testing.expectEqual(allocator_before, fba.end_index);
    try std.testing.expectEqual(@as(usize, 184), @sizeOf(JournalV1));
    const grant_hex = std.fmt.bytesToHex(
        try grantRootV1(sweep_grant),
        .lower,
    );
    try std.testing.expectEqualStrings(
        "062021af17762a0d259073ce5bb2bcf3" ++
            "860d146f621b86d2149efcd7a615612c",
        &grant_hex,
    );
    const prepare_hex = std.fmt.bytesToHex(
        prepared.receipt.prepare_sha256,
        .lower,
    );
    try std.testing.expectEqualStrings(
        "4e660266135b3a4aa7f5116fffb8191e" ++
            "f4c931e479320fbfd6366abbe5999474",
        &prepare_hex,
    );

    const aborted = try abortV1(&store, sweep_grant, prepared.journal);
    try std.testing.expectEqual(JournalState.aborted, aborted.journal.state);
    try verifyJournalV1(sweep_grant, aborted.journal);
    try std.testing.expectError(
        Error.SweepNotPrepared,
        abortV1(&store, sweep_grant, aborted.journal),
    );
    try std.testing.expectEqualSlices(
        u8,
        &snapshot_before,
        &(try store.auditSnapshotRootV2()),
    );
    try std.testing.expectEqual(payload_before, store.payload_bytes);
    try std.testing.expectEqual(allocator_before, fba.end_index);
    try std.testing.expectEqual(JournalState.empty, current.state);
    const abort_hex = std.fmt.bytesToHex(
        aborted.receipt.abort_sha256,
        .lower,
    );
    try std.testing.expectEqualStrings(
        "603535a93206cfafcee6a1a58c58cb97" ++
            "de21c94e0e433f184bd9a9ee09513c1e",
        &abort_hex,
    );
}

test "sweep journal scope evidence budgets and transitions fail closed" {
    var capsule_storage: [capsule.encoded_bytes]u8 = undefined;
    var bundle_storage: [bundle.encoded_bytes]u8 = undefined;
    const fixture = try testBundleFixture(
        &capsule_storage,
        &bundle_storage,
    );
    const store_grant = testStoreGrant(
        try bundle.envelopeRootV1(fixture.bundle_wire),
    );
    var allocator_storage: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_storage);
    var store = try object_store.Store.initV1(
        fba.allocator(),
        store_grant,
        store_grant.authority_epoch,
    );
    defer store.deinit();
    _ = try store.importBundleV1(
        fixture.bundle_wire,
        fixture.bundle_config,
        fixture.capsule_wire,
        fixture.objects,
    );
    const collection = try testCollectionFixture(
        &store,
        fixture,
        store_grant,
    );
    const sweep_grant = testSweepGrant(
        store_grant,
        collection.grant.expected_snapshot_sha256,
        collection.receipt.plan_sha256,
    );
    const empty: JournalV1 = .{};

    var wrong_scope = sweep_grant;
    wrong_scope.bundle_sha256[0] ^= 1;
    try std.testing.expectError(
        Error.SweepScopeMismatch,
        prepareV1(
            &store,
            wrong_scope,
            collection.grant,
            &collection.roots,
            &collection.leases,
            empty,
        ),
    );
    var wrong_plan = sweep_grant;
    wrong_plan.collection_plan_sha256[0] ^= 1;
    try std.testing.expectError(
        Error.SweepPlanMismatch,
        prepareV1(
            &store,
            wrong_plan,
            collection.grant,
            &collection.roots,
            &collection.leases,
            empty,
        ),
    );
    var byte_limited = sweep_grant;
    byte_limited.max_staged_bytes = 29;
    try std.testing.expectError(
        Error.SweepBudgetExceeded,
        prepareV1(
            &store,
            byte_limited,
            collection.grant,
            &collection.roots,
            &collection.leases,
            empty,
        ),
    );
    try std.testing.expectError(
        object_store.Error.ReachabilityMismatch,
        prepareV1(
            &store,
            sweep_grant,
            collection.grant,
            collection.roots[0 .. collection.roots.len - 1],
            &collection.leases,
            empty,
        ),
    );
    try std.testing.expectError(
        object_store.Error.LeaseReceiptMismatch,
        prepareV1(
            &store,
            sweep_grant,
            collection.grant,
            &collection.roots,
            &[_]object_store.LeaseReceiptV1{},
            empty,
        ),
    );

    const prepared = try prepareV1(
        &store,
        sweep_grant,
        collection.grant,
        &collection.roots,
        &collection.leases,
        empty,
    );
    try std.testing.expectError(
        Error.SweepAlreadyPrepared,
        prepareV1(
            &store,
            sweep_grant,
            collection.grant,
            &collection.roots,
            &collection.leases,
            prepared.journal,
        ),
    );
    try std.testing.expectError(
        Error.SweepNotPrepared,
        abortV1(&store, sweep_grant, empty),
    );
    var tampered = prepared.journal;
    tampered.staged_bytes += 1;
    try std.testing.expectError(
        Error.InvalidSweepJournal,
        abortV1(&store, sweep_grant, tampered),
    );
    try store.releaseV1(collection.roots[0]);
    try std.testing.expectError(
        Error.SweepSnapshotMismatch,
        abortV1(&store, sweep_grant, prepared.journal),
    );
}

test "sweep commit atomically frees exact retired target and reclaims allocator tail" {
    var capsule_storage: [capsule.encoded_bytes]u8 = undefined;
    var bundle_storage: [bundle.encoded_bytes]u8 = undefined;
    const fixture = try testBundleFixture(
        &capsule_storage,
        &bundle_storage,
    );
    const store_grant = testStoreGrant(
        try bundle.envelopeRootV1(fixture.bundle_wire),
    );
    var allocator_storage: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_storage);
    var store = try object_store.Store.initV1(
        fba.allocator(),
        store_grant,
        store_grant.authority_epoch,
    );
    defer store.deinit();
    _ = try store.importBundleV1(
        fixture.bundle_wire,
        fixture.bundle_config,
        fixture.capsule_wire,
        fixture.objects,
    );
    const collection = try testCollectionFixtureForKind(
        &store,
        fixture,
        store_grant,
        .publication_receipt,
    );
    const sweep_grant = testSweepGrant(
        store_grant,
        collection.grant.expected_snapshot_sha256,
        collection.receipt.plan_sha256,
    );
    const prepared = try prepareV1(
        &store,
        sweep_grant,
        collection.grant,
        &collection.roots,
        &collection.leases,
        .{},
    );
    const commit_grant = testCommitGrant(
        store_grant,
        sweep_grant,
        prepared.journal,
    );
    const allocator_before = fba.end_index;
    const committed = try commitV1(
        &store,
        sweep_grant,
        commit_grant,
        collection.grant,
        &collection.roots,
        &collection.leases,
        prepared.journal,
    );
    try verifyCommitReceiptV1(
        commit_grant,
        committed.receipt,
        committed.store_receipt,
    );
    const commit_grant_hex = std.fmt.bytesToHex(
        try commitGrantRootV1(commit_grant),
        .lower,
    );
    try std.testing.expectEqualStrings(
        "4bb165e6809e00403cc17997d3bdbcc1" ++
            "3787c051d895b4ff7eadde9d24991d3e",
        &commit_grant_hex,
    );
    const targets_hex = std.fmt.bytesToHex(
        committed.receipt.targets_sha256,
        .lower,
    );
    try std.testing.expectEqualStrings(
        "d5e185b91d3aae5e6d96f249c69cc59" ++
            "b213e9cdd43717669fee2192d2752988e",
        &targets_hex,
    );
    const store_commit_hex = std.fmt.bytesToHex(
        committed.store_receipt.commit_sha256,
        .lower,
    );
    try std.testing.expectEqualStrings(
        "4dc638ad333478ba67e7273f6bdd3e5c" ++
            "3bb7b82c2b3df0fef0d7ad3aa22a2c88",
        &store_commit_hex,
    );
    const commit_hex = std.fmt.bytesToHex(
        committed.receipt.commit_sha256,
        .lower,
    );
    try std.testing.expectEqualStrings(
        "e40010e0a26dbfe6cd94ecfdb3b1fbf" ++
            "49b9b3f4421b1cf40247fa6304ad309b5",
        &commit_hex,
    );
    const after_hex = std.fmt.bytesToHex(
        committed.receipt.snapshot_after_sha256,
        .lower,
    );
    try std.testing.expectEqualStrings(
        "2e537f05538bcb1ef378a600f55fd1bc" ++
            "f35c85c9c1f4185cb908a128ec147ab2",
        &after_hex,
    );
    try store.verifyAllV1();
    try std.testing.expectEqual(@as(u64, 1), committed.receipt.freed_entries);
    try std.testing.expectEqual(@as(u64, 39), committed.receipt.freed_payload_bytes);
    try std.testing.expectEqual(
        object_store.logical_index_entry_bytes,
        committed.receipt.freed_index_bytes,
    );
    try std.testing.expectEqual(@as(u64, 0), committed.receipt.freed_repair_count);
    try std.testing.expectEqual(@as(u64, 1), committed.receipt.allocator_deallocation_calls);
    try std.testing.expectEqual(@as(u64, 7), store.entry_count);
    try std.testing.expectEqual(@as(u64, 0), store.retired_entries);
    try std.testing.expectEqual(@as(u64, 216), store.payload_bytes);
    try std.testing.expectEqual(@as(usize, 255), allocator_before);
    try std.testing.expectEqual(@as(usize, 216), fba.end_index);
    var contradictory_store_receipt = committed.store_receipt;
    contradictory_store_receipt.accounting_after.payload_bytes += 1;
    contradictory_store_receipt.commit_sha256 =
        object_store.retiredCommitReceiptRootV1(contradictory_store_receipt);
    var contradictory_receipt = committed.receipt;
    contradictory_receipt.store_commit_sha256 =
        contradictory_store_receipt.commit_sha256;
    contradictory_receipt.commit_sha256 = commitRootV1(contradictory_receipt);
    try std.testing.expectError(
        Error.InvalidSweepCommitReceipt,
        verifyCommitReceiptV1(
            commit_grant,
            contradictory_receipt,
            contradictory_store_receipt,
        ),
    );
    const retired_entry = fixture.decoded.entry(.publication_receipt);
    try std.testing.expectError(
        object_store.Error.NotFound,
        store.getV1(.{
            .byte_length = retired_entry.byte_length,
            .sha256 = retired_entry.blob_sha256,
        }, &[_]u8{}),
    );
    try std.testing.expectError(
        object_store.Error.CollectionSnapshotMismatch,
        commitV1(
            &store,
            sweep_grant,
            commit_grant,
            collection.grant,
            &collection.roots,
            &collection.leases,
            prepared.journal,
        ),
    );
}

test "sweep commit grant evidence targets and budgets fail before mutation" {
    var capsule_storage: [capsule.encoded_bytes]u8 = undefined;
    var bundle_storage: [bundle.encoded_bytes]u8 = undefined;
    const fixture = try testBundleFixture(
        &capsule_storage,
        &bundle_storage,
    );
    const store_grant = testStoreGrant(
        try bundle.envelopeRootV1(fixture.bundle_wire),
    );
    var allocator_storage: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_storage);
    var store = try object_store.Store.initV1(
        fba.allocator(),
        store_grant,
        store_grant.authority_epoch,
    );
    defer store.deinit();
    _ = try store.importBundleV1(
        fixture.bundle_wire,
        fixture.bundle_config,
        fixture.capsule_wire,
        fixture.objects,
    );
    const collection = try testCollectionFixtureForKind(
        &store,
        fixture,
        store_grant,
        .publication_receipt,
    );
    const sweep_grant = testSweepGrant(
        store_grant,
        collection.grant.expected_snapshot_sha256,
        collection.receipt.plan_sha256,
    );
    const prepared = try prepareV1(
        &store,
        sweep_grant,
        collection.grant,
        &collection.roots,
        &collection.leases,
        .{},
    );
    const commit_grant = testCommitGrant(
        store_grant,
        sweep_grant,
        prepared.journal,
    );
    const snapshot_before = try store.auditSnapshotRootV2();
    const allocator_before = fba.end_index;

    var wrong_scope = commit_grant;
    wrong_scope.bundle_sha256[0] ^= 1;
    try std.testing.expectError(
        Error.SweepCommitScopeMismatch,
        commitV1(
            &store,
            sweep_grant,
            wrong_scope,
            collection.grant,
            &collection.roots,
            &collection.leases,
            prepared.journal,
        ),
    );
    var wrong_prepare = commit_grant;
    wrong_prepare.prepare_sha256[0] ^= 1;
    try std.testing.expectError(
        Error.SweepCommitJournalMismatch,
        commitV1(
            &store,
            sweep_grant,
            wrong_prepare,
            collection.grant,
            &collection.roots,
            &collection.leases,
            prepared.journal,
        ),
    );
    var byte_limited = commit_grant;
    byte_limited.max_freed_bytes = 38;
    try std.testing.expectError(
        Error.SweepCommitBudgetExceeded,
        commitV1(
            &store,
            sweep_grant,
            byte_limited,
            collection.grant,
            &collection.roots,
            &collection.leases,
            prepared.journal,
        ),
    );
    try std.testing.expectError(
        object_store.Error.ReachabilityMismatch,
        commitV1(
            &store,
            sweep_grant,
            commit_grant,
            collection.grant,
            collection.roots[0 .. collection.roots.len - 1],
            &collection.leases,
            prepared.journal,
        ),
    );
    try std.testing.expectError(
        object_store.Error.LeaseReceiptMismatch,
        commitV1(
            &store,
            sweep_grant,
            commit_grant,
            collection.grant,
            &collection.roots,
            &[_]object_store.LeaseReceiptV1{},
            prepared.journal,
        ),
    );
    var tampered = prepared.journal;
    tampered.staged_bytes += 1;
    try std.testing.expectError(
        Error.InvalidSweepJournal,
        commitV1(
            &store,
            sweep_grant,
            commit_grant,
            collection.grant,
            &collection.roots,
            &collection.leases,
            tampered,
        ),
    );

    const retired_entry = fixture.decoded.entry(.publication_receipt);
    const retired: bundle.BlobRefV1 = .{
        .byte_length = retired_entry.byte_length,
        .sha256 = retired_entry.blob_sha256,
    };
    const permit: object_store.RetiredCommitPermitV1 = .{
        .authority_epoch = commit_grant.authority_epoch,
        .tenant_scope_sha256 = commit_grant.tenant_scope_sha256,
        .bundle_sha256 = commit_grant.bundle_sha256,
        .store_grant_sha256 = commit_grant.store_grant_sha256,
        .expected_snapshot_sha256 = commit_grant.expected_snapshot_sha256,
        .authorization_sha256 = try commitGrantRootV1(commit_grant),
        .max_freed_entries = 2,
        .max_freed_bytes = 128,
    };
    try std.testing.expectError(
        object_store.Error.NonCanonicalRetiredTargets,
        store.commitRetiredV1(permit, &[_]bundle.BlobRefV1{ retired, retired }),
    );
    try std.testing.expectError(
        object_store.Error.RetiredTargetMismatch,
        store.commitRetiredV1(permit, &[_]bundle.BlobRefV1{collection.roots[0]}),
    );
    var partial_set = [_]bundle.BlobRefV1{ retired, collection.roots[0] };
    object_store.sortRootReferencesV1(&partial_set);
    try std.testing.expectError(
        object_store.Error.RetiredTargetMismatch,
        store.commitRetiredV1(permit, &partial_set),
    );
    try std.testing.expectEqualSlices(
        u8,
        &snapshot_before,
        &(try store.auditSnapshotRootV2()),
    );
    try std.testing.expectEqual(allocator_before, fba.end_index);
}

test "sweep journal rejects a valid plan with no collectible entries" {
    var capsule_storage: [capsule.encoded_bytes]u8 = undefined;
    var bundle_storage: [bundle.encoded_bytes]u8 = undefined;
    const fixture = try testBundleFixture(
        &capsule_storage,
        &bundle_storage,
    );
    const store_grant = testStoreGrant(
        try bundle.envelopeRootV1(fixture.bundle_wire),
    );
    var allocator_storage: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_storage);
    var store = try object_store.Store.initV1(
        fba.allocator(),
        store_grant,
        store_grant.authority_epoch,
    );
    defer store.deinit();
    _ = try store.importBundleV1(
        fixture.bundle_wire,
        fixture.bundle_config,
        fixture.capsule_wire,
        fixture.objects,
    );
    var roots: [capsule.object_count]bundle.BlobRefV1 = undefined;
    for (capsule.object_kinds, 0..) |kind, index| {
        const entry = fixture.decoded.entry(kind);
        roots[index] = .{
            .byte_length = entry.byte_length,
            .sha256 = entry.blob_sha256,
        };
    }
    object_store.sortRootReferencesV1(&roots);
    const snapshot = try store.auditSnapshotRootV2();
    const collection_grant: object_store.CollectionGrantV1 = .{
        .authority_epoch = store_grant.authority_epoch,
        .tenant_scope_sha256 = store_grant.tenant_scope_sha256,
        .bundle_sha256 = store_grant.bundle_sha256,
        .store_grant_sha256 = try object_store.grantRootV1(store_grant),
        .expected_snapshot_sha256 = snapshot,
        .max_root_references = 16,
        .max_lease_receipts = 4,
        .max_slot_scans = object_store.default_capacity,
        .max_collectible_entries = 2,
        .max_collectible_bytes = 128,
        .challenge_sha256 = [_]u8{0xe8} ** 32,
    };
    var decisions: [object_store.default_capacity]object_store.CollectionDecisionV1 =
        undefined;
    const plan = try store.planCollectionV1(
        collection_grant,
        &roots,
        &[_]object_store.LeaseReceiptV1{},
        &decisions,
    );
    const sweep_grant = testSweepGrant(
        store_grant,
        snapshot,
        plan.plan_sha256,
    );
    try std.testing.expectError(
        Error.NothingToSweep,
        prepareV1(
            &store,
            sweep_grant,
            collection_grant,
            &roots,
            &[_]object_store.LeaseReceiptV1{},
            .{},
        ),
    );
}

fn testBundleFixture(
    capsule_storage: *[capsule.encoded_bytes]u8,
    bundle_storage: *[bundle.encoded_bytes]u8,
) !TestBundleFixture {
    const objects = testObjects();
    const capsule_config = testCapsuleConfig();
    const capsule_wire = try capsule.encodeV1(
        capsule_config,
        objects,
        capsule_storage,
    );
    const bundle_config: bundle.ConfigV1 = .{
        .tenant_scope_sha256 = [_]u8{0x6d} ** 32,
        .capsule_sha256 = try capsule.envelopeRootV1(capsule_wire),
        .bundle_generation = 0,
        .challenge_sha256 = [_]u8{0xe3} ** 32,
    };
    const bundle_wire = try bundle.encodeV1(
        bundle_config,
        capsule_wire,
        objects,
        bundle_storage,
    );
    return .{
        .objects = objects,
        .capsule_config = capsule_config,
        .capsule_wire = capsule_wire,
        .bundle_config = bundle_config,
        .bundle_wire = bundle_wire,
        .decoded = try bundle.decodeManifestV1(bundle_wire),
    };
}

fn testCollectionFixture(
    store: *object_store.Store,
    fixture: TestBundleFixture,
    store_grant: object_store.GrantV1,
) !TestCollectionFixture {
    return testCollectionFixtureForKind(
        store,
        fixture,
        store_grant,
        .kv_state,
    );
}

fn testCollectionFixtureForKind(
    store: *object_store.Store,
    fixture: TestBundleFixture,
    store_grant: object_store.GrantV1,
    retired_kind: capsule.ObjectKind,
) !TestCollectionFixture {
    const model_entry = fixture.decoded.entry(.model);
    const model: bundle.BlobRefV1 = .{
        .byte_length = model_entry.byte_length,
        .sha256 = model_entry.blob_sha256,
    };
    const lifecycle_grant = testLifecycleGrant(store_grant);
    const lease = try store.acquireLeaseV1(
        model,
        lifecycle_grant,
        [_]u8{0x71} ** 32,
        100,
        120,
    );
    const retired_entry = fixture.decoded.entry(retired_kind);
    try store.retireV1(.{
        .byte_length = retired_entry.byte_length,
        .sha256 = retired_entry.blob_sha256,
    });
    const lane_entry = fixture.decoded.entry(.lane_state);
    try store.quarantineV1(.{
        .byte_length = lane_entry.byte_length,
        .sha256 = lane_entry.blob_sha256,
    }, [_]u8{0x9a} ** 32);

    var roots: [capsule.object_count - 1]bundle.BlobRefV1 = undefined;
    var root_count: usize = 0;
    for (capsule.object_kinds) |kind| {
        if (kind == retired_kind) continue;
        const entry = fixture.decoded.entry(kind);
        roots[root_count] = .{
            .byte_length = entry.byte_length,
            .sha256 = entry.blob_sha256,
        };
        root_count += 1;
    }
    if (root_count != roots.len) return error.RootFixtureMismatch;
    object_store.sortRootReferencesV1(&roots);
    var leases = [_]object_store.LeaseReceiptV1{lease};
    object_store.sortLeaseReceiptsV1(&leases);
    const collection_grant: object_store.CollectionGrantV1 = .{
        .authority_epoch = store_grant.authority_epoch,
        .tenant_scope_sha256 = store_grant.tenant_scope_sha256,
        .bundle_sha256 = store_grant.bundle_sha256,
        .store_grant_sha256 = try object_store.grantRootV1(store_grant),
        .expected_snapshot_sha256 = try store.auditSnapshotRootV2(),
        .max_root_references = 16,
        .max_lease_receipts = 4,
        .max_slot_scans = object_store.default_capacity,
        .max_collectible_entries = 2,
        .max_collectible_bytes = 128,
        .challenge_sha256 = [_]u8{0xe8} ** 32,
    };
    var decisions: [object_store.default_capacity]object_store.CollectionDecisionV1 =
        undefined;
    const receipt = try store.planCollectionV1(
        collection_grant,
        &roots,
        &leases,
        &decisions,
    );
    return .{
        .roots = roots,
        .leases = leases,
        .grant = collection_grant,
        .receipt = receipt,
    };
}

fn testSweepGrant(
    store_grant: object_store.GrantV1,
    snapshot_sha256: Digest,
    plan_sha256: Digest,
) GrantV1 {
    return .{
        .authority_epoch = store_grant.authority_epoch,
        .tenant_scope_sha256 = store_grant.tenant_scope_sha256,
        .bundle_sha256 = store_grant.bundle_sha256,
        .store_grant_sha256 = object_store.grantRootV1(store_grant) catch
            unreachable,
        .expected_snapshot_sha256 = snapshot_sha256,
        .collection_plan_sha256 = plan_sha256,
        .max_staged_entries = 2,
        .max_staged_bytes = 128,
        .challenge_sha256 = [_]u8{0xd4} ** 32,
    };
}

fn testCommitGrant(
    store_grant: object_store.GrantV1,
    sweep_grant: GrantV1,
    prepared: JournalV1,
) CommitGrantV1 {
    return .{
        .authority_epoch = store_grant.authority_epoch,
        .tenant_scope_sha256 = store_grant.tenant_scope_sha256,
        .bundle_sha256 = store_grant.bundle_sha256,
        .store_grant_sha256 = object_store.grantRootV1(store_grant) catch
            unreachable,
        .sweep_grant_sha256 = grantRootV1(sweep_grant) catch unreachable,
        .prepare_sha256 = prepared.prepare_sha256,
        .expected_snapshot_sha256 = prepared.snapshot_sha256,
        .collection_plan_sha256 = prepared.collection_plan_sha256,
        .max_freed_entries = 2,
        .max_freed_bytes = 128,
        .challenge_sha256 = [_]u8{0xd7} ** 32,
    };
}

fn testCapsuleConfig() capsule.ConfigV1 {
    return .{
        .execution_abi = 0x4341_4558_0000_0001,
        .request_epoch = 0x4341_5251_0000_0001,
        .publication_sequence = 5,
        .checkpoint_generation = 0,
        .kv_tokens = 37,
        .output_tokens = 5,
        .challenge_sha256 = [_]u8{0xa8} ** 32,
    };
}

fn testObjects() capsule.ObjectsV1 {
    return .{
        .model = .{ .abi_version = 0x4341_4d4f_0000_0001, .bytes = "shared-static-identity-v1" },
        .tokenizer = .{ .abi_version = 0x4341_544b_0000_0001, .bytes = "shared-static-identity-v1" },
        .execution_plan = .{ .abi_version = 0x4341_504c_0000_0001, .bytes = "plan-v1:cpu:threads=4:strict" },
        .resource_state = .{ .abi_version = 0x4341_5253_0000_0001, .bytes = "resource-v1:bank=17:kv=4096:output=64" },
        .lane_state = .{ .abi_version = 0x4341_4c4e_0000_0001, .bytes = "lane-v1:request=41:service=11" },
        .kv_state = .{ .abi_version = 0x4341_4b56_0000_0001, .bytes = "kv-v1:positions=37:root=bundle" },
        .sampler_state = .{ .abi_version = 0x4341_534d_0000_0001, .bytes = "sampler-v1:rng=01020304:calls=5" },
        .output_state = .{ .abi_version = 0x4341_4f55_0000_0001, .bytes = "output-v1:tokens=901,902,903,904,905" },
        .publication_receipt = .{ .abi_version = 0x4341_5052_0000_0001, .bytes = "publication-v1:sequence=5:commit=bundle" },
    };
}

fn testStoreGrant(bundle_sha256: Digest) object_store.GrantV1 {
    return .{
        .authority_epoch = 11,
        .tenant_scope_sha256 = [_]u8{0x6d} ** 32,
        .bundle_sha256 = bundle_sha256,
        .allowed_operation_mask = object_store.allowed_operations,
        .max_entries = 12,
        .max_object_bytes = 64,
        .max_payload_bytes = 512,
        .max_index_bytes = 12 * object_store.logical_index_entry_bytes,
        .max_references = 16,
        .challenge_sha256 = [_]u8{0xf2} ** 32,
    };
}

fn testLifecycleGrant(
    store_grant: object_store.GrantV1,
) object_store.LifecycleGrantV1 {
    return .{
        .authority_epoch = store_grant.authority_epoch,
        .tenant_scope_sha256 = store_grant.tenant_scope_sha256,
        .bundle_sha256 = store_grant.bundle_sha256,
        .store_grant_sha256 = object_store.grantRootV1(store_grant) catch
            unreachable,
        .allowed_operation_mask = object_store.allowed_lease_operations,
        .max_active_leases = 4,
        .max_lease_span_ticks = 64,
        .challenge_sha256 = [_]u8{0xc4} ** 32,
    };
}
