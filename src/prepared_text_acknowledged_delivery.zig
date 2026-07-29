//! Public R1i facade for replay-safe prepared-text delivery.
//!
//! The four layers stay separately reusable:
//! - canonical delivery inputs and acknowledgements;
//! - the descriptor-relative durable POSIX sink;
//! - authority-free acknowledged selector generations; and
//! - lease-pinned restored activation across those generations.

pub const result_sink =
    @import("prepared_text_result_sink.zig");
pub const input_archive =
    @import("prepared_text_input_archive.zig");
pub const result_sink_file =
    @import("prepared_text_result_sink_file.zig");
pub const progress =
    @import("prepared_text_acknowledged_progress.zig");
pub const restore =
    @import("prepared_text_acknowledged_restore.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
