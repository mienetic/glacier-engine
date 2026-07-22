const std = @import("std");
const builtin = @import("builtin");
const progressive = @import("progressive_int4");

const testing = std.testing;

const p1_values = [_]i8{
    -4, -4, -4, -4, -4, -4, -4, -4,
    4,  4,  4,  4,  4,  4,  4,  4,
};

const p2_values = [_]i8{
    -6, -6, -6, -6,
    -2, -2, -2, -2,
    2,  2,  2,  2,
    6,  6,  6,  6,
};

const p4_values = [_]i8{
    -7, -6, -5, -4, -3, -2, -1, 0,
    1,  2,  3,  4,  5,  6,  7,  8,
};

test "1+1+2 decomposition reconstructs all sixteen INT4 nibbles exactly" {
    for (0..16) |raw| {
        const nibble: u8 = @intCast(raw);
        const components = try progressive.decomposeNibble(nibble);

        try testing.expectEqual(p1_values[raw], components.value(.p1));
        try testing.expectEqual(p2_values[raw], components.value(.p2));
        try testing.expectEqual(p4_values[raw], components.value(.p4));
        try testing.expectEqual(p4_values[raw], @as(i8, @intCast(raw)) - 7);

        try testing.expect(components.coarse == -4 or components.coarse == 4);
        try testing.expect(components.middle == -2 or components.middle == 2);
        try testing.expect(components.fine >= -1 and components.fine <= 2);

        try testing.expectEqual(p1_values[raw], try progressive.decodeNibble(nibble, .p1));
        try testing.expectEqual(p2_values[raw], try progressive.decodeNibble(nibble, .p2));
        try testing.expectEqual(p4_values[raw], try progressive.decodeNibble(nibble, .p4));
    }

    try testing.expectError(error.InvalidNibble, progressive.decomposeNibble(16));
    try testing.expectError(error.InvalidNibble, progressive.decodeNibble(255, .p4));
}

test "allocation-backed planes have exact geometry and reconstruct every nibble" {
    var packed_weights: [8]u8 = undefined;
    for (0..16) |index| {
        writeNibble(&packed_weights, index, @intCast(index));
    }

    var planes = try progressive.splitPacked(testing.allocator, &packed_weights, 16);
    defer planes.deinit();

    try testing.expectEqual(@as(usize, 16), planes.num_weights);
    try testing.expectEqual(@as(usize, 2), planes.coarse1.len);
    try testing.expectEqual(@as(usize, 2), planes.middle1.len);
    try testing.expectEqual(@as(usize, 4), planes.fine2.len);
    try testing.expectEqualSlices(u8, &.{ 0x00, 0xff }, planes.coarse1);
    try testing.expectEqualSlices(u8, &.{ 0xf0, 0xf0 }, planes.middle1);
    try testing.expectEqualSlices(u8, &.{ 0xe4, 0xe4, 0xe4, 0xe4 }, planes.fine2);

    const p4_view = planes.p4View();
    for (0..16) |raw| {
        try testing.expectEqual(@as(u8, @intCast(raw)), try planes.nibbleAt(raw));
        try testing.expectEqual(p4_values[raw], try planes.p4At(raw));
        try testing.expectEqual(@as(u8, @intCast(raw)), try progressive.reconstructNibble(p4_view, raw));
        try testing.expectEqual(p4_values[raw], try progressive.reconstructP4(p4_view, raw));
    }
    try testing.expectError(error.WeightIndexOutOfBounds, planes.nibbleAt(16));
    try testing.expectError(error.WeightIndexOutOfBounds, planes.p4At(16));
}

test "plane byte lengths are exact for tails and overflow-safe at usize maximum" {
    const cases = [_]struct { n: usize, coarse: usize, middle: usize, fine: usize }{
        .{ .n = 0, .coarse = 0, .middle = 0, .fine = 0 },
        .{ .n = 1, .coarse = 1, .middle = 1, .fine = 1 },
        .{ .n = 4, .coarse = 1, .middle = 1, .fine = 1 },
        .{ .n = 5, .coarse = 1, .middle = 1, .fine = 2 },
        .{ .n = 8, .coarse = 1, .middle = 1, .fine = 2 },
        .{ .n = 9, .coarse = 2, .middle = 2, .fine = 3 },
    };
    for (cases) |case| {
        const lengths = progressive.planeByteLengths(case.n);
        try testing.expectEqual(case.coarse, lengths.coarse1);
        try testing.expectEqual(case.middle, lengths.middle1);
        try testing.expectEqual(case.fine, lengths.fine2);
        try testing.expectEqual(case.coarse + case.middle + case.fine, try lengths.total());
    }

    const maximum = std.math.maxInt(usize);
    const lengths = progressive.planeByteLengths(maximum);
    try testing.expectEqual(maximum / 8 + 1, lengths.coarse1);
    try testing.expectEqual(maximum / 8 + 1, lengths.middle1);
    try testing.expectEqual(maximum / 4 + 1, lengths.fine2);
    try testing.expect(try lengths.total() <= maximum);
    try testing.expectError(error.SizeOverflow, (progressive.PlaneByteLengths{
        .coarse1 = maximum,
        .middle1 = 1,
        .fine2 = 0,
    }).total());
}

