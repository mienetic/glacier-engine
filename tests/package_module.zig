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
    try std.testing.expect(
        @hasDecl(glacier, "device_allocation_lease_tree"),
    );
    try std.testing.expect(
        @hasDecl(glacier, "DeviceAllocationLeaseTree"),
    );
    try std.testing.expect(@hasDecl(glacier, "workload_closed_loop"));
    try std.testing.expect(@hasDecl(glacier, "WorkloadClosedLoop"));
    try std.testing.expect(@hasDecl(glacier, "typed_workload_contract"));
    try std.testing.expect(@hasDecl(glacier, "TypedWorkloadContract"));
    try std.testing.expect(@hasDecl(glacier, "typed_workload_driver"));
    try std.testing.expect(@hasDecl(glacier, "TypedWorkloadDriver"));
    try std.testing.expect(
        @hasDecl(glacier, "typed_perception_workload"),
    );
    try std.testing.expect(
        @hasDecl(glacier, "TypedPerceptionWorkload"),
    );
    try std.testing.expect(
        @hasDecl(glacier, "typed_tool_workload"),
    );
    try std.testing.expect(
        @hasDecl(glacier, "TypedToolWorkload"),
    );
    try std.testing.expect(
        @hasDecl(glacier, "native_observation_contract"),
    );
    try std.testing.expect(
        @hasDecl(glacier, "native_observation_runner"),
    );
    try std.testing.expect(
        @hasDecl(glacier, "NativeObservationContract"),
    );
    try std.testing.expect(
        @hasDecl(glacier, "NativeObservationRunner"),
    );
    try std.testing.expect(@hasDecl(glacier, "ToolActionContract"));
    try std.testing.expect(@hasDecl(glacier, "ToolActionHarness"));
    try std.testing.expect(
        @hasDecl(glacier, "ToolActionOutboxRecord"),
    );
    try std.testing.expect(
        @hasDecl(glacier, "ToolActionOutboxConformance"),
    );
    try std.testing.expect(
        @hasDecl(glacier, "ToolActionOutboxFile"),
    );
    try std.testing.expect(
        @hasDecl(
            glacier,
            "ToolActionOutboxStoreConformance",
        ),
    );
    try std.testing.expect(@hasDecl(glacier, "prepared_text_successor"));
    try std.testing.expect(
        @hasDecl(glacier, "prepared_text_restore_admission"),
    );
    try std.testing.expect(@hasDecl(glacier_core, "ResourceBank"));
    try std.testing.expect(
        @hasDecl(glacier_core, "device_allocation_lease_tree"),
    );
    try std.testing.expect(
        @hasDecl(glacier_core, "DeviceAllocationLeaseTree"),
    );
    try std.testing.expect(
        @hasDecl(glacier_core, "workload_closed_loop"),
    );
    try std.testing.expect(
        @hasDecl(glacier_core, "WorkloadClosedLoop"),
    );
    try std.testing.expect(
        @hasDecl(glacier_core, "typed_workload_contract"),
    );
    try std.testing.expect(
        @hasDecl(glacier_core, "TypedWorkloadContract"),
    );
    try std.testing.expect(
        @hasDecl(glacier_core, "typed_workload_driver"),
    );
    try std.testing.expect(
        @hasDecl(glacier_core, "TypedWorkloadDriver"),
    );
    try std.testing.expect(
        @hasDecl(glacier_core, "typed_perception_workload"),
    );
    try std.testing.expect(
        @hasDecl(glacier_core, "TypedPerceptionWorkload"),
    );
    try std.testing.expect(
        @hasDecl(glacier_core, "typed_tool_workload"),
    );
    try std.testing.expect(
        @hasDecl(glacier_core, "TypedToolWorkload"),
    );
    try std.testing.expect(
        @hasDecl(glacier_core, "native_observation_contract"),
    );
    try std.testing.expect(
        @hasDecl(glacier_core, "native_observation_runner"),
    );
    try std.testing.expect(
        @hasDecl(glacier_core, "NativeObservationContract"),
    );
    try std.testing.expect(
        @hasDecl(glacier_core, "NativeObservationRunner"),
    );
    try std.testing.expect(
        @hasDecl(glacier_core, "ToolActionContract"),
    );
    try std.testing.expect(
        @hasDecl(glacier_core, "ToolActionHarness"),
    );
    try std.testing.expect(
        @hasDecl(glacier_core, "ToolActionOutboxRecord"),
    );
    try std.testing.expect(
        @hasDecl(glacier_core, "ToolActionOutboxConformance"),
    );
    try std.testing.expect(
        @hasDecl(glacier_core, "ToolActionOutboxFile"),
    );
    try std.testing.expect(
        @hasDecl(
            glacier_core,
            "ToolActionOutboxStoreConformance",
        ),
    );
    try std.testing.expect(@hasDecl(glacier_core, "RuntimeSupportRegistry"));
    try std.testing.expectEqual(
        @as(usize, 8),
        glacier_core.RuntimeSupportRegistry.profiles.len,
    );
    try std.testing.expect(glacier.ResourceBank == glacier_core.ResourceBank);
    try std.testing.expect(
        glacier.DeviceAllocationLeaseTree ==
            glacier_core.DeviceAllocationLeaseTree,
    );
    try std.testing.expect(
        glacier.workload_closed_loop ==
            glacier_core.workload_closed_loop,
    );
    try std.testing.expect(
        glacier.WorkloadClosedLoop ==
            glacier_core.WorkloadClosedLoop,
    );
    try std.testing.expect(
        glacier.TypedWorkloadContract ==
            glacier_core.TypedWorkloadContract,
    );
    try std.testing.expect(
        glacier.TypedWorkloadDriver ==
            glacier_core.TypedWorkloadDriver,
    );
    try std.testing.expect(
        glacier.TypedPerceptionWorkload ==
            glacier_core.TypedPerceptionWorkload,
    );
    try std.testing.expect(
        glacier.TypedToolWorkload ==
            glacier_core.TypedToolWorkload,
    );
    try std.testing.expect(
        glacier.native_observation_contract ==
            glacier_core.native_observation_contract,
    );
    try std.testing.expect(
        glacier.native_observation_runner ==
            glacier_core.native_observation_runner,
    );
    try std.testing.expect(
        glacier.NativeObservationContract ==
            glacier_core.NativeObservationContract,
    );
    try std.testing.expect(
        glacier.NativeObservationRunner ==
            glacier_core.NativeObservationRunner,
    );
    try std.testing.expect(
        glacier.ToolActionContract ==
            glacier_core.ToolActionContract,
    );
    try std.testing.expect(
        glacier.ToolActionHarness ==
            glacier_core.ToolActionHarness,
    );
    try std.testing.expect(
        glacier.ToolActionOutboxRecord ==
            glacier_core.ToolActionOutboxRecord,
    );
    try std.testing.expect(
        glacier.ToolActionOutboxConformance ==
            glacier_core.ToolActionOutboxConformance,
    );
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
