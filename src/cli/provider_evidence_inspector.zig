//! Read-only renderer for the fixed provider evidence join envelope.
//!
//! The default command validates only the framing and checksum of the 712-byte
//! outer envelope. Callers may explicitly supply every nested journal,
//! gateway, and transport artifact to invoke the existing full composition
//! verifier. Neither mode grants authority or renders payloads, prompts,
//! responses, or credentials.

const std = @import("std");
const core = @import("glacier_core");

const join = core.provider_evidence_join_wire;
const journal = core.provider_cost_journal;
const gateway = core.provider_token_gateway;
const gateway_wire = core.provider_gateway_event_wire;
const transport_wire = core.provider_transport_event_wire;
const schema = "glacier.provider-evidence-inspector/v1";
const maximum_nested_wire_bytes: usize = 8 * 1024 * 1024;

const CompositionPaths = struct {
    journal_header_path: []const u8,
    cost_frame_path: []const u8,
    gateway_events_path: []const u8,
    transport_events_path: []const u8,
};

const Options = struct {
    join_path: []const u8,
    composition: ?CompositionPaths,
};

const GatewayScratchRequirements = struct {
    event_count: usize,
    owner_capacity: usize,
    consumer_capacity: usize,
    settlement_count: usize,
};

const EvidenceClaimV1 = union(enum) {
    outer: join.InspectedEnvelopeV1,
    composed: join.DecodedV1,
};

