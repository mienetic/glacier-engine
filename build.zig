const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip_production_cli = b.option(
        bool,
        "strip-production-cli",
        "Strip the installed ReleaseFast/ReleaseSmall CLI artifact",
    ) orelse (optimize == .ReleaseFast or optimize == .ReleaseSmall);
    const size_optimize_production_cli = b.option(
        bool,
        "size-optimize-production-cli",
        "Compile the cold CLI control plane as ReleaseSmall while the engine remains ReleaseFast",
    ) orelse (optimize == .ReleaseFast);
    const cli_control_optimize: std.builtin.OptimizeMode =
        if (size_optimize_production_cli and optimize == .ReleaseFast)
            .ReleaseSmall
        else
            optimize;

    // Metal is auto-enabled on macOS and can be forced off via -Dmetal=false.
    const metal_default = target.result.os.tag == .macos;
    const use_metal = b.option(bool, "metal", "Link the Metal backend (macOS only)") orelse metal_default;
    if (use_metal and target.result.os.tag != .macos)
        @panic("-Dmetal=true is only supported for macOS targets");
    const sanitize_thread = b.option(
        bool,
        "sanitize-thread",
        "Instrument Zig and C test code with ThreadSanitizer",
    );
    if ((sanitize_thread orelse false) and use_metal)
        @panic("-Dsanitize-thread=true requires -Dmetal=false");

    // --- Build options exposed to Zig as comptime flags ----------------------
    const opts = b.addOptions();
    opts.addOption(bool, "metal_enabled", use_metal);
    // Create the config module ONCE so all importers share the same instance
    // (calling createModule() multiple times produces duplicate modules over
    // the same file, which Zig rejects).
    const config_mod = opts.createModule();
    const paged_lease_base_opts = b.addOptions();
    paged_lease_base_opts.addOption(bool, "admission_cli", false);
    const paged_lease_base_opts_mod = paged_lease_base_opts.createModule();
    const paged_lease_admission_opts = b.addOptions();
    paged_lease_admission_opts.addOption(bool, "admission_cli", true);
    const paged_lease_admission_opts_mod =
        paged_lease_admission_opts.createModule();

    // --- Core module (no Metal dependency) -----------------------------------
    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
    });

    // --- Main engine module (composes core + backends) -----------------------
    const engine_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
    });
    engine_mod.addImport("core", core_mod);
    engine_mod.addImport("config", config_mod);

    // --- Metal linking (macOS only) ------------------------------------------
    // When enabled we compile shim.m to a static archive, link it plus
    // Metal/Foundation frameworks into every exe and test target, and expose
    // a build-time flag so Zig code can conditionally compile the bindings.
    const metal_shim: ?*std.Build.Step.Compile = blk: {
        if (!use_metal or target.result.os.tag != .macos) break :blk null;
        const shim = b.addLibrary(.{
            .name = "glacier_metal_shim",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
        shim.linkFramework("Metal");
        shim.linkFramework("Foundation");
        // Compile the Objective-C bridge with ARC.
        shim.root_module.addCSourceFile(.{
            .file = b.path("src/backends/metal/shim.m"),
            .flags = &.{ "-fobjc-arc", "-ObjC" },
        });
        break :blk shim;
    };

    // AArch64 NEON kernel for fused packed-INT4 decode projections. Other
    // architectures compile the portable Zig fallback and need no C object.
    const int4_neon: ?*std.Build.Step.Compile = blk: {
        if (target.result.cpu.arch != .aarch64) break :blk null;
        const lib = b.addLibrary(.{
            .name = "glacier_int4_neon",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
        lib.root_module.addCSourceFile(.{
            .file = b.path("src/backends/cpu/int4_neon.c"),
            // Apple Silicon gets the local SDOT/FP16 tuning. Other AArch64
            // targets keep a portable NEON build instead of inheriting an
            // Apple-only CPU name.
            .flags = if (target.result.os.tag == .macos)
                &.{ "-O3", "-mcpu=apple-m1" }
            else
                &.{"-O3"},
        });
        lib.root_module.addCSourceFile(.{
            .file = b.path("src/backends/cpu/progressive_int4_neon.c"),
            .flags = if (target.result.os.tag == .macos)
                &.{ "-O3", "-mcpu=apple-m1" }
            else
                &.{"-O3"},
        });
        lib.root_module.addCSourceFile(.{
            .file = b.path("src/backends/cpu/crc32_arm.c"),
            .flags = if (target.result.os.tag == .macos)
                &.{ "-O3", "-mcpu=apple-m1" }
            else
                &.{"-O3"},
        });
        lib.linkLibC();
        break :blk lib;
    };

    // --- CLI executable ------------------------------------------------------
    const cli_telemetry_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/telemetry.zig"),
        .target = target,
        .optimize = cli_control_optimize,
    });
    const exe = b.addExecutable(.{
        .name = "glacier",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            // The command parser and evidence renderer are a cold control
            // plane. Imported engine/core modules retain the requested
            // ReleaseFast mode, while this shell avoids another Darwin text
            // page and keeps formatter code out of the hot I-cache budget.
            .optimize = cli_control_optimize,
            .strip = strip_production_cli,
        }),
    });
    exe.root_module.addImport("engine", engine_mod);
    exe.root_module.addImport("core", core_mod);
    exe.root_module.addImport("config", config_mod);
    exe.root_module.addImport("cli_telemetry", cli_telemetry_mod);
    // Cached generation uses std.heap.c_allocator for the optional legacy
    // thread pool. Declare libc explicitly even on non-AArch64 targets where
    // no NEON C archive would otherwise pull it in transitively.
    exe.linkLibC();
    if (metal_shim) |shim| {
        exe.linkLibrary(shim);
        exe.linkFramework("Metal");
        exe.linkFramework("Foundation");
    }
    if (int4_neon) |lib| exe.linkLibrary(lib);
    // Zig's compile-time strip policy intentionally preserves local symbols
    // needed by some Darwin tooling. Remove those names from the distributed
    // native macOS CLI without changing __text/__const bytes. This is an
    // artifact-footprint optimization, not a substitute for the separate
    // same-strip code-growth gate; `-Dstrip-production-cli=false` retains the
    // profiling-friendly executable.
    if (strip_production_cli and target.result.os.tag == .macos and
        builtin.os.tag == .macos)
    {
        const strip = b.addSystemCommand(&.{ "xcrun", "strip", "-x", "-o" });
        const stripped = strip.addOutputFileArg("glacier");
        strip.addArtifactArg(exe);
        const install_stripped = b.addInstallBinFile(stripped, "glacier");
        b.getInstallStep().dependOn(&install_stripped.step);
    } else {
        b.installArtifact(exe);
    }

    // --- Unit tests ----------------------------------------------------------
    const core_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/root.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });

    const run_core_tests = b.addRunArtifact(core_tests);

    // Engine-level tests (model + converter + backends) share the engine module.
    const engine_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    engine_tests.root_module.addImport("core", core_mod);
    engine_tests.root_module.addImport("config", config_mod);
    engine_tests.linkLibC();
    if (metal_shim) |shim| {
        engine_tests.linkLibrary(shim);
        engine_tests.linkFramework("Metal");
        engine_tests.linkFramework("Foundation");
    }
    if (int4_neon) |lib| engine_tests.linkLibrary(lib);
    const run_engine_tests = b.addRunArtifact(engine_tests);

    // Focused correctness suite for progressive 1+1+2 INT4 decode.  The
    // scalar oracle remains portable; AArch64 additionally links the NEON
    // archive for direct SIMD-versus-oracle property tests.
    const progressive_int4_mod = b.createModule(.{
        .root_source_file = b.path("src/progressive_int4.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
    });
    const progressive_int4_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/progressive_int4.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    progressive_int4_tests.root_module.addImport("progressive_int4", progressive_int4_mod);
    progressive_int4_tests.linkLibC();
    if (int4_neon) |lib| progressive_int4_tests.linkLibrary(lib);
    const run_progressive_int4_tests = b.addRunArtifact(progressive_int4_tests);

    // Integration tests that exercise the file system.
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/converter_roundtrip.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    integration_tests.root_module.addImport("engine", engine_mod);
    integration_tests.root_module.addImport("core", core_mod);
    integration_tests.root_module.addImport("config", config_mod);
    integration_tests.linkLibC();
    if (metal_shim) |shim| {
        integration_tests.linkLibrary(shim);
        integration_tests.linkFramework("Metal");
        integration_tests.linkFramework("Foundation");
    }
    if (int4_neon) |lib| integration_tests.linkLibrary(lib);
    const run_integration_tests = b.addRunArtifact(integration_tests);

    // Pager ownership/lifetime integration test. Keep it as a separate root so
    // allocator leaks and double frees fail independently of converter I/O.
    const pager_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/pager_integration.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    pager_tests.root_module.addImport("engine", engine_mod);
    pager_tests.root_module.addImport("core", core_mod);
    pager_tests.root_module.addImport("config", config_mod);
    pager_tests.linkLibC();
    if (metal_shim) |shim| {
        pager_tests.linkLibrary(shim);
        pager_tests.linkFramework("Metal");
        pager_tests.linkFramework("Foundation");
    }
    if (int4_neon) |lib| pager_tests.linkLibrary(lib);
    const run_pager_tests = b.addRunArtifact(pager_tests);

    // End-to-end model forward test: synthesize a tiny transformer, convert
    // to .glacier, load, run multi-layer forward, assert logits are finite.
    const model_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/model_forward.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    model_tests.root_module.addImport("engine", engine_mod);
    model_tests.root_module.addImport("core", core_mod);
    model_tests.linkLibC();
    if (int4_neon) |lib| model_tests.linkLibrary(lib);
    const run_model_tests = b.addRunArtifact(model_tests);

    // Grounded DecodeLane4 evidence primitives remain separate from the
    // production CLI: fixed lane-local token journals and the four-request
    // post-commit barrier can therefore be tested without pulling protocol or
    // benchmark rendering into the shipped binary.
    const lane4_runner_core_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/lane4_runner_core.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    lane4_runner_core_tests.root_module.addImport("engine", engine_mod);
    lane4_runner_core_tests.root_module.addImport("core", core_mod);
    lane4_runner_core_tests.linkLibC();
    if (int4_neon) |lib| lane4_runner_core_tests.linkLibrary(lib);
    const run_lane4_runner_core_tests = b.addRunArtifact(
        lane4_runner_core_tests,
    );

    // Actual-model M1x4/B4 observation logic is kept in its own test root so
    // the production CLI remains free of benchmark protocol code. It imports
    // the fixed-capacity evidence primitives as a normal module and exercises
    // timing/resource/cross-arm validation independently of campaign JSON.
    const lane4_runner_core_mod = b.createModule(.{
        .root_source_file = b.path("bench/lane4_runner_core.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
    });
    lane4_runner_core_mod.addImport("engine", engine_mod);
    lane4_runner_core_mod.addImport("core", core_mod);
    const lane4_runner_observation_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/lane4_runner_observation.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    lane4_runner_observation_tests.root_module.addImport("engine", engine_mod);
    lane4_runner_observation_tests.root_module.addImport("core", core_mod);
    lane4_runner_observation_tests.root_module.addImport(
        "lane4_runner_core",
        lane4_runner_core_mod,
    );
    lane4_runner_observation_tests.linkLibC();
    if (int4_neon) |lib| lane4_runner_observation_tests.linkLibrary(lib);
    const run_lane4_runner_observation_tests = b.addRunArtifact(
        lane4_runner_observation_tests,
    );

    // Standalone cross-language raw-event-v3 codec. Keep this root free of
    // engine imports so canonical JSON/hash ABI vectors are cheap to run and
    // can compile on every supported target independently of model backends.
    const lane4_event_wire_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/lane4_event_wire.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    const run_lane4_event_wire_tests = b.addRunArtifact(
        lane4_event_wire_tests,
    );

    // TokenTxn raw-event-v4 is a distinct timestamp-free profile.  It mirrors
    // runner-v6 transaction receipts and deliberately does not relabel or
    // extend the legacy per-lane raw-event-v3 schema.
    const lane4_token_txn_event_wire_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "bench/lane4_token_txn_event_wire.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    const run_lane4_token_txn_event_wire_tests = b.addRunArtifact(
        lane4_token_txn_event_wire_tests,
    );
    const lane4_token_txn_event_wire_mod = b.createModule(.{
        .root_source_file = b.path(
            "bench/lane4_token_txn_event_wire.zig",
        ),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
    });
    const lane4_token_txn_event_adapter_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "bench/lane4_token_txn_event_adapter.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    lane4_token_txn_event_adapter_tests.root_module.addImport(
        "engine",
        engine_mod,
    );
    lane4_token_txn_event_adapter_tests.root_module.addImport(
        "lane4_runner_core",
        lane4_runner_core_mod,
    );
    lane4_token_txn_event_adapter_tests.root_module.addImport(
        "lane4_runner_observation",
        lane4_runner_observation_tests.root_module,
    );
    lane4_token_txn_event_adapter_tests.root_module.addImport(
        "lane4_token_txn_event_wire",
        lane4_token_txn_event_wire_mod,
    );
    lane4_token_txn_event_adapter_tests.linkLibC();
    if (int4_neon) |lib| lane4_token_txn_event_adapter_tests.linkLibrary(lib);
    const run_lane4_token_txn_event_adapter_tests = b.addRunArtifact(
        lane4_token_txn_event_adapter_tests,
    );

    // Metal correctness test (separate so it can link Metal even when other
    // integration tests run on platforms without it). Skips itself at runtime
    // when there is no Metal device or when -Dmetal=false.
    const metal_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/metal_correctness.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    metal_tests.root_module.addImport("engine", engine_mod);
    metal_tests.root_module.addImport("core", core_mod);
    metal_tests.root_module.addImport("config", config_mod);
    metal_tests.linkLibC();
    if (metal_shim) |shim| {
        metal_tests.linkLibrary(shim);
        metal_tests.linkFramework("Metal");
        metal_tests.linkFramework("Foundation");
    }
    if (int4_neon) |lib| metal_tests.linkLibrary(lib);
    const run_metal_tests = b.addRunArtifact(metal_tests);
    // The metal correctness test loads shaders.metallib at runtime; make
    // sure it exists before the test runs.
    if (metal_shim != null) {
        run_metal_tests.step.dependOn(&buildMetalLib(b).step);
    }

    // Pure trace/oracle tests for the actual-model PagedLease runner. The
    // 400 MB model remains an explicitly invoked host artifact, while masks,
    // heterogeneous retirement and exact page geometry stay in ordinary CI.
    const paged_lease_runner_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/paged_lease_runner.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    paged_lease_runner_tests.root_module.addImport("engine", engine_mod);
    paged_lease_runner_tests.root_module.addImport("core", core_mod);
    paged_lease_runner_tests.root_module.addImport(
        "paged_lease_runner_options",
        paged_lease_base_opts_mod,
    );
    paged_lease_runner_tests.linkLibC();
    if (int4_neon) |lib| paged_lease_runner_tests.linkLibrary(lib);
    const run_paged_lease_runner_tests = b.addRunArtifact(
        paged_lease_runner_tests,
    );

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_engine_tests.step);
    test_step.dependOn(&run_progressive_int4_tests.step);
    test_step.dependOn(&run_integration_tests.step);
    test_step.dependOn(&run_pager_tests.step);
    test_step.dependOn(&run_model_tests.step);
    test_step.dependOn(&run_lane4_runner_core_tests.step);
    test_step.dependOn(&run_lane4_runner_observation_tests.step);
    test_step.dependOn(&run_lane4_event_wire_tests.step);
    test_step.dependOn(&run_lane4_token_txn_event_wire_tests.step);
    test_step.dependOn(&run_lane4_token_txn_event_adapter_tests.step);
    test_step.dependOn(&run_metal_tests.step);
    test_step.dependOn(&run_paged_lease_runner_tests.step);

    // Cross targets often cannot execute on the build host. This step compiles
    // every test root without spawning it, providing an honest portability
    // gate instead of relying on CLI-only cross builds.
    const test_compile_step = b.step("test-compile", "Compile all tests without running them");
    test_compile_step.dependOn(&core_tests.step);
    test_compile_step.dependOn(&engine_tests.step);
    test_compile_step.dependOn(&progressive_int4_tests.step);
    test_compile_step.dependOn(&integration_tests.step);
    test_compile_step.dependOn(&pager_tests.step);
    test_compile_step.dependOn(&model_tests.step);
    test_compile_step.dependOn(&lane4_runner_core_tests.step);
    test_compile_step.dependOn(&lane4_runner_observation_tests.step);
    test_compile_step.dependOn(&lane4_event_wire_tests.step);
    test_compile_step.dependOn(&lane4_token_txn_event_wire_tests.step);
    test_compile_step.dependOn(&lane4_token_txn_event_adapter_tests.step);
    test_compile_step.dependOn(&metal_tests.step);
    test_compile_step.dependOn(&paged_lease_runner_tests.step);

    // Model-free deterministic QoS conformance demo. Native tests execute it,
    // cross-target gates compile it, and it is never installed as a production
    // or benchmark binary.
    const lane_weave_demo_exe = b.addExecutable(.{
        .name = "glacier-lane-weave-qos-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/lane_weave_qos.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    lane_weave_demo_exe.root_module.addImport("core", core_mod);
    const run_lane_weave_demo = b.addRunArtifact(lane_weave_demo_exe);
    const lane_weave_demo_step = b.step(
        "lane-weave-demo",
        "Run the model-free LaneWeave QoS conformance demo",
    );
    lane_weave_demo_step.dependOn(&run_lane_weave_demo.step);
    test_step.dependOn(&run_lane_weave_demo.step);
    test_compile_step.dependOn(&lane_weave_demo_exe.step);

    // Backend-neutral one-token publication demo. It exercises the exact
    // LaneWeave receipt, ResourceBank fence, typed AI-state commitments and
    // standalone transcript verifier without loading a model.
    const lane_publication_demo_exe = b.addExecutable(.{
        .name = "glacier-lane-publication-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/lane_publication_txn.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    lane_publication_demo_exe.root_module.addImport("engine", engine_mod);
    const run_lane_publication_demo = b.addRunArtifact(
        lane_publication_demo_exe,
    );
    const lane_publication_demo_step = b.step(
        "lane-publication-demo",
        "Run the verified one-token AI publication demo",
    );
    lane_publication_demo_step.dependOn(&run_lane_publication_demo.step);
    test_step.dependOn(&run_lane_publication_demo.step);
    test_compile_step.dependOn(&lane_publication_demo_exe.step);

    // Concrete contiguous-state publication demo. The first selected token
    // reuses prefill state, while the second atomically publishes one real KV
    // row, RNG/counter advance, output word, and portable receipt.
    const lane_contiguous_demo_exe = b.addExecutable(.{
        .name = "glacier-lane-contiguous-publication-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "examples/lane_contiguous_publication.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    lane_contiguous_demo_exe.root_module.addImport("engine", engine_mod);
    const run_lane_contiguous_demo = b.addRunArtifact(
        lane_contiguous_demo_exe,
    );
    const lane_contiguous_demo_step = b.step(
        "lane-contiguous-demo",
        "Run the concrete contiguous AI-state publication demo",
    );
    lane_contiguous_demo_step.dependOn(&run_lane_contiguous_demo.step);
    test_step.dependOn(&run_lane_contiguous_demo.step);
    test_compile_step.dependOn(&lane_contiguous_demo_exe.step);

    // Fixed-size proof-carrying continuation manifest. It binds nine typed
    // external AI-state objects and rejects substitution without embedding
    // their payloads or receiving filesystem authority.
    const continuation_capsule_demo_exe = b.addExecutable(.{
        .name = "glacier-continuation-capsule-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "examples/continuation_capsule.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    continuation_capsule_demo_exe.root_module.addImport("core", core_mod);
    const run_continuation_capsule_demo = b.addRunArtifact(
        continuation_capsule_demo_exe,
    );
    const continuation_capsule_demo_step = b.step(
        "continuation-capsule-demo",
        "Run the proof-carrying continuation capsule demo",
    );
    continuation_capsule_demo_step.dependOn(
        &run_continuation_capsule_demo.step,
    );
    test_step.dependOn(&run_continuation_capsule_demo.step);
    test_compile_step.dependOn(&continuation_capsule_demo_exe.step);

    // Least-authority resolver for the exact typed object roots committed by
    // one continuation capsule. The demo exercises tenant isolation, quotas,
    // caller-owned output and full-composition verification without I/O.
    const continuation_resolver_demo_exe = b.addExecutable(.{
        .name = "glacier-continuation-object-resolver-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "examples/continuation_object_resolver.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    continuation_resolver_demo_exe.root_module.addImport("core", core_mod);
    const run_continuation_resolver_demo = b.addRunArtifact(
        continuation_resolver_demo_exe,
    );
    const continuation_resolver_demo_step = b.step(
        "continuation-resolver-demo",
        "Run the tenant-scoped continuation object resolver demo",
    );
    continuation_resolver_demo_step.dependOn(
        &run_continuation_resolver_demo.step,
    );
    test_step.dependOn(&run_continuation_resolver_demo.step);
    test_compile_step.dependOn(&continuation_resolver_demo_exe.step);

    // Canonical tenant-scoped bundle manifest for one capsule and its nine
    // objects. It proves deterministic in-tenant blob deduplication without
    // embedding payloads, allocating memory or opening a storage backend.
    const continuation_bundle_demo_exe = b.addExecutable(.{
        .name = "glacier-continuation-bundle-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "examples/continuation_bundle.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    continuation_bundle_demo_exe.root_module.addImport("core", core_mod);
    const run_continuation_bundle_demo = b.addRunArtifact(
        continuation_bundle_demo_exe,
    );
    const continuation_bundle_demo_step = b.step(
        "continuation-bundle-demo",
        "Run the canonical tenant-scoped continuation bundle demo",
    );
    continuation_bundle_demo_step.dependOn(
        &run_continuation_bundle_demo.step,
    );
    test_step.dependOn(&run_continuation_bundle_demo.step);
    test_compile_step.dependOn(&continuation_bundle_demo_exe.step);

    // Bounded in-memory tenant object store. It imports one verified bundle
    // atomically, owns immutable payload copies, reuses duplicate blob roots,
    // and accounts index/payload/reference state without filesystem access.
    const continuation_store_demo_exe = b.addExecutable(.{
        .name = "glacier-continuation-object-store-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "examples/continuation_object_store.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    continuation_store_demo_exe.root_module.addImport("core", core_mod);
    const run_continuation_store_demo = b.addRunArtifact(
        continuation_store_demo_exe,
    );
    const continuation_store_demo_step = b.step(
        "continuation-store-demo",
        "Run the bounded tenant continuation object-store demo",
    );
    continuation_store_demo_step.dependOn(
        &run_continuation_store_demo.step,
    );
    test_step.dependOn(&run_continuation_store_demo.step);
    test_compile_step.dependOn(&continuation_store_demo_exe.step);

    // Deterministic reachability evidence and a dry-run collection plan. The
    // planner proves exact root multiplicity and active-lease coverage while
    // leaving object payloads and accounting untouched.
    const continuation_collection_demo_exe = b.addExecutable(.{
        .name = "glacier-continuation-object-collection-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "examples/continuation_object_collection.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    continuation_collection_demo_exe.root_module.addImport("core", core_mod);
    const run_continuation_collection_demo = b.addRunArtifact(
        continuation_collection_demo_exe,
    );
    const continuation_collection_demo_step = b.step(
        "continuation-collection-demo",
        "Run the continuation reachability and collection-plan demo",
    );
    continuation_collection_demo_step.dependOn(
        &run_continuation_collection_demo.step,
    );
    test_step.dependOn(&run_continuation_collection_demo.step);
    test_compile_step.dependOn(&continuation_collection_demo_exe.step);

    // Capability-scoped prepare/abort journal for a previously approved
    // collection plan. It regenerates the plan and stages totals without
    // mutating or deallocating store payloads.
    const continuation_sweep_demo_exe = b.addExecutable(.{
        .name = "glacier-continuation-object-sweep-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "examples/continuation_object_sweep.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    continuation_sweep_demo_exe.root_module.addImport("core", core_mod);
    const run_continuation_sweep_demo = b.addRunArtifact(
        continuation_sweep_demo_exe,
    );
    const continuation_sweep_demo_step = b.step(
        "continuation-sweep-demo",
        "Run the capability-scoped object sweep journal demo",
    );
    continuation_sweep_demo_step.dependOn(
        &run_continuation_sweep_demo.step,
    );
    test_step.dependOn(&run_continuation_sweep_demo.step);
    test_compile_step.dependOn(&continuation_sweep_demo_exe.step);

    // Credential-free provider control-plane demo. Two exact logical requests
    // share one dispatch permit, one conservative reservation, one
    // authoritative usage settlement, one fixed-point quote/cost record and
    // one locked, body/footer-synced and reopened cost-journal frame.
    const provider_gateway_demo_exe = b.addExecutable(.{
        .name = "glacier-provider-token-gateway-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "examples/provider_token_gateway.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    provider_gateway_demo_exe.root_module.addImport("core", core_mod);
    const run_provider_gateway_demo = b.addRunArtifact(
        provider_gateway_demo_exe,
    );
    const provider_gateway_demo_step = b.step(
        "provider-gateway-demo",
        "Run provider token, cost and append-journal conformance",
    );
    provider_gateway_demo_step.dependOn(&run_provider_gateway_demo.step);
    test_step.dependOn(&run_provider_gateway_demo.step);
    test_compile_step.dependOn(&provider_gateway_demo_exe.step);

    // Credential-free deterministic provider transport conformance demo.
    // Exact chunks and terminal usage flow through the gateway without any
    // network connection, secret or provider-specific SDK.
    const provider_transport_demo_exe = b.addExecutable(.{
        .name = "glacier-provider-transport-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "examples/provider_transport_harness.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    provider_transport_demo_exe.root_module.addImport("core", core_mod);
    const run_provider_transport_demo = b.addRunArtifact(
        provider_transport_demo_exe,
    );
    const provider_transport_demo_step = b.step(
        "provider-transport-demo",
        "Run the credential-free provider transport conformance demo",
    );
    provider_transport_demo_step.dependOn(&run_provider_transport_demo.step);
    test_step.dependOn(&run_provider_transport_demo.step);
    test_compile_step.dependOn(&provider_transport_demo_exe.step);

    // Credential-free active provider cancellation conformance demo.
    const provider_cancel_demo_exe = b.addExecutable(.{
        .name = "glacier-provider-cancel-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "examples/provider_transport_cancel.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    provider_cancel_demo_exe.root_module.addImport("core", core_mod);
    const run_provider_cancel_demo = b.addRunArtifact(
        provider_cancel_demo_exe,
    );
    const provider_cancel_demo_step = b.step(
        "provider-cancel-demo",
        "Run the credential-free active provider cancellation demo",
    );
    provider_cancel_demo_step.dependOn(&run_provider_cancel_demo.step);
    test_step.dependOn(&run_provider_cancel_demo.step);
    test_compile_step.dependOn(&provider_cancel_demo_exe.step);

    // Lossless exact context packing and Gateway admission demo.
    const provider_context_pack_demo_exe = b.addExecutable(.{
        .name = "glacier-provider-context-pack-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "examples/provider_context_pack.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    provider_context_pack_demo_exe.root_module.addImport("core", core_mod);
    const run_provider_context_pack_demo = b.addRunArtifact(
        provider_context_pack_demo_exe,
    );
    const provider_context_pack_demo_step = b.step(
        "provider-context-pack-demo",
        "Run the lossless provider context packing demo",
    );
    provider_context_pack_demo_step.dependOn(
        &run_provider_context_pack_demo.step,
    );
    test_step.dependOn(&run_provider_context_pack_demo.step);
    test_compile_step.dependOn(&provider_context_pack_demo_exe.step);

    // Deterministic full-wire token reconciliation demo. Raw and packed
    // payloads share one tokenizer-execution identity; Gateway admission uses
    // only the independently verified packed wire count.
    const provider_context_reconciliation_demo_exe = b.addExecutable(.{
        .name = "glacier-provider-context-reconciliation-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "examples/provider_context_reconciliation.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    provider_context_reconciliation_demo_exe.root_module.addImport(
        "core",
        core_mod,
    );
    const run_provider_context_reconciliation_demo = b.addRunArtifact(
        provider_context_reconciliation_demo_exe,
    );
    const provider_context_reconciliation_demo_step = b.step(
        "provider-context-reconciliation-demo",
        "Run the full-wire provider context token reconciliation demo",
    );
    provider_context_reconciliation_demo_step.dependOn(
        &run_provider_context_reconciliation_demo.step,
    );
    test_step.dependOn(&run_provider_context_reconciliation_demo.step);
    test_compile_step.dependOn(
        &provider_context_reconciliation_demo_exe.step,
    );

    // Allocation-free provider renderer/token-counter adapter demo. Core
    // hashes and counts exact scratch bytes, replays execution and admits only
    // the reconciled packed wire through Gateway.
    const provider_context_adapter_demo_exe = b.addExecutable(.{
        .name = "glacier-provider-context-adapter-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "examples/provider_context_adapter.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    provider_context_adapter_demo_exe.root_module.addImport(
        "core",
        core_mod,
    );
    const run_provider_context_adapter_demo = b.addRunArtifact(
        provider_context_adapter_demo_exe,
    );
    const provider_context_adapter_demo_step = b.step(
        "provider-context-adapter-demo",
        "Run the allocation-free provider context adapter demo",
    );
    provider_context_adapter_demo_step.dependOn(
        &run_provider_context_adapter_demo.step,
    );
    test_step.dependOn(&run_provider_context_adapter_demo.step);
    test_compile_step.dependOn(&provider_context_adapter_demo_exe.step);

    // --- Benchmark -----------------------------------------------------------
    const bench_exe = b.addExecutable(.{
        .name = "glacier-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bench_exe.root_module.addImport("engine", engine_mod);
    bench_exe.root_module.addImport("core", core_mod);
    bench_exe.linkLibC();
    if (int4_neon) |lib| bench_exe.linkLibrary(lib);
    b.installArtifact(bench_exe);

    // Same-process actual-model DecodeLane4 smoke driver. This is a diagnostic
    // evidence producer, not part of the production CLI and not by itself a
    // publication-grade ABBA/power/physical-resource campaign.
    const lane4_bench_exe = b.addExecutable(.{
        .name = "glacier-bench-lane4",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/lane4_runner.zig"),
            .target = target,
            .optimize = optimize,
            // The retained runner identity needs executable code and exact
            // artifact bytes, not debug sections. Follow the release strip
            // policy while keeping `-Dstrip-production-cli=false` available
            // for profiler-friendly local builds.
            .strip = strip_production_cli,
        }),
    });
    lane4_bench_exe.root_module.addImport("engine", engine_mod);
    lane4_bench_exe.root_module.addImport("core", core_mod);
    lane4_bench_exe.root_module.addImport(
        "lane4_runner_observation",
        lane4_runner_observation_tests.root_module,
    );
    lane4_bench_exe.root_module.addImport(
        "lane4_runner_core",
        lane4_runner_core_mod,
    );
    lane4_bench_exe.linkLibC();
    if (int4_neon) |lib| lane4_bench_exe.linkLibrary(lib);
    if (strip_production_cli and target.result.os.tag == .macos and
        builtin.os.tag == .macos)
    {
        const strip = b.addSystemCommand(&.{ "xcrun", "strip", "-x", "-o" });
        const stripped = strip.addOutputFileArg("glacier-bench-lane4");
        strip.addArtifactArg(lane4_bench_exe);
        const install_stripped = b.addInstallBinFile(
            stripped,
            "glacier-bench-lane4",
        );
        b.getInstallStep().dependOn(&install_stripped.step);
    } else {
        b.installArtifact(lane4_bench_exe);
    }

    // Actual-model P2b diagnostic. It loads one image and produces an
    // orderable strict-contiguous/strict-paged pair with exact terminal-state
    // equality and separate capacity/resident ledgers.
    const paged_lane4_bench_exe = b.addExecutable(.{
        .name = "glacier-bench-paged-lane4",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/paged_lane4_runner.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip_production_cli,
        }),
    });
    paged_lane4_bench_exe.root_module.addImport("engine", engine_mod);
    paged_lane4_bench_exe.root_module.addImport("core", core_mod);
    paged_lane4_bench_exe.linkLibC();
    if (int4_neon) |lib| paged_lane4_bench_exe.linkLibrary(lib);
    b.installArtifact(paged_lane4_bench_exe);

    // P2c-a actual-model diagnostic. It compares the legacy full-capacity
    // parent receipt with the optional child-sidecar allocator-commitment arm
    // and can isolate either role in a fresh process for external sampling.
    const paged_resident_bench_exe = b.addExecutable(.{
        .name = "glacier-bench-paged-resident",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/paged_resident_runner.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip_production_cli,
        }),
    });
    paged_resident_bench_exe.root_module.addImport("engine", engine_mod);
    paged_resident_bench_exe.root_module.addImport("core", core_mod);
    paged_resident_bench_exe.linkLibC();
    if (int4_neon) |lib| paged_resident_bench_exe.linkLibrary(lib);
    b.installArtifact(paged_resident_bench_exe);

    // Actual-model P2c-b evidence source. The base executable compares
    // retain-until-teardown with immediate terminal reclamation for one
    // heterogeneous-EOS cohort; the explicit admission identity below freezes
    // that cohort after wave zero and schedules a second cohort on the same
    // live Bank.
    const paged_lease_bench_exe = b.addExecutable(.{
        .name = "glacier-bench-paged-lease",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/paged_lease_runner.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip_production_cli,
        }),
    });
    paged_lease_bench_exe.root_module.addImport("engine", engine_mod);
    paged_lease_bench_exe.root_module.addImport("core", core_mod);
    paged_lease_bench_exe.root_module.addImport(
        "paged_lease_runner_options",
        paged_lease_base_opts_mod,
    );
    paged_lease_bench_exe.linkLibC();
    if (int4_neon) |lib| paged_lease_bench_exe.linkLibrary(lib);
    b.installArtifact(paged_lease_bench_exe);

    // Same production source path, but an explicit executable identity selects
    // the two-cohort actual-model CLI. Cohort A yields only after its exact
    // TokenTxn publication and configured terminal reclaim are quiescent;
    // cohort B then competes against the same live ResourceBank.
    const paged_lease_admission_bench_exe = b.addExecutable(.{
        .name = "glacier-bench-paged-lease-admission",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/paged_lease_runner.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip_production_cli,
        }),
    });
    paged_lease_admission_bench_exe.root_module.addImport(
        "engine",
        engine_mod,
    );
    paged_lease_admission_bench_exe.root_module.addImport("core", core_mod);
    paged_lease_admission_bench_exe.root_module.addImport(
        "paged_lease_runner_options",
        paged_lease_admission_opts_mod,
    );
    paged_lease_admission_bench_exe.linkLibC();
    if (int4_neon) |lib| paged_lease_admission_bench_exe.linkLibrary(lib);
    b.installArtifact(paged_lease_admission_bench_exe);

    // Microbenchmark for the packed INT4 decode kernels.  It is kept as a
    // separate executable so end-to-end generation timings are not confused
    // with projection-kernel timings.
    const int4_kernel_bench_exe = b.addExecutable(.{
        .name = "glacier-bench-int4",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/int4_kernel.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    int4_kernel_bench_exe.root_module.addImport("engine", engine_mod);
    int4_kernel_bench_exe.root_module.addImport("core", core_mod);
    int4_kernel_bench_exe.linkLibC();
    if (int4_neon) |lib| int4_kernel_bench_exe.linkLibrary(lib);
    b.installArtifact(int4_kernel_bench_exe);

    // Same-process full-versus-eligible LM-head benchmark over a real GLRT
    // image. Its deterministic synthetic activation keeps this an isolated
    // kernel/API claim rather than an end-to-end decode benchmark.
    const eligible_argmax_bench_exe = b.addExecutable(.{
        .name = "glacier-bench-eligible",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/eligible_argmax.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    eligible_argmax_bench_exe.root_module.addImport("engine", engine_mod);
    eligible_argmax_bench_exe.root_module.addImport("core", core_mod);
    eligible_argmax_bench_exe.linkLibC();
    if (int4_neon) |lib| eligible_argmax_bench_exe.linkLibrary(lib);
    b.installArtifact(eligible_argmax_bench_exe);

    // Isolated Prism P1/P2/P4 bitplane microbenchmark.  This reports scalar
    // oracle versus architecture-dispatched kernel timings without conflating
    // them with model loading or generation scheduler work.
    const progressive_kernel_bench_exe = b.addExecutable(.{
        .name = "glacier-bench-prism",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/progressive_int4_kernel.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    progressive_kernel_bench_exe.root_module.addImport("progressive_int4", progressive_int4_mod);
    progressive_kernel_bench_exe.linkLibC();
    if (int4_neon) |lib| progressive_kernel_bench_exe.linkLibrary(lib);
    b.installArtifact(progressive_kernel_bench_exe);

    // Optional Metal persistent-weight microbenchmark. The executable is
    // still built on every platform, but only links the Objective-C shim when
    // the target has Metal enabled.
    const metal_kernel_bench_exe = b.addExecutable(.{
        .name = "glacier-bench-metal",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/metal_kernel.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    metal_kernel_bench_exe.root_module.addImport("engine", engine_mod);
    metal_kernel_bench_exe.root_module.addImport("core", core_mod);
    metal_kernel_bench_exe.linkLibC();
    if (metal_shim) |shim| {
        metal_kernel_bench_exe.linkLibrary(shim);
        metal_kernel_bench_exe.linkFramework("Metal");
        metal_kernel_bench_exe.linkFramework("Foundation");
    }
    b.installArtifact(metal_kernel_bench_exe);

    // --- Quant-error benchmark (independent exe) -----------------------------
    const quant_bench_exe = b.addExecutable(.{
        .name = "glacier-bench-quant",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/quant_error.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    quant_bench_exe.root_module.addImport("engine", engine_mod);
    quant_bench_exe.root_module.addImport("core", core_mod);
    quant_bench_exe.linkLibC();
    if (int4_neon) |lib| quant_bench_exe.linkLibrary(lib);
    b.installArtifact(quant_bench_exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the glacier CLI");
    run_step.dependOn(&run_cmd.step);

    // --- Metal shader compilation (macOS only, opt-in) -----------------------
    // `zig build metal-lib` compiles the .metal shaders to a .metallib and
    // the Objective-C shim to a static archive. The artifacts are placed in
    // zig-out/metal/. The Zig Metal backend reads the .metallib path at
    // runtime; this step does not link anything into the main exes by default.
    if (target.result.os.tag == .macos) {
        const metal_step = b.step("metal-lib", "Compile Metal shaders + Obj-C shim (macOS)");
        metal_step.dependOn(&buildMetalLib(b).step);
        metal_step.dependOn(&buildShimArchive(b).step);
    }
}

/// Compile src/backends/metal/shaders/*.metal → zig-out/shaders.metallib.
fn buildMetalLib(b: *std.Build) *std.Build.Step.Run {
    const mkdir = b.addSystemCommand(&.{ "mkdir", "-p", "zig-out/metal" });

    // Compile both dequant and matmul shaders into separate .air files,
    // then link them into a single .metallib.
    const compile_dequant = b.addSystemCommand(&.{
        "xcrun",                     "-sdk", "macosx",                                   "metal",
        "-std=metal3.0",             "-c",   "src/backends/metal/shaders/dequant.metal", "-o",
        "zig-out/metal/dequant.air",
    });
    compile_dequant.step.dependOn(&mkdir.step);

    const compile_matmul = b.addSystemCommand(&.{
        "xcrun",                    "-sdk", "macosx",                                  "metal",
        "-std=metal3.0",            "-c",   "src/backends/metal/shaders/matmul.metal", "-o",
        "zig-out/metal/matmul.air",
    });
    compile_matmul.step.dependOn(&mkdir.step);

    const compile_metallib = b.addSystemCommand(&.{
        "xcrun",                     "-sdk",                     "macosx", "metallib",
        "zig-out/metal/dequant.air", "zig-out/metal/matmul.air", "-o",     "zig-out/metal/shaders.metallib",
    });
    compile_metallib.step.dependOn(&compile_dequant.step);
    compile_metallib.step.dependOn(&compile_matmul.step);
    return compile_metallib;
}

/// Compile src/backends/metal/shim.m → zig-out/metal/shim.o.
fn buildShimArchive(b: *std.Build) *std.Build.Step.Run {
    const mkdir = b.addSystemCommand(&.{ "mkdir", "-p", "zig-out/metal" });
    const compile = b.addSystemCommand(&.{
        "xcrun",                "-sdk",                      "macosx",
        "clang",                "-fobjc-arc",                "-framework",
        "Metal",                "-framework",                "Foundation",
        "-c",                   "src/backends/metal/shim.m", "-o",
        "zig-out/metal/shim.o",
    });
    compile.step.dependOn(&mkdir.step);
    return compile;
}
