//! Model-free LaneWeave QoS conformance demo.

const std = @import("std");
const core = @import("core");
const qos = core.lane_weave_qos;
const resource_bank = core.resource_bank;

pub fn main() !void {
    var bank_slots: [3]resource_bank.Slot = [_]resource_bank.Slot{.{}} ** 3;
    var bank = try resource_bank.Bank.init(
        &bank_slots,
        .{
            .host_bytes = 4096,
            .kv_bytes = 4096,
            .queue_slots = 3,
        },
        0x4445_4d4f_4241_4e4b,
    );
    var challenge = qos.zero_digest;
    challenge[0..8].* = .{ 0x6c, 0x61, 0x6e, 0x65, 0x77, 0x65, 0x61, 0x76 };

    var slots: [3]qos.Slot = [_]qos.Slot{.{}} ** 3;
    var projection: [3]qos.ProjectionSlot = [_]qos.ProjectionSlot{.{}} ** 3;
    var scheduler = try qos.Scheduler.init(
        &bank,
        .{ .slots = &slots, .projection = &projection },
        .{
            .scheduler_epoch = 0x4445_4d4f_5153,
            .challenge = challenge,
            .max_weight = 4,
            .max_projection_quanta = 1024,
        },
    );

    var verifier_slots: [3]qos.Slot = [_]qos.Slot{.{}} ** 3;
    var verifier_projection: [3]qos.ProjectionSlot =
        [_]qos.ProjectionSlot{.{}} ** 3;
    var verifier = try qos.Verifier.init(
        .{ .slots = &verifier_slots, .projection = &verifier_projection },
        scheduler.config,
        scheduler.bank_epoch,
        scheduler.limits,
    );

    const weights = [_]u16{ 1, 2, 4 };
    var handles: [3]qos.Handle = undefined;
    for (weights, 0..) |weight, index| {
        const key: u64 = @intCast(index + 1);
        const decision = try scheduler.admit(.{
            .tenant_key = key,
            .request_key = key * 10,
            .request_generation = 1,
            .resource_owner_key = key * 100,
            .weight = weight,
            .work_quanta = weight,
            .claim = .{ .kv_bytes = 64, .queue_slots = 1 },
        });
        const admission = switch (decision) {
            .admitted => |value| value,
            .rejected => return error.UnexpectedAdmissionRejection,
        };
        handles[index] = admission.handle;
        try verifier.apply(admission.event);
    }

    var order: [7]u64 = undefined;
    for (&order) |*tenant| {
        const permit = try scheduler.prepareService();
        const event = try scheduler.commitService(permit);
        tenant.* = event.handle.tenant_key;
        try verifier.apply(event);
    }
    const golden_order = [_]u64{ 1, 2, 3, 2, 3, 3, 3 };
    if (!std.mem.eql(u64, &order, &golden_order))
        return error.UnexpectedServiceOrder;
    for (handles) |handle| try verifier.apply(try scheduler.retire(handle));
    const close_event = try scheduler.close();
    try verifier.apply(close_event);
    const final_head = try verifier.finish(close_event.event_sha256);
    const head_hex = std.fmt.bytesToHex(final_head, .lower);
    if (!std.mem.eql(
        u8,
        &head_hex,
        "042e2f195ade0bdddb535ba1a2e518b9c1a6d3885933ad87f3d28f835a59852c",
    )) return error.UnexpectedChainHead;

    const stdout = std.fs.File.stdout();
    var buffer: [1024]u8 = undefined;
    var writer = std.fs.File.Writer.init(stdout, &buffer);
    try writer.interface.print(
        "{{\"schema\":\"glacier.lane-weave-qos/demo-v1\",\"weights\":[1,2,4]," ++
            "\"service_order\":[{d},{d},{d},{d},{d},{d},{d}]," ++
            "\"maximum_service_gap\":{d},\"final_bank_bytes\":0," ++
            "\"verified\":true,\"chain_head_sha256\":\"{s}\"}}\n",
        .{
            order[0],                      order[1],  order[2], order[3], order[4], order[5], order[6],
            scheduler.maximum_service_gap, &head_hex,
        },
    );
    try writer.interface.flush();
}