test "P4 dot is exactly equivalent to legacy full INT4 for random groups and odd tails" {
    var prng = std.Random.DefaultPrng.init(0x676c_6163_6965_7234);
    const random = prng.random();

    const lengths = [_]usize{ 1, 2, 3, 5, 7, 8, 9, 15, 17, 31, 33, 63, 65, 127 };
    const group_sizes = [_]usize{ 1, 2, 3, 4, 5, 7, 8, 16, 31, 64, 129 };

    var activations: [127]f32 = undefined;
    var packed_bytes: [64]u8 = undefined;
    var scales: [127]f32 = undefined;

    for (lengths) |len| {
        for (group_sizes) |group_size| {
            const packed_len = len / 2 + len % 2;
            const scale_len = len / group_size + @intFromBool(len % group_size != 0);
            @memset(packed_bytes[0..packed_len], 0);

            for (activations[0..len]) |*activation| {
                activation.* = random.float(f32) * 4.0 - 2.0;
            }
            for (scales[0..scale_len]) |*scale| {
                scale.* = random.float(f32) * 0.5 + 0.001;
            }
            for (0..len) |index| {
                writeNibble(packed_bytes[0..packed_len], index, random.int(u8) & 0x0f);
            }

            // The padding nibble of an odd logical stream is deliberately
            // non-zero. It must never participate in any tier.
            if (len % 2 != 0) packed_bytes[packed_len - 1] |= 0xf0;

            const all = try progressive.dotAll(
                activations[0..len],
                packed_bytes[0..packed_len],
                scales[0..scale_len],
                group_size,
            );
            var planes = try progressive.PackedPlanes.init(
                testing.allocator,
                packed_bytes[0..packed_len],
                len,
            );
            defer planes.deinit();

            try testing.expectEqual(
                referenceDot(activations[0..len], packed_bytes[0..packed_len], scales[0..scale_len], group_size, .p1),
                all.p1,
            );
            try testing.expectEqual(
                referenceDot(activations[0..len], packed_bytes[0..packed_len], scales[0..scale_len], group_size, .p2),
                all.p2,
            );
            try testing.expectEqual(
                legacyFullInt4Dot(activations[0..len], packed_bytes[0..packed_len], scales[0..scale_len], group_size),
                all.p4,
            );

            try testing.expectEqual(all.p1, try progressive.dotP1(
                activations[0..len],
                packed_bytes[0..packed_len],
                scales[0..scale_len],
                group_size,
            ));
            try testing.expectEqual(all.p2, try progressive.dotP2(
                activations[0..len],
                packed_bytes[0..packed_len],
                scales[0..scale_len],
                group_size,
            ));
            try testing.expectEqual(all.p4, try progressive.dotP4(
                activations[0..len],
                packed_bytes[0..packed_len],
                scales[0..scale_len],
                group_size,
            ));

            // The tier-tagged views contain only the planes that tier is
            // permitted to read.  Compare the real split representation to
            // the pre-existing packed oracle with identical float order.
            try testing.expectEqual(all.p1, try progressive.dotPlanesTier(
                activations[0..len],
                planes.view(.p1),
                scales[0..scale_len],
                group_size,
            ));
            try testing.expectEqual(all.p2, try progressive.dotPlanesTier(
                activations[0..len],
                planes.view(.p2),
                scales[0..scale_len],
                group_size,
            ));
            try testing.expectEqual(all.p4, try progressive.dotPlanesTier(
                activations[0..len],
                planes.view(.p4),
                scales[0..scale_len],
                group_size,
            ));
        }
    }
}