pub fn main() void {
    run() catch |err| {
        const stderr = std.fs.File.stderr();
        var buffer: [256]u8 = undefined;
        var writer = std.fs.File.Writer.init(stderr, &buffer);
        writer.interface.print(
            "provider-evidence-inspector: {s}\n",
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
    const options = try parseOptions(arguments);

    const encoded = try readExactRegularFile(options.join_path);
    const inspected = try join.decodeEnvelopeV1(&encoded);
    const claim: EvidenceClaimV1 = if (options.composition) |paths|
        .{ .composed = try verifyCompositionV1(
            allocator,
            &encoded,
            inspected.self_asserted,
            paths,
        ) }
    else
        .{ .outer = inspected };

    const stdout = std.fs.File.stdout();
    var output_buffer: [8192]u8 = undefined;
    var output = std.fs.File.Writer.init(stdout, &output_buffer);
    try renderEnvelopeV1(&output.interface, claim);
    try output.interface.flush();
}

fn parseOptions(arguments: []const []const u8) !Options {
    if (arguments.len < 3 or arguments.len % 2 == 0)
        return error.InvalidArguments;
    var join_path: ?[]const u8 = null;
    var journal_header_path: ?[]const u8 = null;
    var cost_frame_path: ?[]const u8 = null;
    var gateway_events_path: ?[]const u8 = null;
    var transport_events_path: ?[]const u8 = null;

    var index: usize = 1;
    while (index < arguments.len) : (index += 2) {
        const name = arguments[index];
        const value = arguments[index + 1];
        if (value.len == 0) return error.InvalidArguments;
        const destination: *?[]const u8 =
            if (std.mem.eql(u8, name, "--join"))
                &join_path
            else if (std.mem.eql(u8, name, "--journal-header"))
                &journal_header_path
            else if (std.mem.eql(u8, name, "--cost-frame"))
                &cost_frame_path
            else if (std.mem.eql(u8, name, "--gateway-events"))
                &gateway_events_path
            else if (std.mem.eql(u8, name, "--transport-events"))
                &transport_events_path
            else
                return error.InvalidArguments;
        if (destination.* != null) return error.InvalidArguments;
        destination.* = value;
    }

    const nested_count =
        @as(usize, @intFromBool(journal_header_path != null)) +
        @as(usize, @intFromBool(cost_frame_path != null)) +
        @as(usize, @intFromBool(gateway_events_path != null)) +
        @as(usize, @intFromBool(transport_events_path != null));
    if (join_path == null or (nested_count != 0 and nested_count != 4))
        return error.InvalidArguments;
    return .{
        .join_path = join_path.?,
        .composition = if (nested_count == 4) .{
            .journal_header_path = journal_header_path.?,
            .cost_frame_path = cost_frame_path.?,
            .gateway_events_path = gateway_events_path.?,
            .transport_events_path = transport_events_path.?,
        } else null,
    };
}

fn readExactRegularFile(path: []const u8) ![join.encoded_bytes]u8 {
    return readFixedRegularFile(join.encoded_bytes, path);
}

fn readFixedRegularFile(
    comptime expected_bytes: usize,
    path: []const u8,
) ![expected_bytes]u8 {
    var file = if (std.fs.path.isAbsolute(path))
        try std.fs.openFileAbsolute(path, .{})
    else
        try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const before = try file.stat();
    if (before.kind != .file) return error.InvalidInputKind;
    if (before.size != expected_bytes)
        return error.InvalidInputLength;

    var encoded: [expected_bytes]u8 = undefined;
    if (try file.readAll(&encoded) != encoded.len)
        return error.InputChanged;
    var probe: [1]u8 = undefined;
    if (try file.pread(&probe, expected_bytes) != 0)
        return error.InputChanged;

    const after = try file.stat();
    if (!sameFileSnapshot(before, after))
        return error.InputChanged;
    return encoded;
}

fn readAllocatedRegularFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    expected_bytes: usize,
) ![]u8 {
    if (expected_bytes == 0 or
        expected_bytes > maximum_nested_wire_bytes)
        return error.InvalidInputLength;
    var file = if (std.fs.path.isAbsolute(path))
        try std.fs.openFileAbsolute(path, .{})
    else
        try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const before = try file.stat();
    if (before.kind != .file) return error.InvalidInputKind;
    if (before.size != expected_bytes)
        return error.InvalidInputLength;

    const encoded = try allocator.alloc(u8, expected_bytes);
    errdefer allocator.free(encoded);
    if (try file.readAll(encoded) != encoded.len)
        return error.InputChanged;
    var probe: [1]u8 = undefined;
    if (try file.pread(&probe, expected_bytes) != 0)
        return error.InputChanged;

    const after = try file.stat();
    if (!sameFileSnapshot(before, after))
        return error.InputChanged;
    return encoded;
}

fn verifyCompositionV1(
    allocator: std.mem.Allocator,
    encoded_join: []const u8,
    outer: join.DecodedV1,
    paths: CompositionPaths,
) !join.DecodedV1 {
    if (outer.journal_frame_bytes != journal.frame_bytes)
        return error.InvalidInputLength;
    const gateway_bytes = std.math.cast(
        usize,
        outer.gateway_wire_bytes,
    ) orelse return error.InvalidInputLength;
    const transport_bytes = std.math.cast(
        usize,
        outer.transport_wire_bytes,
    ) orelse return error.InvalidInputLength;

    const encoded_header = try readFixedRegularFile(
        journal.header_bytes,
        paths.journal_header_path,
    );
    const encoded_frame = try readFixedRegularFile(
        journal.frame_bytes,
        paths.cost_frame_path,
    );
    const encoded_gateway = try readAllocatedRegularFile(
        allocator,
        paths.gateway_events_path,
        gateway_bytes,
    );
    defer allocator.free(encoded_gateway);
    const encoded_transport = try readAllocatedRegularFile(
        allocator,
        paths.transport_events_path,
        transport_bytes,
    );
    defer allocator.free(encoded_transport);

    const header = try journal.decodeHeaderV1(
        &encoded_header,
        outer.journal_header_sha256,
    );
    const gateway_requirements = try gatewayScratchRequirementsV1(
        encoded_gateway,
    );
    const transport_event_count = try transportEventCountV1(
        encoded_transport,
    );
    const gateway_events = try allocator.alloc(
        gateway.EventV2,
        gateway_requirements.event_count,
    );
    defer allocator.free(gateway_events);
    const gateway_owners = try allocator.alloc(
        gateway_wire.ReplayOwnerV1,
        gateway_requirements.owner_capacity,
    );
    defer allocator.free(gateway_owners);
    const gateway_consumers = try allocator.alloc(
        gateway_wire.ReplayConsumerV1,
        gateway_requirements.consumer_capacity,
    );
    defer allocator.free(gateway_consumers);
    const gateway_bindings = try allocator.alloc(
        gateway_wire.SettlementBindingV1,
        gateway_requirements.settlement_count,
    );
    defer allocator.free(gateway_bindings);
    const transport_events = try allocator.alloc(
        transport_wire.EventV1,
        transport_event_count,
    );
    defer allocator.free(transport_events);

    return join.decodeAndVerifyV1(
        encoded_join,
        header,
        &encoded_frame,
        encoded_gateway,
        encoded_transport,
        .{
            .gateway_events = gateway_events,
            .gateway_owners = gateway_owners,
            .gateway_consumers = gateway_consumers,
            .gateway_bindings = gateway_bindings,
            .transport_events = transport_events,
        },
    );
}

fn gatewayScratchRequirementsV1(
    encoded: []const u8,
) !GatewayScratchRequirements {
    if (encoded.len < gateway_wire.header_bytes)
        return error.InvalidInputLength;
    const event_count: usize = std.mem.readInt(
        u32,
        encoded[24..28],
        .little,
    );
    const owner_capacity: usize = std.mem.readInt(
        u32,
        encoded[32..36],
        .little,
    );
    const follower_capacity: usize = std.mem.readInt(
        u32,
        encoded[36..40],
        .little,
    );
    const settlement_count: usize = std.mem.readInt(
        u32,
        encoded[40..44],
        .little,
    );
    const consumer_capacity = std.math.add(
        usize,
        owner_capacity,
        follower_capacity,
    ) catch return error.CapacityExceeded;
    if (event_count > gateway_wire.max_supported_events or
        consumer_capacity > gateway_wire.max_supported_replay_slots or
        settlement_count > event_count)
        return error.CapacityExceeded;
    if (try gateway_wire.encodedLenV1(
        event_count,
        settlement_count,
    ) != encoded.len) return error.InvalidInputLength;
    return .{
        .event_count = event_count,
        .owner_capacity = owner_capacity,
        .consumer_capacity = consumer_capacity,
        .settlement_count = settlement_count,
    };
}

fn transportEventCountV1(encoded: []const u8) !usize {
    if (encoded.len < transport_wire.header_bytes)
        return error.InvalidInputLength;
    const event_count: usize = std.mem.readInt(
        u32,
        encoded[28..32],
        .little,
    );
    if (event_count == 0 or
        event_count > transport_wire.max_supported_events)
        return error.CapacityExceeded;
    return event_count;
}

fn sameFileSnapshot(
    before: std.fs.File.Stat,
    after: std.fs.File.Stat,
) bool {
    return before.kind == after.kind and
        before.inode == after.inode and
        before.size == after.size and
        before.mode == after.mode and
        before.mtime == after.mtime and
        before.ctime == after.ctime;
}

fn renderEnvelopeV1(
    writer: *std.Io.Writer,
    claim: EvidenceClaimV1,
) !void {
    const composition_verified = claim == .composed;
    const value = switch (claim) {
        .outer => |inspected| inspected.self_asserted,
        .composed => |composed| composed,
    };
    try writer.print(
        "{{\"schema\":\"{s}\",\"wire_abi\":\"{x:0>16}\"," ++
            "\"wire_bytes\":{d}," ++
            "\"outer_envelope_verified\":true," ++
            "\"composition_verified\":{s}," ++
            "\"authority_granted\":false," ++
            "\"journal_sequence\":{d}," ++
            "\"gateway_event_index\":{d}," ++
            "\"transport_event_count\":{d}," ++
            "\"journal_frame_bytes\":{d}," ++
            "\"gateway_wire_bytes\":{d}," ++
            "\"transport_wire_bytes\":{d},\"roots\":{{",
        .{
            schema,
            join.wire_abi,
            join.encoded_bytes,
            if (composition_verified) "true" else "false",
            value.journal_sequence,
            value.gateway_event_index,
            value.transport_event_count,
            value.journal_frame_bytes,
            value.gateway_wire_bytes,
            value.transport_wire_bytes,
        },
    );
    try writeDigestField(
        writer,
        "journal_header_sha256",
        value.journal_header_sha256,
        true,
    );
    try writeDigestField(
        writer,
        "journal_previous_chain_sha256",
        value.journal_previous_chain_sha256,
        false,
    );
    try writeDigestField(
        writer,
        "journal_entry_sha256",
        value.journal_entry_sha256,
        false,
    );
    try writeDigestField(
        writer,
        "cost_envelope_sha256",
        value.cost_envelope_sha256,
        false,
    );
    try writeDigestField(
        writer,
        "settlement_envelope_sha256",
        value.settlement_envelope_sha256,
        false,
    );
    try writeDigestField(
        writer,
        "request_sha256",
        value.request_sha256,
        false,
    );
    try writeDigestField(
        writer,
        "dispatch_key_sha256",
        value.dispatch_key_sha256,
        false,
    );
    try writeDigestField(
        writer,
        "intent_sha256",
        value.intent_sha256,
        false,
    );
    try writeDigestField(
        writer,
        "receipt_sha256",
        value.receipt_sha256,
        false,
    );
    try writeDigestField(
        writer,
        "price_sha256",
        value.price_sha256,
        false,
    );
    try writeDigestField(
        writer,
        "quote_sha256",
        value.quote_sha256,
        false,
    );
    try writeDigestField(
        writer,
        "cost_settlement_sha256",
        value.cost_settlement_sha256,
        false,
    );
    try writeDigestField(
        writer,
        "gateway_envelope_sha256",
        value.gateway_envelope_sha256,
        false,
    );
    try writeDigestField(
        writer,
        "gateway_event_sha256",
        value.gateway_event_sha256,
        false,
    );
    try writeDigestField(
        writer,
        "gateway_final_chain_sha256",
        value.gateway_final_chain_sha256,
        false,
    );
    try writeDigestField(
        writer,
        "transport_envelope_sha256",
        value.transport_envelope_sha256,
        false,
    );
    try writeDigestField(
        writer,
        "provider_request_sha256",
        value.provider_request_sha256,
        false,
    );
    try writeDigestField(
        writer,
        "response_chain_sha256",
        value.response_chain_sha256,
        false,
    );
    try writeDigestField(
        writer,
        "transport_outcome_sha256",
        value.transport_outcome_sha256,
        false,
    );
    try writeDigestField(
        writer,
        "envelope_sha256",
        value.envelope_sha256,
        false,
    );
    try writer.writeAll("}}\n");
}

fn writeDigestField(
    writer: *std.Io.Writer,
    name: []const u8,
    value: join.Digest,
    first: bool,
) !void {
    const hex = std.fmt.bytesToHex(value, .lower);
    try writer.print(
        "{s}\"{s}\":\"{s}\"",
        .{ if (first) "" else ",", name, &hex },
    );
}

test "provider evidence inspector accepts outer or complete nested paths" {
    const valid = [_][]const u8{
        "provider-evidence-inspector",
        "--join",
        "fixture.bin",
    };
    const options = try parseOptions(&valid);
    try std.testing.expectEqualStrings("fixture.bin", options.join_path);
    try std.testing.expect(options.composition == null);

    const composed = [_][]const u8{
        "provider-evidence-inspector",
        "--transport-events",
        "transport.bin",
        "--join",
        "fixture.bin",
        "--cost-frame",
        "frame.bin",
        "--gateway-events",
        "gateway.bin",
        "--journal-header",
        "header.bin",
    };
    const composed_options = try parseOptions(&composed);
    const composition = composed_options.composition.?;
    try std.testing.expectEqualStrings(
        "fixture.bin",
        composed_options.join_path,
    );
    try std.testing.expectEqualStrings(
        "header.bin",
        composition.journal_header_path,
    );
    try std.testing.expectEqualStrings(
        "frame.bin",
        composition.cost_frame_path,
    );
    try std.testing.expectEqualStrings(
        "gateway.bin",
        composition.gateway_events_path,
    );
    try std.testing.expectEqualStrings(
        "transport.bin",
        composition.transport_events_path,
    );

    const cases = [_][]const []const u8{
        &.{"provider-evidence-inspector"},
        &.{ "provider-evidence-inspector", "--join" },
        &.{ "provider-evidence-inspector", "--join", "" },
        &.{ "provider-evidence-inspector", "--other", "fixture.bin" },
        &.{
            "provider-evidence-inspector",
            "--join",
            "fixture.bin",
            "--journal-header",
            "header.bin",
        },
        &.{
            "provider-evidence-inspector",
            "--join",
            "one.bin",
            "--join",
            "two.bin",
        },
    };
    for (cases) |arguments| {
        try std.testing.expectError(
            error.InvalidArguments,
            parseOptions(arguments),
        );
    }
}

test "provider evidence inspector reads only an exact stable regular file" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    const exact = [_]u8{0xa5} ** join.encoded_bytes;
    try temporary.dir.writeFile(.{
        .sub_path = "exact.join",
        .data = &exact,
    });
    const exact_path = try temporary.dir.realpathAlloc(
        std.testing.allocator,
        "exact.join",
    );
    defer std.testing.allocator.free(exact_path);
    const read = try readExactRegularFile(exact_path);
    try std.testing.expectEqualSlices(u8, &exact, &read);
    const allocated = try readAllocatedRegularFile(
        std.testing.allocator,
        exact_path,
        exact.len,
    );
    defer std.testing.allocator.free(allocated);
    try std.testing.expectEqualSlices(u8, &exact, allocated);

    try temporary.dir.writeFile(.{
        .sub_path = "short.join",
        .data = exact[0 .. exact.len - 1],
    });
    const short_path = try temporary.dir.realpathAlloc(
        std.testing.allocator,
        "short.join",
    );
    defer std.testing.allocator.free(short_path);
    try std.testing.expectError(
        error.InvalidInputLength,
        readExactRegularFile(short_path),
    );

    const directory_path = try temporary.dir.realpathAlloc(
        std.testing.allocator,
        ".",
    );
    defer std.testing.allocator.free(directory_path);
    try std.testing.expectError(
        error.InvalidInputKind,
        readExactRegularFile(directory_path),
    );
}

