const std = @import("std");
const hip = @import("hip.zig");
const world = @import("world.zig");

// ---------------------------------------------------------------------------
// Owns the HIP module and device buffers and runs one frame:
//   retina view: march_retina -> retina_alpha -> composite
//   slice view:  march_slice
// then copies the RGBA frame back to the host.
// ---------------------------------------------------------------------------

pub const max_retina = 160;

pub const View = enum { retina, slice };

pub const Renderer = struct {
    module: hip.hipModule_t = null,
    k_march: hip.hipFunction_t = null,
    k_alpha: hip.hipFunction_t = null,
    k_composite: hip.hipFunction_t = null,
    k_slice: hip.hipFunction_t = null,
    k_probe: hip.hipFunction_t = null,
    d_params: ?*anyopaque = null,
    d_retina: ?*anyopaque = null,
    d_vol: ?*anyopaque = null,
    d_pixels: ?*anyopaque = null,
    width: u32,
    height: u32,

    pub fn init(width: u32, height: u32, kernel_path: [*:0]const u8) !Renderer {
        var r = Renderer{ .width = width, .height = height };
        try hip.check(hip.hipModuleLoad(&r.module, kernel_path), "hipModuleLoad");
        try hip.check(hip.hipModuleGetFunction(&r.k_march, r.module, "march_retina"), "get march_retina");
        try hip.check(hip.hipModuleGetFunction(&r.k_alpha, r.module, "retina_alpha"), "get retina_alpha");
        try hip.check(hip.hipModuleGetFunction(&r.k_composite, r.module, "composite"), "get composite");
        try hip.check(hip.hipModuleGetFunction(&r.k_slice, r.module, "march_slice"), "get march_slice");
        try hip.check(hip.hipModuleGetFunction(&r.k_probe, r.module, "terrain_probe"), "get terrain_probe");
        const vox = max_retina * max_retina * max_retina;
        try hip.check(hip.hipMalloc(&r.d_params, @sizeOf(world.Params)), "hipMalloc params");
        try hip.check(hip.hipMalloc(&r.d_retina, vox * 16), "hipMalloc retina");
        try hip.check(hip.hipMalloc(&r.d_vol, vox * 4), "hipMalloc volume");
        try hip.check(hip.hipMalloc(&r.d_pixels, @as(usize, width) * height * 4), "hipMalloc pixels");
        return r;
    }

    pub fn deinit(self: *Renderer) void {
        _ = hip.hipFree(self.d_params);
        _ = hip.hipFree(self.d_retina);
        _ = hip.hipFree(self.d_vol);
        _ = hip.hipFree(self.d_pixels);
    }

    fn launch(f: hip.hipFunction_t, grid: [3]u32, block: [3]u32, args: []?*anyopaque, comptime what: []const u8) !void {
        try hip.check(hip.hipModuleLaunchKernel(f, grid[0], grid[1], grid[2], block[0], block[1], block[2], 0, null, args.ptr, null), what);
    }

    fn div(a: u32, b: u32) u32 {
        return (a + b - 1) / b;
    }

    pub fn frame(self: *Renderer, params: *const world.Params, view: View, out: []u8) !void {
        try hip.check(hip.hipMemcpy(self.d_params, params, @sizeOf(world.Params), hip.hip_memcpy_host_to_device), "upload params");
        const screen_grid = [3]u32{ div(self.width, 16), div(self.height, 16), 1 };
        switch (view) {
            .retina => {
                const n: u32 = @intCast(params.n);
                const vgrid = [3]u32{ div(n, 8), div(n, 8), div(n, 4) };
                var a1 = [_]?*anyopaque{ @ptrCast(&self.d_params), @ptrCast(&self.d_retina) };
                try launch(self.k_march, vgrid, .{ 8, 8, 4 }, &a1, "launch march_retina");
                var a2 = [_]?*anyopaque{ @ptrCast(&self.d_params), @ptrCast(&self.d_retina), @ptrCast(&self.d_vol) };
                try launch(self.k_alpha, vgrid, .{ 8, 8, 4 }, &a2, "launch retina_alpha");
                var a3 = [_]?*anyopaque{ @ptrCast(&self.d_params), @ptrCast(&self.d_vol), @ptrCast(&self.d_pixels) };
                try launch(self.k_composite, screen_grid, .{ 16, 16, 1 }, &a3, "launch composite");
            },
            .slice => {
                var a = [_]?*anyopaque{ @ptrCast(&self.d_params), @ptrCast(&self.d_pixels) };
                try launch(self.k_slice, screen_grid, .{ 16, 16, 1 }, &a, "launch march_slice");
            },
        }
        try hip.check(hip.hipDeviceSynchronize(), "hipDeviceSynchronize");
        try hip.check(hip.hipMemcpy(out.ptr, self.d_pixels, out.len, hip.hip_memcpy_device_to_host), "download frame");
    }

    /// Evaluate the GPU terrain function on `dirs` (for the CPU/GPU cross-check).
    pub fn probeTerrain(self: *Renderer, params: *const world.Params, body: i32, octaves: i32, dirs: []const [4]f32, out: []f32) !void {
        var d_dirs: ?*anyopaque = null;
        var d_out: ?*anyopaque = null;
        try hip.check(hip.hipMalloc(&d_dirs, dirs.len * 16), "hipMalloc dirs");
        defer _ = hip.hipFree(d_dirs);
        try hip.check(hip.hipMalloc(&d_out, out.len * 4), "hipMalloc probe out");
        defer _ = hip.hipFree(d_out);
        try hip.check(hip.hipMemcpy(self.d_params, params, @sizeOf(world.Params), hip.hip_memcpy_host_to_device), "upload params");
        try hip.check(hip.hipMemcpy(d_dirs, dirs.ptr, dirs.len * 16, hip.hip_memcpy_host_to_device), "upload dirs");
        var count: i32 = @intCast(dirs.len);
        var b = body;
        var o = octaves;
        var args = [_]?*anyopaque{ @ptrCast(&self.d_params), @ptrCast(&d_dirs), @ptrCast(&d_out), @ptrCast(&count), @ptrCast(&b), @ptrCast(&o) };
        try launch(self.k_probe, .{ div(@intCast(dirs.len), 256), 1, 1 }, .{ 256, 1, 1 }, &args, "launch terrain_probe");
        try hip.check(hip.hipDeviceSynchronize(), "hipDeviceSynchronize");
        try hip.check(hip.hipMemcpy(out.ptr, d_out, out.len * 4, hip.hip_memcpy_device_to_host), "download probe");
    }
};