test "AArch64 split-plane kernels match scalar tiers across blocks and tails" {
    if (builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    var prng = std.Random.DefaultPrng.init(0x7072_6973_6d2d_6e65);
    const random = prng.random();
    const lengths = [_]usize{ 8, 9, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127, 128, 129, 1024 };
    const group_sizes = [_]usize{ 8, 16, 24, 32, 64 };

    var activations: [1024]f32 = undefined;
    var packed_bytes: [512]u8 = undefined;
    var scales: [128]f32 = undefined;

    for (lengths) |len| {
        for (group_sizes) |group_size| {
            const packed_len = len / 2 + len % 2;
            const scale_len = len / group_size + @intFromBool(len % group_size != 0);
            @memset(packed_bytes[0..packed_len], 0);
            for (activations[0..len]) |*activation| {
                activation.* = random.float(f32) * 4.0 - 2.0;
            }
            for (scales[0..scale_len]) |*scale| {
                scale.* = random.float(f32) * 0.5 + 0.001;
            }
            for (0..len) |index| {
                writeNibble(packed_bytes[0..packed_len], index, random.int(u8) & 0x0f);
            }

            var planes = try progressive.PackedPlanes.init(
                testing.allocator,
                packed_bytes[0..packed_len],
                len,
            );
            defer planes.deinit();

            try testing.expect(progressive.canUseNeonPlaneKernel(len, group_size));
            inline for (std.meta.tags(progressive.Tier)) |tier| {
                const scalar = try progressive.dotPlanesTier(
                    activations[0..len],
                    planes.view(tier),
                    scales[0..scale_len],
                    group_size,
                );
                const accelerated = try progressive.dotPlanesTierCpu(
                    activations[0..len],
                    planes.view(tier),
                    scales[0..scale_len],
                    group_size,
                );
                const tolerance = @max(@as(f32, 0.0001), @abs(scalar) * 0.00002);
                try testing.expectApproxEqAbs(scalar, accelerated, tolerance);
            }
        }
    }
}

test "AArch64 P4 SIMD reconstructs every signed INT4 value exactly" {
    if (builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    var packed_weights: [8]u8 = undefined;
    for (0..16) |index| writeNibble(&packed_weights, index, @intCast(index));
    var planes = try progressive.PackedPlanes.init(testing.allocator, &packed_weights, 16);
    defer planes.deinit();

    var activations = [_]f32{0} ** 16;
    const scales = [_]f32{ 1, 1 };
    for (0..16) |index| {
        @memset(&activations, 0);
        activations[index] = 1;
        try testing.expectEqual(
            @as(f32, @floatFromInt(p1_values[index])),
            try progressive.dotPlanesTierCpu(
                &activations,
                planes.view(.p1),
                &scales,
                8,
            ),
        );
        try testing.expectEqual(
            @as(f32, @floatFromInt(p2_values[index])),
            try progressive.dotPlanesTierCpu(
                &activations,
                planes.view(.p2),
                &scales,
                8,
            ),
        );
        try testing.expectEqual(
            @as(f32, @floatFromInt(p4_values[index])),
            try progressive.dotPlanesTierCpu(
                &activations,
                planes.view(.p4),
                &scales,
                8,
            ),
        );
    }
}

test "CPU split-plane API preserves scalar fallback and validation" {
    const activations = [_]f32{ 0.25, -1.5, 2.0, 0.75, -0.125 };
    const scales = [_]f32{ 0.5, 0.125 };
    const packed_weights = [_]u8{ 0x30, 0xa5, 0x02 };
    var planes = try progressive.PackedPlanes.init(testing.allocator, &packed_weights, 5);
    defer planes.deinit();

    try testing.expect(!progressive.canUseNeonPlaneKernel(5, 3));
    inline for (std.meta.tags(progressive.Tier)) |tier| {
        try testing.expectEqual(
            try progressive.dotPlanesTier(&activations, planes.view(tier), &scales, 3),
            try progressive.dotPlanesTierCpu(&activations, planes.view(tier), &scales, 3),
        );
    }
    try testing.expectError(
        error.InvalidGroupSize,
        progressive.dotPlanesTierCpu(&activations, planes.view(.p1), &scales, 0),
    );
    try testing.expectError(
        error.WeightLengthMismatch,
        progressive.dotPlanesTierCpu(activations[0..4], planes.view(.p1), &scales, 3),
    );
}

test "tier views expose only required planes and ignore odd-tail padding" {
    const activations = [_]f32{ 0.25, -1.5, 2.0, 0.75, -0.125 };
    const scales = [_]f32{ 0.5, 0.125, 0.75 };
    const low_padding = [_]u8{ 0x30, 0xa5, 0x02 };
    const high_padding = [_]u8{ 0x30, 0xa5, 0xf2 };

    var low_planes = try progressive.PackedPlanes.init(testing.allocator, &low_padding, 5);
    defer low_planes.deinit();
    var high_planes = try progressive.PackedPlanes.init(testing.allocator, &high_padding, 5);
    defer high_planes.deinit();

    try testing.expectEqualSlices(u8, low_planes.coarse1, high_planes.coarse1);
    try testing.expectEqualSlices(u8, low_planes.middle1, high_planes.middle1);
    try testing.expectEqualSlices(u8, low_planes.fine2, high_planes.fine2);

    // These values can be built without providing inaccessible planes at all.
    const p1_only: progressive.PlaneSlices = .{ .p1 = .{
        .num_weights = 5,
        .coarse1 = low_planes.coarse1,
    } };
    const p2_only: progressive.PlaneSlices = .{ .p2 = .{
        .num_weights = 5,
        .coarse1 = low_planes.coarse1,
        .middle1 = low_planes.middle1,
    } };
    try testing.expectEqual(
        try progressive.dotP1(&activations, &low_padding, &scales, 2),
        try progressive.dotPlanesTier(&activations, p1_only, &scales, 2),
    );
    try testing.expectEqual(
        try progressive.dotP2(&activations, &low_padding, &scales, 2),
        try progressive.dotPlanesTier(&activations, p2_only, &scales, 2),
    );

    inline for (std.meta.tags(progressive.Tier)) |tier| {
        const low = try progressive.dotPlanesTier(&activations, low_planes.view(tier), &scales, 2);
        const high = try progressive.dotPlanesTier(&activations, high_planes.view(tier), &scales, 2);
        try testing.expectEqual(low, high);
    }
}

test "odd-tail padding is ignored at every progressive tier" {
    const activations = [_]f32{ 0.25, -1.5, 2.0 };
    const scales = [_]f32{ 0.5, 0.125 };
    const low_padding = [_]u8{ 0x30, 0x05 };
    const high_padding = [_]u8{ 0x30, 0xf5 };

    inline for (std.meta.tags(progressive.Tier)) |tier| {
        const low = try progressive.dotTier(&activations, &low_padding, &scales, 2, tier);
        const high = try progressive.dotTier(&activations, &high_padding, &scales, 2, tier);
        try testing.expectEqual(low, high);
    }
}

test "scalar dot rejects every malformed packed or scale length" {
    const activations = [_]f32{ 1.0, -2.0, 3.0 };
    const packed_bytes = [_]u8{ 0x70, 0x0f };
    const packed_extra = [_]u8{ 0x70, 0x0f, 0xaa };
    const scales = [_]f32{ 0.25, 0.5 };
    const scales_extra = [_]f32{ 0.25, 0.5, 1.0 };

    try testing.expectError(
        error.InvalidGroupSize,
        progressive.dotP4(&activations, &packed_bytes, &scales, 0),
    );
    try testing.expectError(
        error.PackedLengthMismatch,
        progressive.dotP4(&activations, packed_bytes[0..1], &scales, 2),
    );
    try testing.expectError(
        error.PackedLengthMismatch,
        progressive.dotP4(&activations, &packed_extra, &scales, 2),
    );
    try testing.expectError(
        error.ScaleLengthMismatch,
        progressive.dotP4(&activations, &packed_bytes, scales[0..1], 2),
    );
    try testing.expectError(
        error.ScaleLengthMismatch,
        progressive.dotP4(&activations, &packed_bytes, &scales_extra, 2),
    );

    try testing.expectEqual(@as(f32, 0), try progressive.dotP4(&.{}, &.{}, &.{}, 1));
    try testing.expectError(
        error.PackedLengthMismatch,
        progressive.dotP4(&.{}, &.{0}, &.{}, 1),
    );
    try testing.expectError(
        error.ScaleLengthMismatch,
        progressive.dotP4(&.{}, &.{}, &.{1.0}, 1),
    );
}

test "split-plane dot rejects malformed required geometry and scale groups" {
    const activations = [_]f32{ 1.0, -2.0, 3.0 };
    const activations_short = activations[0..2];
    const scales = [_]f32{ 0.25, 0.5 };
    const scales_extra = [_]f32{ 0.25, 0.5, 1.0 };
    const coarse = [_]u8{0x05};
    const coarse_extra = [_]u8{ 0x05, 0xff };
    const middle = [_]u8{0x03};
    const middle_extra = [_]u8{ 0x03, 0xff };
    const fine = [_]u8{0x39};
    const fine_extra = [_]u8{ 0x39, 0xff };

    const valid_p1: progressive.PlaneSlices = .{ .p1 = .{
        .num_weights = 3,
        .coarse1 = &coarse,
    } };
    const valid_p2: progressive.PlaneSlices = .{ .p2 = .{
        .num_weights = 3,
        .coarse1 = &coarse,
        .middle1 = &middle,
    } };
    const valid_p4: progressive.PlaneSlices = .{ .p4 = .{
        .num_weights = 3,
        .coarse1 = &coarse,
        .middle1 = &middle,
        .fine2 = &fine,
    } };

    try testing.expectError(
        error.InvalidGroupSize,
        progressive.dotPlanesTier(&activations, valid_p1, &scales, 0),
    );
    try testing.expectError(
        error.WeightLengthMismatch,
        progressive.dotPlanesTier(activations_short, valid_p1, &scales, 2),
    );
    try testing.expectError(
        error.ScaleLengthMismatch,
        progressive.dotPlanesTier(&activations, valid_p1, scales[0..1], 2),
    );
    try testing.expectError(
        error.ScaleLengthMismatch,
        progressive.dotPlanesTier(&activations, valid_p1, &scales_extra, 2),
    );

    const p1_short: progressive.PlaneSlices = .{ .p1 = .{
        .num_weights = 3,
        .coarse1 = &.{},
    } };
    const p1_long: progressive.PlaneSlices = .{ .p1 = .{
        .num_weights = 3,
        .coarse1 = &coarse_extra,
    } };
    try testing.expectError(
        error.CoarseLengthMismatch,
        progressive.dotPlanesTier(&activations, p1_short, &scales, 2),
    );
    try testing.expectError(
        error.CoarseLengthMismatch,
        progressive.dotPlanesTier(&activations, p1_long, &scales, 2),
    );

    const p2_short: progressive.PlaneSlices = .{ .p2 = .{
        .num_weights = 3,
        .coarse1 = &coarse,
        .middle1 = &.{},
    } };
    const p2_long: progressive.PlaneSlices = .{ .p2 = .{
        .num_weights = 3,
        .coarse1 = &coarse,
        .middle1 = &middle_extra,
    } };
    try testing.expectError(
        error.MiddleLengthMismatch,
        progressive.dotPlanesTier(&activations, p2_short, &scales, 2),
    );
    try testing.expectError(
        error.MiddleLengthMismatch,
        progressive.dotPlanesTier(&activations, p2_long, &scales, 2),
    );

    const p4_short: progressive.PlaneSlices = .{ .p4 = .{
        .num_weights = 3,
        .coarse1 = &coarse,
        .middle1 = &middle,
        .fine2 = &.{},
    } };
    const p4_long: progressive.PlaneSlices = .{ .p4 = .{
        .num_weights = 3,
        .coarse1 = &coarse,
        .middle1 = &middle,
        .fine2 = &fine_extra,
    } };
    try testing.expectError(
        error.FineLengthMismatch,
        progressive.dotPlanesTier(&activations, p4_short, &scales, 2),
    );
    try testing.expectError(
        error.FineLengthMismatch,
        progressive.dotPlanesTier(&activations, p4_long, &scales, 2),
    );

    // A malformed P4 view is rejected before index access as well.
    try testing.expectError(
        error.FineLengthMismatch,
        progressive.reconstructNibble(p4_short.p4, 0),
    );
    try testing.expectEqual(
        @as(f32, 0),
        try progressive.dotPlanesTier(&.{}, .{ .p1 = .{
            .num_weights = 0,
            .coarse1 = &.{},
        } }, &.{}, 1),
    );

    _ = valid_p2;
    _ = valid_p4;
}

test "split rejects packed geometry and cleans every allocation failure path" {
    const packed_weights = [_]u8{ 0x10, 0x32, 0x54, 0x76, 0x08 };
    try testing.expectError(
        error.PackedLengthMismatch,
        progressive.PackedPlanes.init(testing.allocator, packed_weights[0..4], 9),
    );
    const packed_extra = packed_weights ++ [_]u8{0xff};
    try testing.expectError(
        error.PackedLengthMismatch,
        progressive.PackedPlanes.init(testing.allocator, &packed_extra, 9),
    );

    try testing.checkAllAllocationFailures(testing.allocator, splitAllocationProbe, .{});
}

test "rows4 K16 production geometry commits exact independent P2 and P4 extents" {
    const g8 = try progressive.rows4K16Geometry(12, 80, 8);
    const g8_again = try progressive.rows4K16Geometry(12, 80, 8);
    const g16 = try progressive.rows4K16Geometry(12, 80, 16);

    try testing.expectEqual(progressive.rows4_k16_progressive_abi, g8.abi);
    try testing.expectEqual(
        progressive.Rows4K16PlaneLayout.physical_1_1_2,
        g8.layout,
    );
    try testing.expectEqual(@as(usize, 960), g8.extents.num_weights);
    try testing.expectEqual(@as(usize, 480), g8.extents.packed_p4);
    try testing.expectEqual(@as(usize, 120), g8.extents.coarse1);
    try testing.expectEqual(@as(usize, 120), g8.extents.middle1);
    try testing.expectEqual(@as(usize, 240), g8.extents.fine2);
    try testing.expectEqual(@as(usize, 240), g8.extents.p2_planes);
    try testing.expectEqual(@as(usize, 480), g8.extents.p4_planes);
    try testing.expectEqual(@as(u64, 0x9ec3_b8ea_f714_efdc), g8.geometry_commitment);
    try testing.expectEqual(g8.geometry_commitment, g8_again.geometry_commitment);
    try testing.expect(g8.geometry_commitment != g16.geometry_commitment);
    try progressive.validateRows4K16Geometry(g8);

    // These compile-time field checks lock the structural bandwidth contract.
    try testing.expect(!@hasField(progressive.Rows4K16P2View, "fine2"));
    try testing.expect(@hasField(progressive.Rows4K16P4View, "fine2"));
    try testing.expect(!@hasField(progressive.Rows4K16Progressive, "packed_bytes"));

    var malformed = g8;
    malformed.abi ^= 1;
    try testing.expectError(
        error.AbiMismatch,
        progressive.validateRows4K16Geometry(malformed),
    );
    malformed = g8;
    malformed.extents.fine2 -= 1;
    try testing.expectError(
        error.GeometryMismatch,
        progressive.validateRows4K16Geometry(malformed),
    );
    malformed = g8;
    malformed.geometry_commitment ^= 1;
    try testing.expectError(
        error.GeometryCommitmentMismatch,
        progressive.validateRows4K16Geometry(malformed),
    );

    try testing.expectError(
        error.InvalidRows4Geometry,
        progressive.rows4K16Geometry(2, 80, 8),
    );
    try testing.expectError(
        error.InvalidRows4Geometry,
        progressive.rows4K16Geometry(4, 72, 8),
    );
    try testing.expectError(
        error.UnsupportedGroupSize,
        progressive.rows4K16Geometry(4, 80, 4),
    );
    const maximum_rows = std.math.maxInt(usize) -
        (std.math.maxInt(usize) % 4);
    try testing.expectError(
        error.SizeOverflow,
        progressive.rows4K16Geometry(maximum_rows, 16, 8),
    );
}

test "rows4 K16 split pins physical little-lane plane encoding" {
    var packed_bytes = [_]u8{0x00} ** 32;
    for (0..64) |physical_index| {
        writeNibble(
            &packed_bytes,
            physical_index,
            @intCast(physical_index % 16),
        );
    }
    var split = try progressive.Rows4K16Progressive.init(
        testing.allocator,
        .{
            .packed_bytes = &packed_bytes,
            .out_f = 4,
            .in_f = 16,
            .group_size = 8,
        },
    );
    defer split.deinit();

    try testing.expectEqualSlices(
        u8,
        &([_]u8{ 0x00, 0xff } ** 4),
        split.coarse1,
    );
    try testing.expectEqualSlices(u8, &([_]u8{0xf0} ** 8), split.middle1);
    try testing.expectEqualSlices(u8, &([_]u8{0xe4} ** 16), split.fine2);
}

test "rows4 K16 P4 reconstructs random g8 and g16 streams byte exactly" {
    var prng = std.Random.DefaultPrng.init(0x7072_6973_6d2d_7034);
    const random = prng.random();
    const group_sizes = [_]u32{ 8, 16 };
    const widths = [_]usize{ 16, 64, 80, 128 };
    const heights = [_]usize{ 4, 8, 12 };

    for (group_sizes) |group_size| {
        for (widths) |in_f| {
            for (heights) |out_f| {
                const num_weights = out_f * in_f;
                const packed_bytes = try testing.allocator.alloc(u8, num_weights / 2);
                defer testing.allocator.free(packed_bytes);
                random.bytes(packed_bytes);

                var split = try progressive.Rows4K16Progressive.init(
                    testing.allocator,
                    .{
                        .packed_bytes = packed_bytes,
                        .out_f = out_f,
                        .in_f = in_f,
                        .group_size = group_size,
                    },
                );
                defer split.deinit();

                const p2 = split.p2View();
                const p4 = split.p4View();
                try p2.validate();
                try p4.validate();
                switch (split.view(.p2)) {
                    .p2 => |view| try view.validate(),
                    .p4 => return error.TestUnexpectedResult,
                }
                switch (split.view(.p4)) {
                    .p2 => return error.TestUnexpectedResult,
                    .p4 => |view| try view.validate(),
                }

                const reconstructed = try testing.allocator.alloc(u8, packed_bytes.len);
                defer testing.allocator.free(reconstructed);
                try split.writePackedP4(reconstructed);
                try testing.expectEqualSlices(u8, packed_bytes, reconstructed);

                for (0..num_weights) |physical_index| {
                    const nibble = readNibble(packed_bytes, physical_index);
                    try testing.expectEqual(
                        nibble,
                        try split.p4NibbleAt(physical_index),
                    );
                    const expected_p2: i8 =
                        (if (nibble & 0x08 == 0) @as(i8, -4) else @as(i8, 4)) +
                        (if (nibble & 0x04 == 0) @as(i8, -2) else @as(i8, 2));
                    try testing.expectEqual(
                        expected_p2,
                        try split.p2ValueAt(physical_index),
                    );
                }

                for (0..out_f) |row| {
                    for (0..in_f) |col| {
                        const physical_index = referenceRows4K16Index(
                            row,
                            col,
                            in_f,
                        );
                        try testing.expectEqual(
                            physical_index,
                            try progressive.rows4K16PhysicalIndex(
                                split.geometry,
                                row,
                                col,
                            ),
                        );
                        try testing.expectEqual(
                            readNibble(packed_bytes, physical_index),
                            try split.logicalP4NibbleAt(row, col),
                        );
                    }
                }
                try testing.expectError(
                    error.WeightIndexOutOfBounds,
                    split.p4NibbleAt(num_weights),
                );
                try testing.expectError(
                    error.WeightIndexOutOfBounds,
                    split.logicalP4NibbleAt(out_f, 0),
                );
            }
        }
    }
}

test "rows4 K16 pack validates every exact length and overflow before writes" {
    var packed_bytes = [_]u8{0x93} ** 33;
    var coarse = [_]u8{0xa1} ** 9;
    var middle = [_]u8{0xb2} ** 9;
    var fine = [_]u8{0xc3} ** 17;
    const packed_snapshot = packed_bytes;
    const coarse_snapshot = coarse;
    const middle_snapshot = middle;
    const fine_snapshot = fine;

    try testing.expectError(
        error.PackedLengthMismatch,
        progressive.packRows4K16Into(
            .{ .packed_bytes = packed_bytes[0..31], .out_f = 4, .in_f = 16, .group_size = 8 },
            coarse[0..8],
            middle[0..8],
            fine[0..16],
        ),
    );
    try testing.expectError(
        error.PackedLengthMismatch,
        progressive.packRows4K16Into(
            .{ .packed_bytes = &packed_bytes, .out_f = 4, .in_f = 16, .group_size = 8 },
            coarse[0..8],
            middle[0..8],
            fine[0..16],
        ),
    );
    try testing.expectError(
        error.CoarseLengthMismatch,
        progressive.packRows4K16Into(
            .{ .packed_bytes = packed_bytes[0..32], .out_f = 4, .in_f = 16, .group_size = 8 },
            coarse[0..7],
            middle[0..8],
            fine[0..16],
        ),
    );
    try testing.expectError(
        error.CoarseLengthMismatch,
        progressive.packRows4K16Into(
            .{ .packed_bytes = packed_bytes[0..32], .out_f = 4, .in_f = 16, .group_size = 8 },
            &coarse,
            middle[0..8],
            fine[0..16],
        ),
    );
    try testing.expectError(
        error.MiddleLengthMismatch,
        progressive.packRows4K16Into(
            .{ .packed_bytes = packed_bytes[0..32], .out_f = 4, .in_f = 16, .group_size = 8 },
            coarse[0..8],
            middle[0..7],
            fine[0..16],
        ),
    );
    try testing.expectError(
        error.MiddleLengthMismatch,
        progressive.packRows4K16Into(
            .{ .packed_bytes = packed_bytes[0..32], .out_f = 4, .in_f = 16, .group_size = 8 },
            coarse[0..8],
            &middle,
            fine[0..16],
        ),
    );
    try testing.expectError(
        error.FineLengthMismatch,
        progressive.packRows4K16Into(
            .{ .packed_bytes = packed_bytes[0..32], .out_f = 4, .in_f = 16, .group_size = 8 },
            coarse[0..8],
            middle[0..8],
            fine[0..15],
        ),
    );
    try testing.expectError(
        error.FineLengthMismatch,
        progressive.packRows4K16Into(
            .{ .packed_bytes = packed_bytes[0..32], .out_f = 4, .in_f = 16, .group_size = 8 },
            coarse[0..8],
            middle[0..8],
            &fine,
        ),
    );
    try testing.expectError(
        error.UnsupportedGroupSize,
        progressive.packRows4K16Into(
            .{ .packed_bytes = packed_bytes[0..32], .out_f = 4, .in_f = 16, .group_size = 4 },
            coarse[0..8],
            middle[0..8],
            fine[0..16],
        ),
    );
    const maximum_rows = std.math.maxInt(usize) -
        (std.math.maxInt(usize) % 4);
    try testing.expectError(
        error.SizeOverflow,
        progressive.packRows4K16Into(
            .{ .packed_bytes = &packed_bytes, .out_f = maximum_rows, .in_f = 16, .group_size = 8 },
            coarse[0..8],
            middle[0..8],
            fine[0..16],
        ),
    );

    try testing.expectEqualSlices(u8, &packed_snapshot, &packed_bytes);
    try testing.expectEqualSlices(u8, &coarse_snapshot, &coarse);
    try testing.expectEqualSlices(u8, &middle_snapshot, &middle);
    try testing.expectEqualSlices(u8, &fine_snapshot, &fine);
}

test "rows4 K16 pack rejects all buffer aliases without writes" {
    const alias_cases = [_]Rows4AliasCase{
        .source_coarse,
        .source_middle,
        .source_fine,
        .coarse_middle,
        .coarse_fine,
        .middle_fine,
    };
    for (alias_cases) |alias_case| {
        try expectRows4PackAliasNoWrite(alias_case);
    }

    // Exact adjacency is legal and proves the overlap check is half-open.
    var adjacent = [_]u8{0x00} ** 64;
    for (adjacent[0..32], 0..) |*byte, index| {
        byte.* = @truncate(index * 37 + 11);
    }
    const source_snapshot: [32]u8 = adjacent[0..32].*;
    const geometry = try progressive.packRows4K16Into(
        .{
            .packed_bytes = adjacent[0..32],
            .out_f = 4,
            .in_f = 16,
            .group_size = 8,
        },
        adjacent[32..40],
        adjacent[40..48],
        adjacent[48..64],
    );
    const view: progressive.Rows4K16P4View = .{
        .geometry = geometry,
        .coarse1 = adjacent[32..40],
        .middle1 = adjacent[40..48],
        .fine2 = adjacent[48..64],
    };
    var reconstructed: [32]u8 = undefined;
    try progressive.writeRows4K16PackedP4(view, &reconstructed);
    try testing.expectEqualSlices(u8, &source_snapshot, &reconstructed);
}

test "rows4 K16 P4 writer validates malformed views and aliases before writes" {
    var packed_bytes = [_]u8{0x5a} ** 32;
    var plane_backing = [_]u8{0xd4} ** 64;
    const geometry = try progressive.packRows4K16Into(
        .{ .packed_bytes = &packed_bytes, .out_f = 4, .in_f = 16, .group_size = 16 },
        plane_backing[0..8],
        plane_backing[8..16],
        plane_backing[16..32],
    );
    const view: progressive.Rows4K16P4View = .{
        .geometry = geometry,
        .coarse1 = plane_backing[0..8],
        .middle1 = plane_backing[8..16],
        .fine2 = plane_backing[16..32],
    };

    var destination = [_]u8{0xe7} ** 33;
    const destination_snapshot = destination;
    try testing.expectError(
        error.DestinationLengthMismatch,
        progressive.writeRows4K16PackedP4(view, destination[0..31]),
    );
    try testing.expectError(
        error.DestinationLengthMismatch,
        progressive.writeRows4K16PackedP4(view, &destination),
    );

    var malformed = view;
    malformed.fine2 = plane_backing[16..31];
    try testing.expectError(
        error.FineLengthMismatch,
        progressive.writeRows4K16PackedP4(malformed, destination[0..32]),
    );
    malformed = view;
    malformed.geometry.geometry_commitment ^= 1;
    try testing.expectError(
        error.GeometryCommitmentMismatch,
        progressive.writeRows4K16PackedP4(malformed, destination[0..32]),
    );
    try testing.expectEqualSlices(u8, &destination_snapshot, &destination);

    const planes_snapshot = plane_backing;
    try testing.expectError(
        error.AliasedBuffers,
        progressive.writeRows4K16PackedP4(view, plane_backing[0..32]),
    );
    try testing.expectEqualSlices(u8, &planes_snapshot, &plane_backing);
}

test "rows4 K16 production owner cleans every allocation failure path" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        rows4AllocationProbe,
        .{},
    );
}

