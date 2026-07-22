//! D-axis: early-exit router (STUB).
//!
//! Not in the MVP. The interface is sketched here so the rest of the
//! engine can compile against it and so the docs and code stay in sync.
//!
//! See docs/DESIGN.md §2 "D-axis — Depth".

const std = @import("std");

pub const ExitDecision = struct {
    /// True if this token may stop after the current layer.
    can_exit: bool,
    /// Confidence of the decision, [0, 1]. Used for logging/bench only.
    confidence: f32,
};

/// MVP placeholder: never early-exit. Every token goes through every layer.
pub fn route(layer_idx: u32, hidden_entropy: f32) ExitDecision {
    _ = layer_idx;
    _ = hidden_entropy;
    return .{ .can_exit = false, .confidence = 1.0 };
}
