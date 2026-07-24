//! Compile-time inventory of platform-specific adapters.
//!
//! An available adapter means that Glacier has an implementation selected for
//! the target OS. It does not establish native execution, recovery,
//! accelerator, packaging, or support evidence.

const std = @import("std");
const builtin = @import("builtin");

pub const AdapterAvailabilityV1 = struct {
    /// A bounded POSIX `mmap` or Windows NT section implementation exists.
    read_only_file_mapping_adapter: bool,
    /// The descriptor-relative POSIX locking and `fsync` adapter exists.
    posix_durable_file_adapter: bool,
    /// A POSIX `SIGKILL` or Windows `TerminateProcess` fixture branch exists.
    hard_termination_fixture: bool,
    /// The macOS Metal source adapter exists; build enablement is separate.
    metal_backend_adapter: bool,
};

/// Returns the bounded adapter inventory for an OS at compile time.
pub fn adapterAvailabilityForOsV1(
    comptime os_tag: std.Target.Os.Tag,
) AdapterAvailabilityV1 {
    const posix_files = switch (os_tag) {
        .linux,
        .macos,
        .ios,
        .freebsd,
        .netbsd,
        .dragonfly,
        .openbsd,
        .solaris,
        .illumos,
        => true,
        else => false,
    };

    return .{
        .read_only_file_mapping_adapter = posix_files or os_tag == .windows,
        .posix_durable_file_adapter = posix_files,
        .hard_termination_fixture = posix_files or os_tag == .windows,
        .metal_backend_adapter = os_tag == .macos,
    };
}

pub const current_adapter_availability_v1 =
    adapterAvailabilityForOsV1(builtin.os.tag);

test "adapter inventory is explicit for primary portability targets" {
    const testing = std.testing;

    const macos = adapterAvailabilityForOsV1(.macos);
    try testing.expect(macos.read_only_file_mapping_adapter);
    try testing.expect(macos.posix_durable_file_adapter);
    try testing.expect(macos.hard_termination_fixture);
    try testing.expect(macos.metal_backend_adapter);

    const linux = adapterAvailabilityForOsV1(.linux);
    try testing.expect(linux.read_only_file_mapping_adapter);
    try testing.expect(linux.posix_durable_file_adapter);
    try testing.expect(linux.hard_termination_fixture);
    try testing.expect(!linux.metal_backend_adapter);

    const windows = adapterAvailabilityForOsV1(.windows);
    try testing.expect(windows.read_only_file_mapping_adapter);
    try testing.expect(!windows.posix_durable_file_adapter);
    try testing.expect(windows.hard_termination_fixture);
    try testing.expect(!windows.metal_backend_adapter);

    const freebsd = adapterAvailabilityForOsV1(.freebsd);
    try testing.expect(freebsd.read_only_file_mapping_adapter);
    try testing.expect(freebsd.posix_durable_file_adapter);
    try testing.expect(freebsd.hard_termination_fixture);
    try testing.expect(!freebsd.metal_backend_adapter);

    const wasi = adapterAvailabilityForOsV1(.wasi);
    try testing.expect(!wasi.read_only_file_mapping_adapter);
    try testing.expect(!wasi.posix_durable_file_adapter);
    try testing.expect(!wasi.hard_termination_fixture);
    try testing.expect(!wasi.metal_backend_adapter);
}

test "current adapter inventory is derived from the compile target" {
    try std.testing.expectEqual(
        adapterAvailabilityForOsV1(builtin.os.tag),
        current_adapter_availability_v1,
    );
}