fn referenceDot(
    activations: []const f32,
    packed_bytes: []const u8,
    scales: []const f32,
    group_size: usize,
    tier: progressive.Tier,
) f32 {
    var result: f32 = 0;
    for (activations, 0..) |activation, index| {
        const nibble = readNibble(packed_bytes, index);
        const value = switch (tier) {
            .p1 => p1_values[nibble],
            .p2 => p2_values[nibble],
            .p4 => p4_values[nibble],
        };
        const weight: f32 = @floatFromInt(value);
        result += activation * (weight * scales[index / group_size]);
    }
    return result;
}

/// Independent copy of the pre-progressive scalar decode formula.  Keeping
/// it separate from the decomposition is intentional: exact equality here
/// proves that P4 did not change full-INT4 arithmetic or accumulation order.
fn legacyFullInt4Dot(
    activations: []const f32,
    packed_bytes: []const u8,
    scales: []const f32,
    group_size: usize,
) f32 {
    var result: f32 = 0;
    for (activations, 0..) |activation, index| {
        const nibble = readNibble(packed_bytes, index);
        const signed_value: i8 = @as(i8, @intCast(nibble)) - 7;
        const weight: f32 = @floatFromInt(signed_value);
        result += activation * (weight * scales[index / group_size]);
    }
    return result;
}