test "provider evidence inspector renders deterministic bounded claims" {
    const value = testDecodedV1();
    const outer_claim: EvidenceClaimV1 = .{
        .outer = .{ .self_asserted = value },
    };
    var first_storage: [8192]u8 = undefined;
    var first_writer = std.Io.Writer.fixed(&first_storage);
    try renderEnvelopeV1(&first_writer, outer_claim);

    var second_storage: [8192]u8 = undefined;
    var second_writer = std.Io.Writer.fixed(&second_storage);
    try renderEnvelopeV1(&second_writer, outer_claim);

    const first = first_writer.buffered();
    try std.testing.expectEqualStrings(first, second_writer.buffered());
    try std.testing.expectEqual(@as(u8, '\n'), first[first.len - 1]);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, first, "\n"),
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        first,
        "\"outer_envelope_verified\":true," ++ "\"composition_verified\":false," ++ "\"authority_granted\":false",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "payload") == null);
    try std.testing.expect(std.mem.indexOf(u8, first, "credential") == null);
    try std.testing.expect(std.mem.indexOf(u8, first, "prompt") == null);

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
    try std.testing.expect(object.get("outer_envelope_verified").?.bool);
    try std.testing.expect(!object.get("composition_verified").?.bool);
    try std.testing.expect(!object.get("authority_granted").?.bool);
    try std.testing.expectEqual(
        @as(i64, join.encoded_bytes),
        object.get("wire_bytes").?.integer,
    );
    const roots = object.get("roots").?.object;
    try std.testing.expectEqual(@as(usize, 20), roots.count());
    try std.testing.expectEqual(@as(usize, 64), roots
        .get("journal_header_sha256").?.string.len);
    try std.testing.expectEqual(@as(usize, 64), roots
        .get("envelope_sha256").?.string.len);

    var composed_storage: [8192]u8 = undefined;
    var composed_writer = std.Io.Writer.fixed(&composed_storage);
    try renderEnvelopeV1(
        &composed_writer,
        .{ .composed = value },
    );
    const composed_document = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        composed_writer.buffered(),
        .{},
    );
    try std.testing.expect(
        composed_document.object.get("composition_verified").?.bool,
    );
    try std.testing.expect(
        !composed_document.object.get("authority_granted").?.bool,
    );
}

