const std = @import("std");

// ---------------------------------------------------------------------------
// Minimal, hand-written bindings for the HIP runtime C API. See the notes in
// the original vecadd demo: this is the whole "C interop" surface, and it's
// just a handful of extern fn declarations against libamdhip64.so -- no
// @cImport of HIP's headers anywhere.
// ---------------------------------------------------------------------------

pub const hipError_t = c_int;
pub const hip_success: hipError_t = 0;

pub const hipMemcpyKind = c_int;
pub const hip_memcpy_host_to_device: hipMemcpyKind = 1;
pub const hip_memcpy_device_to_host: hipMemcpyKind = 2;

pub const hipModule_t = ?*opaque {};
pub const hipFunction_t = ?*opaque {};
pub const hipStream_t = ?*opaque {};

pub extern fn hipMalloc(ptr: *?*anyopaque, size: usize) hipError_t;
pub extern fn hipFree(ptr: ?*anyopaque) hipError_t;
pub extern fn hipMemcpy(dst: ?*anyopaque, src: ?*const anyopaque, size_bytes: usize, kind: hipMemcpyKind) hipError_t;
pub extern fn hipDeviceSynchronize() hipError_t;
pub extern fn hipGetErrorString(err: hipError_t) [*:0]const u8;
pub extern fn hipModuleLoad(module: *hipModule_t, fname: [*:0]const u8) hipError_t;
pub extern fn hipModuleGetFunction(function: *hipFunction_t, module: hipModule_t, kname: [*:0]const u8) hipError_t;
pub extern fn hipModuleLaunchKernel(
    f: hipFunction_t,
    grid_dim_x: c_uint,
    grid_dim_y: c_uint,
    grid_dim_z: c_uint,
    block_dim_x: c_uint,
    block_dim_y: c_uint,
    block_dim_z: c_uint,
    shared_mem_bytes: c_uint,
    stream: hipStream_t,
    kernel_params: ?[*]?*anyopaque,
    extra: ?[*]?*anyopaque,
) hipError_t;

pub fn check(err: hipError_t, comptime what: []const u8) !void {
    if (err != hip_success) {
        std.debug.print("{s} failed: {s}\n", .{ what, hipGetErrorString(err) });
        return error.HipError;
    }
}
