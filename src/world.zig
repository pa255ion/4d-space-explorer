const std = @import("std");
const m4 = @import("math4.zig");
const V4 = m4.V4;

// ---------------------------------------------------------------------------
// GPU-shared layouts. These must match `struct Body` / `struct Params` in
// src/kernels.hip field for field (all 4-byte scalars, so no padding).
// ---------------------------------------------------------------------------

pub const max_bodies = 8;
pub const max_octaves = 9;

pub const Body = extern struct {
    c: [4]f32 = .{ 0, 0, 0, 0 },
    radius: f32,
    amp: f32 = 0,
    sea: f32 = -1e9,
    feature: f32 = 1,
    atmo_h: f32 = 0,
    atmo_rgb: [3]f32 = .{ 0, 0, 0 },
    col_low: [3]f32 = .{ 0.5, 0.5, 0.5 },
    col_mid: [3]f32 = .{ 0.5, 0.5, 0.5 },
    col_high: [3]f32 = .{ 0.9, 0.9, 0.9 },
    col_sea: [3]f32 = .{ 0.05, 0.1, 0.3 },
    emissive: f32 = 0,
    seed: u32 = 0,
};

pub const Params = extern struct {
    right: [4]f32,
    up: [4]f32,
    fwd: [4]f32,
    ana: [4]f32,
    tan_half_fov: f32,
    n: i32,
    slab: f32,
    shadows: i32,
    sun_rgb: [3]f32,
    sun_index: i32,
    num_bodies: i32,
    width: i32,
    height: i32,
    obs_yaw: f32,
    obs_pitch: f32,
    obs_dist: f32,
    base_alpha: f32,
    edge_gain: f32,
    marker: [4]f32,
    bodies: [max_bodies]Body,
};

comptime {
    std.debug.assert(@sizeOf(Body) == 26 * 4);
    std.debug.assert(@sizeOf(Params) == (16 + 4 + 3 + 2 + 2 + 5 + 4) * 4 + max_bodies * @sizeOf(Body));
}

// ---------------------------------------------------------------------------
// The solar system. Positions are in metres (f64 on the CPU; the GPU only
// ever sees them relative to the ship, as f32).
// ---------------------------------------------------------------------------

pub const Planet = struct {
    name: []const u8,
    pos: V4,
    /// Surface gravity at `radius`, m/s^2. With 4D gravity a = GM / r^3, so
    /// GM = g * R^3.
    surface_g: f64,
    gpu: Body,

    pub fn gm(self: Planet) f64 {
        const r: f64 = self.gpu.radius;
        return self.surface_g * r * r * r;
    }
};

pub const sun_index = 0;

pub const planets = [_]Planet{
    .{
        .name = "SOL",
        .pos = .{ 0, 0, 0, 0 },
        .surface_g = 40,
        .gpu = .{ .radius = 3000, .emissive = 4.0 },
    },
    .{
        .name = "TERRA",
        .pos = .{ 25000, 0, 0, 0 },
        .surface_g = 9.81,
        .gpu = .{
            .radius = 2000,
            .amp = 120,
            .sea = 0,
            .feature = 450,
            .atmo_h = 120,
            .atmo_rgb = .{ 0.35, 0.55, 1.0 },
            .col_low = .{ 0.16, 0.36, 0.1 },
            .col_mid = .{ 0.35, 0.3, 0.18 },
            .col_high = .{ 0.92, 0.94, 0.98 },
            .col_sea = .{ 0.03, 0.09, 0.25 },
            .seed = 1234,
        },
    },
    .{
        .name = "OCHRE",
        .pos = .{ 24000, 1500, 5500, 4500 },
        .surface_g = 6.0,
        .gpu = .{
            .radius = 1400,
            .amp = 160,
            .feature = 380,
            .atmo_h = 60,
            .atmo_rgb = .{ 0.9, 0.55, 0.3 },
            .col_low = .{ 0.62, 0.38, 0.18 },
            .col_mid = .{ 0.5, 0.26, 0.14 },
            .col_high = .{ 0.75, 0.6, 0.45 },
            .seed = 777,
        },
    },
    .{
        .name = "GLACIES",
        .pos = .{ 21000, -2500, -1500, -5500 },
        .surface_g = 2.5,
        .gpu = .{
            .radius = 700,
            .amp = 70,
            .feature = 220,
            .col_low = .{ 0.55, 0.62, 0.7 },
            .col_mid = .{ 0.75, 0.82, 0.9 },
            .col_high = .{ 0.95, 0.97, 1.0 },
            .seed = 4242,
        },
    },
};

comptime {
    std.debug.assert(planets.len <= max_bodies);
}

// ---------------------------------------------------------------------------
// Terrain: exact mirror of hash4 / vnoise / terrain_height in kernels.hip.
// Uses f32 throughout so the CPU agrees with the GPU to rounding error.
// ---------------------------------------------------------------------------

const F4 = @Vector(4, f32);

fn hash4(x: i32, y: i32, z: i32, w: i32, seed: u32) u32 {
    var h: u32 = seed;
    h ^= @as(u32, @bitCast(x)) *% 0x8da6b343;
    h ^= @as(u32, @bitCast(y)) *% 0xd8163841;
    h ^= @as(u32, @bitCast(z)) *% 0xcb1ab31f;
    h ^= @as(u32, @bitCast(w)) *% 0x165667b1;
    h ^= h >> 15;
    h *%= 0x2c1b3c6d;
    h ^= h >> 12;
    h *%= 0x297a2d39;
    h ^= h >> 15;
    return h;
}

