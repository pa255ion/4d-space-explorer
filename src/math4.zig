const std = @import("std");

// ---------------------------------------------------------------------------
// 4D vectors and orientations (f64, CPU side).
//
// An orientation is an orthonormal 4x4 frame stored as four column vectors:
//   axes[0] = right, axes[1] = up, axes[2] = forward, axes[3] = ana
// Rotations in 4D happen in *planes*, not around axes; there are six of
// them, one per pair of axes.
// ---------------------------------------------------------------------------

pub const V4 = @Vector(4, f64);

pub const right = 0;
pub const up = 1;
pub const fwd = 2;
pub const ana = 3;

pub fn dot(a: V4, b: V4) f64 {
    return @reduce(.Add, a * b);
}

pub fn len(a: V4) f64 {
    return @sqrt(dot(a, a));
}

pub fn scale(a: V4, s: f64) V4 {
    return a * @as(V4, @splat(s));
}

pub fn normalize(a: V4) V4 {
    return scale(a, 1.0 / len(a));
}

/// The six rotation planes, in the order used for angular velocity.
pub const planes = [6][2]u2{
    .{ right, up }, // roll
    .{ right, fwd }, // yaw
    .{ right, ana },
    .{ up, fwd }, // pitch
    .{ up, ana },
    .{ fwd, ana },
};

pub const Frame = struct {
    axes: [4]V4 = .{
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 0, 0, 0, 1 },
    },

    /// Rotate by `angle` radians in the plane of local axes (a, b), turning
    /// axis b toward axis a. E.g. rotate(right, fwd, x) yaws to the right.
    pub fn rotate(self: *Frame, a: u2, b: u2, angle: f64) void {
        const c = @cos(angle);
        const s = @sin(angle);
        const va = self.axes[a];
        const vb = self.axes[b];
        self.axes[a] = scale(va, c) - scale(vb, s);
        self.axes[b] = scale(vb, c) + scale(va, s);
    }

    /// Apply a body-frame angular velocity (one rate per plane in `planes`)
    /// for `dt` seconds. Planes are applied sequentially, which is exact to
    /// first order in dt -- plenty at physics rates.
    pub fn spin(self: *Frame, omega: [6]f64, dt: f64) void {
        for (planes, omega) |pl, w| {
            if (w != 0) self.rotate(pl[0], pl[1], w * dt);
        }
        self.orthonormalize();
    }

    /// Gram-Schmidt, keeping forward exact first (it's what the pilot cares
    /// about most), then up, right, ana.
    pub fn orthonormalize(self: *Frame) void {
        const order = [4]u2{ fwd, up, right, ana };
        for (order, 0..) |k, i| {
            var v = self.axes[k];
            for (order[0..i]) |j| v -= scale(self.axes[j], dot(v, self.axes[j]));
            self.axes[k] = normalize(v);
        }
    }

    /// World vector -> local components (right, up, fwd, ana).
    pub fn toLocal(self: Frame, v: V4) V4 {
        return .{ dot(v, self.axes[0]), dot(v, self.axes[1]), dot(v, self.axes[2]), dot(v, self.axes[3]) };
    }

    /// Local components -> world vector.
    pub fn toWorld(self: Frame, l: V4) V4 {
        return scale(self.axes[0], l[0]) + scale(self.axes[1], l[1]) + scale(self.axes[2], l[2]) + scale(self.axes[3], l[3]);
    }

    /// Build a frame whose `up` is `up_dir`, with forward as close as possible
    /// to `fwd_hint`, completed by the remaining axes.
    pub fn lookUp(up_dir: V4, fwd_hint: V4) Frame {
        var f = Frame{};
        f.axes[up] = normalize(up_dir);
        f.axes[fwd] = fwd_hint;
        // Complete with whichever world axes are least aligned.
        const order = [4]u2{ up, fwd, right, ana };
        for (order, 0..) |k, i| {
            if (i < 2) {
                var v = f.axes[k];
                for (order[0..i]) |j| v -= scale(f.axes[j], dot(v, f.axes[j]));
                f.axes[k] = normalize(v);
                continue;
            }
            var best: V4 = undefined;
            var best_len: f64 = -1;
            inline for (0..4) |e| {
                var v: V4 = @splat(0);
                v[e] = 1;
                for (order[0..i]) |j| v -= scale(f.axes[j], dot(v, f.axes[j]));
                const l = len(v);
                if (l > best_len) {
                    best_len = l;
                    best = scale(v, 1.0 / l);
                }
            }
            f.axes[k] = best;
        }
        return f;
    }
};

fn expectOrthonormal(f: Frame) !void {
    for (0..4) |i| for (0..4) |j| {
        const want: f64 = if (i == j) 1 else 0;
        try std.testing.expectApproxEqAbs(want, dot(f.axes[i], f.axes[j]), 1e-9);
    };
}

test "rotation turns b toward a and stays orthonormal" {
    var f = Frame{};
    f.rotate(right, fwd, std.math.pi / 2.0);
    try std.testing.expectApproxEqAbs(@as(f64, 1), f.axes[fwd][0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, -1), f.axes[right][2], 1e-12);
    try expectOrthonormal(f);
}

test "spinning in all six planes keeps the frame orthonormal" {
    var f = Frame{};
    for (0..10000) |_| f.spin(.{ 0.3, -0.2, 0.7, 0.1, -0.5, 0.25 }, 1.0 / 240.0);
    try expectOrthonormal(f);
}

test "a full turn in the fwd-ana plane returns to start" {
    var f = Frame{};
    for (0..360) |_| f.rotate(fwd, ana, std.math.pi / 180.0);
    try std.testing.expectApproxEqAbs(@as(f64, 1), f.axes[fwd][2], 1e-9);
}

test "lookUp gives an orthonormal frame with the requested up" {
    const f = Frame.lookUp(.{ -1, 0.4, 0, 0 }, .{ 0, 0, 1, 0.2 });
    try expectOrthonormal(f);
    const u = normalize(V4{ -1, 0.4, 0, 0 });
    try std.testing.expectApproxEqAbs(@as(f64, 1), dot(f.axes[up], u), 1e-12);
}