fn testDecodedV1() join.DecodedV1 {
    return .{
        .journal_sequence = 7,
        .gateway_event_index = 3,
        .transport_event_count = 5,
        .journal_frame_bytes = 1_645,
        .gateway_wire_bytes = 5_984,
        .transport_wire_bytes = 2_758,
        .journal_header_sha256 = testDigest(1),
        .journal_previous_chain_sha256 = testDigest(2),
        .journal_entry_sha256 = testDigest(3),
        .cost_envelope_sha256 = testDigest(4),
        .settlement_envelope_sha256 = testDigest(5),
        .request_sha256 = testDigest(6),
        .dispatch_key_sha256 = testDigest(7),
        .intent_sha256 = testDigest(8),
        .receipt_sha256 = testDigest(9),
        .price_sha256 = testDigest(10),
        .quote_sha256 = testDigest(11),
        .cost_settlement_sha256 = testDigest(12),
        .gateway_envelope_sha256 = testDigest(13),
        .gateway_event_sha256 = testDigest(14),
        .gateway_final_chain_sha256 = testDigest(15),
        .transport_envelope_sha256 = testDigest(16),
        .provider_request_sha256 = testDigest(17),
        .response_chain_sha256 = testDigest(18),
        .transport_outcome_sha256 = testDigest(19),
        .envelope_sha256 = testDigest(20),
    };
}

fn testDigest(fill: u8) join.Digest {
    return [_]u8{fill} ** @sizeOf(join.Digest);
}
