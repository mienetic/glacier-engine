const std = @import("std");
const core = @import("glacier_core");

const registry = core.runtime_support_registry;
const schema = "glacier.runtime-support-registry/v1";

pub fn main() void {
    run() catch |err| {
        const stderr = std.fs.File.stderr();
        var buffer: [256]u8 = undefined;
        var writer = std.fs.File.Writer.init(stderr, &buffer);
        writer.interface.print(
            "runtime-support-inspector: {s}\n",
            .{@errorName(err)},
        ) catch {};
        writer.interface.flush() catch {};
        std.process.exit(2);
    };
}

fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const arguments = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, arguments);
    try validateArgumentCount(arguments.len);

    const stdout = std.fs.File.stdout();
    var output_buffer: [8192]u8 = undefined;
    var output = std.fs.File.Writer.init(stdout, &output_buffer);
    try renderRegistryV1(&output.interface);
    try output.interface.flush();
}

fn validateArgumentCount(argument_count: usize) !void {
    if (argument_count != 1) return error.UnexpectedArgument;
}

pub fn renderRegistryV1(writer: *std.Io.Writer) !void {
    try writer.print(
        "{{\"schema\":\"{s}\",\"registry_abi\":\"{x:0>16}\"," ++
            "\"production_model_support\":false," ++
            "\"host_backend_probed\":false," ++
            "\"claim_scope\":\"retained_reference_fixture_contracts\"," ++
            "\"profile_count\":{d},\"max_profiles\":{d}," ++
            "\"profiles\":[",
        .{
            schema,
            registry.registry_abi,
            registry.profiles.len,
            registry.max_profiles,
        },
    );

    for (registry.profiles, 0..) |profile, ordinal| {
        if (ordinal != 0) try writer.writeByte(',');
        try renderProfileV1(writer, profile);
    }

    try writer.writeAll("]}\n");
}

fn renderProfileV1(
    writer: *std.Io.Writer,
    profile: registry.ProfileV1,
) !void {
    const support = profile.support;
    try writer.print(
        "{{\"index\":{d},\"slug\":\"{s}\"," ++
            "\"profile_abi\":\"{x:0>16}\"," ++
            "\"lifecycle\":\"{s}\",\"evidence\":\"{s}\"," ++
            "\"support\":{{" ++
            "\"family\":\"{s}\",\"family_id\":{d}," ++
            "\"operation\":\"{s}\",\"operation_id\":{d}," ++
            "\"input_kind\":\"{s}\",\"input_kind_id\":{d}," ++
            "\"output_kind\":\"{s}\",\"output_kind_id\":{d}," ++
            "\"numerical_policy\":\"{s}\"," ++
            "\"numerical_policy_id\":{d}," ++
            "\"max_batch_items\":{d}," ++
            "\"max_input_features\":{d}," ++
            "\"max_output_dimensions\":{d}," ++
            "\"allowed_capabilities\":\"{x:0>16}\"}}}}",
        .{
            @intFromEnum(profile.index),
            profile.slug,
            profile.profile_abi,
            @tagName(profile.lifecycle),
            @tagName(profile.evidence),
            @tagName(support.family),
            @intFromEnum(support.family),
            @tagName(support.operation),
            @intFromEnum(support.operation),
            @tagName(support.input_kind),
            @intFromEnum(support.input_kind),
            @tagName(support.output_kind),
            @intFromEnum(support.output_kind),
            @tagName(support.numerical_policy),
            @intFromEnum(support.numerical_policy),
            support.max_batch_items,
            support.max_input_features,
            support.max_output_dimensions,
            support.allowed_capabilities,
        },
    );
}

test "inspector accepts no semantic arguments only" {
    try validateArgumentCount(1);
    try std.testing.expectError(
        error.UnexpectedArgument,
        validateArgumentCount(0),
    );
    try std.testing.expectError(
        error.UnexpectedArgument,
        validateArgumentCount(2),
    );
}

test "inspector renders deterministic valid newline JSON" {
    var first_storage: [8192]u8 = undefined;
    var first_writer = std.Io.Writer.fixed(&first_storage);
    try renderRegistryV1(&first_writer);

    var second_storage: [8192]u8 = undefined;
    var second_writer = std.Io.Writer.fixed(&second_storage);
    try renderRegistryV1(&second_writer);

    const first = first_writer.buffered();
    const second = second_writer.buffered();
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expectEqual(@as(u8, '\n'), first[first.len - 1]);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, first, "\n"));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const document = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        first,
        .{},
    );
    try std.testing.expect(document == .object);
    const object = document.object;
    try std.testing.expectEqualStrings(
        schema,
        object.get("schema").?.string,
    );
    try std.testing.expect(!object.get("production_model_support").?.bool);
    try std.testing.expect(!object.get("host_backend_probed").?.bool);
    try std.testing.expectEqualStrings(
        "retained_reference_fixture_contracts",
        object.get("claim_scope").?.string,
    );
    try std.testing.expectEqual(
        @as(i64, registry.profiles.len),
        object.get("profile_count").?.integer,
    );

    const rendered_profiles = object.get("profiles").?.array.items;
    try std.testing.expectEqual(registry.profiles.len, rendered_profiles.len);
    for (rendered_profiles, registry.profiles, 0..) |
        rendered,
        profile,
        ordinal,
    | {
        try std.testing.expectEqual(
            @as(i64, @intCast(ordinal)),
            rendered.object.get("index").?.integer,
        );
        try std.testing.expectEqualStrings(
            profile.slug,
            rendered.object.get("slug").?.string,
        );
        try std.testing.expectEqual(@as(usize, 16), rendered.object
            .get("support").?.object
            .get("allowed_capabilities").?.string.len);
    }
}
