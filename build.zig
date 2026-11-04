const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // A game: optimize by default (`-Doptimize=Debug` for debugging).
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default ReleaseFast)") orelse .ReleaseFast;

    // GPU ISA for the kernels; find yours with `rocminfo | grep gfx`.
    const offload_arch = b.option([]const u8, "offload-arch", "AMD GPU target, e.g. gfx1032") orelse "gfx1032";
    // Defaults come from the nix devShell (ROCM_PREFIX / SDL2_PREFIX).
    const env = &b.graph.environ_map;
    const rocm_path = b.option([]const u8, "rocm-path", "Path to the ROCm/HIP install") orelse
        env.get("ROCM_PREFIX") orelse "/opt/rocm";
    const sdl2_path = b.option([]const u8, "sdl2-path", "Path to the SDL2 install (optional)") orelse
        env.get("SDL2_PREFIX") orelse "";

    // Device code: src/kernels.hip -> kernels.hsaco, loaded at runtime.
    const kernel_cc = b.addSystemCommand(&.{
        "hipcc",
        b.fmt("--offload-arch={s}", .{offload_arch}),
        "-O3",
        "-ffast-math",
        "-c",
        "--genco",
        "-o",
    });
    const hsaco = kernel_cc.addOutputFileArg("kernels.hsaco");
    kernel_cc.addFileArg(b.path("src/kernels.hip"));
    const install_kernel = b.addInstallFileWithDir(hsaco, .bin, "kernels.hsaco");
    b.getInstallStep().dependOn(&install_kernel.step);

    const exe = b.addExecutable(.{
        .name = "space4d",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{rocm_path}) });
    exe.root_module.linkSystemLibrary("amdhip64", .{});
    if (sdl2_path.len > 0) {
        exe.root_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{sdl2_path}) });
    }
    exe.root_module.linkSystemLibrary("SDL2", .{});
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.setCwd(.{ .cwd_relative = b.getInstallPath(.bin, "") });
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Build and run the game").dependOn(&run.step);

    // CPU/GPU terrain agreement check (needs the GPU).
    const check = b.addRunArtifact(exe);
    check.step.dependOn(b.getInstallStep());
    check.setCwd(.{ .cwd_relative = b.getInstallPath(.bin, "") });
    check.addArg("--gpucheck");
    b.step("gpucheck", "Compare CPU and GPU terrain functions").dependOn(&check.step);

    // Browser build: zig-out/web/ is a static site (upload the folder as is).
    // The game logic compiles to wasm; web/app.js drives WebGPU with
    // web/shaders.wgsl, a port of src/kernels.hip.
    const wasm = b.addExecutable(.{
        .name = "space4d",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/web.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
            .optimize = optimize,
            .strip = optimize != .Debug,
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    const web_step = b.step("web", "Build the browser version into zig-out/web");
    web_step.dependOn(&b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = .{ .custom = "web" } } }).step);
    for ([_][]const u8{ "index.html", "app.js", "gpu.js", "shaders.wgsl" }) |f| {
        web_step.dependOn(&b.addInstallFileWithDir(b.path(b.fmt("web/{s}", .{f})), .{ .custom = "web" }, f).step);
    }

    // Headless WebGPU test of the web build (Deno): `zig build webcheck -- --check`.
    const webcheck = b.addSystemCommand(&.{ "deno", "run", "--allow-read", "--allow-write", "tools/webcheck.js" });
    webcheck.step.dependOn(web_step);
    if (b.args) |args| webcheck.addArgs(args);
    b.step("webcheck", "Test the web build headlessly with Deno's WebGPU").dependOn(&webcheck.step);

    // Serve zig-out/web on http://localhost:8000 for testing in a browser.
    const serve = b.addSystemCommand(&.{ "python3", "-m", "http.server", "8000", "--bind", "127.0.0.1", "--directory" });
    serve.addArg(b.getInstallPath(.{ .custom = "web" }, ""));
    serve.step.dependOn(web_step);
    b.step("serve", "Build the web version and serve it on localhost:8000").dependOn(&serve.step);

    // Pure-CPU unit tests: 4D math, noise, physics.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