fn readNibble(packed_bytes: []const u8, index: usize) u8 {
    return if (index & 1 == 0)
        packed_bytes[index / 2] & 0x0f
    else
        packed_bytes[index / 2] >> 4;
}

fn writeNibble(packed_bytes: []u8, index: usize, nibble: u8) void {
    const byte_index = index / 2;
    if (index & 1 == 0) {
        packed_bytes[byte_index] = (packed_bytes[byte_index] & 0xf0) | (nibble & 0x0f);
    } else {
        packed_bytes[byte_index] = (packed_bytes[byte_index] & 0x0f) | (nibble << 4);
    }
}

fn splitAllocationProbe(allocator: std.mem.Allocator) !void {
    const packed_weights = [_]u8{ 0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe, 0x01 };
    var planes = try progressive.PackedPlanes.init(allocator, &packed_weights, 17);
    defer planes.deinit();

    try testing.expectEqual(@as(usize, 3), planes.coarse1.len);
    try testing.expectEqual(@as(usize, 3), planes.middle1.len);
    try testing.expectEqual(@as(usize, 5), planes.fine2.len);
}

const Rows4AliasCase = enum {
    source_coarse,
    source_middle,
    source_fine,
    coarse_middle,
    coarse_fine,
    middle_fine,
};

fn expectRows4PackAliasNoWrite(alias_case: Rows4AliasCase) !void {
    var backing = [_]u8{0xa5} ** 128;
    var coarse1: []u8 = backing[40..48];
    var middle1: []u8 = backing[64..72];
    var fine2: []u8 = backing[80..96];
    switch (alias_case) {
        .source_coarse => coarse1 = backing[4..12],
        .source_middle => middle1 = backing[12..20],
        .source_fine => fine2 = backing[8..24],
        .coarse_middle => middle1 = backing[44..52],
        .coarse_fine => fine2 = backing[44..60],
        .middle_fine => fine2 = backing[68..84],
    }
    const snapshot = backing;
    try testing.expectError(
        error.AliasedBuffers,
        progressive.packRows4K16Into(
            .{
                .packed_bytes = backing[0..32],
                .out_f = 4,
                .in_f = 16,
                .group_size = 8,
            },
            coarse1,
            middle1,
            fine2,
        ),
    );
    try testing.expectEqualSlices(u8, &snapshot, &backing);
}

fn referenceRows4K16Index(row: usize, col: usize, in_f: usize) usize {
    const tile = row / 4;
    const lane = row % 4;
    const block = col / 16;
    const chunk = (col % 16) / 4;
    const inner = col % 4;
    return tile * (4 * in_f) + block * 64 + chunk * 16 + lane * 4 + inner;
}

fn rows4AllocationProbe(allocator: std.mem.Allocator) !void {
    var packed_bytes: [32]u8 = undefined;
    for (&packed_bytes, 0..) |*byte, index| byte.* = @truncate(index * 29 + 7);
    var planes = try progressive.Rows4K16Progressive.init(
        allocator,
        .{
            .packed_bytes = &packed_bytes,
            .out_f = 4,
            .in_f = 16,
            .group_size = 8,
        },
    );
    defer planes.deinit();

    var reconstructed: [32]u8 = undefined;
    try planes.writePackedP4(&reconstructed);
    try testing.expectEqualSlices(u8, &packed_bytes, &reconstructed);
}
