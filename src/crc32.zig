//! Architecture-aware IEEE CRC-32 used for model-page integrity checks.

const std = @import("std");
const builtin = @import("builtin");

extern fn glacier_crc32_ieee_arm(data: [*]const u8, len: usize) callconv(.c) u32;
extern fn glacier_crc32_ieee_arm_extend(
    previous: u32,
    data: [*]const u8,
    len: usize,
) callconv(.c) u32;

const State = if (builtin.cpu.arch == .aarch64) u32 else std.hash.Crc32;

/// Incremental IEEE CRC-32. On AArch64 each update continues directly from
/// the prior hardware result, which is required for multi-stream runtime-image
/// records without concatenating them in memory.
pub const Hasher = struct {
    state: State,

    pub fn init() Hasher {
        return .{ .state = if (comptime builtin.cpu.arch == .aarch64)
            0
        else
            std.hash.Crc32.init() };
    }

    pub fn update(self: *Hasher, bytes: []const u8) void {
        if (comptime builtin.cpu.arch == .aarch64) {
            self.state = glacier_crc32_ieee_arm_extend(self.state, bytes.ptr, bytes.len);
        } else {
            self.state.update(bytes);
        }
    }

    pub fn final(self: Hasher) u32 {
        return if (comptime builtin.cpu.arch == .aarch64)
            self.state
        else
            self.state.final();
    }
};

pub fn hash(bytes: []const u8) u32 {
    if (comptime builtin.cpu.arch == .aarch64) {
        return glacier_crc32_ieee_arm(bytes.ptr, bytes.len);
    }
    return std.hash.Crc32.hash(bytes);
}

test "accelerated CRC32 matches the portable oracle" {
    const cases = [_][]const u8{
        "",
        "123456789",
        "hello glacier",
        &([_]u8{0xA5} ** 257),
    };
    for (cases) |bytes| {
        try std.testing.expectEqual(std.hash.Crc32.hash(bytes), hash(bytes));
    }

    var storage: [1024 + 8]u8 = undefined;
    var rng = std.Random.DefaultPrng.init(0x474C_4143_4945_52);
    rng.random().bytes(&storage);
    for (0..8) |misalignment| {
        var len: usize = 0;
        while (len <= 1024) : (len += 1) {
            const bytes = storage[misalignment .. misalignment + len];
            try std.testing.expectEqual(std.hash.Crc32.hash(bytes), hash(bytes));
        }
    }

    var split = Hasher.init();
    split.update(storage[3..149]);
    split.update(storage[149..777]);
    split.update(storage[777..]);
    try std.testing.expectEqual(std.hash.Crc32.hash(storage[3..]), split.final());
}
