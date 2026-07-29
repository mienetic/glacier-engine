//! Thin CLI surface for the ordinary-model package producer.

const std = @import("std");
const engine = @import("engine");

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    writer: *std.Io.Writer,
) !void {
    if (args.len < 8) {
        try usage(writer);
        return error.InvalidUsage;
    }
    const source_path = args[2];
    const portable_path = args[3];
    const prepared_path = args[4];
    const package_path = args[5];
    var license_path: ?[]const u8 = null;
    var config_path: ?[]const u8 = null;
    var group_size: u32 = 64;
    var index: usize = 6;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--license")) {
            if (license_path != null)
                return error.InvalidUsage;
            index += 1;
            if (index >= args.len)
                return error.InvalidUsage;
            license_path = args[index];
        } else if (std.mem.eql(u8, argument, "--config")) {
            if (config_path != null)
                return error.InvalidUsage;
            index += 1;
            if (index >= args.len)
                return error.InvalidUsage;
            config_path = args[index];
        } else if (std.mem.eql(u8, argument, "--group-size")) {
            index += 1;
            if (index >= args.len)
                return error.InvalidUsage;
            group_size = std.fmt.parseInt(
                u32,
                args[index],
                10,
            ) catch return error.InvalidUsage;
        } else {
            return error.InvalidUsage;
        }
    }
    const license = license_path orelse {
        try usage(writer);
        return error.InvalidUsage;
    };

    const receipt = try engine.model_package_producer
        .produceSafetensorsV1(
        allocator,
        source_path,
        portable_path,
        prepared_path,
        package_path,
        license,
        .{
            .config_path = config_path,
            .conversion = .{
                .quantize_int4 = true,
                .quant_group_size = group_size,
            },
        },
    );
    const source_hex = std.fmt.bytesToHex(
        receipt.source_identity.source_sha256,
        .lower,
    );
    const portable_hex = std.fmt.bytesToHex(
        receipt.portable_identity.container_sha256,
        .lower,
    );
    const profile_hex = std.fmt.bytesToHex(
        receipt.conversion_profile_sha256,
        .lower,
    );
    const plan_hex = std.fmt.bytesToHex(
        receipt.conversion_plan_sha256,
        .lower,
    );
    const content_hex = std.fmt.bytesToHex(
        receipt.package.model_content_sha256,
        .lower,
    );
    const package_hex = std.fmt.bytesToHex(
        receipt.package.package_sha256,
        .lower,
    );
    const representation_hex = std.fmt.bytesToHex(
        receipt.representation.representation_sha256,
        .lower,
    );
    const prepared_hex = std.fmt.bytesToHex(
        receipt.prepared_identity.container_sha256,
        .lower,
    );
    const prepared_abi_hex = std.fmt.bytesToHex(
        receipt.prepared_identity.abi_fingerprint,
        .lower,
    );
    const tokenizer_domain_hex = std.fmt.bytesToHex(
        receipt.tokenizer_manifest.domain_sha256,
        .lower,
    );
    const tokenizer_behavior_hex = std.fmt.bytesToHex(
        receipt.tokenizer_manifest.behavior_sha256,
        .lower,
    );
    const tokenizer_config_hex = std.fmt.bytesToHex(
        receipt.tokenizer_manifest.config_sha256,
        .lower,
    );
    const license_hex = std.fmt.bytesToHex(
        receipt.package.license_sha256,
        .lower,
    );
    const resolved_config_hex = std.fmt.bytesToHex(
        receipt.package.resolved_config_sha256,
        .lower,
    );
    const config = receipt.package.config;
    try writer.print(
        "{{\"schema\":\"glacier.model-package-producer/v1\"," ++
            "\"conversion_disposition\":\"{s}\"," ++
            "\"package_disposition\":\"{s}\"," ++
            "\"family\":\"autoregressive\"," ++
            "\"source_format\":\"safetensors\"," ++
            "\"tokenizer_profile\":\"utf8-byte-v1\"," ++
            "\"prepared_layout\":\"separate\"," ++
            "\"source_bytes\":{d}," ++
            "\"portable_bytes\":{d}," ++
            "\"portable_page_count\":{d}," ++
            "\"prepared_bytes\":{d}," ++
            "\"package_bytes\":{d}," ++
            "\"package_manifest_bytes\":{d}," ++
            "\"prepared_representation_bytes\":{d}," ++
            "\"license_bytes\":{d}," ++
            "\"tokenizer_max_input_bytes\":{d}," ++
            "\"config_source\":\"{s}\",",
        .{
            switch (receipt.conversion_disposition) {
                .published => "published",
                .already_current => "already_current",
            },
            switch (receipt.package_disposition) {
                .published => "published",
                .already_current => "already_current",
            },
            receipt.source_identity.source_bytes,
            receipt.portable_identity.container_bytes,
            receipt.portable_identity.page_count,
            receipt.prepared_identity.container_bytes,
            engine.model_package_manifest.admission_bundle_bytes,
            engine.model_package_manifest.manifest_bytes,
            engine.model_package_manifest.prepared_representation_bytes,
            receipt.package.license_bytes,
            receipt.tokenizer_manifest.max_input_bytes,
            switch (receipt.config_source) {
                .derived => "derived",
                .explicit => "explicit",
            },
        },
    );
    if (receipt.config_input_identity) |identity| {
        const config_input_hex = std.fmt.bytesToHex(
            identity.sha256,
            .lower,
        );
        try writer.print(
            "\"config_input_bytes\":{d}," ++
                "\"config_input_sha256\":\"{s}\",",
            .{
                identity.bytes,
                &config_input_hex,
            },
        );
    } else {
        try writer.writeAll(
            "\"config_input_bytes\":null," ++
                "\"config_input_sha256\":null,",
        );
    }
    try writer.print(
        "\"config\":{{\"dim\":{d},\"hidden_dim\":{d}," ++
            "\"layers\":{d},\"vocab\":{d},\"heads\":{d}," ++
            "\"head_dim\":{d},\"kv_heads\":{d}," ++
            "\"rms_eps_bits\":{d},\"rope_theta_bits\":{d}," ++
            "\"tie_embeddings\":{s}}}," ++
            "\"source_sha256\":\"{s}\"," ++
            "\"portable_artifact_sha256\":\"{s}\"," ++
            "\"conversion_profile_sha256\":\"{s}\"," ++
            "\"conversion_plan_sha256\":\"{s}\"," ++
            "\"resolved_config_sha256\":\"{s}\"," ++
            "\"model_content_sha256\":\"{s}\"," ++
            "\"package_sha256\":\"{s}\"," ++
            "\"representation_sha256\":\"{s}\"," ++
            "\"prepared_artifact_sha256\":\"{s}\"," ++
            "\"prepared_abi_fingerprint\":\"{s}\"," ++
            "\"tokenizer_domain_sha256\":\"{s}\"," ++
            "\"tokenizer_behavior_sha256\":\"{s}\"," ++
            "\"tokenizer_config_sha256\":\"{s}\"," ++
            "\"license_sha256\":\"{s}\"," ++
            "\"request_independent\":true," ++
            "\"prepared_representation_separate\":false," ++
            "\"prepared_representation_embedded\":true," ++
            "\"network_required\":false," ++
            "\"publisher_authenticity_proven\":false," ++
            "\"production_model_verified\":false}}\n",
        .{
            config.dim,
            config.hidden_dim,
            config.layers,
            config.vocab,
            config.heads,
            config.head_dim,
            config.kv_heads,
            @as(u32, @bitCast(config.rms_eps)),
            @as(u32, @bitCast(config.rope_theta)),
            if (config.tie_embeddings) "true" else "false",
            &source_hex,
            &portable_hex,
            &profile_hex,
            &plan_hex,
            &resolved_config_hex,
            &content_hex,
            &package_hex,
            &representation_hex,
            &prepared_hex,
            &prepared_abi_hex,
            &tokenizer_domain_hex,
            &tokenizer_behavior_hex,
            &tokenizer_config_hex,
            &license_hex,
        },
    );
}

fn usage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        "usage: glacier package-model <source.safetensors> " ++
            "<out.glacier> <out.glrt> <out.glpkg> " ++
            "--license <file> [--config <file>] [--group-size N]\n",
    );
}
