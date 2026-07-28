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
    const metal_output_dir = b.option(
        []const u8,
        "metal-output-dir",
        "Directory for generated Metal shader products",
    ) orelse "zig-out/metal";
    if (metal_output_dir.len == 0)
        @panic("-Dmetal-output-dir must not be empty");
    const native_metal_report_output = b.option(
        []const u8,
        "native-metal-report-output",
        "Optional path that retains the focused native Metal workload report wire",
    );
    if (native_metal_report_output) |path| {
        if (path.len == 0)
            @panic("-Dnative-metal-report-output must not be empty");
    }
    const native_metal_suite_report_output = b.option(
        []const u8,
        "native-metal-suite-report-output",
        "Optional path that retains the serialized-suite native Metal workload report wire",
    );
    if (native_metal_suite_report_output) |path| {
        if (path.len == 0)
            @panic("-Dnative-metal-suite-report-output must not be empty");
    }
    const native_metal_disruption_report_output = b.option(
        []const u8,
        "native-metal-disruption-report-output",
        "Optional path that retains the focused native Metal disruption report wire",
    );
    if (native_metal_disruption_report_output) |path| {
        if (path.len == 0)
            @panic("-Dnative-metal-disruption-report-output must not be empty");
    }
    const native_metal_cancellation_storm_report_output = b.option(
        []const u8,
        "native-metal-cancellation-storm-report-output",
        "Optional path that retains the focused native Metal cancellation-storm report wire",
    );
    if (native_metal_cancellation_storm_report_output) |path| {
        if (path.len == 0)
            @panic(
                "-Dnative-metal-cancellation-storm-report-output must not be empty",
            );
    }
    const native_metal_soak_output_dir = b.option(
        []const u8,
        "native-metal-soak-output-dir",
        "Optional directory that retains the verified native Metal soak campaign store",
    );
    if (native_metal_soak_output_dir) |path| {
        if (path.len == 0)
            @panic("-Dnative-metal-soak-output-dir must not be empty");
    }
    const native_metal_process_kill_output_dir = b.option(
        []const u8,
        "native-metal-process-kill-output-dir",
        "Optional directory that retains the verified native Metal process-kill campaign store",
    );
    if (native_metal_process_kill_output_dir) |path| {
        if (path.len == 0)
            @panic(
                "-Dnative-metal-process-kill-output-dir must not be empty",
            );
    }
    const native_metal_inflight_process_kill_report_output = b.option(
        []const u8,
        "native-metal-inflight-process-kill-report-output",
        "Optional path that retains the verified event-blocked native Metal process-kill report",
    );
    if (native_metal_inflight_process_kill_report_output) |path| {
        if (path.len == 0)
            @panic(
                "-Dnative-metal-inflight-process-kill-report-output must not be empty",
            );
    }
    const native_metal_supervisor_recovery_death_output_dir = b.option(
        []const u8,
        "native-metal-supervisor-recovery-death-output-dir",
        "Optional directory that retains the verified supervisor/recovery-death report and campaign store",
    );
    if (native_metal_supervisor_recovery_death_output_dir) |path| {
        if (path.len == 0)
            @panic(
                "-Dnative-metal-supervisor-recovery-death-output-dir must not be empty",
            );
    }
    const native_workload_store_fault_output = b.option(
        []const u8,
        "native-workload-store-fault-output",
        "Optional path that retains the native workload store-fault report wire",
    );
    if (native_workload_store_fault_output) |path| {
        if (path.len == 0)
            @panic(
                "-Dnative-workload-store-fault-output must not be empty",
            );
    }
    if (native_metal_report_output != null and
        native_metal_suite_report_output != null)
        @panic(
            "-Dnative-metal-report-output and " ++
                "-Dnative-metal-suite-report-output are mutually exclusive",
        );
    const metal_library_path = b.allocator.dupeZ(
        u8,
        b.fmt("{s}/shaders.metallib", .{metal_output_dir}),
    ) catch @panic("out of memory");
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
    opts.addOption(
        [:0]const u8,
        "metal_library_path",
        metal_library_path,
    );
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
    const core_mod = b.addModule("glacier_core", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
    });

    // --- Main engine module (composes core + backends) -----------------------
    const engine_mod = b.addModule("glacier", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
    });
    engine_mod.addImport("core", core_mod);
    engine_mod.addImport("config", config_mod);

    // --- Experimental language interop --------------------------------------
    // Keep the first non-Zig boundary narrow: it verifies the already
    // versioned, pointer-free Model Contract V1 wires and imports only the
    // hardware-independent core. The static artifact has a distinct name so
    // its Windows .lib cannot collide with the shared library's import .lib.
    const contract_shared_mod = b.createModule(.{
        .root_source_file = b.path("src/ffi/model_contract_c.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
    });
    contract_shared_mod.addImport("glacier_core", core_mod);
    const contract_shared = b.addLibrary(.{
        .name = "glacier_contract",
        .linkage = .dynamic,
        .root_module = contract_shared_mod,
    });
    contract_shared.installHeader(
        b.path("include/glacier/model_contract.h"),
        "glacier/model_contract.h",
    );

    const contract_static_mod = b.createModule(.{
        .root_source_file = b.path("src/ffi/model_contract_c.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
    });
    contract_static_mod.addImport("glacier_core", core_mod);
    const contract_static = b.addLibrary(.{
        .name = "glacier_contract_static",
        .linkage = .static,
        .root_module = contract_static_mod,
    });

    const install_contract_shared = b.addInstallArtifact(
        contract_shared,
        .{},
    );
    const install_contract_static = b.addInstallArtifact(
        contract_static,
        .{},
    );
    const contract_install_step = b.step(
        "contract-c",
        "Install the experimental C contract libraries and header",
    );
    contract_install_step.dependOn(&install_contract_shared.step);
    contract_install_step.dependOn(&install_contract_static.step);

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
    const metal_lib: ?*std.Build.Step.Run =
        if (target.result.os.tag == .macos)
            buildMetalLib(b, metal_output_dir)
        else
            null;

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

    // Native requirements belong to the exported module so dependency
    // consumers inherit the same link graph as project-owned executables.
    // Keep glacier_core free of these requirements.
    engine_mod.link_libc = true;
    if (metal_shim) |shim| {
        engine_mod.linkLibrary(shim);
        engine_mod.linkFramework("Metal", .{});
        engine_mod.linkFramework("Foundation", .{});
    }
    if (int4_neon) |lib| engine_mod.linkLibrary(lib);

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

    // A dependency consumer should be able to import the public package
    // modules without depending on the CLI, demos, or benchmark executables.
    const package_module_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/package_module.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    package_module_tests.root_module.addImport("glacier", engine_mod);
    package_module_tests.root_module.addImport("glacier_core", core_mod);
    const run_package_module_tests = b.addRunArtifact(package_module_tests);
    const package_module_test_step = b.step(
        "package-module-test",
        "Verify the exported glacier and glacier_core package modules",
    );
    package_module_test_step.dependOn(&run_package_module_tests.step);

    // Deterministic compatibility registry inspector. It reports only the
    // retained reference fixtures compiled into glacier_core and deliberately
    // does not probe host backends or claim production-model support.
    const runtime_support_inspector_exe = b.addExecutable(.{
        .name = "glacier-runtime-support-inspector",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "src/cli/runtime_support_inspector.zig",
            ),
            .target = target,
            .optimize = cli_control_optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    runtime_support_inspector_exe.root_module.addImport(
        "glacier_core",
        core_mod,
    );
    const run_runtime_support_inspector =
        b.addRunArtifact(runtime_support_inspector_exe);
    if (b.args) |args| run_runtime_support_inspector.addArgs(args);
    const runtime_support_inspector_run_step = b.step(
        "runtime-support-inspector",
        "Print the deterministic retained-fixture compatibility registry",
    );
    runtime_support_inspector_run_step.dependOn(
        &run_runtime_support_inspector.step,
    );

    const runtime_support_inspector_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "src/cli/runtime_support_inspector.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    runtime_support_inspector_tests.root_module.addImport(
        "glacier_core",
        core_mod,
    );
    const run_runtime_support_inspector_tests =
        b.addRunArtifact(runtime_support_inspector_tests);
    const runtime_support_inspector_test_step = b.step(
        "runtime-support-inspector-test",
        "Run focused runtime support registry and inspector tests",
    );
    runtime_support_inspector_test_step.dependOn(
        &run_runtime_support_inspector_tests.step,
    );
    const runtime_support_inspector_compile_step = b.step(
        "runtime-support-inspector-compile",
        "Compile the runtime support registry inspector without running it",
    );
    runtime_support_inspector_compile_step.dependOn(
        &runtime_support_inspector_exe.step,
    );
    runtime_support_inspector_compile_step.dependOn(
        &runtime_support_inspector_tests.step,
    );
    const run_runtime_support_inspector_oracle =
        b.addSystemCommand(&.{"python3"});
    run_runtime_support_inspector_oracle.setCwd(b.path("."));
    run_runtime_support_inspector_oracle.setEnvironmentVariable(
        "PYTHONDONTWRITEBYTECODE",
        "1",
    );
    run_runtime_support_inspector_oracle.addFileArg(
        b.path("bench/runtime_support_registry.py"),
    );
    run_runtime_support_inspector_oracle.addArg("--inspector");
    run_runtime_support_inspector_oracle.addArtifactArg(
        runtime_support_inspector_exe,
    );
    runtime_support_inspector_test_step.dependOn(
        &run_runtime_support_inspector_oracle.step,
    );

    // Read-only outer-envelope inspector for compact provider evidence joins.
    // It deliberately reports that nested composition is unverified and grants
    // no authority; the independent Python oracle retains that claim boundary.
    const provider_evidence_inspector_exe = b.addExecutable(.{
        .name = "glacier-provider-evidence-inspector",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "src/cli/provider_evidence_inspector.zig",
            ),
            .target = target,
            .optimize = cli_control_optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    provider_evidence_inspector_exe.root_module.addImport(
        "glacier_core",
        core_mod,
    );
    const run_provider_evidence_inspector =
        b.addRunArtifact(provider_evidence_inspector_exe);
    if (b.args) |args| run_provider_evidence_inspector.addArgs(args);
    const provider_evidence_inspector_run_step = b.step(
        "provider-evidence-inspector",
        "Validate and render one provider join outer envelope",
    );
    provider_evidence_inspector_run_step.dependOn(
        &run_provider_evidence_inspector.step,
    );

    const provider_evidence_inspector_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "src/cli/provider_evidence_inspector.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    provider_evidence_inspector_tests.root_module.addImport(
        "glacier_core",
        core_mod,
    );
    const run_provider_evidence_inspector_tests =
        b.addRunArtifact(provider_evidence_inspector_tests);
    const run_provider_evidence_inspector_oracle =
        b.addSystemCommand(&.{"python3"});
    run_provider_evidence_inspector_oracle.setCwd(b.path("."));
    run_provider_evidence_inspector_oracle.setEnvironmentVariable(
        "PYTHONDONTWRITEBYTECODE",
        "1",
    );
    run_provider_evidence_inspector_oracle.setEnvironmentVariable(
        "PYTHONPATH",
        ".",
    );
    run_provider_evidence_inspector_oracle.addFileArg(
        b.path("bench/provider_evidence_inspector.py"),
    );
    run_provider_evidence_inspector_oracle.addArg("--inspector");
    run_provider_evidence_inspector_oracle.addArtifactArg(
        provider_evidence_inspector_exe,
    );
    const provider_evidence_inspector_test_step = b.step(
        "provider-evidence-inspector-test",
        "Run provider join outer-inspector tests and independent oracle",
    );
    provider_evidence_inspector_test_step.dependOn(
        &run_provider_evidence_inspector_tests.step,
    );
    provider_evidence_inspector_test_step.dependOn(
        &run_provider_evidence_inspector_oracle.step,
    );
    const provider_evidence_inspector_compile_step = b.step(
        "provider-evidence-inspector-compile",
        "Compile the provider evidence inspector without running it",
    );
    provider_evidence_inspector_compile_step.dependOn(
        &provider_evidence_inspector_exe.step,
    );
    provider_evidence_inspector_compile_step.dependOn(
        &provider_evidence_inspector_tests.step,
    );

    // Verify the experimental C boundary in three independent ways: the Zig
    // implementation tests its fail-closed status behavior, a C11 consumer
    // compiles against the installed-shape header and static library, and a
    // standard-library-only Python process loads the shared library.
    const contract_c_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ffi/model_contract_c.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    contract_c_tests.root_module.addImport("glacier_core", core_mod);
    const run_contract_c_tests = b.addRunArtifact(contract_c_tests);

    const contract_c_consumer = b.addExecutable(.{
        .name = "glacier-contract-c-consumer",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    contract_c_consumer.root_module.addCSourceFile(.{
        .file = b.path("tests/model_contract_c_consumer.c"),
        .flags = &.{
            "-std=c11",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-DGLACIER_MODEL_CONTRACT_STATIC=1",
        },
    });
    contract_c_consumer.root_module.addIncludePath(b.path("include"));
    contract_c_consumer.linkLibrary(contract_static);
    contract_c_consumer.linkLibC();
    const run_contract_c_consumer = b.addRunArtifact(contract_c_consumer);
    run_contract_c_consumer.addFileArg(
        b.path("examples/interop/fixtures/artifact_manifest_v1.hex"),
    );
    run_contract_c_consumer.addFileArg(
        b.path("examples/interop/fixtures/execution_plan_v1.hex"),
    );
    run_contract_c_consumer.addFileArg(
        b.path("examples/interop/fixtures/result_envelope_v1.hex"),
    );

    // Compile the same consumer against the shared artifact without the
    // static-header define. This retains the Windows dllimport/import-library
    // path even though foreign-target executables are compile-only evidence.
    const contract_c_shared_consumer = b.addExecutable(.{
        .name = "glacier-contract-c-shared-consumer",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    contract_c_shared_consumer.root_module.addCSourceFile(.{
        .file = b.path("tests/model_contract_c_consumer.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });
    contract_c_shared_consumer.root_module.addIncludePath(b.path("include"));
    contract_c_shared_consumer.linkLibrary(contract_shared);
    contract_c_shared_consumer.linkLibC();

    const contract_cpp_consumer = b.addExecutable(.{
        .name = "glacier-contract-cpp-consumer",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    contract_cpp_consumer.root_module.addCSourceFile(.{
        .file = b.path("tests/model_contract_cpp_consumer.cpp"),
        .flags = &.{
            "-std=c++17",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-fno-exceptions",
            "-fno-rtti",
            "-DGLACIER_MODEL_CONTRACT_STATIC=1",
        },
    });
    contract_cpp_consumer.root_module.addIncludePath(b.path("include"));
    contract_cpp_consumer.linkLibrary(contract_static);
    contract_cpp_consumer.linkLibC();
    const run_contract_cpp_consumer =
        b.addRunArtifact(contract_cpp_consumer);

    // This second C executable consumes the staged install tree rather than
    // source headers or a direct build-graph library. It catches install-path,
    // stale-header, archive-name, and permission regressions in the focused
    // native gate.
    const contract_installed_c_consumer = b.addExecutable(.{
        .name = "glacier-contract-installed-c-consumer",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    contract_installed_c_consumer.root_module.addCSourceFile(.{
        .file = b.path("tests/model_contract_c_consumer.c"),
        .flags = &.{
            "-std=c11",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-DGLACIER_MODEL_CONTRACT_STATIC=1",
        },
    });
    contract_installed_c_consumer.root_module.addIncludePath(.{
        .cwd_relative = b.h_dir,
    });
    contract_installed_c_consumer.root_module.addObjectFile(.{
        .cwd_relative = b.getInstallPath(
            .lib,
            install_contract_static.dest_sub_path,
        ),
    });
    contract_installed_c_consumer.linkLibC();
    contract_installed_c_consumer.step.dependOn(
        &install_contract_shared.step,
    );
    contract_installed_c_consumer.step.dependOn(
        &install_contract_static.step,
    );
    const run_contract_installed_c_consumer =
        b.addRunArtifact(contract_installed_c_consumer);
    run_contract_installed_c_consumer.addFileArg(
        b.path("examples/interop/fixtures/artifact_manifest_v1.hex"),
    );
    run_contract_installed_c_consumer.addFileArg(
        b.path("examples/interop/fixtures/execution_plan_v1.hex"),
    );
    run_contract_installed_c_consumer.addFileArg(
        b.path("examples/interop/fixtures/result_envelope_v1.hex"),
    );

    const contract_c_test_step = b.step(
        "contract-c-test",
        "Run focused Zig and installed C/C++ contract ABI tests",
    );
    contract_c_test_step.dependOn(&run_contract_c_tests.step);
    contract_c_test_step.dependOn(&run_contract_c_consumer.step);
    contract_c_test_step.dependOn(&run_contract_cpp_consumer.step);
    contract_c_test_step.dependOn(
        &run_contract_installed_c_consumer.step,
    );

    const contract_c_compile_step = b.step(
        "contract-c-compile",
        "Compile the contract libraries and C/C++ consumers without running",
    );
    contract_c_compile_step.dependOn(&contract_shared.step);
    contract_c_compile_step.dependOn(&contract_static.step);
    contract_c_compile_step.dependOn(&contract_c_tests.step);
    contract_c_compile_step.dependOn(&contract_c_consumer.step);
    contract_c_compile_step.dependOn(&contract_c_shared_consumer.step);
    contract_c_compile_step.dependOn(&contract_cpp_consumer.step);
    contract_c_compile_step.dependOn(
        runtime_support_inspector_compile_step,
    );

    const run_contract_fixture_oracle = b.addSystemCommand(&.{
        "python3",
        "-m",
        "unittest",
        "bench.tests.test_model_contract_interop",
    });
    run_contract_fixture_oracle.setCwd(b.path("."));
    run_contract_fixture_oracle.setEnvironmentVariable(
        "PYTHONDONTWRITEBYTECODE",
        "1",
    );

    const run_contract_python = b.addSystemCommand(&.{"python3"});
    run_contract_python.setEnvironmentVariable(
        "PYTHONDONTWRITEBYTECODE",
        "1",
    );
    run_contract_python.addFileArg(
        b.path("examples/interop/python_verify.py"),
    );
    run_contract_python.addArg("--library");
    run_contract_python.addArtifactArg(contract_shared);
    run_contract_python.addArg("--fixtures");
    run_contract_python.addDirectoryArg(
        b.path("examples/interop/fixtures"),
    );
    const contract_python_test_step = b.step(
        "contract-python-test",
        "Verify the shared contract library through Python ctypes",
    );
    contract_python_test_step.dependOn(&run_contract_fixture_oracle.step);
    contract_python_test_step.dependOn(&run_contract_python.step);

    const contract_rust_test_step = b.step(
        "contract-rust-test",
        "Compile and run the dependency-free Rust contract consumer",
    );
    if (target.result.cpu.arch == builtin.cpu.arch and
        target.result.os.tag == builtin.os.tag and
        target.result.abi == builtin.abi and
        (builtin.os.tag == .macos or
            builtin.os.tag == .linux or
            builtin.os.tag == .freebsd))
    {
        const compile_contract_rust = b.addSystemCommand(&.{"rustc"});
        compile_contract_rust.addFileArg(
            b.path("examples/interop/rust_verify.rs"),
        );
        compile_contract_rust.addArg("-L");
        compile_contract_rust.addArg(
            b.fmt("native={s}", .{b.lib_dir}),
        );
        compile_contract_rust.addArg("-C");
        compile_contract_rust.addArg(
            b.fmt("link-arg=-Wl,-rpath,{s}", .{b.lib_dir}),
        );
        compile_contract_rust.addArg("-o");
        const contract_rust_exe =
            compile_contract_rust.addOutputFileArg(
                "glacier-contract-rust",
            );
        compile_contract_rust.step.dependOn(
            &install_contract_shared.step,
        );

        const run_contract_rust = b.addSystemCommand(&.{"env"});
        run_contract_rust.addFileArg(contract_rust_exe);
        run_contract_rust.addArg("--fixtures");
        run_contract_rust.addDirectoryArg(
            b.path("examples/interop/fixtures"),
        );
        contract_rust_test_step.dependOn(&run_contract_rust.step);
    } else {
        const rust_target_failure = b.addFail(
            "contract-rust-test requires a native macOS, Linux, or FreeBSD " ++
                "target and a rustc executable on PATH",
        );
        contract_rust_test_step.dependOn(&rust_target_failure.step);
    }

    const contract_interop_test_step = b.step(
        "contract-interop-test",
        "Run the focused Zig, C/C++, and Python contract interop tests",
    );
    contract_interop_test_step.dependOn(&run_contract_c_tests.step);
    contract_interop_test_step.dependOn(&run_contract_c_consumer.step);
    contract_interop_test_step.dependOn(&run_contract_cpp_consumer.step);
    contract_interop_test_step.dependOn(
        &run_contract_installed_c_consumer.step,
    );
    contract_interop_test_step.dependOn(&run_contract_fixture_oracle.step);
    contract_interop_test_step.dependOn(&run_contract_python.step);
    contract_interop_test_step.dependOn(
        &run_runtime_support_inspector_oracle.step,
    );

    // Allocation-free canonical PNG/WAVE/APNG delivery profiles plus the
    // additive generated-media conformance sidecar.
    const media_external_format_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "src/media/generated_media_format_conformance.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    media_external_format_tests.root_module.addImport("core", core_mod);
    const run_media_external_format_tests =
        b.addRunArtifact(media_external_format_tests);
    const media_external_format_test_step = b.step(
        "media-external-format-test",
        "Run canonical PNG/WAVE/APNG and format-evidence tests",
    );
    media_external_format_test_step.dependOn(
        &run_media_external_format_tests.step,
    );
    const media_external_format_test_compile_step = b.step(
        "media-external-format-test-compile",
        "Compile canonical media-format tests without running them",
    );
    media_external_format_test_compile_step.dependOn(
        &media_external_format_tests.step,
    );

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
    const run_native_metal_correctness_tests =
        b.addRunArtifact(metal_tests);
    // The metal correctness test loads shaders.metallib at runtime; make
    // sure it exists before the test runs.
    if (metal_shim != null) {
        run_metal_tests.step.dependOn(&metal_lib.?.step);
        run_native_metal_correctness_tests.step.dependOn(
            &metal_lib.?.step,
        );
    }
    const native_metal_correctness_test_step = b.step(
        "native-metal-correctness-test",
        "Run focused native Metal correctness tests",
    );
    native_metal_correctness_test_step.dependOn(
        &run_native_metal_correctness_tests.step,
    );

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
    test_step.dependOn(&run_package_module_tests.step);
    test_step.dependOn(&run_runtime_support_inspector_tests.step);
    test_step.dependOn(provider_evidence_inspector_test_step);
    test_step.dependOn(&run_media_external_format_tests.step);
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
    test_step.dependOn(&run_contract_c_tests.step);
    test_step.dependOn(&run_contract_c_consumer.step);
    test_step.dependOn(&run_contract_cpp_consumer.step);

    // Cross targets often cannot execute on the build host. This step compiles
    // every test root without spawning it, providing an honest portability
    // gate instead of relying on CLI-only cross builds.
    const test_compile_step = b.step("test-compile", "Compile all tests without running them");
    test_compile_step.dependOn(&core_tests.step);
    test_compile_step.dependOn(&engine_tests.step);
    test_compile_step.dependOn(&package_module_tests.step);
    test_compile_step.dependOn(&runtime_support_inspector_tests.step);
    test_compile_step.dependOn(
        provider_evidence_inspector_compile_step,
    );
    test_compile_step.dependOn(&media_external_format_tests.step);
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
    test_compile_step.dependOn(&contract_c_tests.step);
    test_compile_step.dependOn(&contract_c_consumer.step);
    test_compile_step.dependOn(&contract_c_shared_consumer.step);
    test_compile_step.dependOn(&contract_cpp_consumer.step);
    const host_runtime_compile_step = b.step(
        "host-runtime-compile",
        "Compile the complete host test and contract runtime closure",
    );
    host_runtime_compile_step.dependOn(test_compile_step);
    host_runtime_compile_step.dependOn(contract_c_compile_step);

    // R2a exposes one download-free dense-tensor reranking fixture. The
    // independent Python verifier executes the exact demo artifact produced by
    // this graph, so the focused gate compiles the executable only once.
    const dense_tensor_reranker_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "src/core/dense_tensor_reranker.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    const run_dense_tensor_reranker_tests = b.addRunArtifact(
        dense_tensor_reranker_tests,
    );
    const dense_tensor_reranker_exe = b.addExecutable(.{
        .name = "glacier-dense-tensor-reranker-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "examples/dense_tensor_reranker.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    dense_tensor_reranker_exe.root_module.addImport("core", core_mod);
    const run_dense_tensor_reranker = b.addRunArtifact(
        dense_tensor_reranker_exe,
    );
    const dense_tensor_reranker_demo_step = b.step(
        "dense-tensor-reranker-demo",
        "Print the canonical dense-tensor reranking result",
    );
    dense_tensor_reranker_demo_step.dependOn(
        &run_dense_tensor_reranker.step,
    );

    const run_dense_tensor_reranker_oracle =
        b.addSystemCommand(&.{"python3"});
    run_dense_tensor_reranker_oracle.setCwd(b.path("."));
    run_dense_tensor_reranker_oracle.setEnvironmentVariable(
        "PYTHONDONTWRITEBYTECODE",
        "1",
    );
    run_dense_tensor_reranker_oracle.addFileArg(
        b.path("bench/stateless_tensor_result.py"),
    );
    run_dense_tensor_reranker_oracle.addArg("--demo");
    run_dense_tensor_reranker_oracle.addArtifactArg(
        dense_tensor_reranker_exe,
    );
    const run_dense_tensor_reranker_python_tests =
        b.addSystemCommand(&.{
            "python3",
            "-m",
            "unittest",
            "bench.tests.test_stateless_tensor_result",
        });
    run_dense_tensor_reranker_python_tests.setCwd(b.path("."));
    run_dense_tensor_reranker_python_tests.setEnvironmentVariable(
        "PYTHONDONTWRITEBYTECODE",
        "1",
    );

    const dense_tensor_reranker_test_step = b.step(
        "dense-tensor-reranker-test",
        "Run dense-tensor reranking tests and independent verification",
    );
    dense_tensor_reranker_test_step.dependOn(
        &run_dense_tensor_reranker_tests.step,
    );
    dense_tensor_reranker_test_step.dependOn(
        &run_dense_tensor_reranker_oracle.step,
    );
    dense_tensor_reranker_test_step.dependOn(
        &run_dense_tensor_reranker_python_tests.step,
    );
    const dense_tensor_reranker_compile_step = b.step(
        "dense-tensor-reranker-compile",
        "Compile dense-tensor reranking tests and demo",
    );
    dense_tensor_reranker_compile_step.dependOn(
        &dense_tensor_reranker_tests.step,
    );
    dense_tensor_reranker_compile_step.dependOn(
        &dense_tensor_reranker_exe.step,
    );
    // The umbrella core test artifact already imports this module. Attach the
    // independent checks and demo directly so full rounds do not compile a
    // second standalone copy of the same Zig tests.
    test_step.dependOn(&run_dense_tensor_reranker_oracle.step);
    test_step.dependOn(
        &run_dense_tensor_reranker_python_tests.step,
    );
    test_compile_step.dependOn(&dense_tensor_reranker_exe.step);

    // The normalized-embedding fixture shares the same compile-once shape:
    // one Zig test artifact, one demo executable, and an independent Python
    // replay of that exact executable.
    const dense_tensor_embedding_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "src/core/dense_tensor_embedding.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    const run_dense_tensor_embedding_tests = b.addRunArtifact(
        dense_tensor_embedding_tests,
    );
    const dense_tensor_embedding_exe = b.addExecutable(.{
        .name = "glacier-dense-tensor-embedding-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "examples/dense_tensor_embedding_demo.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    dense_tensor_embedding_exe.root_module.addImport("core", core_mod);
    const run_dense_tensor_embedding = b.addRunArtifact(
        dense_tensor_embedding_exe,
    );
    const dense_tensor_embedding_demo_step = b.step(
        "dense-tensor-embedding-demo",
        "Print the canonical normalized dense embedding",
    );
    dense_tensor_embedding_demo_step.dependOn(
        &run_dense_tensor_embedding.step,
    );

    const run_dense_tensor_embedding_oracle =
        b.addSystemCommand(&.{"python3"});
    run_dense_tensor_embedding_oracle.setCwd(b.path("."));
    run_dense_tensor_embedding_oracle.setEnvironmentVariable(
        "PYTHONDONTWRITEBYTECODE",
        "1",
    );
    run_dense_tensor_embedding_oracle.addFileArg(
        b.path("bench/stateless_embedding_result.py"),
    );
    run_dense_tensor_embedding_oracle.addArg("--demo");
    run_dense_tensor_embedding_oracle.addArtifactArg(
        dense_tensor_embedding_exe,
    );
    const run_dense_tensor_embedding_python_tests =
        b.addSystemCommand(&.{
            "python3",
            "-m",
            "unittest",
            "bench.tests.test_stateless_embedding_result",
        });
    run_dense_tensor_embedding_python_tests.setCwd(b.path("."));
    run_dense_tensor_embedding_python_tests.setEnvironmentVariable(
        "PYTHONDONTWRITEBYTECODE",
        "1",
    );

    const dense_tensor_embedding_test_step = b.step(
        "dense-tensor-embedding-test",
        "Run normalized dense-embedding tests and independent verification",
    );
    dense_tensor_embedding_test_step.dependOn(
        &run_dense_tensor_embedding_tests.step,
    );
    dense_tensor_embedding_test_step.dependOn(
        &run_dense_tensor_embedding_oracle.step,
    );
    dense_tensor_embedding_test_step.dependOn(
        &run_dense_tensor_embedding_python_tests.step,
    );
    const dense_tensor_embedding_compile_step = b.step(
        "dense-tensor-embedding-compile",
        "Compile the normalized dense-embedding demo",
    );
    dense_tensor_embedding_compile_step.dependOn(
        &dense_tensor_embedding_exe.step,
    );
    // core_tests already imports both embedding modules. Full rounds only add
    // the independent checks and the single demo artifact.
    test_step.dependOn(&run_dense_tensor_embedding_oracle.step);
    test_step.dependOn(
        &run_dense_tensor_embedding_python_tests.step,
    );
    test_compile_step.dependOn(&dense_tensor_embedding_exe.step);

    // Stateless generated W2 scenarios exercise the unchanged W0 workload
    // and W1 scheduled-media contracts. The focused gate compares the native
    // canonical report with an independent Python replay and retained fixture.
    const workload_scenario_corpus_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "src/core/workload_scenario_corpus.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    const run_workload_scenario_corpus_tests = b.addRunArtifact(
        workload_scenario_corpus_tests,
    );
    const workload_scenario_corpus_exe = b.addExecutable(.{
        .name = "glacier-workload-scenario-corpus",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "examples/workload_scenario_corpus.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    workload_scenario_corpus_exe.root_module.addImport("core", core_mod);
    const run_workload_scenario_corpus = b.addRunArtifact(
        workload_scenario_corpus_exe,
    );
    const workload_scenario_corpus_demo_step = b.step(
        "workload-scenario-corpus-demo",
        "Print the canonical retained workload corpus report",
    );
    workload_scenario_corpus_demo_step.dependOn(
        &run_workload_scenario_corpus.step,
    );

    const run_workload_scenario_corpus_oracle =
        b.addSystemCommand(&.{"python3"});
    run_workload_scenario_corpus_oracle.setCwd(b.path("."));
    run_workload_scenario_corpus_oracle.setEnvironmentVariable(
        "PYTHONDONTWRITEBYTECODE",
        "1",
    );
    run_workload_scenario_corpus_oracle.setEnvironmentVariable(
        "PYTHONPATH",
        ".",
    );
    run_workload_scenario_corpus_oracle.addFileArg(
        b.path("bench/workload_scenario_corpus.py"),
    );
    run_workload_scenario_corpus_oracle.addArg("--runner");
    run_workload_scenario_corpus_oracle.addArtifactArg(
        workload_scenario_corpus_exe,
    );
    run_workload_scenario_corpus_oracle.addArg("--fixture");
    run_workload_scenario_corpus_oracle.addFileArg(
        b.path("bench/results/workload-scenario-corpus-v1.json"),
    );

    const workload_scenario_corpus_test_step = b.step(
        "workload-scenario-corpus-test",
        "Run generated workload corpus tests and independent replay",
    );
    workload_scenario_corpus_test_step.dependOn(
        &run_workload_scenario_corpus_tests.step,
    );
    workload_scenario_corpus_test_step.dependOn(
        &run_workload_scenario_corpus_oracle.step,
    );
    const workload_scenario_corpus_compile_step = b.step(
        "workload-scenario-corpus-compile",
        "Compile the generated workload corpus tests and runner",
    );
    workload_scenario_corpus_compile_step.dependOn(
        &workload_scenario_corpus_tests.step,
    );
    workload_scenario_corpus_compile_step.dependOn(
        &workload_scenario_corpus_exe.step,
    );
    test_step.dependOn(workload_scenario_corpus_test_step);
    test_compile_step.dependOn(
        workload_scenario_corpus_compile_step,
    );

    // Direct four-phase W3 target maintenance. This is a stateful
    // candidate-source driver, not a materialized W0 open-loop scenario.
    // Native evidence is compared with an independent Python state machine
    // and a retained canonical fixture.
    const workload_closed_loop_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "src/core/workload_closed_loop.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    const run_workload_closed_loop_tests = b.addRunArtifact(
        workload_closed_loop_tests,
    );
    const workload_closed_loop_exe = b.addExecutable(.{
        .name = "glacier-workload-closed-loop",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "examples/workload_closed_loop.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    workload_closed_loop_exe.root_module.addImport("core", core_mod);
    const run_workload_closed_loop = b.addRunArtifact(
        workload_closed_loop_exe,
    );
    const workload_closed_loop_demo_step = b.step(
        "workload-closed-loop-demo",
        "Print the canonical deterministic closed-loop report",
    );
    workload_closed_loop_demo_step.dependOn(
        &run_workload_closed_loop.step,
    );

    const run_workload_closed_loop_oracle =
        b.addSystemCommand(&.{"python3"});
    run_workload_closed_loop_oracle.setCwd(b.path("."));
    run_workload_closed_loop_oracle.setEnvironmentVariable(
        "PYTHONDONTWRITEBYTECODE",
        "1",
    );
    run_workload_closed_loop_oracle.setEnvironmentVariable(
        "PYTHONPATH",
        ".",
    );
    run_workload_closed_loop_oracle.addFileArg(
        b.path("bench/workload_closed_loop.py"),
    );
    run_workload_closed_loop_oracle.addArg("--runner");
    run_workload_closed_loop_oracle.addArtifactArg(
        workload_closed_loop_exe,
    );
    run_workload_closed_loop_oracle.addArg("--fixture");
    run_workload_closed_loop_oracle.addFileArg(
        b.path("bench/results/workload-closed-loop-v1.json"),
    );

    const workload_closed_loop_test_step = b.step(
        "workload-closed-loop-test",
        "Run deterministic closed-loop tests and independent replay",
    );
    workload_closed_loop_test_step.dependOn(
        &run_workload_closed_loop_tests.step,
    );
    workload_closed_loop_test_step.dependOn(
        &run_workload_closed_loop_oracle.step,
    );
    const workload_closed_loop_compile_step = b.step(
        "workload-closed-loop-compile",
        "Compile the deterministic closed-loop tests and runner",
    );
    workload_closed_loop_compile_step.dependOn(
        &workload_closed_loop_tests.step,
    );
    workload_closed_loop_compile_step.dependOn(
        &workload_closed_loop_exe.step,
    );
    test_step.dependOn(workload_closed_loop_test_step);
    test_compile_step.dependOn(workload_closed_loop_compile_step);

    // W4a composes the generic typed-workload lifecycle with the retained
    // exact-integer vision, audio-window, and temporal-video adapters. The
    // native report must match an independent Python replay and retained
    // fixture byte-for-byte; this remains logical conformance, not a native
    // performance target.
    const typed_workload_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "src/core/typed_perception_workload.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    const run_typed_workload_tests = b.addRunArtifact(
        typed_workload_tests,
    );
    const typed_workload_exe = b.addExecutable(.{
        .name = "glacier-typed-perception-workload",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "examples/typed_perception_workload.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    typed_workload_exe.root_module.addImport("core", core_mod);
    const run_typed_workload = b.addRunArtifact(
        typed_workload_exe,
    );
    const typed_workload_demo_step = b.step(
        "typed-workload-demo",
        "Print the canonical mixed typed-workload report",
    );
    typed_workload_demo_step.dependOn(&run_typed_workload.step);

    const run_typed_workload_oracle =
        b.addSystemCommand(&.{"python3"});
    run_typed_workload_oracle.setCwd(b.path("."));
    run_typed_workload_oracle.setEnvironmentVariable(
        "PYTHONDONTWRITEBYTECODE",
        "1",
    );
    run_typed_workload_oracle.setEnvironmentVariable(
        "PYTHONPATH",
        ".",
    );
    run_typed_workload_oracle.addFileArg(
        b.path("bench/typed_workload_conformance.py"),
    );
    run_typed_workload_oracle.addArg("--runner");
    run_typed_workload_oracle.addArtifactArg(typed_workload_exe);
    run_typed_workload_oracle.addArg("--fixture");
    run_typed_workload_oracle.addFileArg(
        b.path("bench/results/typed-workload-conformance-v1.json"),
    );

    const typed_workload_test_step = b.step(
        "typed-workload-test",
        "Run mixed typed-workload tests and independent replay",
    );
    typed_workload_test_step.dependOn(&run_typed_workload_tests.step);
    typed_workload_test_step.dependOn(&run_typed_workload_oracle.step);
    const typed_workload_compile_step = b.step(
        "typed-workload-compile",
        "Compile the mixed typed-workload tests and runner",
    );
    typed_workload_compile_step.dependOn(&typed_workload_tests.step);
    typed_workload_compile_step.dependOn(&typed_workload_exe.step);
    test_step.dependOn(typed_workload_test_step);
    test_compile_step.dependOn(typed_workload_compile_step);

    // W5a binds the retained three-family/six-item workload to a portable,
    // fixed-size native-observation contract. The observer admits before the
    // workload starts, closes after every begun run, retains post-run
    // contamination, and never treats unavailable telemetry as zero. The
    // reference is download-free and is not a performance claim.
    const native_observation_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "src/core/native_observation_runner.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    const run_native_observation_tests = b.addRunArtifact(
        native_observation_tests,
    );
    const native_observation_exe = b.addExecutable(.{
        .name = "glacier-native-observation",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "examples/native_observation.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    native_observation_exe.root_module.addImport("core", core_mod);
    const run_native_observation = b.addRunArtifact(
        native_observation_exe,
    );
    const native_observation_demo_step = b.step(
        "native-observation-demo",
        "Print the canonical native-observation reference report",
    );
    native_observation_demo_step.dependOn(
        &run_native_observation.step,
    );

    const run_native_observation_model =
        b.addSystemCommand(&.{
            "python3",
            "-m",
            "unittest",
            "bench.tests.test_native_observation_conformance",
            "bench.tests.test_native_observer",
            "bench.tests.test_native_observer_linux",
            "bench.tests.test_paired_abba",
        });
    run_native_observation_model.setCwd(b.path("."));
    run_native_observation_model.setEnvironmentVariable(
        "PYTHONDONTWRITEBYTECODE",
        "1",
    );
    run_native_observation_model.setEnvironmentVariable(
        "PYTHONPATH",
        ".",
    );
    const run_native_observation_oracle =
        b.addSystemCommand(&.{"python3"});
    run_native_observation_oracle.setCwd(b.path("."));
    run_native_observation_oracle.setEnvironmentVariable(
        "PYTHONDONTWRITEBYTECODE",
        "1",
    );
    run_native_observation_oracle.setEnvironmentVariable(
        "PYTHONPATH",
        ".",
    );
    run_native_observation_oracle.addFileArg(
        b.path("bench/native_observation_conformance.py"),
    );
    run_native_observation_oracle.addArg("--runner");
    run_native_observation_oracle.addArtifactArg(
        native_observation_exe,
    );
    run_native_observation_oracle.addArg("--fixture");
    run_native_observation_oracle.addFileArg(
        b.path(
            "bench/results/native-observation-conformance-v1.json",
        ),
    );
    const native_observation_test_step = b.step(
        "native-observation-test",
        "Run native observation, oracle and host-adapter tests",
    );
    native_observation_test_step.dependOn(
        &run_native_observation_tests.step,
    );
    native_observation_test_step.dependOn(
        &run_native_observation_model.step,
    );
    native_observation_test_step.dependOn(
        &run_native_observation_oracle.step,
    );
    const native_observation_compile_step = b.step(
        "native-observation-compile",
        "Compile portable native-observation tests and report",
    );
    native_observation_compile_step.dependOn(
        &native_observation_tests.step,
    );
    native_observation_compile_step.dependOn(
        &native_observation_exe.step,
    );
    const native_observation_cross_compile_step = b.step(
        "native-observation-cross-compile",
        "Cross-compile the observation contract for Linux, Windows and FreeBSD",
    );
    const native_observation_cross_targets = [_]std.Target.Query{
        .{
            .cpu_arch = .x86_64,
            .os_tag = .linux,
            .abi = .gnu,
        },
        .{
            .cpu_arch = .aarch64,
            .os_tag = .linux,
            .abi = .gnu,
        },
        .{
            .cpu_arch = .x86_64,
            .os_tag = .windows,
            .abi = .gnu,
        },
        .{
            .cpu_arch = .x86_64,
            .os_tag = .freebsd,
        },
    };
    for (native_observation_cross_targets) |cross_query| {
        const cross_target = b.resolveTargetQuery(cross_query);
        const cross_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/core/native_observation_runner.zig",
                ),
                .target = cross_target,
                .optimize = optimize,
            }),
        });
        native_observation_cross_compile_step.dependOn(
            &cross_tests.step,
        );
    }
    test_step.dependOn(native_observation_test_step);
    test_compile_step.dependOn(
        native_observation_compile_step,
    );

    // W6 is a portable, allocation-free workload evidence wire. The focused
    // module tests and fixed reference runner deliberately import only the
    // hardware-independent report codec; the Python model independently
    // decodes, validates, and mutation-tests the runner's raw stdout.
    const native_workload_report_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "src/core/native_workload_report.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    const run_native_workload_report_tests = b.addRunArtifact(
        native_workload_report_tests,
    );
    const native_workload_report_mod = b.createModule(.{
        .root_source_file = b.path(
            "src/core/native_workload_report.zig",
        ),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
    });
    const native_workload_report_exe = b.addExecutable(.{
        .name = "glacier-native-workload-report",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "examples/native_workload_report.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    native_workload_report_exe.root_module.addImport(
        "native_workload_report",
        native_workload_report_mod,
    );

    const run_native_workload_report_model =
        b.addSystemCommand(&.{
            "python3",
            "-m",
            "unittest",
            "bench.tests.test_native_workload_report",
        });
    run_native_workload_report_model.setCwd(b.path("."));
    run_native_workload_report_model.setEnvironmentVariable(
        "PYTHONDONTWRITEBYTECODE",
        "1",
    );
    run_native_workload_report_model.setEnvironmentVariable(
        "PYTHONPATH",
        ".",
    );
    const run_native_workload_report_oracle =
        b.addSystemCommand(&.{"python3"});
    run_native_workload_report_oracle.setCwd(b.path("."));
    run_native_workload_report_oracle.setEnvironmentVariable(
        "PYTHONDONTWRITEBYTECODE",
        "1",
    );
    run_native_workload_report_oracle.setEnvironmentVariable(
        "PYTHONPATH",
        ".",
    );
    run_native_workload_report_oracle.addFileArg(
        b.path("bench/native_workload_report.py"),
    );
    run_native_workload_report_oracle.addArg("--runner");
    run_native_workload_report_oracle.addArtifactArg(
        native_workload_report_exe,
    );
    run_native_workload_report_oracle.addArg(
        "--expected-wire-sha256",
    );
    run_native_workload_report_oracle.addArg(
        "7b61707818f7a4acc0f3f66ee2c8d729" ++
            "9a3e1fffc4336ae3fc9d34e11c56d954",
    );

    const native_workload_report_test_step = b.step(
        "native-workload-report-test",
        "Run native workload report codec and independent Python tests",
    );
    native_workload_report_test_step.dependOn(
        &run_native_workload_report_tests.step,
    );
    native_workload_report_test_step.dependOn(
        &run_native_workload_report_model.step,
    );
    native_workload_report_test_step.dependOn(
        &run_native_workload_report_oracle.step,
    );
    const native_workload_report_compile_step = b.step(
        "native-workload-report-compile",
        "Compile the native workload report tests and reference runner",
    );
    native_workload_report_compile_step.dependOn(
        &native_workload_report_tests.step,
    );
    native_workload_report_compile_step.dependOn(
        &native_workload_report_exe.step,
    );

    const native_workload_report_cross_compile_step = b.step(
        "native-workload-report-cross-compile",
        "Cross-compile the report tests and runner for portable targets",
    );
    const native_workload_report_cross_targets = [_]std.Target.Query{
        .{
            .cpu_arch = .x86_64,
            .os_tag = .linux,
            .abi = .gnu,
        },
        .{
            .cpu_arch = .aarch64,
            .os_tag = .linux,
            .abi = .gnu,
        },
        .{
            .cpu_arch = .x86_64,
            .os_tag = .windows,
            .abi = .gnu,
        },
        .{
            .cpu_arch = .x86_64,
            .os_tag = .freebsd,
        },
    };
    for (native_workload_report_cross_targets) |cross_query| {
        const cross_target = b.resolveTargetQuery(cross_query);
        const cross_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/core/native_workload_report.zig",
                ),
                .target = cross_target,
                .optimize = optimize,
            }),
        });
        const cross_report_mod = b.createModule(.{
            .root_source_file = b.path(
                "src/core/native_workload_report.zig",
            ),
            .target = cross_target,
            .optimize = optimize,
        });
        const cross_runner = b.addExecutable(.{
            .name = "glacier-native-workload-report",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "examples/native_workload_report.zig",
                ),
                .target = cross_target,
                .optimize = optimize,
            }),
        });
        cross_runner.root_module.addImport(
            "native_workload_report",
            cross_report_mod,
        );
        native_workload_report_cross_compile_step.dependOn(
            &cross_tests.step,
        );
        native_workload_report_cross_compile_step.dependOn(
            &cross_runner.step,
        );
    }
    test_step.dependOn(native_workload_report_test_step);
    test_compile_step.dependOn(
        native_workload_report_compile_step,
    );

    // W7 keeps the 256-record W6 ABI fixed and composes independently
    // verified inner wires through a bounded, canonical outer campaign
    // manifest. The portable gate checks the Zig codec and an independent
    // Python model; foreign targets are compile-only evidence.
    const native_workload_campaign_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "src/core/native_workload_campaign_manifest.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    const run_native_workload_campaign_tests = b.addRunArtifact(
        native_workload_campaign_tests,
    );
    const run_native_workload_campaign_model =
        b.addSystemCommand(&.{
            "python3",
            "-m",
            "unittest",
            "bench.tests.test_native_workload_campaign",
        });
    run_native_workload_campaign_model.setCwd(b.path("."));
    run_native_workload_campaign_model.setEnvironmentVariable(
        "PYTHONDONTWRITEBYTECODE",
        "1",
    );
    run_native_workload_campaign_model.setEnvironmentVariable(
        "PYTHONPATH",
        ".",
    );
    const native_workload_campaign_test_step = b.step(
        "native-workload-campaign-test",
        "Run the segmented workload campaign codec and independent model",
    );
    native_workload_campaign_test_step.dependOn(
        &run_native_workload_campaign_tests.step,
    );
    native_workload_campaign_test_step.dependOn(
        &run_native_workload_campaign_model.step,
    );
    const native_workload_campaign_compile_step = b.step(
        "native-workload-campaign-compile",
        "Compile the segmented workload campaign codec tests",
    );
    native_workload_campaign_compile_step.dependOn(
        &native_workload_campaign_tests.step,
    );
    const native_workload_campaign_cross_compile_step = b.step(
        "native-workload-campaign-cross-compile",
        "Cross-compile the segmented campaign codec tests for portable targets",
    );
    for (native_workload_report_cross_targets) |cross_query| {
        const cross_target = b.resolveTargetQuery(cross_query);
        const cross_campaign_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/core/native_workload_campaign_manifest.zig",
                ),
                .target = cross_target,
                .optimize = optimize,
            }),
        });
        native_workload_campaign_cross_compile_step.dependOn(
            &cross_campaign_tests.step,
        );
    }
    test_step.dependOn(native_workload_campaign_test_step);
    test_compile_step.dependOn(
        native_workload_campaign_compile_step,
    );

    // W7b-b2 keeps campaign storage faults separate from device execution.
    // The fixed report codec is portable; the hard campaign below uses real
    // native POSIX processes and filesystem calls plus controlled errno
    // adapters, without turning those adapters into physical-disk evidence.
    const native_workload_store_fault_report_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "src/core/native_workload_store_fault_report.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    const run_native_workload_store_fault_report_tests =
        b.addRunArtifact(native_workload_store_fault_report_tests);
    const native_workload_store_fault_report_mod = b.createModule(.{
        .root_source_file = b.path(
            "src/core/native_workload_store_fault_report.zig",
        ),
        .target = target,
        .optimize = optimize,
    });
    const native_workload_store_fault_report_verifier =
        b.addExecutable(.{
            .name = "glacier-native-workload-store-fault-report",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "examples/native_workload_store_fault_report.zig",
                ),
                .target = target,
                .optimize = optimize,
            }),
        });
    native_workload_store_fault_report_verifier.root_module.addImport(
        "native_workload_store_fault_report",
        native_workload_store_fault_report_mod,
    );
    const native_workload_store_fault_report_verifier_tests =
        b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "examples/native_workload_store_fault_report.zig",
                ),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
    native_workload_store_fault_report_verifier_tests.root_module.addImport(
        "native_workload_store_fault_report",
        native_workload_store_fault_report_mod,
    );
    const run_native_workload_store_fault_report_verifier_tests =
        b.addRunArtifact(
            native_workload_store_fault_report_verifier_tests,
        );
    const run_native_workload_store_fault_report_model =
        b.addSystemCommand(&.{
            "python3",
            "-m",
            "unittest",
            "bench.tests.test_native_workload_store_fault_report",
        });
    run_native_workload_store_fault_report_model.setCwd(b.path("."));
    run_native_workload_store_fault_report_model.setEnvironmentVariable(
        "PYTHONDONTWRITEBYTECODE",
        "1",
    );
    run_native_workload_store_fault_report_model.setEnvironmentVariable(
        "PYTHONPATH",
        ".",
    );
    const native_workload_store_fault_report_test_step = b.step(
        "native-workload-store-fault-report-test",
        "Run the portable store-fault report codec and independent verifier",
    );
    native_workload_store_fault_report_test_step.dependOn(
        &run_native_workload_store_fault_report_tests.step,
    );
    native_workload_store_fault_report_test_step.dependOn(
        &run_native_workload_store_fault_report_model.step,
    );
    native_workload_store_fault_report_test_step.dependOn(
        &run_native_workload_store_fault_report_verifier_tests.step,
    );
    const native_workload_store_fault_report_compile_step = b.step(
        "native-workload-store-fault-report-compile",
        "Compile the store-fault report codec and fresh verifier",
    );
    native_workload_store_fault_report_compile_step.dependOn(
        &native_workload_store_fault_report_tests.step,
    );
    native_workload_store_fault_report_compile_step.dependOn(
        &native_workload_store_fault_report_verifier.step,
    );
    native_workload_store_fault_report_compile_step.dependOn(
        &native_workload_store_fault_report_verifier_tests.step,
    );
    const native_workload_store_fault_report_cross_compile_step = b.step(
        "native-workload-store-fault-report-cross-compile",
        "Cross-compile the store-fault report codec and verifier",
    );
    for (native_workload_report_cross_targets) |cross_query| {
        const cross_target = b.resolveTargetQuery(cross_query);
        const cross_store_fault_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/core/native_workload_store_fault_report.zig",
                ),
                .target = cross_target,
                .optimize = optimize,
            }),
        });
        const cross_store_fault_mod = b.createModule(.{
            .root_source_file = b.path(
                "src/core/native_workload_store_fault_report.zig",
            ),
            .target = cross_target,
            .optimize = optimize,
        });
        const cross_store_fault_verifier = b.addExecutable(.{
            .name = "glacier-native-workload-store-fault-report",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "examples/native_workload_store_fault_report.zig",
                ),
                .target = cross_target,
                .optimize = optimize,
            }),
        });
        cross_store_fault_verifier.root_module.addImport(
            "native_workload_store_fault_report",
            cross_store_fault_mod,
        );
        native_workload_store_fault_report_cross_compile_step.dependOn(
            &cross_store_fault_tests.step,
        );
        native_workload_store_fault_report_cross_compile_step.dependOn(
            &cross_store_fault_verifier.step,
        );
    }
    const run_native_workload_store_fault_pure =
        b.addSystemCommand(&.{
            "python3",
            "-m",
            "unittest",
            "bench.tests.test_native_workload_store_fault_campaign",
            "bench.tests.test_native_metal_soak_report",
        });
    run_native_workload_store_fault_pure.setCwd(b.path("."));
    run_native_workload_store_fault_pure.setEnvironmentVariable(
        "PYTHONDONTWRITEBYTECODE",
        "1",
    );
    run_native_workload_store_fault_pure.setEnvironmentVariable(
        "PYTHONPATH",
        ".",
    );
    const native_workload_store_fault_pure_test_step = b.step(
        "native-workload-store-fault-pure-test",
        "Run POSIX-host publication, recovery, and negative-state tests",
    );
    native_workload_store_fault_pure_test_step.dependOn(
        &run_native_workload_store_fault_pure.step,
    );
    native_workload_store_fault_pure_test_step.dependOn(
        native_workload_store_fault_report_test_step,
    );

    const run_native_workload_store_fault_campaign =
        b.addSystemCommand(&.{
            "python3",
            "-m",
            "bench.native_workload_store_fault_campaign",
            "run-matrix",
            "--zig-verifier",
        });
    run_native_workload_store_fault_campaign.addArtifactArg(
        native_workload_store_fault_report_verifier,
    );
    if (native_workload_store_fault_output) |path| {
        run_native_workload_store_fault_campaign.addArg("--output");
        run_native_workload_store_fault_campaign.addArg(path);
    }
    run_native_workload_store_fault_campaign.setCwd(b.path("."));
    run_native_workload_store_fault_campaign.setEnvironmentVariable(
        "PYTHONDONTWRITEBYTECODE",
        "1",
    );
    run_native_workload_store_fault_campaign.setEnvironmentVariable(
        "PYTHONPATH",
        ".",
    );
    run_native_workload_store_fault_campaign.step.dependOn(
        &native_workload_store_fault_report_verifier.step,
    );
    const native_workload_store_fault_test_step = b.step(
        "native-workload-store-fault-test",
        "Run real process-death and controlled POSIX storage-error recovery",
    );
    native_workload_store_fault_test_step.dependOn(
        native_workload_store_fault_pure_test_step,
    );
    native_workload_store_fault_test_step.dependOn(
        &run_native_workload_store_fault_campaign.step,
    );
    // Keep only the portable codec in the default build graph. The local
    // affected/full/matrix verifier selects the hard POSIX-host campaign after
    // checking native host availability.
    test_step.dependOn(native_workload_store_fault_report_test_step);
    test_compile_step.dependOn(
        native_workload_store_fault_report_compile_step,
    );

    // W5b-a is an explicitly invoked native macOS gate. Its Python verifier
    // launches the only real fixed-input Metal dispatch after all pure Zig
    // and Python mutation tests finish. Unlike the broad test suite, this
    // gate fails rather than skipping when native Metal evidence is absent.
    const native_metal_observation_test_step = b.step(
        "native-metal-observation-test",
        "Run the hard native macOS Metal readiness gate",
    );
    const native_metal_observation_pure_test_step = b.step(
        "native-metal-observation-pure-test",
        "Run pure Metal readiness composition tests without a GPU dispatch",
    );
    const native_metal_observation_compile_step = b.step(
        "native-metal-observation-compile",
        "Compile the native macOS Metal readiness CLI without running it",
    );
    const native_metal_allocation_test_step = b.step(
        "native-metal-allocation-test",
        "Run the hard native macOS Metal allocation ownership gate",
    );
    const native_metal_allocation_compile_step = b.step(
        "native-metal-allocation-compile",
        "Compile the native macOS Metal allocation ownership gate",
    );
    const native_metal_fault_test_step = b.step(
        "native-metal-fault-test",
        "Run the build-isolated native Metal fault and settlement gate",
    );
    const native_metal_workload_report_test_step = b.step(
        "native-metal-workload-report-test",
        "Run one hard production-native Metal workload report gate",
    );
    const native_metal_workload_report_compile_step = b.step(
        "native-metal-workload-report-compile",
        "Compile the production-native Metal workload report producer",
    );
    const native_metal_disruption_report_test_step = b.step(
        "native-metal-disruption-report-test",
        "Run one hard production-native Metal disruption report gate",
    );
    const native_metal_disruption_report_compile_step = b.step(
        "native-metal-disruption-report-compile",
        "Compile the production-native Metal disruption report producer",
    );
    const native_metal_cancellation_storm_report_test_step = b.step(
        "native-metal-cancellation-storm-report-test",
        "Run the hard production-native Metal cancellation-storm report gate",
    );
    const native_metal_cancellation_storm_report_compile_step = b.step(
        "native-metal-cancellation-storm-report-compile",
        "Compile the production-native Metal cancellation-storm report producer",
    );
    const native_metal_soak_report_test_step = b.step(
        "native-metal-soak-report-test",
        "Admit the environment, then run the hard 60-second segmented native Metal soak gate",
    );
    const native_metal_soak_report_pure_test_step = b.step(
        "native-metal-soak-report-pure-test",
        "Run pure segmented Metal soak supervisor and store tests",
    );
    const native_metal_soak_report_compile_step = b.step(
        "native-metal-soak-report-compile",
        "Compile the persistent native Metal soak worker",
    );
    const native_metal_process_kill_report_test_step = b.step(
        "native-metal-process-kill-report-test",
        "Admit the environment, then run the hard native Metal post-segment SIGKILL recovery gate",
    );
    const native_metal_inflight_process_kill_report_test_step = b.step(
        "native-metal-inflight-process-kill-report-test",
        "Run the hard event-blocked native Metal process-kill gate",
    );
    const native_metal_inflight_process_kill_report_pure_test_step = b.step(
        "native-metal-inflight-process-kill-report-pure-test",
        "Run pure event-blocked process-kill ready-frame tests",
    );
    const native_metal_inflight_process_kill_report_compile_step = b.step(
        "native-metal-inflight-process-kill-report-compile",
        "Compile the event-blocked native Metal victim worker",
    );
    const native_supervisor_recovery_death_report_test_step = b.step(
        "native-supervisor-recovery-death-report-test",
        "Run the portable supervisor/recovery-death codec and independent model",
    );
    const native_supervisor_recovery_death_report_compile_step = b.step(
        "native-supervisor-recovery-death-report-compile",
        "Compile the portable supervisor/recovery-death codec and verifier",
    );
    const native_supervisor_recovery_death_report_cross_compile_step = b.step(
        "native-supervisor-recovery-death-report-cross-compile",
        "Cross-compile the supervisor/recovery-death codec and verifier",
    );
    const native_supervisor_recovery_death_host_test_step = b.step(
        "native-supervisor-recovery-death-host-test",
        "Run the POSIX process/lock protocol and deterministic staged-store model",
    );
    const native_metal_supervisor_recovery_death_report_test_step = b.step(
        "native-metal-supervisor-recovery-death-report-test",
        "Run the hard production-native Metal supervisor and recovery-process death campaign",
    );
    const native_metal_supervisor_recovery_death_report_compile_step = b.step(
        "native-metal-supervisor-recovery-death-report-compile",
        "Compile every artifact used by the native Metal supervisor/recovery-death campaign",
    );
    const native_metal_suite_compile_step = b.step(
        "native-metal-suite-compile",
        "Compile and statically validate every native Metal suite artifact",
    );
    const native_metal_suite_test_step = b.step(
        "native-metal-suite-test",
        "Run serialized Metal gates with bounded admission before thermal-sensitive campaigns",
    );

    const native_metal_inflight_process_kill_ready_mod = b.createModule(.{
        .root_source_file = b.path(
            "src/core/native_metal_inflight_process_kill_ready.zig",
        ),
        .target = target,
        .optimize = optimize,
    });
    const native_metal_inflight_process_kill_ready_tests = b.addTest(.{
        .name = "glacier-native-metal-inflight-process-kill-ready-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "src/core/native_metal_inflight_process_kill_ready.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    const run_native_metal_inflight_process_kill_ready_tests =
        b.addRunArtifact(
            native_metal_inflight_process_kill_ready_tests,
        );
    native_metal_inflight_process_kill_report_pure_test_step.dependOn(
        &run_native_metal_inflight_process_kill_ready_tests.step,
    );
    const run_native_metal_inflight_process_kill_report_model =
        b.addSystemCommand(&.{
            "python3",
            "-m",
            "unittest",
            "bench.tests.test_native_metal_inflight_process_kill_report",
        });
    run_native_metal_inflight_process_kill_report_model.setCwd(
        b.path("."),
    );
    run_native_metal_inflight_process_kill_report_model
        .setEnvironmentVariable(
        "PYTHONDONTWRITEBYTECODE",
        "1",
    );
    run_native_metal_inflight_process_kill_report_model
        .setEnvironmentVariable(
        "PYTHONPATH",
        ".",
    );
    run_native_metal_inflight_process_kill_report_model.step.dependOn(
        &run_native_metal_inflight_process_kill_ready_tests.step,
    );
    native_metal_inflight_process_kill_report_pure_test_step.dependOn(
        &run_native_metal_inflight_process_kill_report_model.step,
    );
    test_step.dependOn(
        &run_native_metal_inflight_process_kill_ready_tests.step,
    );
    test_step.dependOn(
        &run_native_metal_inflight_process_kill_report_model.step,
    );

    // W7b-b5 keeps its fixed report codec portable even though the hard
    // producer below requires native macOS Metal plus POSIX process/storage
    // evidence. The independent Python model and fresh Zig verifier retain
    // the exact 3,520-byte wire without granting continuation authority.
    const native_supervisor_recovery_death_report_mod = b.createModule(.{
        .root_source_file = b.path(
            "src/core/native_metal_supervisor_recovery_death_report.zig",
        ),
        .target = target,
        .optimize = optimize,
    });
    const native_supervisor_recovery_death_report_tests = b.addTest(.{
        .name = "glacier-native-supervisor-recovery-death-report-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "src/core/native_metal_supervisor_recovery_death_report.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    const run_native_supervisor_recovery_death_report_tests =
        b.addRunArtifact(
            native_supervisor_recovery_death_report_tests,
        );
    const native_supervisor_recovery_death_report_verifier =
        b.addExecutable(.{
            .name = "glacier-native-supervisor-recovery-death-report",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "examples/native_metal_supervisor_recovery_death_report.zig",
                ),
                .target = target,
                .optimize = optimize,
            }),
        });
    native_supervisor_recovery_death_report_verifier.root_module.addImport(
        "native_metal_supervisor_recovery_death_report",
        native_supervisor_recovery_death_report_mod,
    );
    const native_supervisor_recovery_death_report_verifier_tests =
        b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "examples/native_metal_supervisor_recovery_death_report.zig",
                ),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
    native_supervisor_recovery_death_report_verifier_tests.root_module
        .addImport(
        "native_metal_supervisor_recovery_death_report",
        native_supervisor_recovery_death_report_mod,
    );
    const run_native_supervisor_recovery_death_report_verifier_tests =
        b.addRunArtifact(
            native_supervisor_recovery_death_report_verifier_tests,
        );
    const run_native_supervisor_recovery_death_report_model =
        b.addSystemCommand(&.{
            "python3",
            "-m",
            "unittest",
            "bench.tests.test_native_metal_supervisor_recovery_death_report",
        });
    run_native_supervisor_recovery_death_report_model.setCwd(
        b.path("."),
    );
    run_native_supervisor_recovery_death_report_model
        .setEnvironmentVariable(
        "PYTHONDONTWRITEBYTECODE",
        "1",
    );
    run_native_supervisor_recovery_death_report_model
        .setEnvironmentVariable(
        "PYTHONPATH",
        ".",
    );
    run_native_supervisor_recovery_death_report_model.step.dependOn(
        &run_native_supervisor_recovery_death_report_tests.step,
    );
    const emit_python_supervisor_recovery_death_golden =
        b.addSystemCommand(&.{
            "python3",
            "-c",
            "from pathlib import Path; import sys; " ++
                "from bench.tests." ++
                "test_native_metal_supervisor_recovery_death_report " ++
                "import _fixture; " ++
                "Path(sys.argv[1]).write_bytes(_fixture()[-1])",
        });
    emit_python_supervisor_recovery_death_golden.setCwd(b.path("."));
    emit_python_supervisor_recovery_death_golden.setEnvironmentVariable(
        "PYTHONDONTWRITEBYTECODE",
        "1",
    );
    emit_python_supervisor_recovery_death_golden.setEnvironmentVariable(
        "PYTHONPATH",
        ".",
    );
    const python_supervisor_recovery_death_golden =
        emit_python_supervisor_recovery_death_golden.addOutputFileArg(
            "python-supervisor-recovery-death-golden.bin",
        );
    const run_python_to_zig_supervisor_recovery_death_interop =
        b.addRunArtifact(
            native_supervisor_recovery_death_report_verifier,
        );
    run_python_to_zig_supervisor_recovery_death_interop.addFileArg(
        python_supervisor_recovery_death_golden,
    );
    run_python_to_zig_supervisor_recovery_death_interop.expectStdOutEqual(
        "wire_verified=true claims_only=true generation=6->12 " ++
            "recovery_lock_ack=1 claimed_sigkills=2 " ++
            "claimed_commands=1200 claimed_cpu_oracles=1200 " ++
            "report_sha256=" ++
            "0260c4a008fa5b27c78ed793feceb110" ++
            "7bf7615b373b76982f4d96a2b9cf58c9\n",
    );
    run_python_to_zig_supervisor_recovery_death_interop.step.dependOn(
        &run_native_supervisor_recovery_death_report_model.step,
    );
    const run_native_supervisor_recovery_death_protocol_model =
        b.addSystemCommand(&.{
            "python3",
            "-m",
            "unittest",
            "bench.tests.test_native_metal_soak_report",
            "bench.tests.test_native_metal_supervisor_recovery_death_protocol",
        });
    run_native_supervisor_recovery_death_protocol_model.setCwd(
        b.path("."),
    );
    run_native_supervisor_recovery_death_protocol_model
        .setEnvironmentVariable(
        "PYTHONDONTWRITEBYTECODE",
        "1",
    );
    run_native_supervisor_recovery_death_protocol_model
        .setEnvironmentVariable(
        "PYTHONPATH",
        ".",
    );
    run_native_supervisor_recovery_death_protocol_model.step.dependOn(
        &run_native_supervisor_recovery_death_report_model.step,
    );
    native_supervisor_recovery_death_host_test_step.dependOn(
        &run_native_supervisor_recovery_death_protocol_model.step,
    );
    native_supervisor_recovery_death_report_test_step.dependOn(
        &run_native_supervisor_recovery_death_report_tests.step,
    );
    native_supervisor_recovery_death_report_test_step.dependOn(
        &run_native_supervisor_recovery_death_report_verifier_tests.step,
    );
    native_supervisor_recovery_death_report_test_step.dependOn(
        &run_native_supervisor_recovery_death_report_model.step,
    );
    native_supervisor_recovery_death_report_test_step.dependOn(
        &run_python_to_zig_supervisor_recovery_death_interop.step,
    );
    native_supervisor_recovery_death_report_compile_step.dependOn(
        &native_supervisor_recovery_death_report_tests.step,
    );
    native_supervisor_recovery_death_report_compile_step.dependOn(
        &native_supervisor_recovery_death_report_verifier.step,
    );
    native_supervisor_recovery_death_report_compile_step.dependOn(
        &native_supervisor_recovery_death_report_verifier_tests.step,
    );
    for (native_workload_report_cross_targets) |cross_query| {
        const cross_target = b.resolveTargetQuery(cross_query);
        const cross_supervisor_recovery_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "src/core/native_metal_supervisor_recovery_death_report.zig",
                ),
                .target = cross_target,
                .optimize = optimize,
            }),
        });
        const cross_supervisor_recovery_mod = b.createModule(.{
            .root_source_file = b.path(
                "src/core/native_metal_supervisor_recovery_death_report.zig",
            ),
            .target = cross_target,
            .optimize = optimize,
        });
        const cross_supervisor_recovery_verifier = b.addExecutable(.{
            .name = "glacier-native-supervisor-recovery-death-report",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "examples/native_metal_supervisor_recovery_death_report.zig",
                ),
                .target = cross_target,
                .optimize = optimize,
            }),
        });
        cross_supervisor_recovery_verifier.root_module.addImport(
            "native_metal_supervisor_recovery_death_report",
            cross_supervisor_recovery_mod,
        );
        native_supervisor_recovery_death_report_cross_compile_step.dependOn(
            &cross_supervisor_recovery_tests.step,
        );
        native_supervisor_recovery_death_report_cross_compile_step.dependOn(
            &cross_supervisor_recovery_verifier.step,
        );
    }
    test_step.dependOn(
        native_supervisor_recovery_death_report_test_step,
    );
    test_compile_step.dependOn(
        native_supervisor_recovery_death_report_compile_step,
    );

    const native_metal_build_available =
        metal_shim != null and
        builtin.os.tag == .macos and
        target.result.cpu.arch == builtin.cpu.arch and
        target.result.os.tag == builtin.os.tag and
        target.result.abi == builtin.abi;
    if (native_metal_build_available) {
        const shim = metal_shim.?;
        const native_metal_lib = metal_lib.?;
        const native_metal_observation_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "tests/native_metal_observation.zig",
                ),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
        native_metal_observation_tests.root_module.addImport(
            "engine",
            engine_mod,
        );
        const run_native_metal_observation_tests =
            b.addRunArtifact(native_metal_observation_tests);

        const native_metal_observation_exe = b.addExecutable(.{
            .name = "glacier-native-metal-observation",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "examples/native_metal_observation.zig",
                ),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
        native_metal_observation_exe.root_module.addImport(
            "engine",
            engine_mod,
        );
        native_metal_observation_exe.linkLibC();
        native_metal_observation_exe.linkLibrary(shim);
        native_metal_observation_exe.linkFramework("Metal");
        native_metal_observation_exe.linkFramework("Foundation");
        native_metal_observation_compile_step.dependOn(
            &native_metal_observation_exe.step,
        );

        const run_native_metal_observation_model =
            b.addSystemCommand(&.{
                "python3",
                "-m",
                "unittest",
                "bench.tests.test_native_metal_readiness",
            });
        run_native_metal_observation_model.setCwd(b.path("."));
        run_native_metal_observation_model.setEnvironmentVariable(
            "PYTHONDONTWRITEBYTECODE",
            "1",
        );
        run_native_metal_observation_model.setEnvironmentVariable(
            "PYTHONPATH",
            ".",
        );

        const run_native_metal_observation_verifier =
            b.addSystemCommand(&.{"python3"});
        const run_native_metal_observation_verifier_suite =
            b.addSystemCommand(&.{"python3"});
        for ([_]*std.Build.Step.Run{
            run_native_metal_observation_verifier,
            run_native_metal_observation_verifier_suite,
        }) |run_observation| {
            run_observation.setCwd(b.path("."));
            run_observation.setEnvironmentVariable(
                "PYTHONDONTWRITEBYTECODE",
                "1",
            );
            run_observation.setEnvironmentVariable(
                "PYTHONPATH",
                ".",
            );
            run_observation.addFileArg(
                b.path("bench/native_metal_readiness.py"),
            );
            run_observation.addArg("--runner");
            run_observation.addArtifactArg(
                native_metal_observation_exe,
            );
            run_observation.step.dependOn(
                &native_metal_lib.step,
            );
            run_observation.step.dependOn(
                &run_native_metal_observation_tests.step,
            );
            run_observation.step.dependOn(
                &run_native_metal_observation_model.step,
            );
        }
        // The serialized hardware suite has a dedicated first device process.
        // Its compile-frontier dependency prevents any GPU command from
        // starting until every suite artifact and static isolation check has
        // completed once in this build graph. Focused readiness remains small.
        run_native_metal_observation_verifier_suite.step.dependOn(
            native_metal_suite_compile_step,
        );
        run_native_metal_correctness_tests.step.dependOn(
            &run_native_metal_observation_verifier.step,
        );
        native_metal_observation_pure_test_step.dependOn(
            &run_native_metal_observation_tests.step,
        );
        native_metal_observation_pure_test_step.dependOn(
            &run_native_metal_observation_model.step,
        );
        native_metal_observation_test_step.dependOn(
            &run_native_metal_observation_verifier.step,
        );

        const native_metal_allocation_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "tests/native_metal_allocation.zig",
                ),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
        native_metal_allocation_tests.root_module.addImport(
            "engine",
            engine_mod,
        );
        native_metal_allocation_tests.root_module.addImport(
            "config",
            config_mod,
        );
        const native_metal_fault_control_mod = b.createModule(.{
            .root_source_file = b.path(
                "tests/support/metal_fault_control.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        });
        native_metal_fault_control_mod.addImport(
            "engine",
            engine_mod,
        );
        native_metal_fault_control_mod.addImport(
            "config",
            config_mod,
        );
        native_metal_allocation_tests.root_module.addImport(
            "metal_fault_control",
            native_metal_fault_control_mod,
        );
        native_metal_allocation_tests.linkLibC();
        native_metal_allocation_tests.linkLibrary(shim);
        native_metal_allocation_tests.linkFramework("Metal");
        native_metal_allocation_tests.linkFramework("Foundation");
        const run_native_metal_allocation_tests =
            b.addRunArtifact(native_metal_allocation_tests);
        run_native_metal_allocation_tests.step.dependOn(
            &native_metal_lib.step,
        );
        const run_native_metal_allocation_suite =
            b.addRunArtifact(native_metal_allocation_tests);
        run_native_metal_allocation_suite.step.dependOn(
            &native_metal_lib.step,
        );
        run_native_metal_allocation_suite.step.dependOn(
            &run_native_metal_observation_verifier_suite.step,
        );

        // W6b emits one raw, independently decoded report from twenty real
        // production-adapter dispatches. The standalone and serialized-suite
        // runners are distinct so the focused gate does not pull in the
        // allocation suite, while either invocation still executes the
        // campaign exactly once.
        const native_metal_workload_report_exe = b.addExecutable(.{
            .name = "glacier-native-metal-workload-report",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "examples/native_metal_workload_report.zig",
                ),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
        native_metal_workload_report_exe.root_module.addImport(
            "engine",
            engine_mod,
        );
        native_metal_workload_report_exe.linkLibC();
        native_metal_workload_report_exe.linkLibrary(shim);
        native_metal_workload_report_exe.linkFramework("Metal");
        native_metal_workload_report_exe.linkFramework("Foundation");
        native_metal_workload_report_compile_step.dependOn(
            &native_metal_workload_report_exe.step,
        );

        const run_native_metal_workload_report_model =
            b.addSystemCommand(&.{
                "python3",
                "-m",
                "unittest",
                "bench.tests.test_native_metal_workload_report",
            });
        run_native_metal_workload_report_model.setCwd(b.path("."));
        run_native_metal_workload_report_model.setEnvironmentVariable(
            "PYTHONDONTWRITEBYTECODE",
            "1",
        );
        run_native_metal_workload_report_model.setEnvironmentVariable(
            "PYTHONPATH",
            ".",
        );
        run_native_metal_workload_report_model.step.dependOn(
            &run_native_workload_report_model.step,
        );

        const run_native_metal_workload_report_verifier =
            b.addSystemCommand(&.{"python3"});
        const run_native_metal_workload_report_suite =
            b.addSystemCommand(&.{"python3"});
        for ([_]*std.Build.Step.Run{
            run_native_metal_workload_report_verifier,
            run_native_metal_workload_report_suite,
        }) |run_report| {
            run_report.setCwd(b.path("."));
            run_report.setEnvironmentVariable(
                "PYTHONDONTWRITEBYTECODE",
                "1",
            );
            run_report.setEnvironmentVariable(
                "PYTHONPATH",
                ".",
            );
            run_report.addFileArg(
                b.path("bench/native_metal_workload_report.py"),
            );
            run_report.addArg("--runner");
            run_report.addArtifactArg(
                native_metal_workload_report_exe,
            );
            run_report.addArg("--metallib");
            run_report.addArg(metal_library_path);
            run_report.step.dependOn(&native_metal_lib.step);
            run_report.step.dependOn(
                &run_native_metal_workload_report_model.step,
            );
            run_report.step.dependOn(
                &run_native_workload_report_tests.step,
            );
        }
        if (native_metal_report_output) |path| {
            run_native_metal_workload_report_verifier.addArg(
                "--output",
            );
            run_native_metal_workload_report_verifier.addArg(path);
        }
        if (native_metal_suite_report_output) |path| {
            run_native_metal_workload_report_suite.addArg(
                "--output",
            );
            run_native_metal_workload_report_suite.addArg(path);
        }
        run_native_metal_workload_report_suite.step.dependOn(
            &run_native_metal_allocation_suite.step,
        );
        native_metal_workload_report_test_step.dependOn(
            &run_native_metal_workload_report_verifier.step,
        );

        // W7a retains every controlled cancellation and every real recovery
        // dispatch in a separate fixed campaign. The suite command is chained
        // after W6b so only one native disruption campaign is in flight.
        const native_metal_disruption_report_exe = b.addExecutable(.{
            .name = "glacier-native-metal-disruption-report",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "examples/native_metal_disruption_report.zig",
                ),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
        native_metal_disruption_report_exe.root_module.addImport(
            "engine",
            engine_mod,
        );
        native_metal_disruption_report_exe.linkLibC();
        native_metal_disruption_report_exe.linkLibrary(shim);
        native_metal_disruption_report_exe.linkFramework("Metal");
        native_metal_disruption_report_exe.linkFramework("Foundation");
        native_metal_disruption_report_compile_step.dependOn(
            &native_metal_disruption_report_exe.step,
        );

        const run_native_metal_disruption_report_model =
            b.addSystemCommand(&.{
                "python3",
                "-m",
                "unittest",
                "bench.tests.test_native_metal_disruption_report",
            });
        run_native_metal_disruption_report_model.setCwd(b.path("."));
        run_native_metal_disruption_report_model.setEnvironmentVariable(
            "PYTHONDONTWRITEBYTECODE",
            "1",
        );
        run_native_metal_disruption_report_model.setEnvironmentVariable(
            "PYTHONPATH",
            ".",
        );
        run_native_metal_disruption_report_model.step.dependOn(
            &run_native_metal_workload_report_model.step,
        );

        const run_native_metal_disruption_report_verifier =
            b.addSystemCommand(&.{"python3"});
        const run_native_metal_disruption_report_suite =
            b.addSystemCommand(&.{"python3"});
        for ([_]*std.Build.Step.Run{
            run_native_metal_disruption_report_verifier,
            run_native_metal_disruption_report_suite,
        }) |run_report| {
            run_report.setCwd(b.path("."));
            run_report.setEnvironmentVariable(
                "PYTHONDONTWRITEBYTECODE",
                "1",
            );
            run_report.setEnvironmentVariable(
                "PYTHONPATH",
                ".",
            );
            run_report.addFileArg(
                b.path("bench/native_metal_disruption_report.py"),
            );
            run_report.addArg("--runner");
            run_report.addArtifactArg(
                native_metal_disruption_report_exe,
            );
            run_report.addArg("--metallib");
            run_report.addArg(metal_library_path);
            run_report.step.dependOn(&native_metal_lib.step);
            run_report.step.dependOn(
                &run_native_metal_disruption_report_model.step,
            );
            run_report.step.dependOn(
                &run_native_workload_report_tests.step,
            );
        }
        if (native_metal_disruption_report_output) |path| {
            run_native_metal_disruption_report_verifier.addArg(
                "--output",
            );
            run_native_metal_disruption_report_verifier.addArg(path);
        }
        run_native_metal_disruption_report_suite.step.dependOn(
            &run_native_metal_workload_report_suite.step,
        );
        native_metal_disruption_report_test_step.dependOn(
            &run_native_metal_disruption_report_verifier.step,
        );

        // W7b-b3 exercises cancellation admission and settlement through
        // paired real host threads while retaining zero-command
        // cancellation records and a bounded set of real Metal controls.
        // The serialized runner follows W7a and completes before either soak.
        const native_metal_cancellation_storm_report_exe = b.addExecutable(.{
            .name = "glacier-native-metal-cancellation-storm-report",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "examples/native_metal_cancellation_storm_report.zig",
                ),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
        native_metal_cancellation_storm_report_exe.root_module.addImport(
            "engine",
            engine_mod,
        );
        native_metal_cancellation_storm_report_exe.linkLibC();
        native_metal_cancellation_storm_report_exe.linkLibrary(shim);
        native_metal_cancellation_storm_report_exe.linkFramework("Metal");
        native_metal_cancellation_storm_report_exe.linkFramework(
            "Foundation",
        );
        native_metal_cancellation_storm_report_compile_step.dependOn(
            &native_metal_cancellation_storm_report_exe.step,
        );

        const run_native_metal_cancellation_storm_report_model =
            b.addSystemCommand(&.{
                "python3",
                "-m",
                "unittest",
                "bench.tests.test_native_metal_cancellation_storm_report",
            });
        run_native_metal_cancellation_storm_report_model.setCwd(b.path("."));
        run_native_metal_cancellation_storm_report_model.setEnvironmentVariable(
            "PYTHONDONTWRITEBYTECODE",
            "1",
        );
        run_native_metal_cancellation_storm_report_model.setEnvironmentVariable(
            "PYTHONPATH",
            ".",
        );
        run_native_metal_cancellation_storm_report_model.step.dependOn(
            &run_native_metal_disruption_report_model.step,
        );

        const run_native_metal_cancellation_storm_report_verifier =
            b.addSystemCommand(&.{"python3"});
        const run_native_metal_cancellation_storm_report_suite =
            b.addSystemCommand(&.{"python3"});
        for ([_]*std.Build.Step.Run{
            run_native_metal_cancellation_storm_report_verifier,
            run_native_metal_cancellation_storm_report_suite,
        }) |run_report| {
            run_report.setCwd(b.path("."));
            run_report.setEnvironmentVariable(
                "PYTHONDONTWRITEBYTECODE",
                "1",
            );
            run_report.setEnvironmentVariable(
                "PYTHONPATH",
                ".",
            );
            run_report.addFileArg(
                b.path(
                    "bench/native_metal_cancellation_storm_report.py",
                ),
            );
            run_report.addArg("--runner");
            run_report.addArtifactArg(
                native_metal_cancellation_storm_report_exe,
            );
            run_report.addArg("--metallib");
            run_report.addArg(metal_library_path);
            run_report.step.dependOn(&native_metal_lib.step);
            run_report.step.dependOn(
                &run_native_metal_cancellation_storm_report_model.step,
            );
            run_report.step.dependOn(
                &run_native_workload_report_tests.step,
            );
        }
        if (native_metal_cancellation_storm_report_output) |path| {
            run_native_metal_cancellation_storm_report_verifier.addArg(
                "--output",
            );
            run_native_metal_cancellation_storm_report_verifier.addArg(
                path,
            );
        }
        run_native_metal_cancellation_storm_report_suite.step.dependOn(
            &run_native_metal_disruption_report_suite.step,
        );
        native_metal_cancellation_storm_report_test_step.dependOn(
            &run_native_metal_cancellation_storm_report_verifier.step,
        );

        // W7b keeps one Metal backend alive for six paced five-second
        // segments, checkpoints every independently verified W7 wire, then
        // repeats in a fresh worker process. This makes the 60-second soak
        // gate serialized after W7b-b3 while preserving a focused invocation.
        const native_metal_soak_worker_exe = b.addExecutable(.{
            .name = "glacier-native-metal-soak-worker",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "examples/native_metal_soak_worker.zig",
                ),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
        native_metal_soak_worker_exe.root_module.addImport(
            "engine",
            engine_mod,
        );
        native_metal_soak_worker_exe.linkLibC();
        native_metal_soak_worker_exe.linkLibrary(shim);
        native_metal_soak_worker_exe.linkFramework("Metal");
        native_metal_soak_worker_exe.linkFramework("Foundation");
        native_metal_soak_report_compile_step.dependOn(
            &native_metal_soak_worker_exe.step,
        );

        const run_native_metal_soak_report_model =
            b.addSystemCommand(&.{
                "python3",
                "-m",
                "unittest",
                "bench.tests.test_native_environment_admission",
                "bench.tests.test_native_metal_soak_report",
                "bench.tests.test_native_metal_soak_protocol",
            });
        run_native_metal_soak_report_model.setCwd(b.path("."));
        run_native_metal_soak_report_model.setEnvironmentVariable(
            "PYTHONDONTWRITEBYTECODE",
            "1",
        );
        run_native_metal_soak_report_model.setEnvironmentVariable(
            "PYTHONPATH",
            ".",
        );
        run_native_metal_soak_report_model.step.dependOn(
            &run_native_workload_campaign_model.step,
        );
        run_native_metal_soak_report_model.step.dependOn(
            &run_native_metal_disruption_report_model.step,
        );
        native_metal_soak_report_pure_test_step.dependOn(
            &run_native_metal_soak_report_model.step,
        );
        native_metal_soak_report_pure_test_step.dependOn(
            &run_native_workload_campaign_tests.step,
        );

        const run_native_metal_soak_environment_admission =
            b.addSystemCommand(&.{"python3"});
        const run_native_metal_soak_environment_admission_suite =
            b.addSystemCommand(&.{"python3"});
        const run_native_metal_process_kill_environment_admission =
            b.addSystemCommand(&.{"python3"});
        const run_native_metal_process_kill_environment_admission_suite =
            b.addSystemCommand(&.{"python3"});
        const run_native_metal_supervisor_recovery_death_admission =
            b.addSystemCommand(&.{"python3"});
        const run_native_metal_supervisor_recovery_death_admission_suite =
            b.addSystemCommand(&.{"python3"});
        for ([_]*std.Build.Step.Run{
            run_native_metal_soak_environment_admission,
            run_native_metal_soak_environment_admission_suite,
            run_native_metal_process_kill_environment_admission,
            run_native_metal_process_kill_environment_admission_suite,
            run_native_metal_supervisor_recovery_death_admission,
            run_native_metal_supervisor_recovery_death_admission_suite,
        }) |run_admission| {
            run_admission.setCwd(b.path("."));
            run_admission.setEnvironmentVariable(
                "PYTHONDONTWRITEBYTECODE",
                "1",
            );
            run_admission.setEnvironmentVariable(
                "PYTHONPATH",
                ".",
            );
            run_admission.addFileArg(
                b.path("bench/native_environment_admission.py"),
            );
            run_admission.addArgs(&.{
                "--timeout-seconds",
                "180",
                "--interval-seconds",
                "10",
                "--consecutive-samples",
                "2",
            });
            run_admission.step.dependOn(
                &native_metal_lib.step,
            );
            run_admission.step.dependOn(
                &native_metal_soak_worker_exe.step,
            );
            run_admission.step.dependOn(
                &run_native_metal_soak_report_model.step,
            );
            run_admission.step.dependOn(
                &run_native_workload_campaign_tests.step,
            );
        }

        const run_native_metal_soak_report_verifier =
            b.addSystemCommand(&.{"python3"});
        const run_native_metal_soak_report_suite =
            b.addSystemCommand(&.{"python3"});
        for ([_]*std.Build.Step.Run{
            run_native_metal_soak_report_verifier,
            run_native_metal_soak_report_suite,
        }) |run_soak| {
            run_soak.setCwd(b.path("."));
            run_soak.setEnvironmentVariable(
                "PYTHONDONTWRITEBYTECODE",
                "1",
            );
            run_soak.setEnvironmentVariable(
                "PYTHONPATH",
                ".",
            );
            run_soak.addFileArg(
                b.path("bench/native_metal_soak_report.py"),
            );
            run_soak.addArg("--worker");
            run_soak.addArtifactArg(native_metal_soak_worker_exe);
            run_soak.addArg("--metallib");
            run_soak.addArg(metal_library_path);
            run_soak.step.dependOn(&native_metal_lib.step);
            run_soak.step.dependOn(
                &run_native_metal_soak_report_model.step,
            );
            run_soak.step.dependOn(
                &run_native_workload_campaign_tests.step,
            );
        }
        if (native_metal_soak_output_dir) |path| {
            run_native_metal_soak_report_verifier.addArg(
                "--output-dir",
            );
            run_native_metal_soak_report_verifier.addArg(path);
        }
        // The supervisor always closes the live writer and launches a fresh
        // offline-verifier process. The option above changes retention only.
        run_native_metal_soak_report_verifier.step.dependOn(
            &run_native_metal_soak_environment_admission.step,
        );
        native_metal_soak_report_test_step.dependOn(
            &run_native_metal_soak_report_verifier.step,
        );
        run_native_metal_soak_environment_admission_suite.step.dependOn(
            &run_native_metal_cancellation_storm_report_suite.step,
        );
        run_native_metal_soak_report_suite.step.dependOn(
            &run_native_metal_soak_environment_admission_suite.step,
        );

        // W7b-b1 preserves the W7b-a geometry but seals a distinct schedule:
        // after segment six is independently verified, the supervisor sends
        // SIGKILL to that worker, reaps the exact signal status, publishes and
        // reopens the prefix, then continues in a fresh Metal process.
        const run_native_metal_process_kill_report =
            b.addSystemCommand(&.{"python3"});
        const run_native_metal_process_kill_report_suite =
            b.addSystemCommand(&.{"python3"});
        for ([_]*std.Build.Step.Run{
            run_native_metal_process_kill_report,
            run_native_metal_process_kill_report_suite,
        }) |run_process_kill| {
            run_process_kill.setCwd(b.path("."));
            run_process_kill.setEnvironmentVariable(
                "PYTHONDONTWRITEBYTECODE",
                "1",
            );
            run_process_kill.setEnvironmentVariable(
                "PYTHONPATH",
                ".",
            );
            run_process_kill.addFileArg(
                b.path("bench/native_metal_soak_report.py"),
            );
            run_process_kill.addArg("--worker");
            run_process_kill.addArtifactArg(
                native_metal_soak_worker_exe,
            );
            run_process_kill.addArg("--metallib");
            run_process_kill.addArg(metal_library_path);
            run_process_kill.addArg("--forced-process-restart");
            run_process_kill.step.dependOn(&native_metal_lib.step);
            run_process_kill.step.dependOn(
                &run_native_metal_soak_report_model.step,
            );
            run_process_kill.step.dependOn(
                &run_native_workload_campaign_tests.step,
            );
        }
        if (native_metal_process_kill_output_dir) |path| {
            run_native_metal_process_kill_report.addArg(
                "--output-dir",
            );
            run_native_metal_process_kill_report.addArg(path);
        }
        run_native_metal_process_kill_report.step.dependOn(
            &run_native_metal_process_kill_environment_admission.step,
        );
        native_metal_process_kill_report_test_step.dependOn(
            &run_native_metal_process_kill_report.step,
        );
        run_native_metal_process_kill_environment_admission_suite.step
            .dependOn(
            &run_native_metal_soak_report_suite.step,
        );
        run_native_metal_process_kill_report_suite.step.dependOn(
            &run_native_metal_process_kill_environment_admission_suite.step,
        );

        // The fault shim is a second, non-installed build of the same bridge.
        // Its control symbols and state exist only when this private macro is
        // set and never enter the normal engine module or production archive.
        const fault_shim = b.addLibrary(.{
            .name = "glacier_metal_fault_shim",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
        fault_shim.linkFramework("Metal");
        fault_shim.linkFramework("Foundation");
        fault_shim.root_module.addCSourceFile(.{
            .file = b.path("src/backends/metal/shim.m"),
            .flags = &.{
                "-fobjc-arc",
                "-ObjC",
                "-DGLACIER_METAL_TEST_FAULTS=1",
            },
        });

        const fault_opts = b.addOptions();
        fault_opts.addOption(bool, "metal_enabled", true);
        fault_opts.addOption(
            [:0]const u8,
            "metal_library_path",
            metal_library_path,
        );
        fault_opts.addOption(
            bool,
            "metal_test_faults",
            true,
        );
        const fault_config_mod = fault_opts.createModule();
        const fault_engine_mod = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        });
        fault_engine_mod.addImport("core", core_mod);
        fault_engine_mod.addImport(
            "config",
            fault_config_mod,
        );
        fault_engine_mod.link_libc = true;
        fault_engine_mod.linkLibrary(fault_shim);
        fault_engine_mod.linkFramework("Metal", .{});
        fault_engine_mod.linkFramework("Foundation", .{});
        if (int4_neon) |lib|
            fault_engine_mod.linkLibrary(lib);

        const fault_control_mod = b.createModule(.{
            .root_source_file = b.path(
                "tests/support/metal_fault_control.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        });
        fault_control_mod.addImport(
            "engine",
            fault_engine_mod,
        );
        fault_control_mod.addImport(
            "config",
            fault_config_mod,
        );

        const native_metal_inflight_process_kill_worker_exe =
            b.addExecutable(.{
                .name = "glacier-native-metal-inflight-process-kill-worker",
                .root_module = b.createModule(.{
                    .root_source_file = b.path(
                        "examples/native_metal_inflight_process_kill_worker.zig",
                    ),
                    .target = target,
                    .optimize = optimize,
                    .sanitize_thread = sanitize_thread,
                }),
            });
        native_metal_inflight_process_kill_worker_exe.root_module.addImport(
            "engine",
            fault_engine_mod,
        );
        native_metal_inflight_process_kill_worker_exe.root_module.addImport(
            "config",
            fault_config_mod,
        );
        native_metal_inflight_process_kill_worker_exe.root_module.addImport(
            "metal_fault_control",
            fault_control_mod,
        );
        native_metal_inflight_process_kill_worker_exe.root_module.addImport(
            "native_metal_inflight_process_kill_ready",
            native_metal_inflight_process_kill_ready_mod,
        );
        native_metal_inflight_process_kill_worker_exe.linkLibC();
        native_metal_inflight_process_kill_worker_exe.linkLibrary(
            fault_shim,
        );
        native_metal_inflight_process_kill_worker_exe.linkFramework(
            "Metal",
        );
        native_metal_inflight_process_kill_worker_exe.linkFramework(
            "Foundation",
        );
        native_metal_inflight_process_kill_report_compile_step.dependOn(
            &native_metal_inflight_process_kill_worker_exe.step,
        );

        const native_metal_fault_tests = b.addTest(.{
            .name = "glacier-native-metal-fault-tests",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "tests/native_metal_allocation.zig",
                ),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
            .filters = &.{
                "fault-injected Metal terminal error settles after physical success",
                "fault-only synthetic loss retires real Metal references with recovery",
                "retirement binds exact consumed native loss snapshot",
                "held Metal callback permits retirement and wait releases allocation mutex",
                "bounded two-slot Metal dispatch settles out of order without native replay",
                "Phase-B callback retirement settles native submission-ambiguous dispatch",
                "Phase-B callback retirement settles native completion-unknown dispatch",
                "Phase-B callback retirement settles native invalid-completion dispatch",
                "synthetic loss settles pending adapter dispatch through callback retirement",
            },
        });
        native_metal_fault_tests.root_module.addImport(
            "engine",
            fault_engine_mod,
        );
        native_metal_fault_tests.root_module.addImport(
            "config",
            fault_config_mod,
        );
        native_metal_fault_tests.root_module.addImport(
            "metal_fault_control",
            fault_control_mod,
        );
        native_metal_fault_tests.linkLibC();
        native_metal_fault_tests.linkLibrary(fault_shim);
        native_metal_fault_tests.linkFramework("Metal");
        native_metal_fault_tests.linkFramework("Foundation");

        const check_metal_fault_symbols =
            b.addSystemCommand(&.{"sh"});
        check_metal_fault_symbols.addFileArg(
            b.path("tools/check-metal-fault-isolation.sh"),
        );
        check_metal_fault_symbols.addArtifactArg(shim);
        check_metal_fault_symbols.addArtifactArg(
            fault_shim,
        );
        check_metal_fault_symbols.expectExitCode(0);

        // Compile every distinct artifact consumed by the serialized suite
        // before any native process or GPU command runs. Repeated references
        // below are intentional: named focused compile roots stay complete,
        // while this explicit inventory prevents a new suite consumer from
        // being hidden behind a runtime step.
        for ([_]*std.Build.Step.Compile{
            metal_tests,
            native_metal_inflight_process_kill_ready_tests,
            native_supervisor_recovery_death_report_tests,
            native_supervisor_recovery_death_report_verifier,
            native_supervisor_recovery_death_report_verifier_tests,
            native_metal_observation_tests,
            native_metal_observation_exe,
            native_metal_allocation_tests,
            native_workload_report_tests,
            native_workload_campaign_tests,
            native_metal_workload_report_exe,
            native_metal_disruption_report_exe,
            native_metal_cancellation_storm_report_exe,
            native_metal_soak_worker_exe,
            native_metal_inflight_process_kill_worker_exe,
            native_metal_fault_tests,
        }) |artifact| {
            native_metal_suite_compile_step.dependOn(
                &artifact.step,
            );
        }
        native_metal_suite_compile_step.dependOn(
            native_metal_observation_compile_step,
        );
        native_metal_suite_compile_step.dependOn(
            native_metal_allocation_compile_step,
        );
        native_metal_suite_compile_step.dependOn(
            native_metal_workload_report_compile_step,
        );
        native_metal_suite_compile_step.dependOn(
            native_metal_disruption_report_compile_step,
        );
        native_metal_suite_compile_step.dependOn(
            native_metal_cancellation_storm_report_compile_step,
        );
        native_metal_suite_compile_step.dependOn(
            native_metal_soak_report_compile_step,
        );
        native_metal_suite_compile_step.dependOn(
            native_metal_inflight_process_kill_report_compile_step,
        );
        native_metal_supervisor_recovery_death_report_compile_step.dependOn(
            &native_metal_soak_worker_exe.step,
        );
        native_metal_supervisor_recovery_death_report_compile_step.dependOn(
            native_supervisor_recovery_death_report_compile_step,
        );
        native_metal_supervisor_recovery_death_report_compile_step.dependOn(
            &native_metal_lib.step,
        );
        native_metal_suite_compile_step.dependOn(
            native_metal_supervisor_recovery_death_report_compile_step,
        );
        native_metal_suite_compile_step.dependOn(
            &native_metal_lib.step,
        );
        native_metal_suite_compile_step.dependOn(
            &check_metal_fault_symbols.step,
        );

        const run_native_metal_inflight_process_kill_report =
            b.addSystemCommand(&.{"python3"});
        const run_native_metal_inflight_process_kill_report_suite =
            b.addSystemCommand(&.{"python3"});
        for ([_]*std.Build.Step.Run{
            run_native_metal_inflight_process_kill_report,
            run_native_metal_inflight_process_kill_report_suite,
        }) |run_report| {
            run_report.setCwd(b.path("."));
            run_report.setEnvironmentVariable(
                "PYTHONDONTWRITEBYTECODE",
                "1",
            );
            run_report.setEnvironmentVariable(
                "PYTHONPATH",
                ".",
            );
            run_report.addFileArg(
                b.path(
                    "bench/native_metal_inflight_process_kill_report.py",
                ),
            );
            run_report.addArg("--victim");
            run_report.addArtifactArg(
                native_metal_inflight_process_kill_worker_exe,
            );
            run_report.addArg("--victim-metallib");
            run_report.addArg(metal_library_path);
            run_report.addArg("--recovery-runner");
            run_report.addArtifactArg(
                native_metal_workload_report_exe,
            );
            run_report.addArg("--recovery-metallib");
            run_report.addArg(metal_library_path);
            run_report.step.dependOn(&native_metal_lib.step);
            run_report.step.dependOn(
                &check_metal_fault_symbols.step,
            );
            run_report.step.dependOn(
                &run_native_metal_inflight_process_kill_report_model.step,
            );
            run_report.step.dependOn(
                &run_native_metal_workload_report_model.step,
            );
            run_report.step.dependOn(
                &run_native_workload_report_tests.step,
            );
        }
        if (native_metal_inflight_process_kill_report_output) |path| {
            run_native_metal_inflight_process_kill_report.addArg(
                "--output",
            );
            run_native_metal_inflight_process_kill_report.addArg(path);
        }
        native_metal_inflight_process_kill_report_test_step.dependOn(
            &run_native_metal_inflight_process_kill_report.step,
        );
        run_native_metal_inflight_process_kill_report_suite.step.dependOn(
            &run_native_metal_process_kill_report_suite.step,
        );

        // W7b-b5 kills two distinct supervisor roles only after each has
        // cleanly reaped its Metal worker and published a fixed durable
        // boundary. The suite variant follows the in-flight kill gate, while
        // both variants reuse the already compiled soak worker, shader
        // library, portable codec, and fresh Zig verifier.
        const run_native_metal_supervisor_recovery_death_report =
            b.addSystemCommand(&.{"python3"});
        const run_native_metal_supervisor_recovery_death_report_suite =
            b.addSystemCommand(&.{"python3"});
        for ([_]*std.Build.Step.Run{
            run_native_metal_supervisor_recovery_death_report,
            run_native_metal_supervisor_recovery_death_report_suite,
        }) |run_report| {
            run_report.setCwd(b.path("."));
            run_report.setEnvironmentVariable(
                "PYTHONDONTWRITEBYTECODE",
                "1",
            );
            run_report.setEnvironmentVariable(
                "PYTHONPATH",
                ".",
            );
            run_report.addFileArg(
                b.path(
                    "bench/native_metal_supervisor_recovery_death_campaign.py",
                ),
            );
            run_report.addArg("--worker");
            run_report.addArtifactArg(native_metal_soak_worker_exe);
            run_report.addArg("--metallib");
            run_report.addArg(metal_library_path);
            run_report.addArg("--zig-verifier");
            run_report.addArtifactArg(
                native_supervisor_recovery_death_report_verifier,
            );
            run_report.step.dependOn(&native_metal_lib.step);
            run_report.step.dependOn(
                &run_native_supervisor_recovery_death_protocol_model.step,
            );
            run_report.step.dependOn(
                &run_native_metal_soak_report_model.step,
            );
            run_report.step.dependOn(
                &run_native_workload_campaign_tests.step,
            );
        }
        if (native_metal_supervisor_recovery_death_output_dir) |path| {
            run_native_metal_supervisor_recovery_death_report.addArg(
                "--output-dir",
            );
            run_native_metal_supervisor_recovery_death_report.addArg(path);
        }
        run_native_metal_supervisor_recovery_death_report.step.dependOn(
            &run_native_metal_supervisor_recovery_death_admission.step,
        );
        native_metal_supervisor_recovery_death_report_test_step.dependOn(
            &run_native_metal_supervisor_recovery_death_report.step,
        );
        run_native_metal_supervisor_recovery_death_admission_suite.step
            .dependOn(
            &run_native_metal_inflight_process_kill_report_suite.step,
        );
        run_native_metal_supervisor_recovery_death_report_suite.step
            .dependOn(
            &run_native_metal_supervisor_recovery_death_admission_suite.step,
        );

        const run_native_metal_fault_tests =
            b.addRunArtifact(native_metal_fault_tests);
        run_native_metal_fault_tests.step.dependOn(
            &native_metal_lib.step,
        );
        run_native_metal_fault_tests.step.dependOn(
            &check_metal_fault_symbols.step,
        );
        const run_native_metal_fault_suite =
            b.addRunArtifact(native_metal_fault_tests);
        run_native_metal_fault_suite.step.dependOn(
            &native_metal_lib.step,
        );
        run_native_metal_fault_suite.step.dependOn(
            &check_metal_fault_symbols.step,
        );
        run_native_metal_fault_suite.step.dependOn(
            &run_native_metal_supervisor_recovery_death_report_suite.step,
        );
        const run_native_metal_correctness_suite =
            b.addRunArtifact(metal_tests);
        run_native_metal_correctness_suite.step.dependOn(
            &native_metal_lib.step,
        );
        run_native_metal_correctness_suite.step.dependOn(
            &run_native_metal_fault_suite.step,
        );
        native_metal_suite_test_step.dependOn(
            &run_native_metal_correctness_suite.step,
        );
        native_metal_allocation_compile_step.dependOn(
            &native_metal_allocation_tests.step,
        );
        native_metal_allocation_test_step.dependOn(
            &run_native_metal_allocation_tests.step,
        );
        native_metal_fault_test_step.dependOn(
            &run_native_metal_fault_tests.step,
        );
    } else {
        const native_metal_failure = b.addFail(
            "native Metal readiness requires a native macOS target and " ++
                "Metal enabled (omit -Dmetal=false)",
        );
        native_metal_observation_test_step.dependOn(
            &native_metal_failure.step,
        );
        native_metal_observation_pure_test_step.dependOn(
            &native_metal_failure.step,
        );
        native_metal_observation_compile_step.dependOn(
            &native_metal_failure.step,
        );
        native_metal_correctness_test_step.dependOn(
            &native_metal_failure.step,
        );
        native_metal_allocation_test_step.dependOn(
            &native_metal_failure.step,
        );
        native_metal_allocation_compile_step.dependOn(
            &native_metal_failure.step,
        );
        native_metal_fault_test_step.dependOn(
            &native_metal_failure.step,
        );
        native_metal_workload_report_test_step.dependOn(
            &native_metal_failure.step,
        );
        native_metal_workload_report_compile_step.dependOn(
            &native_metal_failure.step,
        );
        native_metal_disruption_report_test_step.dependOn(
            &native_metal_failure.step,
        );
        native_metal_disruption_report_compile_step.dependOn(
            &native_metal_failure.step,
        );
        native_metal_cancellation_storm_report_test_step.dependOn(
            &native_metal_failure.step,
        );
        native_metal_cancellation_storm_report_compile_step.dependOn(
            &native_metal_failure.step,
        );
        native_metal_soak_report_test_step.dependOn(
            &native_metal_failure.step,
        );
        native_metal_soak_report_pure_test_step.dependOn(
            &native_metal_failure.step,
        );
        native_metal_soak_report_compile_step.dependOn(
            &native_metal_failure.step,
        );
        native_metal_process_kill_report_test_step.dependOn(
            &native_metal_failure.step,
        );
        native_metal_inflight_process_kill_report_test_step.dependOn(
            &native_metal_failure.step,
        );
        native_metal_inflight_process_kill_report_compile_step.dependOn(
            &native_metal_failure.step,
        );
        native_metal_supervisor_recovery_death_report_test_step.dependOn(
            &native_metal_failure.step,
        );
        native_metal_supervisor_recovery_death_report_compile_step.dependOn(
            &native_metal_failure.step,
        );
        native_metal_suite_test_step.dependOn(
            &native_metal_failure.step,
        );
        native_metal_suite_compile_step.dependOn(
            &native_metal_failure.step,
        );
    }

    // W4b-a keeps pure tool execution separate from W4a. The retained
    // fixed-storage harness has no ambient I/O authority; its native report
    // must match the independent Python scheduler and tool replay exactly.
    const typed_tool_workload_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "src/core/typed_tool_workload.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    const run_typed_tool_workload_tests = b.addRunArtifact(
        typed_tool_workload_tests,
    );
    const typed_tool_workload_exe = b.addExecutable(.{
        .name = "glacier-typed-tool-workload",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "examples/typed_tool_workload.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    typed_tool_workload_exe.root_module.addImport("core", core_mod);
    const run_typed_tool_workload = b.addRunArtifact(
        typed_tool_workload_exe,
    );
    const typed_tool_workload_demo_step = b.step(
        "typed-tool-workload-demo",
        "Print the canonical typed tool workload report",
    );
    typed_tool_workload_demo_step.dependOn(
        &run_typed_tool_workload.step,
    );

    const run_typed_tool_workload_oracle =
        b.addSystemCommand(&.{"python3"});
    run_typed_tool_workload_oracle.setCwd(b.path("."));
    run_typed_tool_workload_oracle.setEnvironmentVariable(
        "PYTHONDONTWRITEBYTECODE",
        "1",
    );
    run_typed_tool_workload_oracle.setEnvironmentVariable(
        "PYTHONPATH",
        ".",
    );
    run_typed_tool_workload_oracle.addFileArg(
        b.path("bench/typed_tool_conformance.py"),
    );
    run_typed_tool_workload_oracle.addArg("--runner");
    run_typed_tool_workload_oracle.addArtifactArg(
        typed_tool_workload_exe,
    );
    run_typed_tool_workload_oracle.addArg("--fixture");
    run_typed_tool_workload_oracle.addFileArg(
        b.path("bench/results/typed-tool-conformance-v1.json"),
    );

    const typed_tool_workload_test_step = b.step(
        "typed-tool-workload-test",
        "Run typed tool workload tests and independent replay",
    );
    typed_tool_workload_test_step.dependOn(
        &run_typed_tool_workload_tests.step,
    );
    typed_tool_workload_test_step.dependOn(
        &run_typed_tool_workload_oracle.step,
    );
    const typed_tool_workload_compile_step = b.step(
        "typed-tool-workload-compile",
        "Compile the typed tool workload tests and runner",
    );
    typed_tool_workload_compile_step.dependOn(
        &typed_tool_workload_tests.step,
    );
    typed_tool_workload_compile_step.dependOn(
        &typed_tool_workload_exe.step,
    );
    test_step.dependOn(typed_tool_workload_test_step);
    test_compile_step.dependOn(typed_tool_workload_compile_step);

    // W4b-b starts the external-action handoff boundary with a portable,
    // allocation-free journal. The record core has no I/O authority: it
    // proves canonical intent, uncertainty, reconciliation, compensation,
    // and prefix recovery before a durable file adapter is introduced.
    const action_outbox_record_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "src/core/tool_action_outbox_conformance.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    const run_action_outbox_record_tests = b.addRunArtifact(
        action_outbox_record_tests,
    );
    const action_outbox_record_test_step = b.step(
        "action-outbox-record-test",
        "Run portable ActionOutbox record and recovery tests",
    );
    action_outbox_record_test_step.dependOn(
        &run_action_outbox_record_tests.step,
    );
    const action_outbox_record_exe = b.addExecutable(.{
        .name = "glacier-action-outbox-record",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "examples/action_outbox_record.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    action_outbox_record_exe.root_module.addImport("core", core_mod);
    const run_action_outbox_record = b.addRunArtifact(
        action_outbox_record_exe,
    );
    const action_outbox_record_demo_step = b.step(
        "action-outbox-record-demo",
        "Print the canonical ActionOutbox conformance report",
    );
    action_outbox_record_demo_step.dependOn(
        &run_action_outbox_record.step,
    );
    const run_action_outbox_record_oracle =
        b.addSystemCommand(&.{"python3"});
    run_action_outbox_record_oracle.setCwd(b.path("."));
    run_action_outbox_record_oracle.setEnvironmentVariable(
        "PYTHONDONTWRITEBYTECODE",
        "1",
    );
    run_action_outbox_record_oracle.setEnvironmentVariable(
        "PYTHONPATH",
        ".",
    );
    run_action_outbox_record_oracle.addFileArg(
        b.path("bench/action_outbox_conformance.py"),
    );
    run_action_outbox_record_oracle.addArg("--runner");
    run_action_outbox_record_oracle.addArtifactArg(
        action_outbox_record_exe,
    );
    run_action_outbox_record_oracle.addArg("--fixture");
    run_action_outbox_record_oracle.addFileArg(
        b.path(
            "bench/results/action-outbox-conformance-v1.json",
        ),
    );
    action_outbox_record_test_step.dependOn(
        &run_action_outbox_record_oracle.step,
    );
    const action_outbox_record_compile_step = b.step(
        "action-outbox-record-compile",
        "Compile portable ActionOutbox record tests and report",
    );
    action_outbox_record_compile_step.dependOn(
        &action_outbox_record_tests.step,
    );
    action_outbox_record_compile_step.dependOn(
        &action_outbox_record_exe.step,
    );
    test_step.dependOn(action_outbox_record_test_step);
    test_compile_step.dependOn(action_outbox_record_compile_step);

    // W4b-c binds the portable ActionOutbox protocol to an exclusively locked,
    // descriptor-relative POSIX file. Deterministic native/Python matrices
    // remain separate from the real 49-process-death filesystem campaign.
    const action_outbox_store_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "src/core/tool_action_outbox_store_conformance.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    const run_action_outbox_store_tests = b.addRunArtifact(
        action_outbox_store_tests,
    );
    const action_outbox_store_exe = b.addExecutable(.{
        .name = "glacier-action-outbox-store",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "examples/action_outbox_store.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    action_outbox_store_exe.root_module.addImport(
        "core",
        core_mod,
    );
    const run_action_outbox_store_oracle =
        b.addSystemCommand(&.{"python3"});
    run_action_outbox_store_oracle.setCwd(b.path("."));
    run_action_outbox_store_oracle.setEnvironmentVariable(
        "PYTHONDONTWRITEBYTECODE",
        "1",
    );
    run_action_outbox_store_oracle.setEnvironmentVariable(
        "PYTHONPATH",
        ".",
    );
    run_action_outbox_store_oracle.addFileArg(
        b.path("bench/action_outbox_store_conformance.py"),
    );
    run_action_outbox_store_oracle.addArg("--runner");
    run_action_outbox_store_oracle.addArtifactArg(
        action_outbox_store_exe,
    );
    run_action_outbox_store_oracle.addArg("--fixture");
    run_action_outbox_store_oracle.addFileArg(
        b.path(
            "bench/results/action-outbox-store-conformance-v1.json",
        ),
    );

    const action_outbox_file_worker_exe = b.addExecutable(.{
        .name = "glacier-action-outbox-file-worker",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "bench/action_outbox_file_worker.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    action_outbox_file_worker_exe.root_module.addImport(
        "core",
        core_mod,
    );
    const action_outbox_file_recovery_exe =
        b.addExecutable(.{
            .name = "glacier-action-outbox-file-recovery",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "examples/action_outbox_file_recovery.zig",
                ),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
    action_outbox_file_recovery_exe.root_module.addImport(
        "core",
        core_mod,
    );
    const run_action_outbox_file_recovery =
        b.addRunArtifact(action_outbox_file_recovery_exe);
    run_action_outbox_file_recovery.addArtifactArg(
        action_outbox_file_worker_exe,
    );

    const action_outbox_recovery_test_step = b.step(
        "action-outbox-recovery-test",
        "Run durable ActionOutbox model and process-death recovery",
    );
    action_outbox_recovery_test_step.dependOn(
        &run_action_outbox_store_tests.step,
    );
    action_outbox_recovery_test_step.dependOn(
        &run_action_outbox_store_oracle.step,
    );
    action_outbox_recovery_test_step.dependOn(
        &run_action_outbox_file_recovery.step,
    );
    const action_outbox_recovery_compile_step = b.step(
        "action-outbox-recovery-compile",
        "Compile durable ActionOutbox tests, runner and worker",
    );
    action_outbox_recovery_compile_step.dependOn(
        &action_outbox_store_tests.step,
    );
    action_outbox_recovery_compile_step.dependOn(
        &action_outbox_store_exe.step,
    );
    action_outbox_recovery_compile_step.dependOn(
        &action_outbox_file_worker_exe.step,
    );
    action_outbox_recovery_compile_step.dependOn(
        &action_outbox_file_recovery_exe.step,
    );
    test_step.dependOn(action_outbox_recovery_test_step);
    test_compile_step.dependOn(
        action_outbox_recovery_compile_step,
    );

    // W4b-d composes the unchanged record/store layers with a bounded
    // same-process fake authority. It proves intent-before-callback ordering,
    // authoritative generation fencing, stale-dispatch rejection, exact
    // terminal replay, and reopen convergence under deterministic append
    // faults. This is not a live network or new process-death campaign.
    const action_outbox_dispatch_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "src/core/tool_action_outbox_dispatch_conformance.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    const run_action_outbox_dispatch_tests = b.addRunArtifact(
        action_outbox_dispatch_tests,
    );
    const action_outbox_adapter_exe = b.addExecutable(.{
        .name = "glacier-action-outbox-adapter",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "examples/action_outbox_adapter.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    action_outbox_adapter_exe.root_module.addImport(
        "core",
        core_mod,
    );
    const run_action_outbox_dispatch_model =
        b.addSystemCommand(&.{
            "python3",
            "-m",
            "unittest",
            "bench.tests.test_action_outbox_adapter_conformance",
        });
    run_action_outbox_dispatch_model.setCwd(b.path("."));
    run_action_outbox_dispatch_model.setEnvironmentVariable(
        "PYTHONDONTWRITEBYTECODE",
        "1",
    );
    run_action_outbox_dispatch_model.setEnvironmentVariable(
        "PYTHONPATH",
        ".",
    );
    const run_action_outbox_adapter_oracle =
        b.addSystemCommand(&.{"python3"});
    run_action_outbox_adapter_oracle.setCwd(b.path("."));
    run_action_outbox_adapter_oracle.setEnvironmentVariable(
        "PYTHONDONTWRITEBYTECODE",
        "1",
    );
    run_action_outbox_adapter_oracle.setEnvironmentVariable(
        "PYTHONPATH",
        ".",
    );
    run_action_outbox_adapter_oracle.addFileArg(
        b.path("bench/action_outbox_adapter_conformance.py"),
    );
    run_action_outbox_adapter_oracle.addArg("--runner");
    run_action_outbox_adapter_oracle.addArtifactArg(
        action_outbox_adapter_exe,
    );
    const action_outbox_dispatch_test_step = b.step(
        "action-outbox-dispatch-test",
        "Run fenced ActionOutbox dispatch and status conformance",
    );
    action_outbox_dispatch_test_step.dependOn(
        &run_action_outbox_dispatch_tests.step,
    );
    action_outbox_dispatch_test_step.dependOn(
        &run_action_outbox_dispatch_model.step,
    );
    action_outbox_dispatch_test_step.dependOn(
        &run_action_outbox_adapter_oracle.step,
    );
    const action_outbox_dispatch_compile_step = b.step(
        "action-outbox-dispatch-compile",
        "Compile fenced ActionOutbox dispatch conformance",
    );
    action_outbox_dispatch_compile_step.dependOn(
        &action_outbox_dispatch_tests.step,
    );
    action_outbox_dispatch_compile_step.dependOn(
        &action_outbox_adapter_exe.step,
    );
    test_step.dependOn(action_outbox_dispatch_test_step);
    test_compile_step.dependOn(
        action_outbox_dispatch_compile_step,
    );

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

    // Destructive sweep commit demonstration. A separately scoped commit
    // grant authorizes one exact retired target after the collection plan is
    // regenerated; the fixture makes that target the allocator tail so both
    // logical release and physical allocator reclamation are observable.
    const continuation_sweep_commit_demo_exe = b.addExecutable(.{
        .name = "glacier-continuation-object-sweep-commit-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "examples/continuation_object_sweep_commit.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    continuation_sweep_commit_demo_exe.root_module.addImport("core", core_mod);
    const run_continuation_sweep_commit_demo = b.addRunArtifact(
        continuation_sweep_commit_demo_exe,
    );
    const continuation_sweep_commit_demo_step = b.step(
        "continuation-sweep-commit-demo",
        "Run the atomic continuation object sweep commit demo",
    );
    continuation_sweep_commit_demo_step.dependOn(
        &run_continuation_sweep_commit_demo.step,
    );
    test_step.dependOn(&run_continuation_sweep_commit_demo.step);
    test_compile_step.dependOn(&continuation_sweep_commit_demo_exe.step);

    // Fixed pointer-free body/footer record for an already committed sweep.
    // The demo also exercises snapshot-bound append/repair capabilities and a
    // deterministic crash-storage model without performing real filesystem I/O.
    const continuation_sweep_record_demo_exe = b.addExecutable(.{
        .name = "glacier-continuation-object-sweep-record-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "examples/continuation_object_sweep_record.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    continuation_sweep_record_demo_exe.root_module.addImport("core", core_mod);
    const run_continuation_sweep_record_demo = b.addRunArtifact(
        continuation_sweep_record_demo_exe,
    );
    const continuation_sweep_record_demo_step = b.step(
        "continuation-sweep-record-demo",
        "Run sweep record, recovery, writer and repair conformance",
    );
    continuation_sweep_record_demo_step.dependOn(
        &run_continuation_sweep_record_demo.step,
    );
    test_step.dependOn(&run_continuation_sweep_record_demo.step);
    test_compile_step.dependOn(&continuation_sweep_record_demo_exe.step);

    // Descriptor-relative real-file publication and subprocess-death recovery.
    // The worker is intentionally separate so lock release and page-cache
    // visibility are exercised across an actual process boundary.
    const continuation_sweep_file_worker_exe = b.addExecutable(.{
        .name = "glacier-continuation-object-sweep-file-worker",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "bench/continuation_object_sweep_file_worker.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    continuation_sweep_file_worker_exe.root_module.addImport("core", core_mod);
    const continuation_sweep_fixture_mod = b.createModule(.{
        .root_source_file = b.path(
            "examples/continuation_object_sweep_fixture.zig",
        ),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
    });
    continuation_sweep_fixture_mod.addImport("core", core_mod);
    const continuation_sweep_file_demo_exe = b.addExecutable(.{
        .name = "glacier-continuation-object-sweep-file-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "examples/continuation_object_sweep_file.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    continuation_sweep_file_demo_exe.root_module.addImport("core", core_mod);
    continuation_sweep_file_demo_exe.root_module.addImport(
        "sweep_fixture",
        continuation_sweep_fixture_mod,
    );
    const run_continuation_sweep_file_demo = b.addRunArtifact(
        continuation_sweep_file_demo_exe,
    );
    run_continuation_sweep_file_demo.addArtifactArg(
        continuation_sweep_file_worker_exe,
    );
    const continuation_sweep_file_demo_step = b.step(
        "continuation-sweep-file-demo",
        "Run descriptor-relative sweep file and process-death conformance",
    );
    continuation_sweep_file_demo_step.dependOn(
        &run_continuation_sweep_file_demo.step,
    );
    test_step.dependOn(&run_continuation_sweep_file_demo.step);
    test_compile_step.dependOn(&continuation_sweep_file_demo_exe.step);
    test_compile_step.dependOn(&continuation_sweep_file_worker_exe.step);

    // Canonical durable payload snapshots use a stable lock inode and
    // copy-on-write promotion. The worker dies after candidate write/sync,
    // atomic rename, and directory sync so recovery sees real process loss.
    const continuation_payload_file_worker_exe = b.addExecutable(.{
        .name = "glacier-continuation-object-payload-file-worker",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "bench/continuation_object_payload_file_worker.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    continuation_payload_file_worker_exe.root_module.addImport(
        "core",
        core_mod,
    );
    const continuation_payload_file_demo_exe = b.addExecutable(.{
        .name = "glacier-continuation-object-payload-file-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "examples/continuation_object_payload_file.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    continuation_payload_file_demo_exe.root_module.addImport(
        "core",
        core_mod,
    );
    continuation_payload_file_demo_exe.root_module.addImport(
        "sweep_fixture",
        continuation_sweep_fixture_mod,
    );
    const run_continuation_payload_file_demo = b.addRunArtifact(
        continuation_payload_file_demo_exe,
    );
    run_continuation_payload_file_demo.addArtifactArg(
        continuation_payload_file_worker_exe,
    );
    const continuation_payload_file_demo_step = b.step(
        "continuation-payload-file-demo",
        "Run durable payload promotion and process-death conformance",
    );
    continuation_payload_file_demo_step.dependOn(
        &run_continuation_payload_file_demo.step,
    );
    test_step.dependOn(&run_continuation_payload_file_demo.step);
    test_compile_step.dependOn(
        &continuation_payload_file_demo_exe.step,
    );
    test_compile_step.dependOn(
        &continuation_payload_file_worker_exe.step,
    );

    // A source worker publishes token 503, syncs a complete checkpoint and
    // exits. A fresh target worker reacquires ownership, remaps paged-KV,
    // restores RNG/output/commit state and publishes token 504 exactly once.
    const continuation_live_restart_worker_exe = b.addExecutable(.{
        .name = "glacier-continuation-live-restart-worker",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "bench/continuation_live_restart_worker.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    continuation_live_restart_worker_exe.root_module.addImport(
        "core",
        core_mod,
    );
    continuation_live_restart_worker_exe.root_module.addImport(
        "engine",
        engine_mod,
    );
    continuation_live_restart_worker_exe.linkLibC();
    if (int4_neon) |lib|
        continuation_live_restart_worker_exe.linkLibrary(lib);
    const continuation_live_restart_demo_exe = b.addExecutable(.{
        .name = "glacier-continuation-live-restart-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "examples/continuation_live_restart.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    continuation_live_restart_demo_exe.linkLibC();
    const run_continuation_live_restart_demo = b.addRunArtifact(
        continuation_live_restart_demo_exe,
    );
    run_continuation_live_restart_demo.addArtifactArg(
        continuation_live_restart_worker_exe,
    );
    const continuation_live_restart_demo_step = b.step(
        "continuation-live-restart-demo",
        "Run two-process paged-KV/RNG/output continuation proof",
    );
    continuation_live_restart_demo_step.dependOn(
        &run_continuation_live_restart_demo.step,
    );
    test_step.dependOn(&run_continuation_live_restart_demo.step);
    test_compile_step.dependOn(
        &continuation_live_restart_demo_exe.step,
    );
    test_compile_step.dependOn(
        &continuation_live_restart_worker_exe.step,
    );

    // Prepared-text handoff first closes the exact source publication
    // authority into a selector-chosen archive. A fresh target process holds
    // the exclusive lease, proves a second writer would block, consumes the
    // source-exit grant, restores at N, and reaches a receipt-independent
    // terminal semantic with no duplicate publication sequence.
    const prepared_text_live_restart_worker_exe = b.addExecutable(.{
        .name = "glacier-prepared-text-live-restart-worker",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "bench/prepared_text_live_restart_worker.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    prepared_text_live_restart_worker_exe.root_module.addImport(
        "core",
        core_mod,
    );
    prepared_text_live_restart_worker_exe.root_module.addImport(
        "engine",
        engine_mod,
    );
    prepared_text_live_restart_worker_exe.linkLibC();
    if (int4_neon) |lib|
        prepared_text_live_restart_worker_exe.linkLibrary(lib);
    const prepared_text_live_restart_demo_exe = b.addExecutable(.{
        .name = "glacier-prepared-text-live-restart-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "examples/prepared_text_live_restart.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    prepared_text_live_restart_demo_exe.linkLibC();
    const run_prepared_text_live_restart_demo = b.addRunArtifact(
        prepared_text_live_restart_demo_exe,
    );
    run_prepared_text_live_restart_demo.addArtifactArg(
        prepared_text_live_restart_worker_exe,
    );
    const prepared_text_live_restart_demo_step = b.step(
        "prepared-text-live-restart-demo",
        "Run selected source-exit and fresh-process prepared-text proof",
    );
    prepared_text_live_restart_demo_step.dependOn(
        &run_prepared_text_live_restart_demo.step,
    );
    test_step.dependOn(&run_prepared_text_live_restart_demo.step);
    test_compile_step.dependOn(
        &prepared_text_live_restart_demo_exe.step,
    );
    test_compile_step.dependOn(
        &prepared_text_live_restart_worker_exe.step,
    );

    // R1j compiles the acknowledged-delivery layers through one facade
    // so the ordinary test, compile-only, and durable-profile gates share the
    // same Zig artifact instead of rebuilding each module as a separate root.
    const prepared_text_acknowledged_delivery_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "src/prepared_text_acknowledged_delivery.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    prepared_text_acknowledged_delivery_tests.root_module.addImport(
        "core",
        core_mod,
    );
    prepared_text_acknowledged_delivery_tests.linkLibC();
    if (int4_neon) |lib|
        prepared_text_acknowledged_delivery_tests.linkLibrary(lib);
    const run_prepared_text_acknowledged_delivery_tests =
        b.addRunArtifact(
            prepared_text_acknowledged_delivery_tests,
        );
    const prepared_text_acknowledged_delivery_test_step = b.step(
        "prepared-text-acknowledged-delivery-test",
        "Run prepared-text acknowledged delivery and recovery tests",
    );
    prepared_text_acknowledged_delivery_test_step.dependOn(
        &run_prepared_text_acknowledged_delivery_tests.step,
    );
    const prepared_text_acknowledged_delivery_compile_step =
        b.step(
            "prepared-text-acknowledged-delivery-compile",
            "Compile prepared-text acknowledged delivery once",
        );
    prepared_text_acknowledged_delivery_compile_step.dependOn(
        &prepared_text_acknowledged_delivery_tests.step,
    );
    test_step.dependOn(
        prepared_text_acknowledged_delivery_test_step,
    );
    test_compile_step.dependOn(
        prepared_text_acknowledged_delivery_compile_step,
    );

    // The POSIX recovery worker is compiled once per supported target. A
    // native worker is then reused by all 49 process-death cases: seven
    // generation-one bootstrap boundaries, 23 source-transition boundaries,
    // and 19 target-transition boundaries. Pure Python protocol/decoder tests
    // run before the real SIGKILL matrix, whose disposable directory is a
    // declared build output rather than a repository-local fixture.
    const prepared_text_recovery_target_available =
        target.result.os.tag == .macos or
        target.result.os.tag == .linux or
        target.result.os.tag == .freebsd;
    const prepared_text_recovery_worker_exe: ?*std.Build.Step.Compile = blk: {
        if (!prepared_text_recovery_target_available) break :blk null;
        const worker = b.addExecutable(.{
            .name = "glacier-prepared-text-recovery-worker",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "bench/prepared_text_recovery_worker.zig",
                ),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
        worker.root_module.addImport("engine", engine_mod);
        worker.linkLibC();
        if (int4_neon) |lib| worker.linkLibrary(lib);
        break :blk worker;
    };
    const prepared_text_recovery_test_step = b.step(
        "prepared-text-recovery-test",
        "Run prepared-text source and target process-death recovery",
    );
    const prepared_text_recovery_native_available =
        (target.result.os.tag == .macos or
            target.result.os.tag == .linux) and
        target.result.cpu.arch == builtin.cpu.arch and
        target.result.os.tag == builtin.os.tag and
        target.result.abi == builtin.abi;
    if (prepared_text_recovery_native_available) {
        const run_prepared_text_recovery_model =
            b.addSystemCommand(&.{
                "python3",
                "-m",
                "unittest",
                "bench.tests.test_prepared_text_result_sink",
                "bench.tests.test_prepared_text_recovery_campaign",
            });
        run_prepared_text_recovery_model.setCwd(b.path("."));
        run_prepared_text_recovery_model.setEnvironmentVariable(
            "PYTHONDONTWRITEBYTECODE",
            "1",
        );
        run_prepared_text_recovery_model.setEnvironmentVariable(
            "PYTHONPATH",
            ".",
        );

        const run_prepared_text_recovery_campaign =
            b.addSystemCommand(&.{
                "python3",
                "-m",
                "bench.prepared_text_recovery_campaign",
                "--worker",
            });
        run_prepared_text_recovery_campaign.addArtifactArg(
            prepared_text_recovery_worker_exe.?,
        );
        run_prepared_text_recovery_campaign.addArg("--directory");
        _ = run_prepared_text_recovery_campaign.addOutputDirectoryArg(
            "prepared-text-recovery",
        );
        run_prepared_text_recovery_campaign.setCwd(b.path("."));
        run_prepared_text_recovery_campaign.setEnvironmentVariable(
            "PYTHONDONTWRITEBYTECODE",
            "1",
        );
        run_prepared_text_recovery_campaign.setEnvironmentVariable(
            "PYTHONPATH",
            ".",
        );
        run_prepared_text_recovery_campaign.step.dependOn(
            &run_prepared_text_recovery_model.step,
        );
        prepared_text_recovery_test_step.dependOn(
            &run_prepared_text_recovery_campaign.step,
        );
    } else {
        const prepared_text_recovery_failure = b.addFail(
            "prepared-text-recovery-test requires a native macOS or Linux " ++
                "target",
        );
        prepared_text_recovery_test_step.dependOn(
            &prepared_text_recovery_failure.step,
        );
    }
    test_step.dependOn(prepared_text_recovery_test_step);
    if (prepared_text_recovery_worker_exe) |worker|
        test_compile_step.dependOn(&worker.step);

    // Complete checkpoint sets are immutable archives selected by one fixed
    // root switch. A worker dies after every archive and selector durability
    // phase; fresh recovery accepts only the previous or successor set, then
    // the existing restart worker resumes from that selected archive.
    const continuation_checkpoint_file_worker_exe = b.addExecutable(.{
        .name = "glacier-continuation-checkpoint-file-worker",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "bench/continuation_checkpoint_file_worker.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    continuation_checkpoint_file_worker_exe.root_module.addImport(
        "core",
        core_mod,
    );
    const continuation_checkpoint_file_demo_exe = b.addExecutable(.{
        .name = "glacier-continuation-checkpoint-file-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "examples/continuation_checkpoint_file.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    continuation_checkpoint_file_demo_exe.root_module.addImport(
        "core",
        core_mod,
    );
    continuation_checkpoint_file_demo_exe.root_module.addImport(
        "engine",
        engine_mod,
    );
    const run_continuation_checkpoint_file_demo = b.addRunArtifact(
        continuation_checkpoint_file_demo_exe,
    );
    run_continuation_checkpoint_file_demo.addArtifactArg(
        continuation_checkpoint_file_worker_exe,
    );
    run_continuation_checkpoint_file_demo.addArtifactArg(
        continuation_live_restart_worker_exe,
    );
    const continuation_checkpoint_file_demo_step = b.step(
        "continuation-checkpoint-file-demo",
        "Run atomic checkpoint root-switch process-death conformance",
    );
    continuation_checkpoint_file_demo_step.dependOn(
        &run_continuation_checkpoint_file_demo.step,
    );
    test_step.dependOn(&run_continuation_checkpoint_file_demo.step);
    test_compile_step.dependOn(
        &continuation_checkpoint_file_demo_exe.step,
    );
    test_compile_step.dependOn(
        &continuation_checkpoint_file_worker_exe.step,
    );

    // Shared authority-free image/audio/video identity, rational timeline,
    // and exact-once publication contract. This is a model-free foundation;
    // decoder, encoder, device, and network integration remain separate.
    const media_contract_demo_exe = b.addExecutable(.{
        .name = "glacier-media-contract-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "examples/media_contract.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    media_contract_demo_exe.root_module.addImport("core", core_mod);
    const run_media_contract_demo = b.addRunArtifact(
        media_contract_demo_exe,
    );
    const media_contract_demo_step = b.step(
        "media-contract-demo",
        "Run the shared image/audio/video contract demo",
    );
    media_contract_demo_step.dependOn(&run_media_contract_demo.step);
    test_step.dependOn(&run_media_contract_demo.step);
    test_compile_step.dependOn(&media_contract_demo_exe.step);

    // Sealed decode plans plus tiny bounded RGB, PCM, and intra-frame video
    // fixtures. The identity decoder writes only to caller-owned storage and
    // exposes complete per-unit source mappings without model or I/O authority.
    const media_decode_fixture_demo_exe = b.addExecutable(.{
        .name = "glacier-media-decode-fixture-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "examples/media_decode_fixture.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    media_decode_fixture_demo_exe.root_module.addImport("core", core_mod);
    const run_media_decode_fixture_demo = b.addRunArtifact(
        media_decode_fixture_demo_exe,
    );
    const media_decode_fixture_demo_step = b.step(
        "media-decode-fixture-demo",
        "Run bounded image/audio/video decode fixtures",
    );
    media_decode_fixture_demo_step.dependOn(
        &run_media_decode_fixture_demo.step,
    );
    test_step.dependOn(&run_media_decode_fixture_demo.step);
    test_compile_step.dependOn(&media_decode_fixture_demo_exe.step);

    // Deterministic bounded transforms over the decoded fixtures: image crop,
    // nearest resize and tile mappings; weighted PCM mix with exact integer
    // decimation; and keyframe-only video selection. All output and mapping
    // storage remains caller-owned and no model or I/O authority is present.
    const media_transform_demo_exe = b.addExecutable(.{
        .name = "glacier-media-transform-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "examples/media_transform.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    media_transform_demo_exe.root_module.addImport("core", core_mod);
    const run_media_transform_demo = b.addRunArtifact(
        media_transform_demo_exe,
    );
    const media_transform_demo_step = b.step(
        "media-transform-demo",
        "Run deterministic bounded image/audio/video transforms",
    );
    media_transform_demo_step.dependOn(
        &run_media_transform_demo.step,
    );
    test_step.dependOn(&run_media_transform_demo.step);
    test_compile_step.dependOn(&media_transform_demo_exe.step);

    // Full model-free media runtime vertical: exact ResourceBank admission,
    // transform candidate execution, candidate revalidation, transactional
    // media publication, explicit abort/scrub, and exact final release.
    const media_runtime_demo_exe = b.addExecutable(.{
        .name = "glacier-media-runtime-txn-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "examples/media_runtime_txn.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    media_runtime_demo_exe.root_module.addImport("core", core_mod);
    const run_media_runtime_demo = b.addRunArtifact(
        media_runtime_demo_exe,
    );
    const media_runtime_demo_step = b.step(
        "media-runtime-demo",
        "Run resource-admitted transactional media publication",
    );
    media_runtime_demo_step.dependOn(
        &run_media_runtime_demo.step,
    );
    test_step.dependOn(&run_media_runtime_demo.step);
    test_compile_step.dependOn(&media_runtime_demo_exe.step);

    // Hierarchical media ownership: every decoded source, mapping table,
    // scratch region, and output receives its own generation-fenced LeaseTree
    // allocation before execution. Provisional buffers can retire early while
    // the published output remains live.
    const media_runtime_lease_demo_exe = b.addExecutable(.{
        .name = "glacier-media-runtime-lease-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "examples/media_runtime_lease.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    media_runtime_lease_demo_exe.root_module.addImport("core", core_mod);
    const run_media_runtime_lease_demo = b.addRunArtifact(
        media_runtime_lease_demo_exe,
    );
    const media_runtime_lease_demo_step = b.step(
        "media-runtime-lease-demo",
        "Run per-buffer LeaseTree media ownership and early retirement",
    );
    media_runtime_lease_demo_step.dependOn(
        &run_media_runtime_lease_demo.step,
    );
    test_step.dependOn(&run_media_runtime_lease_demo.step);
    test_compile_step.dependOn(&media_runtime_lease_demo_exe.step);

    // Bounded multi-chunk media stream: exact contiguous target boundaries,
    // one retained output lease per committed chunk, cancellation-safe
    // unpublished reclamation, and a portable chunk receipt chain.
    const media_stream_demo_exe = b.addExecutable(.{
        .name = "glacier-media-stream-runtime-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "examples/media_stream_runtime.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    media_stream_demo_exe.root_module.addImport("core", core_mod);
    const run_media_stream_demo = b.addRunArtifact(
        media_stream_demo_exe,
    );
    const media_stream_demo_step = b.step(
        "media-stream-demo",
        "Run bounded two-chunk image/audio/video streams",
    );
    media_stream_demo_step.dependOn(
        &run_media_stream_demo.step,
    );
    test_step.dependOn(&run_media_stream_demo.step);
    test_compile_step.dependOn(&media_stream_demo_exe.step);

    // Portable media stream checkpoints: release the source Bank, charge
    // retained outputs in a fresh Bank before materialization, then append
    // the exact next image/audio/video chunk.
    const media_stream_continuation_demo_exe = b.addExecutable(.{
        .name = "glacier-media-stream-continuation-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "examples/media_stream_continuation.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    media_stream_continuation_demo_exe.root_module.addImport(
        "core",
        core_mod,
    );
    const run_media_stream_continuation_demo =
        b.addRunArtifact(
            media_stream_continuation_demo_exe,
        );
    const media_stream_continuation_demo_step = b.step(
        "media-stream-continuation-demo",
        "Run fresh-Bank image/audio/video stream resume",
    );
    media_stream_continuation_demo_step.dependOn(
        &run_media_stream_continuation_demo.step,
    );
    test_step.dependOn(
        &run_media_stream_continuation_demo.step,
    );
    test_compile_step.dependOn(
        &media_stream_continuation_demo_exe.step,
    );

    // A source process syncs three media checkpoints and retained outputs,
    // releases all source ownership, and exits. A distinct target process
    // restores every output in a fresh Bank and publishes the next chunks.
    const media_stream_live_restart_worker_exe =
        b.addExecutable(.{
            .name = "glacier-media-stream-live-restart-worker",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "bench/media_stream_live_restart_worker.zig",
                ),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
    media_stream_live_restart_worker_exe.root_module.addImport(
        "core",
        core_mod,
    );
    media_stream_live_restart_worker_exe.linkLibC();
    const media_stream_live_restart_demo_exe =
        b.addExecutable(.{
            .name = "glacier-media-stream-live-restart-demo",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "examples/media_stream_live_restart.zig",
                ),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
    const run_media_stream_live_restart_demo =
        b.addRunArtifact(
            media_stream_live_restart_demo_exe,
        );
    run_media_stream_live_restart_demo.addArtifactArg(
        media_stream_live_restart_worker_exe,
    );
    const media_stream_live_restart_demo_step = b.step(
        "media-stream-live-restart-demo",
        "Run two-process image/audio/video stream resume",
    );
    media_stream_live_restart_demo_step.dependOn(
        &run_media_stream_live_restart_demo.step,
    );
    test_step.dependOn(
        &run_media_stream_live_restart_demo.step,
    );
    test_compile_step.dependOn(
        &media_stream_live_restart_demo_exe.step,
    );
    test_compile_step.dependOn(
        &media_stream_live_restart_worker_exe.step,
    );

    // A stateful model process commits one latent step and syncs its canonical
    // checkpoint. A distinct target process reacquires retained-state
    // ownership before materialization and publishes the terminal step once.
    const stateful_model_live_restart_worker_exe =
        b.addExecutable(.{
            .name = "glacier-stateful-model-live-restart-worker",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "bench/stateful_model_live_restart_worker.zig",
                ),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
    stateful_model_live_restart_worker_exe.root_module.addImport(
        "core",
        core_mod,
    );
    stateful_model_live_restart_worker_exe.linkLibC();
    const stateful_model_live_restart_demo_exe =
        b.addExecutable(.{
            .name = "glacier-stateful-model-live-restart-demo",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "examples/stateful_model_live_restart.zig",
                ),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
    const run_stateful_model_live_restart_demo =
        b.addRunArtifact(
            stateful_model_live_restart_demo_exe,
        );
    run_stateful_model_live_restart_demo.addArtifactArg(
        stateful_model_live_restart_worker_exe,
    );
    const stateful_model_live_restart_demo_step = b.step(
        "stateful-model-live-restart-demo",
        "Run two-process retained-state model continuation",
    );
    stateful_model_live_restart_demo_step.dependOn(
        &run_stateful_model_live_restart_demo.step,
    );
    test_step.dependOn(
        &run_stateful_model_live_restart_demo.step,
    );
    test_compile_step.dependOn(
        &stateful_model_live_restart_demo_exe.step,
    );
    test_compile_step.dependOn(
        &stateful_model_live_restart_worker_exe.step,
    );

    // Reuse the retained-latent checkpoint source above, then let a distinct
    // target process restore the intermediate state, commit the terminal
    // latent, decode bounded raw pixels, and publish image plus provenance
    // atomically after one cancellation-safe retry.
    const generated_image_live_restart_worker_exe =
        b.addExecutable(.{
            .name = "glacier-generated-image-live-restart-worker",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "bench/generated_image_live_restart_worker.zig",
                ),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
    generated_image_live_restart_worker_exe.root_module.addImport(
        "core",
        core_mod,
    );
    generated_image_live_restart_worker_exe.linkLibC();
    const generated_image_live_restart_demo_exe =
        b.addExecutable(.{
            .name = "glacier-generated-image-live-restart-demo",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "examples/generated_image_live_restart.zig",
                ),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
    const run_generated_image_live_restart_demo =
        b.addRunArtifact(
            generated_image_live_restart_demo_exe,
        );
    run_generated_image_live_restart_demo.addArtifactArg(
        stateful_model_live_restart_worker_exe,
    );
    run_generated_image_live_restart_demo.addArtifactArg(
        generated_image_live_restart_worker_exe,
    );
    const generated_image_live_restart_demo_step =
        b.step(
            "generated-image-live-restart-demo",
            "Publish bounded generated image after model restart",
        );
    generated_image_live_restart_demo_step.dependOn(
        &run_generated_image_live_restart_demo.step,
    );
    test_step.dependOn(
        &run_generated_image_live_restart_demo.step,
    );
    test_compile_step.dependOn(
        &generated_image_live_restart_demo_exe.step,
    );
    test_compile_step.dependOn(
        &generated_image_live_restart_worker_exe.step,
    );

    // A source process publishes one bounded generated PCM chunk and exits
    // with an outstanding application acknowledgement. A distinct target
    // validates that state before admission, rejects partial acknowledgement,
    // acknowledges the exact buffer, and publishes the next chunk only after
    // the backpressure gate opens.
    const generated_audio_live_restart_worker_exe =
        b.addExecutable(.{
            .name = "glacier-generated-audio-live-restart-worker",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "bench/generated_audio_live_restart_worker.zig",
                ),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
    generated_audio_live_restart_worker_exe.root_module.addImport(
        "core",
        core_mod,
    );
    generated_audio_live_restart_worker_exe.linkLibC();
    const generated_audio_live_restart_demo_exe =
        b.addExecutable(.{
            .name = "glacier-generated-audio-live-restart-demo",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "examples/generated_audio_live_restart.zig",
                ),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
    const run_generated_audio_live_restart_demo =
        b.addRunArtifact(
            generated_audio_live_restart_demo_exe,
        );
    run_generated_audio_live_restart_demo.addArtifactArg(
        generated_audio_live_restart_worker_exe,
    );
    const generated_audio_live_restart_demo_step =
        b.step(
            "generated-audio-live-restart-demo",
            "Publish and acknowledge generated audio across processes",
        );
    generated_audio_live_restart_demo_step.dependOn(
        &run_generated_audio_live_restart_demo.step,
    );
    test_step.dependOn(
        &run_generated_audio_live_restart_demo.step,
    );
    test_compile_step.dependOn(
        &generated_audio_live_restart_demo_exe.step,
    );
    test_compile_step.dependOn(
        &generated_audio_live_restart_worker_exe.step,
    );

    // A source process publishes an ordered two-frame raw-video manifest and
    // exits with one outstanding application display acknowledgement. A
    // distinct target validates every retained wire before admission, rejects
    // partial display, acknowledges the segment, and only then publishes the
    // successor manifest.
    const generated_video_live_restart_worker_exe =
        b.addExecutable(.{
            .name = "glacier-generated-video-live-restart-worker",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "bench/generated_video_live_restart_worker.zig",
                ),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
    generated_video_live_restart_worker_exe.root_module.addImport(
        "core",
        core_mod,
    );
    generated_video_live_restart_worker_exe.linkLibC();
    const generated_video_live_restart_demo_exe =
        b.addExecutable(.{
            .name = "glacier-generated-video-live-restart-demo",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "examples/generated_video_live_restart.zig",
                ),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
    const run_generated_video_live_restart_demo =
        b.addRunArtifact(
            generated_video_live_restart_demo_exe,
        );
    run_generated_video_live_restart_demo.addArtifactArg(
        generated_video_live_restart_worker_exe,
    );
    const generated_video_live_restart_demo_step =
        b.step(
            "generated-video-live-restart-demo",
            "Publish and acknowledge generated video across processes",
        );
    generated_video_live_restart_demo_step.dependOn(
        &run_generated_video_live_restart_demo.step,
    );
    test_step.dependOn(
        &run_generated_video_live_restart_demo.step,
    );
    test_compile_step.dependOn(
        &generated_video_live_restart_demo_exe.step,
    );
    test_compile_step.dependOn(
        &generated_video_live_restart_worker_exe.step,
    );

    // Three typed generated-media completions are sealed behind one selector.
    // Four source/promoter/recovery campaigns kill the promoter after selector
    // write, sync, rename, and directory sync; recovery accepts only the
    // complete previous or complete successor image/audio/video generation.
    const generated_media_checkpoint_restart_worker_exe =
        b.addExecutable(.{
            .name = "glacier-generated-media-checkpoint-restart-worker",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "bench/generated_media_checkpoint_restart_worker.zig",
                ),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
    generated_media_checkpoint_restart_worker_exe.root_module.addImport(
        "core",
        core_mod,
    );
    generated_media_checkpoint_restart_worker_exe.linkLibC();
    const generated_media_checkpoint_restart_demo_exe =
        b.addExecutable(.{
            .name = "glacier-generated-media-checkpoint-restart-demo",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "examples/generated_media_checkpoint_restart.zig",
                ),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
    const run_generated_media_checkpoint_restart_demo =
        b.addRunArtifact(
            generated_media_checkpoint_restart_demo_exe,
        );
    run_generated_media_checkpoint_restart_demo.addArtifactArg(
        generated_media_checkpoint_restart_worker_exe,
    );
    const generated_media_checkpoint_restart_demo_step =
        b.step(
            "generated-media-checkpoint-restart-demo",
            "Recover exact generated image/audio/video checkpoints",
        );
    generated_media_checkpoint_restart_demo_step.dependOn(
        &run_generated_media_checkpoint_restart_demo.step,
    );
    test_step.dependOn(
        &run_generated_media_checkpoint_restart_demo.step,
    );
    test_compile_step.dependOn(
        &generated_media_checkpoint_restart_demo_exe.step,
    );
    test_compile_step.dependOn(
        &generated_media_checkpoint_restart_worker_exe.step,
    );

    // One canonical archive binds the generated-media checkpoint, its image,
    // audio, and video members, and all three encoded payloads. Seven
    // process-death campaigns cover the archive and selector publication
    // phases; recovery observes only the exact predecessor or successor.
    const generated_media_payload_archive_worker_exe =
        b.addExecutable(.{
            .name = "glacier-generated-media-payload-archive-worker",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "bench/generated_media_payload_archive_worker.zig",
                ),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
    generated_media_payload_archive_worker_exe.root_module.addImport(
        "core",
        core_mod,
    );
    generated_media_payload_archive_worker_exe.linkLibC();
    const generated_media_payload_archive_demo_exe =
        b.addExecutable(.{
            .name = "glacier-generated-media-payload-archive-demo",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "examples/generated_media_payload_archive_restart_demo.zig",
                ),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
    generated_media_payload_archive_demo_exe.root_module.addImport(
        "core",
        core_mod,
    );
    generated_media_payload_archive_demo_exe.linkLibC();
    const run_generated_media_payload_archive_demo =
        b.addRunArtifact(
            generated_media_payload_archive_demo_exe,
        );
    run_generated_media_payload_archive_demo.addArtifactArg(
        generated_media_payload_archive_worker_exe,
    );
    const generated_media_payload_archive_demo_step =
        b.step(
            "generated-media-payload-archive-restart-demo",
            "Recover exact encoded image/audio/video payload archives",
        );
    generated_media_payload_archive_demo_step.dependOn(
        &run_generated_media_payload_archive_demo.step,
    );
    test_step.dependOn(
        &run_generated_media_payload_archive_demo.step,
    );
    test_compile_step.dependOn(
        &generated_media_payload_archive_demo_exe.step,
    );
    test_compile_step.dependOn(
        &generated_media_payload_archive_worker_exe.step,
    );

    // One canonical registry archive selects every ordered image, audio, and
    // video output in a generation. Seven process-death campaigns cover the
    // archive and selector publication phases; recovery observes only the
    // exact predecessor or successor registry.
    const generated_media_output_registry_worker_exe =
        b.addExecutable(.{
            .name = "glacier-generated-media-output-registry-worker",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "bench/generated_media_output_registry_worker.zig",
                ),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
    generated_media_output_registry_worker_exe.root_module.addImport(
        "core",
        core_mod,
    );
    generated_media_output_registry_worker_exe.linkLibC();
    const generated_media_output_registry_demo_exe =
        b.addExecutable(.{
            .name = "glacier-generated-media-output-registry-demo",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "examples/generated_media_output_registry_restart_demo.zig",
                ),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
    generated_media_output_registry_demo_exe.root_module.addImport(
        "core",
        core_mod,
    );
    generated_media_output_registry_demo_exe.linkLibC();
    const run_generated_media_output_registry_demo =
        b.addRunArtifact(
            generated_media_output_registry_demo_exe,
        );
    run_generated_media_output_registry_demo.addArtifactArg(
        generated_media_output_registry_worker_exe,
    );
    const generated_media_output_registry_demo_step =
        b.step(
            "generated-media-output-registry-restart-demo",
            "Recover exact ordered image/audio/video output registries",
        );
    generated_media_output_registry_demo_step.dependOn(
        &run_generated_media_output_registry_demo.step,
    );
    test_step.dependOn(
        &run_generated_media_output_registry_demo.step,
    );
    test_compile_step.dependOn(
        &generated_media_output_registry_demo_exe.step,
    );
    test_compile_step.dependOn(
        &generated_media_output_registry_worker_exe.step,
    );

    // Experimental read-only renderer for a generated-media registry archive
    // and its transition-evidence sidecar. Successors require the exact
    // predecessor pair; the tool emits deterministic JSON only after all
    // structural and lineage validation succeeds.
    const generated_media_evidence_inspector_exe =
        b.addExecutable(.{
            .name = "glacier-generated-media-evidence-inspector",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "bench/generated_media_evidence_inspector.zig",
                ),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
    generated_media_evidence_inspector_exe.root_module.addImport(
        "core",
        core_mod,
    );
    const generated_media_format_conformance_mod =
        b.createModule(.{
            .root_source_file = b.path(
                "src/media/generated_media_format_conformance.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        });
    generated_media_format_conformance_mod.addImport(
        "core",
        core_mod,
    );
    generated_media_evidence_inspector_exe.root_module.addImport(
        "format_evidence",
        generated_media_format_conformance_mod,
    );
    const run_generated_media_evidence_inspector =
        b.addRunArtifact(
            generated_media_evidence_inspector_exe,
        );
    if (b.args) |args|
        run_generated_media_evidence_inspector.addArgs(args);
    const generated_media_evidence_inspector_step =
        b.step(
            "generated-media-evidence-inspector",
            "Validate and render a generated-media registry/evidence pair",
        );
    generated_media_evidence_inspector_step.dependOn(
        &run_generated_media_evidence_inspector.step,
    );
    test_compile_step.dependOn(
        &generated_media_evidence_inspector_exe.step,
    );

    // A stateful transcript process commits one exact sample range and syncs a
    // composed checkpoint. A distinct target process charges and materializes
    // retained state, publishes the next transcript, and advances its
    // cross-modal video link without duplicated text.
    const audio_transcript_live_restart_worker_exe =
        b.addExecutable(.{
            .name = "glacier-audio-transcript-live-restart-worker",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "bench/audio_transcript_live_restart_worker.zig",
                ),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
    audio_transcript_live_restart_worker_exe.root_module.addImport(
        "core",
        core_mod,
    );
    audio_transcript_live_restart_worker_exe.linkLibC();
    const audio_transcript_live_restart_demo_exe =
        b.addExecutable(.{
            .name = "glacier-audio-transcript-live-restart-demo",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "examples/audio_transcript_live_restart.zig",
                ),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
    const run_audio_transcript_live_restart_demo =
        b.addRunArtifact(
            audio_transcript_live_restart_demo_exe,
        );
    run_audio_transcript_live_restart_demo.addArtifactArg(
        audio_transcript_live_restart_worker_exe,
    );
    const audio_transcript_live_restart_demo_step = b.step(
        "audio-transcript-live-restart-demo",
        "Run two-process transcript and video-link continuation",
    );
    audio_transcript_live_restart_demo_step.dependOn(
        &run_audio_transcript_live_restart_demo.step,
    );
    test_step.dependOn(
        &run_audio_transcript_live_restart_demo.step,
    );
    test_compile_step.dependOn(
        &audio_transcript_live_restart_demo_exe.step,
    );
    test_compile_step.dependOn(
        &audio_transcript_live_restart_worker_exe.step,
    );

    // A speech-annotation source publishes exact word timing and speaker one.
    // A distinct target validates the fixed state before admission, aborts one
    // private candidate, then publishes the next word and speaker turn once.
    const speech_annotation_live_restart_worker_exe =
        b.addExecutable(.{
            .name = "glacier-speech-annotation-live-restart-worker",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "bench/speech_annotation_live_restart_worker.zig",
                ),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
    speech_annotation_live_restart_worker_exe.root_module.addImport(
        "core",
        core_mod,
    );
    speech_annotation_live_restart_worker_exe.linkLibC();
    const speech_annotation_live_restart_demo_exe =
        b.addExecutable(.{
            .name = "glacier-speech-annotation-live-restart-demo",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "examples/speech_annotation_live_restart.zig",
                ),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
    const run_speech_annotation_live_restart_demo =
        b.addRunArtifact(
            speech_annotation_live_restart_demo_exe,
        );
    run_speech_annotation_live_restart_demo.addArtifactArg(
        speech_annotation_live_restart_worker_exe,
    );
    const speech_annotation_live_restart_demo_step = b.step(
        "speech-annotation-live-restart-demo",
        "Publish exact word timing and speaker turns after restart",
    );
    speech_annotation_live_restart_demo_step.dependOn(
        &run_speech_annotation_live_restart_demo.step,
    );
    test_step.dependOn(
        &run_speech_annotation_live_restart_demo.step,
    );
    test_compile_step.dependOn(
        &speech_annotation_live_restart_demo_exe.step,
    );
    test_compile_step.dependOn(
        &speech_annotation_live_restart_worker_exe.step,
    );

    // A source process commits an explicit per-frame VFR window and video
    // segment. A fresh target charges retained model state before
    // materialization, publishes the successor after a declared timeline gap,
    // then advances the canonical segment timeline and cross-modal link.
    const video_model_live_restart_worker_exe =
        b.addExecutable(.{
            .name = "glacier-video-model-live-restart-worker",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "bench/video_model_live_restart_worker.zig",
                ),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
    video_model_live_restart_worker_exe.root_module.addImport(
        "core",
        core_mod,
    );
    video_model_live_restart_worker_exe.linkLibC();
    const video_model_live_restart_demo_exe =
        b.addExecutable(.{
            .name = "glacier-video-model-live-restart-demo",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "examples/video_model_live_restart.zig",
                ),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
    const run_video_model_live_restart_demo =
        b.addRunArtifact(
            video_model_live_restart_demo_exe,
        );
    run_video_model_live_restart_demo.addArtifactArg(
        video_model_live_restart_worker_exe,
    );
    const video_model_live_restart_demo_step = b.step(
        "video-model-live-restart-demo",
        "Run two-process stateful VFR video continuation",
    );
    video_model_live_restart_demo_step.dependOn(
        &run_video_model_live_restart_demo.step,
    );
    test_step.dependOn(
        &run_video_model_live_restart_demo.step,
    );
    test_compile_step.dependOn(
        &video_model_live_restart_demo_exe.step,
    );
    test_compile_step.dependOn(
        &video_model_live_restart_worker_exe.step,
    );

    // Three stream checkpoints plus retained-output, processor-state, and
    // processor-cache bundles share a single immutable archive root. The
    // source produces two generations; a publisher dies after every durability
    // phase, then a restored process rebinds output/cache ownership and
    // publishes a third generation for another resume.
    const media_stream_checkpoint_set_worker_exe =
        b.addExecutable(.{
            .name = "glacier-media-stream-checkpoint-set-worker",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "bench/media_stream_checkpoint_set_worker.zig",
                ),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
    media_stream_checkpoint_set_worker_exe.root_module.addImport(
        "core",
        core_mod,
    );
    media_stream_checkpoint_set_worker_exe.linkLibC();
    const media_stream_checkpoint_set_demo_exe =
        b.addExecutable(.{
            .name = "glacier-media-stream-checkpoint-set-demo",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "examples/media_stream_checkpoint_set.zig",
                ),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
    media_stream_checkpoint_set_demo_exe.root_module.addImport(
        "core",
        core_mod,
    );
    media_stream_checkpoint_set_demo_exe.linkLibC();
    const run_media_stream_checkpoint_set_demo =
        b.addRunArtifact(
            media_stream_checkpoint_set_demo_exe,
        );
    run_media_stream_checkpoint_set_demo.addArtifactArg(
        continuation_checkpoint_file_worker_exe,
    );
    run_media_stream_checkpoint_set_demo.addArtifactArg(
        media_stream_checkpoint_set_worker_exe,
    );
    const media_stream_checkpoint_set_demo_step = b.step(
        "media-stream-checkpoint-set-demo",
        "Run crash-atomic multimodal checkpoint generations",
    );
    media_stream_checkpoint_set_demo_step.dependOn(
        &run_media_stream_checkpoint_set_demo.step,
    );
    test_step.dependOn(
        &run_media_stream_checkpoint_set_demo.step,
    );
    test_compile_step.dependOn(
        &media_stream_checkpoint_set_demo_exe.step,
    );
    test_compile_step.dependOn(
        &media_stream_checkpoint_set_worker_exe.step,
    );

    // Fixed image processor, audio feature-window, video temporal-cache, and
    // exact synchronized-watermark state share one independently verifiable
    // bundle and advance through lineage-bound generations.
    const media_processor_state_demo_exe =
        b.addExecutable(.{
            .name = "glacier-media-processor-state-demo",
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    "examples/media_processor_state.zig",
                ),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
    media_processor_state_demo_exe.root_module.addImport(
        "core",
        core_mod,
    );
    const run_media_processor_state_demo =
        b.addRunArtifact(media_processor_state_demo_exe);
    const media_processor_state_demo_step = b.step(
        "media-processor-state-demo",
        "Run bounded multimodal processor/cache state proof",
    );
    media_processor_state_demo_step.dependOn(
        &run_media_processor_state_demo.step,
    );
    test_step.dependOn(
        &run_media_processor_state_demo.step,
    );
    test_compile_step.dependOn(
        &media_processor_state_demo_exe.step,
    );

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
    // Benchmark and diagnostic executables are developer tools rather than
    // production runtime payloads. Keep them behind an explicit install step
    // so the default install and `run` paths build only the CLI.
    const install_benchmarks_step = b.step(
        "install-benchmarks",
        "Install all benchmark and diagnostic executables",
    );
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
    const install_bench = b.addInstallArtifact(bench_exe, .{});
    install_benchmarks_step.dependOn(&install_bench.step);

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
        install_benchmarks_step.dependOn(&install_stripped.step);
    } else {
        const install_lane4_bench =
            b.addInstallArtifact(lane4_bench_exe, .{});
        install_benchmarks_step.dependOn(
            &install_lane4_bench.step,
        );
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
    const install_paged_lane4_bench =
        b.addInstallArtifact(paged_lane4_bench_exe, .{});
    install_benchmarks_step.dependOn(
        &install_paged_lane4_bench.step,
    );

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
    const install_paged_resident_bench =
        b.addInstallArtifact(paged_resident_bench_exe, .{});
    install_benchmarks_step.dependOn(
        &install_paged_resident_bench.step,
    );

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
    const install_paged_lease_bench =
        b.addInstallArtifact(paged_lease_bench_exe, .{});
    install_benchmarks_step.dependOn(
        &install_paged_lease_bench.step,
    );

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
    const install_paged_lease_admission_bench =
        b.addInstallArtifact(paged_lease_admission_bench_exe, .{});
    install_benchmarks_step.dependOn(
        &install_paged_lease_admission_bench.step,
    );

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
    const install_int4_kernel_bench =
        b.addInstallArtifact(int4_kernel_bench_exe, .{});
    install_benchmarks_step.dependOn(
        &install_int4_kernel_bench.step,
    );

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
    const install_eligible_argmax_bench =
        b.addInstallArtifact(eligible_argmax_bench_exe, .{});
    install_benchmarks_step.dependOn(
        &install_eligible_argmax_bench.step,
    );

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
    const install_progressive_kernel_bench =
        b.addInstallArtifact(progressive_kernel_bench_exe, .{});
    install_benchmarks_step.dependOn(
        &install_progressive_kernel_bench.step,
    );

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
    const install_metal_kernel_bench =
        b.addInstallArtifact(metal_kernel_bench_exe, .{});
    install_benchmarks_step.dependOn(
        &install_metal_kernel_bench.step,
    );

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
    const install_quant_bench =
        b.addInstallArtifact(quant_bench_exe, .{});
    install_benchmarks_step.dependOn(
        &install_quant_bench.step,
    );

    // --- Cross-target compile profiles --------------------------------------
    // Affected-path verification selects the smallest audited union of these
    // roots. Every profile reuses existing artifact steps, so multiple named
    // profiles in one Zig invocation share their dependency graph.
    const profile_core_compile_step = b.step(
        "profile-core-compile",
        "Compile the portable core and language-contract boundary",
    );
    profile_core_compile_step.dependOn(&core_tests.step);
    profile_core_compile_step.dependOn(&contract_shared.step);
    profile_core_compile_step.dependOn(&contract_static.step);
    profile_core_compile_step.dependOn(&contract_c_tests.step);
    profile_core_compile_step.dependOn(&contract_c_consumer.step);
    profile_core_compile_step.dependOn(
        &contract_c_shared_consumer.step,
    );
    profile_core_compile_step.dependOn(&contract_cpp_consumer.step);
    profile_core_compile_step.dependOn(
        &contract_installed_c_consumer.step,
    );
    profile_core_compile_step.dependOn(
        &dense_tensor_reranker_exe.step,
    );
    profile_core_compile_step.dependOn(
        &dense_tensor_embedding_exe.step,
    );

    const profile_cpu_compile_step = b.step(
        "profile-cpu-compile",
        "Compile the public runtime and CPU execution surface",
    );
    profile_cpu_compile_step.dependOn(&engine_tests.step);
    profile_cpu_compile_step.dependOn(&package_module_tests.step);
    profile_cpu_compile_step.dependOn(&progressive_int4_tests.step);
    profile_cpu_compile_step.dependOn(&integration_tests.step);
    profile_cpu_compile_step.dependOn(&pager_tests.step);
    profile_cpu_compile_step.dependOn(&model_tests.step);

    const profile_durable_compile_step = b.step(
        "profile-durable-compile",
        "Compile durable state, recovery, and process-worker surfaces",
    );
    profile_durable_compile_step.dependOn(
        action_outbox_recovery_compile_step,
    );
    profile_durable_compile_step.dependOn(
        &continuation_sweep_file_demo_exe.step,
    );
    profile_durable_compile_step.dependOn(
        &continuation_sweep_file_worker_exe.step,
    );
    profile_durable_compile_step.dependOn(
        &continuation_payload_file_demo_exe.step,
    );
    profile_durable_compile_step.dependOn(
        &continuation_payload_file_worker_exe.step,
    );
    profile_durable_compile_step.dependOn(
        &continuation_live_restart_demo_exe.step,
    );
    profile_durable_compile_step.dependOn(
        &continuation_live_restart_worker_exe.step,
    );
    profile_durable_compile_step.dependOn(
        &prepared_text_live_restart_demo_exe.step,
    );
    profile_durable_compile_step.dependOn(
        &prepared_text_live_restart_worker_exe.step,
    );
    profile_durable_compile_step.dependOn(
        prepared_text_acknowledged_delivery_compile_step,
    );
    if (prepared_text_recovery_worker_exe) |worker|
        profile_durable_compile_step.dependOn(&worker.step);
    profile_durable_compile_step.dependOn(
        &continuation_checkpoint_file_demo_exe.step,
    );
    profile_durable_compile_step.dependOn(
        &continuation_checkpoint_file_worker_exe.step,
    );
    profile_durable_compile_step.dependOn(
        &provider_gateway_demo_exe.step,
    );

    const profile_device_compile_step = b.step(
        "profile-device-compile",
        "Compile accelerator-facing tests and diagnostics",
    );
    profile_device_compile_step.dependOn(&metal_tests.step);
    profile_device_compile_step.dependOn(
        &native_metal_inflight_process_kill_ready_tests.step,
    );
    profile_device_compile_step.dependOn(
        &native_supervisor_recovery_death_report_tests.step,
    );
    profile_device_compile_step.dependOn(
        &metal_kernel_bench_exe.step,
    );

    const profile_host_tool_compile_step = b.step(
        "profile-host-tool-compile",
        "Compile the CLI and retained read-only host inspectors",
    );
    profile_host_tool_compile_step.dependOn(&exe.step);
    profile_host_tool_compile_step.dependOn(
        runtime_support_inspector_compile_step,
    );
    profile_host_tool_compile_step.dependOn(
        provider_evidence_inspector_compile_step,
    );
    profile_host_tool_compile_step.dependOn(
        native_observation_compile_step,
    );
    profile_host_tool_compile_step.dependOn(
        &generated_media_evidence_inspector_exe.step,
    );
    if (native_metal_build_available) {
        native_metal_suite_compile_step.dependOn(
            profile_device_compile_step,
        );
        native_metal_suite_compile_step.dependOn(
            profile_host_tool_compile_step,
        );
    }

    // Keep the compatibility umbrella authoritative while allowing affected
    // verification to name only the smaller roots above.
    test_compile_step.dependOn(profile_core_compile_step);
    test_compile_step.dependOn(profile_cpu_compile_step);
    test_compile_step.dependOn(profile_durable_compile_step);
    test_compile_step.dependOn(profile_device_compile_step);
    test_compile_step.dependOn(profile_host_tool_compile_step);

    // Shared producer APIs need every retained compile consumer, including
    // demos and benchmarks that intentionally sit outside the five domain
    // profiles. This root is complete but compile-only: it avoids staging
    // production or benchmark files into the installation prefix.
    const profile_complete_compile_step = b.step(
        "profile-complete-compile",
        "Compile every retained production, test, demo, and benchmark consumer",
    );
    profile_complete_compile_step.dependOn(test_compile_step);
    profile_complete_compile_step.dependOn(&bench_exe.step);
    profile_complete_compile_step.dependOn(&lane4_bench_exe.step);
    profile_complete_compile_step.dependOn(
        &paged_lane4_bench_exe.step,
    );
    profile_complete_compile_step.dependOn(
        &paged_resident_bench_exe.step,
    );
    profile_complete_compile_step.dependOn(
        &paged_lease_bench_exe.step,
    );
    profile_complete_compile_step.dependOn(
        &paged_lease_admission_bench_exe.step,
    );
    profile_complete_compile_step.dependOn(
        &int4_kernel_bench_exe.step,
    );
    profile_complete_compile_step.dependOn(
        &eligible_argmax_bench_exe.step,
    );
    profile_complete_compile_step.dependOn(
        &progressive_kernel_bench_exe.step,
    );
    profile_complete_compile_step.dependOn(
        &metal_kernel_bench_exe.step,
    );
    profile_complete_compile_step.dependOn(&quant_bench_exe.step);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the glacier CLI");
    run_step.dependOn(&run_cmd.step);

    // --- Metal shader compilation (macOS only, opt-in) -----------------------
    // `zig build metal-lib` compiles the .metal shaders to a .metallib and
    // the Objective-C shim to a static archive. The artifacts are placed in
    // zig-out/metal/ by default; -Dmetal-output-dir selects an isolated
    // location. The Zig Metal backend receives that exact path at compile
    // time; this step does not link anything into the main exes by default.
    if (target.result.os.tag == .macos) {
        const metal_step = b.step("metal-lib", "Compile Metal shaders + Obj-C shim (macOS)");
        metal_step.dependOn(&metal_lib.?.step);
        metal_step.dependOn(
            &buildShimArchive(b, metal_output_dir).step,
        );
    }
}

/// Compile src/backends/metal/shaders/*.metal into one runtime library.
fn buildMetalLib(
    b: *std.Build,
    output_dir: []const u8,
) *std.Build.Step.Run {
    const metallib_path = b.fmt(
        "{s}/shaders.metallib",
        .{output_dir},
    );
    const module_cache_dir = b.cache_root.join(
        b.allocator,
        &.{"metal-module-cache"},
    ) catch @panic("OOM");
    const prepare_directories = b.addSystemCommand(&.{
        "mkdir",
        "-p",
        output_dir,
        module_cache_dir,
    });
    const capture_toolchain_identity = b.addSystemCommand(&.{"sh"});
    capture_toolchain_identity.addFileArg(
        b.path("tools/metal-toolchain-identity.sh"),
    );
    const toolchain_identity =
        capture_toolchain_identity.addOutputFileArg(
            "metal-toolchain.identity",
        );
    capture_toolchain_identity.has_side_effects = true;

    // Declare source and product paths through Step.Run so Zig can cache the
    // expensive shader compiler and linker stages across build invocations.
    // The always-refreshed identity input invalidates those products after a
    // selected Xcode, SDK, compiler, linker, or Metal standard-library change.
    const compile_dequant = b.addSystemCommand(&.{
        "xcrun",
        "-sdk",
        "macosx",
        "metal",
        "-std=metal3.0",
        "-c",
    });
    compile_dequant.addArg(b.fmt(
        "-fmodules-cache-path={s}",
        .{module_cache_dir},
    ));
    compile_dequant.addFileArg(
        b.path("src/backends/metal/shaders/dequant.metal"),
    );
    compile_dequant.addArg("-o");
    const dequant_air =
        compile_dequant.addOutputFileArg("dequant.air");
    compile_dequant.addFileInput(toolchain_identity);
    compile_dequant.step.dependOn(&prepare_directories.step);

    const compile_matmul = b.addSystemCommand(&.{
        "xcrun",
        "-sdk",
        "macosx",
        "metal",
        "-std=metal3.0",
        "-c",
    });
    compile_matmul.addArg(b.fmt(
        "-fmodules-cache-path={s}",
        .{module_cache_dir},
    ));
    compile_matmul.addFileArg(
        b.path("src/backends/metal/shaders/matmul.metal"),
    );
    compile_matmul.addArg("-o");
    const matmul_air =
        compile_matmul.addOutputFileArg("matmul.air");
    compile_matmul.addFileInput(toolchain_identity);
    compile_matmul.step.dependOn(&prepare_directories.step);

    const compile_metallib = b.addSystemCommand(&.{
        "xcrun",
        "-sdk",
        "macosx",
        "metallib",
    });
    compile_metallib.addFileArg(dequant_air);
    compile_metallib.addFileArg(matmul_air);
    compile_metallib.addArg("-o");
    const cached_metallib =
        compile_metallib.addOutputFileArg("shaders.metallib");
    compile_metallib.addFileInput(toolchain_identity);

    // The runtime ABI intentionally retains a stable, caller-selected path.
    // Materializing the cached library is cheap and keeps that public path
    // independent from Zig's content-addressed cache layout.
    const materialize = b.addSystemCommand(&.{ "cp", "-f" });
    materialize.addFileArg(cached_metallib);
    materialize.addArg(metallib_path);
    materialize.step.dependOn(&prepare_directories.step);
    return materialize;
}

/// Compile src/backends/metal/shim.m into the selected Metal output directory.
fn buildShimArchive(
    b: *std.Build,
    output_dir: []const u8,
) *std.Build.Step.Run {
    const mkdir = b.addSystemCommand(&.{ "mkdir", "-p", output_dir });
    const shim_object = b.fmt("{s}/shim.o", .{output_dir});
    const compile = b.addSystemCommand(&.{
        "xcrun",     "-sdk",                      "macosx",
        "clang",     "-fobjc-arc",                "-framework",
        "Metal",     "-framework",                "Foundation",
        "-c",        "src/backends/metal/shim.m", "-o",
        shim_object,
    });
    compile.step.dependOn(&mkdir.step);
    return compile;
}