fn quintic(t: f32) f32 {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

fn cornerValue(x: i32, y: i32, z: i32, w: i32, seed: u32) f32 {
    return @as(f32, @floatFromInt(hash4(x, y, z, w, seed))) * (2.0 / 4294967296.0) - 1.0;
}

pub fn vnoise(p: F4, seed: u32) f32 {
    const f = @floor(p);
    const t = p - f;
    const ix: i32 = @intFromFloat(f[0]);
    const iy: i32 = @intFromFloat(f[1]);
    const iz: i32 = @intFromFloat(f[2]);
    const iw: i32 = @intFromFloat(f[3]);
    const ux = quintic(t[0]);
    const uy = quintic(t[1]);
    const uz = quintic(t[2]);
    const uw = quintic(t[3]);
    var lw: [2]f32 = undefined;
    for (0..2) |dw| {
        var lz: [2]f32 = undefined;
        for (0..2) |dz| {
            var ly: [2]f32 = undefined;
            for (0..2) |dy| {
                const yy = iy + @as(i32, @intCast(dy));
                const zz = iz + @as(i32, @intCast(dz));
                const ww = iw + @as(i32, @intCast(dw));
                const a = cornerValue(ix, yy, zz, ww, seed);
                const b = cornerValue(ix + 1, yy, zz, ww, seed);
                ly[dy] = a + (b - a) * ux;
            }
            lz[dz] = ly[0] + (ly[1] - ly[0]) * uy;
        }
        lw[dw] = lz[0] + (lz[1] - lz[0]) * uz;
    }
    return lw[0] + (lw[1] - lw[0]) * uw;
}

pub fn terrainHeight(b: *const Body, dir: F4, octaves: u32) f32 {
    const q = dir * @as(F4, @splat(b.radius / b.feature));
    var base: f32 = 0;
    var ridge: f32 = 0;
    var a: f32 = 1;
    var norm: f32 = 0;
    var p = q;
    var i: u32 = 0;
    while (i < octaves) : (i += 1) {
        const n = vnoise(p, b.seed +% i);
        base += a * n;
        if (i >= 1) {
            const r = 1.0 - @abs(vnoise(p * @as(F4, @splat(0.5)) + F4{ 5.2, 1.3, 7.7, 3.1 }, b.seed ^ 0x9e3779b9));
            ridge += a * r * r;
        }
        norm += a;
        a *= 0.48;
        p = p * @as(F4, @splat(2.03)) + F4{ 1.7, 9.2, 3.4, 6.1 };
    }
    base /= norm;
    ridge /= norm;
    const land = base * 1.6;
    const mountains = @max(land + 0.05, 0.0) * ridge * 2.2;
    return b.amp * (land + mountains);
}

/// Height of the solid-or-liquid surface above `pos` relative to planet `pl`:
/// positive = clearance, negative = penetration. Measured radially, which for
/// gentle terrain is close to the true distance.
pub fn surfaceGap(pl: *const Planet, pos: V4) f64 {
    const rel = pos - pl.pos;
    const r = m4.len(rel);
    const b = &pl.gpu;
    if (b.amp <= 0) return r - b.radius;
    // Far above the highest possible peak the noise doesn't matter.
    if (r > b.radius + b.amp * 2.6 + 50) return r - b.radius - b.amp * 2.6;
    const dir: F4 = @floatCast(rel / @as(V4, @splat(r)));
    var h: f64 = terrainHeight(b, dir, max_octaves);
    if (b.sea > -b.amp) h = @max(h, b.sea);
    return r - b.radius - h;
}

/// Outward surface normal at `pos` (gradient of surfaceGap).
pub fn surfaceNormal(pl: *const Planet, pos: V4) V4 {
    const e = 0.25;
    const g0 = surfaceGap(pl, pos);
    var g: V4 = undefined;
    inline for (0..4) |k| {
        var q = pos;
        q[k] += e;
        g[k] = surfaceGap(pl, q) - g0;
    }
    const l = m4.len(g);
    if (l < 1e-9) return m4.normalize(pos - pl.pos);
    return g / @as(V4, @splat(l));
}

test "hash is deterministic and spreads" {
    try std.testing.expectEqual(hash4(1, 2, 3, 4, 5), hash4(1, 2, 3, 4, 5));
    try std.testing.expect(hash4(1, 2, 3, 4, 5) != hash4(1, 2, 3, 5, 5));
    try std.testing.expect(hash4(-1, 0, 0, 0, 0) != hash4(1, 0, 0, 0, 0));
}

test "value noise is continuous and bounded" {
    var p = F4{ 0.3, -2.7, 11.1, 4.9 };
    var prev = vnoise(p, 9);
    for (0..2000) |_| {
        p += F4{ 0.001, 0.0007, -0.0013, 0.0009 };
        const v = vnoise(p, 9);
        try std.testing.expect(v >= -1.0 and v <= 1.0);
        try std.testing.expect(@abs(v - prev) < 0.02);
        prev = v;
    }
}

test "terrain stays within the renderer's bounding shell" {
    const terra = &planets[1];
    var rng = std.Random.DefaultPrng.init(42);
    const r = rng.random();
    for (0..4000) |_| {
        const d = m4.normalize(V4{ r.floatNorm(f64), r.floatNorm(f64), r.floatNorm(f64), r.floatNorm(f64) });
        const h = terrainHeight(&terra.gpu, @floatCast(d), max_octaves);
        try std.testing.expect(@abs(h) < terra.gpu.amp * 2.6);
    }
}
