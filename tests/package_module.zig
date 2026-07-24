const std = @import("std");
const glacier = @import("glacier");
const glacier_core = @import("glacier_core");

test "package exports runtime and core modules independently of host tools" {
    try std.testing.expect(@hasDecl(glacier, "core"));
    try std.testing.expect(@hasDecl(glacier, "CpuBackend"));
    try std.testing.expect(
        @hasDecl(glacier, "generated_media_format_conformance"),
    );
    try std.testing.expect(@hasDecl(glacier, "platform_capabilities"));
    try std.testing.expect(@hasDecl(glacier_core, "ResourceBank"));
    try std.testing.expect(@hasDecl(glacier_core, "RuntimeSupportRegistry"));
    try std.testing.expectEqual(
        @as(usize, 8),
        glacier_core.RuntimeSupportRegistry.profiles.len,
    );
    try std.testing.expect(glacier.ResourceBank == glacier_core.ResourceBank);
}

test "runtime module propagates native link requirements" {
    var input = try glacier.core.tensor.fromF32(
        std.testing.allocator,
        &.{ 1, 16 },
        &([_]f32{1} ** 16),
    );
    defer input.deinit();
    var output = try glacier.core.tensor.zerosF32(
        std.testing.allocator,
        &.{ 1, 1 },
    );
    defer output.deinit();
    try glacier.int4_matmul.linearInt4OnTheFly(
        input,
        &([_]u8{0x88} ** 8),
        &.{ 1, 1 },
        &.{},
        output,
        1,
        16,
        8,
    );
    try std.testing.expect(std.math.isFinite(output.asF32()[0]));

    if (glacier.metal_enabled) {
        var backend = glacier.MetalBackend.init(
            "glacier-package-module-link-smoke.missing",
        ) catch return;
        backend.deinit();
    }
}
