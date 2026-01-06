const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    const enable_voice = b.option(bool, "voice", "Enable voice command (Linux only)") orelse false;
    const enable_vulkan = b.option(bool, "vulkan", "Enable Vulkan GPU acceleration for voice (requires pre-built shaders)") orelse false;

    const build_options = b.addOptions();
    build_options.addOption(bool, "voice", enable_voice);

    // Get clap dependency
    const clap = b.dependency("clap", .{});

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("ligi", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
        .imports = &.{
            .{ .name = "clap", .module = clap.module("clap") },
            .{ .name = "build_options", .module = build_options.createModule() },
        },
    });

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "ligi",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                // Here "ligi" is the name you will use in your source code to
                // import this module (e.g. `@import("ligi")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "ligi", .module = mod },
                .{ .name = "clap", .module = clap.module("clap") },
                .{ .name = "build_options", .module = build_options.createModule() },
            },
        }),
    });

    if (enable_voice) {
        if (target.result.os.tag != .linux) {
            @panic("voice is only supported on linux");
        }

        const vendor_path = "vendor/whisper.cpp";
        std.fs.cwd().access(vendor_path, .{}) catch @panic("voice enabled but vendor/whisper.cpp is missing");

        exe.linkLibC();
        exe.linkLibCpp();
        exe.linkSystemLibrary("asound");
        exe.linkSystemLibrary("pthread");
        exe.linkSystemLibrary("m");
        exe.linkSystemLibrary("dl");

        exe.addIncludePath(b.path("vendor/whisper.cpp/include"));
        exe.addIncludePath(b.path("vendor/whisper.cpp/ggml/include"));
        exe.addIncludePath(b.path("vendor/whisper.cpp/ggml/src"));
        exe.addIncludePath(b.path("vendor/whisper.cpp/ggml/src/ggml-cpu"));
        exe.addIncludePath(b.path("vendor/whisper.cpp/src"));

        const base_c_flags = [_][]const u8{
            "-std=c11",
            "-D_GNU_SOURCE",
            "-D_XOPEN_SOURCE=600",
            "-D_POSIX_C_SOURCE=200809L",
            "-DGGML_USE_CPU",
            "-DGGML_VERSION=\"v1.8.2\"",
            "-DGGML_COMMIT=\"4979e04\"",
            "-DWHISPER_VERSION=\"v1.8.2\"",
        };

        const base_cpp_flags = [_][]const u8{
            "-std=c++17",
            "-D_GNU_SOURCE",
            "-D_XOPEN_SOURCE=600",
            "-D_POSIX_C_SOURCE=200809L",
            "-DGGML_USE_CPU",
            "-DGGML_VERSION=\"v1.8.2\"",
            "-DGGML_COMMIT=\"4979e04\"",
            "-DWHISPER_VERSION=\"v1.8.2\"",
        };

        const vulkan_flag = [_][]const u8{"-DGGML_USE_VULKAN"};
        const c_flags: []const []const u8 = if (enable_vulkan) &(base_c_flags ++ vulkan_flag) else &base_c_flags;
        const cpp_flags: []const []const u8 = if (enable_vulkan) &(base_cpp_flags ++ vulkan_flag) else &base_cpp_flags;

        const ggml_c_sources = [_][]const u8{
            "vendor/whisper.cpp/ggml/src/ggml.c",
            "vendor/whisper.cpp/ggml/src/ggml-alloc.c",
            "vendor/whisper.cpp/ggml/src/ggml-quants.c",
            "vendor/whisper.cpp/ggml/src/ggml-cpu/ggml-cpu.c",
            "vendor/whisper.cpp/ggml/src/ggml-cpu/quants.c",
        };

        const ggml_cpp_sources = [_][]const u8{
            "vendor/whisper.cpp/src/whisper.cpp",
            "vendor/whisper.cpp/ggml/src/ggml.cpp",
            "vendor/whisper.cpp/ggml/src/ggml-backend.cpp",
            "vendor/whisper.cpp/ggml/src/ggml-backend-reg.cpp",
            "vendor/whisper.cpp/ggml/src/ggml-opt.cpp",
            "vendor/whisper.cpp/ggml/src/ggml-threading.cpp",
            "vendor/whisper.cpp/ggml/src/gguf.cpp",
            "vendor/whisper.cpp/ggml/src/ggml-cpu/ggml-cpu.cpp",
            "vendor/whisper.cpp/ggml/src/ggml-cpu/repack.cpp",
            "vendor/whisper.cpp/ggml/src/ggml-cpu/hbm.cpp",
            "vendor/whisper.cpp/ggml/src/ggml-cpu/traits.cpp",
            "vendor/whisper.cpp/ggml/src/ggml-cpu/binary-ops.cpp",
            "vendor/whisper.cpp/ggml/src/ggml-cpu/unary-ops.cpp",
            "vendor/whisper.cpp/ggml/src/ggml-cpu/vec.cpp",
            "vendor/whisper.cpp/ggml/src/ggml-cpu/ops.cpp",
        };

        exe.addCSourceFiles(.{ .files = &ggml_c_sources, .flags = c_flags });
        exe.addCSourceFiles(.{ .files = &ggml_cpp_sources, .flags = cpp_flags });

        switch (target.result.cpu.arch) {
            .x86, .x86_64 => {
                const x86_c_sources = [_][]const u8{
                    "vendor/whisper.cpp/ggml/src/ggml-cpu/arch/x86/quants.c",
                };
                const x86_cpp_sources = [_][]const u8{
                    "vendor/whisper.cpp/ggml/src/ggml-cpu/arch/x86/repack.cpp",
                    "vendor/whisper.cpp/ggml/src/ggml-cpu/arch/x86/cpu-feats.cpp",
                };
                exe.addCSourceFiles(.{ .files = &x86_c_sources, .flags = c_flags });
                exe.addCSourceFiles(.{ .files = &x86_cpp_sources, .flags = cpp_flags });
            },
            .arm, .aarch64 => {
                const arm_c_sources = [_][]const u8{
                    "vendor/whisper.cpp/ggml/src/ggml-cpu/arch/arm/quants.c",
                };
                const arm_cpp_sources = [_][]const u8{
                    "vendor/whisper.cpp/ggml/src/ggml-cpu/arch/arm/repack.cpp",
                    "vendor/whisper.cpp/ggml/src/ggml-cpu/arch/arm/cpu-feats.cpp",
                };
                exe.addCSourceFiles(.{ .files = &arm_c_sources, .flags = c_flags });
                exe.addCSourceFiles(.{ .files = &arm_cpp_sources, .flags = cpp_flags });
            },
            else => @panic("voice only supports x86_64 and aarch64 on linux"),
        }

        if (enable_vulkan) {
            const vk_shader_path = "vendor/whisper.cpp/build-vk/ggml/src/ggml-vulkan";
            std.fs.cwd().access(vk_shader_path ++ "/ggml-vulkan-shaders.hpp", .{}) catch
                @panic("Vulkan enabled but shaders not built. Run: cd vendor/whisper.cpp && mkdir -p build-vk && cd build-vk && cmake .. -DGGML_VULKAN=ON && make");

            exe.linkSystemLibrary("vulkan");
            exe.addIncludePath(b.path(vk_shader_path));
            exe.addIncludePath(b.path("vendor/whisper.cpp/ggml/src/ggml-vulkan"));

            // Main Vulkan backend source
            exe.addCSourceFiles(.{
                .files = &[_][]const u8{"vendor/whisper.cpp/ggml/src/ggml-vulkan/ggml-vulkan.cpp"},
                .flags = cpp_flags,
            });

            // Generated shader sources (built by CMake)
            const vk_shader_sources = [_][]const u8{
                vk_shader_path ++ "/acc.comp.cpp",
                vk_shader_path ++ "/add.comp.cpp",
                vk_shader_path ++ "/add_id.comp.cpp",
                vk_shader_path ++ "/argmax.comp.cpp",
                vk_shader_path ++ "/argsort.comp.cpp",
                vk_shader_path ++ "/clamp.comp.cpp",
                vk_shader_path ++ "/concat.comp.cpp",
                vk_shader_path ++ "/contig_copy.comp.cpp",
                vk_shader_path ++ "/conv2d_dw.comp.cpp",
                vk_shader_path ++ "/conv2d_mm.comp.cpp",
                vk_shader_path ++ "/conv_transpose_1d.comp.cpp",
                vk_shader_path ++ "/copy.comp.cpp",
                vk_shader_path ++ "/copy_from_quant.comp.cpp",
                vk_shader_path ++ "/copy_to_quant.comp.cpp",
                vk_shader_path ++ "/cos.comp.cpp",
                vk_shader_path ++ "/count_equal.comp.cpp",
                vk_shader_path ++ "/dequant_f32.comp.cpp",
                vk_shader_path ++ "/dequant_iq1_m.comp.cpp",
                vk_shader_path ++ "/dequant_iq1_s.comp.cpp",
                vk_shader_path ++ "/dequant_iq2_s.comp.cpp",
                vk_shader_path ++ "/dequant_iq2_xs.comp.cpp",
                vk_shader_path ++ "/dequant_iq2_xxs.comp.cpp",
                vk_shader_path ++ "/dequant_iq3_s.comp.cpp",
                vk_shader_path ++ "/dequant_iq3_xxs.comp.cpp",
                vk_shader_path ++ "/dequant_iq4_nl.comp.cpp",
                vk_shader_path ++ "/dequant_iq4_xs.comp.cpp",
                vk_shader_path ++ "/dequant_mxfp4.comp.cpp",
                vk_shader_path ++ "/dequant_q2_k.comp.cpp",
                vk_shader_path ++ "/dequant_q3_k.comp.cpp",
                vk_shader_path ++ "/dequant_q4_0.comp.cpp",
                vk_shader_path ++ "/dequant_q4_1.comp.cpp",
                vk_shader_path ++ "/dequant_q4_k.comp.cpp",
                vk_shader_path ++ "/dequant_q5_0.comp.cpp",
                vk_shader_path ++ "/dequant_q5_1.comp.cpp",
                vk_shader_path ++ "/dequant_q5_k.comp.cpp",
                vk_shader_path ++ "/dequant_q6_k.comp.cpp",
                vk_shader_path ++ "/dequant_q8_0.comp.cpp",
                vk_shader_path ++ "/diag_mask_inf.comp.cpp",
                vk_shader_path ++ "/div.comp.cpp",
                vk_shader_path ++ "/exp.comp.cpp",
                vk_shader_path ++ "/flash_attn.comp.cpp",
                vk_shader_path ++ "/flash_attn_cm1.comp.cpp",
                vk_shader_path ++ "/flash_attn_cm2.comp.cpp",
                vk_shader_path ++ "/flash_attn_split_k_reduce.comp.cpp",
                vk_shader_path ++ "/geglu.comp.cpp",
                vk_shader_path ++ "/geglu_erf.comp.cpp",
                vk_shader_path ++ "/geglu_quick.comp.cpp",
                vk_shader_path ++ "/gelu.comp.cpp",
                vk_shader_path ++ "/gelu_erf.comp.cpp",
                vk_shader_path ++ "/gelu_quick.comp.cpp",
                vk_shader_path ++ "/get_rows.comp.cpp",
                vk_shader_path ++ "/get_rows_quant.comp.cpp",
                vk_shader_path ++ "/group_norm.comp.cpp",
                vk_shader_path ++ "/hardsigmoid.comp.cpp",
                vk_shader_path ++ "/hardswish.comp.cpp",
                vk_shader_path ++ "/im2col.comp.cpp",
                vk_shader_path ++ "/im2col_3d.comp.cpp",
                vk_shader_path ++ "/l2_norm.comp.cpp",
                vk_shader_path ++ "/leaky_relu.comp.cpp",
                vk_shader_path ++ "/mul.comp.cpp",
                vk_shader_path ++ "/mul_mat_split_k_reduce.comp.cpp",
                vk_shader_path ++ "/mul_mat_vec.comp.cpp",
                vk_shader_path ++ "/mul_mat_vec_iq1_m.comp.cpp",
                vk_shader_path ++ "/mul_mat_vec_iq1_s.comp.cpp",
                vk_shader_path ++ "/mul_mat_vec_iq2_s.comp.cpp",
                vk_shader_path ++ "/mul_mat_vec_iq2_xs.comp.cpp",
                vk_shader_path ++ "/mul_mat_vec_iq2_xxs.comp.cpp",
                vk_shader_path ++ "/mul_mat_vec_iq3_s.comp.cpp",
                vk_shader_path ++ "/mul_mat_vec_iq3_xxs.comp.cpp",
                vk_shader_path ++ "/mul_mat_vec_nc.comp.cpp",
                vk_shader_path ++ "/mul_mat_vec_p021.comp.cpp",
                vk_shader_path ++ "/mul_mat_vec_q2_k.comp.cpp",
                vk_shader_path ++ "/mul_mat_vec_q3_k.comp.cpp",
                vk_shader_path ++ "/mul_mat_vec_q4_k.comp.cpp",
                vk_shader_path ++ "/mul_mat_vec_q5_k.comp.cpp",
                vk_shader_path ++ "/mul_mat_vec_q6_k.comp.cpp",
                vk_shader_path ++ "/mul_mat_vecq.comp.cpp",
                vk_shader_path ++ "/mul_mm.comp.cpp",
                vk_shader_path ++ "/mul_mm_cm2.comp.cpp",
                vk_shader_path ++ "/mul_mmq.comp.cpp",
                vk_shader_path ++ "/multi_add.comp.cpp",
                vk_shader_path ++ "/norm.comp.cpp",
                vk_shader_path ++ "/opt_step_adamw.comp.cpp",
                vk_shader_path ++ "/opt_step_sgd.comp.cpp",
                vk_shader_path ++ "/pad.comp.cpp",
                vk_shader_path ++ "/pool2d.comp.cpp",
                vk_shader_path ++ "/quantize_q8_1.comp.cpp",
                vk_shader_path ++ "/reglu.comp.cpp",
                vk_shader_path ++ "/relu.comp.cpp",
                vk_shader_path ++ "/repeat.comp.cpp",
                vk_shader_path ++ "/repeat_back.comp.cpp",
                vk_shader_path ++ "/rms_norm.comp.cpp",
                vk_shader_path ++ "/rms_norm_back.comp.cpp",
                vk_shader_path ++ "/rms_norm_partials.comp.cpp",
                vk_shader_path ++ "/roll.comp.cpp",
                vk_shader_path ++ "/rope_multi.comp.cpp",
                vk_shader_path ++ "/rope_neox.comp.cpp",
                vk_shader_path ++ "/rope_norm.comp.cpp",
                vk_shader_path ++ "/rope_vision.comp.cpp",
                vk_shader_path ++ "/scale.comp.cpp",
                vk_shader_path ++ "/sigmoid.comp.cpp",
                vk_shader_path ++ "/silu.comp.cpp",
                vk_shader_path ++ "/silu_back.comp.cpp",
                vk_shader_path ++ "/sin.comp.cpp",
                vk_shader_path ++ "/soft_max.comp.cpp",
                vk_shader_path ++ "/soft_max_back.comp.cpp",
                vk_shader_path ++ "/sqrt.comp.cpp",
                vk_shader_path ++ "/square.comp.cpp",
                vk_shader_path ++ "/sub.comp.cpp",
                vk_shader_path ++ "/sum_rows.comp.cpp",
                vk_shader_path ++ "/swiglu.comp.cpp",
                vk_shader_path ++ "/swiglu_oai.comp.cpp",
                vk_shader_path ++ "/tanh.comp.cpp",
                vk_shader_path ++ "/timestep_embedding.comp.cpp",
                vk_shader_path ++ "/upscale.comp.cpp",
                vk_shader_path ++ "/wkv6.comp.cpp",
                vk_shader_path ++ "/wkv7.comp.cpp",
            };
            exe.addCSourceFiles(.{ .files = &vk_shader_sources, .flags = cpp_flags });
        }
    }

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // Integration tests
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testing/integration/serve.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    // Ensure the main executable is built and installed before running integration tests
    run_integration_tests.step.dependOn(b.getInstallStep());

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_integration_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.

    // Install to ~/.local/bin (similar to `go install`)
    const install_local_step = b.step("install-local", "Install to ~/.local/bin");
    const install_local = b.addSystemCommand(&.{
        "sh", "-c", "mkdir -p \"$HOME/.local/bin\" && cp \"$1\" \"$HOME/.local/bin/ligi\"",
        "--",
    });
    install_local.addArtifactArg(exe);
    install_local_step.dependOn(&install_local.step);
}
