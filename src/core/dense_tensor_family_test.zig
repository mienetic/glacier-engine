//! Shared focused test root for the retained dense-tensor family.
//!
//! Keeping these imports in one artifact lets reranking, classification, and
//! embedding changes share a single Zig compile while preserving each
//! module's independent tests.

test "dense tensor family modules are included" {
    _ = @import("dense_tensor_reranker.zig");
    _ = @import("dense_tensor_classifier.zig");
    _ = @import("dense_tensor_embedding.zig");
}
