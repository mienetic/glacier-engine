//! Per-token 4-axis scheduler (STUB for MVP).
//!
//! For the MVP the scheduler is a thin shim that consults the static
//! precision profile and feeds (page_id, precision) pairs to the pager.
//! The learned 4-axis policy described in docs/DESIGN.md is future work.

const std = @import("std");
const precision_mod = @import("precision.zig");
const pager_mod = @import("pager.zig");

pub const Precision = precision_mod.Precision;
pub const PrecisionProfile = precision_mod.PrecisionProfile;
pub const Pager = pager_mod.Pager;
pub const PageId = pager_mod.PageId;

/// What the scheduler decides for one layer of one token.
pub const LayerDecision = struct {
    layer_idx: u32,
    required_precision: Precision,
    // D-axis and E-axis fields will land here once implemented.
};

pub const Scheduler = struct {
    profile: *const PrecisionProfile,

    pub fn init(profile: *const PrecisionProfile) Scheduler {
        return .{ .profile = profile };
    }

    /// MVP policy: static precision from the profile, no early-exit,
    /// no expert selection.
    pub fn decide(self: *const Scheduler, layer_idx: u32) LayerDecision {
        const p = if (layer_idx < self.profile.required.len)
            self.profile.required[layer_idx]
        else
            Precision.int4; // safe default
        return .{ .layer_idx = layer_idx, .required_precision = p };
    }

    /// Drive the pager through one layer's pages.
    pub fn ensureLayerResident(
        self: *const Scheduler,
        pager: *Pager,
        layer_pages: []const PageId,
        layer_idx: u32,
    ) !void {
        const dec = self.decide(layer_idx);
        for (layer_pages) |pid| {
            try pager.ensureResident(pid, dec.required_precision);
        }
    }
};
