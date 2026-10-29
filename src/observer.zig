const std = @import("std");

// ---------------------------------------------------------------------------
// You, standing in the observatory looking at the retina cube. Plain 3D:
// y up, cube [-1,1]^3 at the origin, metres. Room bounds mirror ROOM_* in
// kernels.hip.
// ---------------------------------------------------------------------------

pub const room_half = 9.0;
pub const room_floor = -2.3;
pub const room_ceil = 3.5;
pub const eye_height = 1.7;

const V3 = @Vector(3, f32);

pub const Observer = struct {
    pos: V3 = .{ 0, 0, 0 },
    yaw: f32 = 0.55,
    pitch: f32 = -0.22,

    pub fn initOrbit(dist: f32) Observer {
        var o = Observer{};
        o.pos = -o.basis().fwd * @as(V3, @splat(dist));
        return o;
    }

    pub const Basis = struct { fwd: V3, right: V3, up: V3 };

    /// At yaw = pitch = 0 you look along +z (the retina's depth axis, from
    /// its negative face) with +x to your right: the cube's s = 0 layer then
    /// faces you like an ordinary picture.
    pub fn basis(self: Observer) Basis {
        const cy = @cos(self.yaw);
        const sy = @sin(self.yaw);
        const cp = @cos(self.pitch);
        const sp = @sin(self.pitch);
        return .{
            .fwd = .{ sy * cp, sp, cy * cp },
            .right = .{ cy, 0, -sy },
            .up = .{ -sy * sp, cp, -cy * sp },
        };
    }

    /// Orbit around the cube, keeping the current distance, looking at it.
    pub fn orbit(self: *Observer, dyaw: f32, dpitch: f32) void {
        const dist = @max(@sqrt(@reduce(.Add, self.pos * self.pos)), 2.2);
        self.yaw += dyaw;
        self.pitch = std.math.clamp(self.pitch + dpitch, -1.4, 1.4);
        self.pos = -self.basis().fwd * @as(V3, @splat(dist));
        self.confine();
    }

    pub fn look(self: *Observer, dyaw: f32, dpitch: f32) void {
        self.yaw += dyaw;
        self.pitch = std.math.clamp(self.pitch + dpitch, -1.5, 1.5);
    }

    /// Walk: `move` = (strafe right, rise, forward) in m/s, horizontal
    /// motion relative to where you face.
    pub fn walk(self: *Observer, move: V3, dt: f32) void {
        const fwd = V3{ @sin(self.yaw), 0, @cos(self.yaw) };
        const right = V3{ @cos(self.yaw), 0, -@sin(self.yaw) };
        const d = right * @as(V3, @splat(move[0])) + V3{ 0, move[1], 0 } + fwd * @as(V3, @splat(move[2]));
        self.pos += d * @as(V3, @splat(dt));
        self.confine();
    }

    /// Stay inside the room and out of the cube/pedestal column.
    pub fn confine(self: *Observer) void {
        const m = 0.4;
        self.pos[0] = std.math.clamp(self.pos[0], -room_half + m, room_half - m);
        self.pos[2] = std.math.clamp(self.pos[2], -room_half + m, room_half - m);
        self.pos[1] = std.math.clamp(self.pos[1], room_floor + 0.3, room_ceil - 0.3);
        const col: f32 = 1.35;
        if (@abs(self.pos[0]) < col and @abs(self.pos[2]) < col and self.pos[1] < 1.35) {
            // Push out along whichever horizontal axis is shallower.
            if (col - @abs(self.pos[0]) < col - @abs(self.pos[2])) {
                self.pos[0] = std.math.copysign(col, self.pos[0]);
            } else {
                self.pos[2] = std.math.copysign(col, self.pos[2]);
            }
        }
    }

    /// Screen position of room point `p` for a w x h view with tan(half
    /// vertical fov) = `fov`, matching the composite kernel. Null if behind.
    pub fn project(self: Observer, p: V3, fov: f32, w: f32, h: f32) ?[2]f32 {
        const b = self.basis();
        const rel = p - self.pos;
        const z = @reduce(.Add, rel * b.fwd);
        if (z < 0.05) return null;
        const x = @reduce(.Add, rel * b.right) / (z * fov);
        const y = @reduce(.Add, rel * b.up) / (z * fov);
        return .{ (x * h / w + 1) * 0.5 * w, (1 - y) * 0.5 * h };
    }
};

test "observer basis is orthonormal" {
    const o = Observer{ .yaw = 1.1, .pitch = -0.4 };
    const b = o.basis();
    const vs = [_]V3{ b.fwd, b.right, b.up };
    for (vs, 0..) |a, i| for (vs, 0..) |c, j| {
        const want: f32 = if (i == j) 1 else 0;
        try std.testing.expectApproxEqAbs(want, @reduce(.Add, a * c), 1e-5);
    };
}

test "walking can't leave the room or enter the cube" {
    var o = Observer.initOrbit(4);
    for (0..1000) |_| o.walk(.{ 0, 0, 3 }, 0.05);
    try std.testing.expect(@abs(o.pos[0]) <= room_half and @abs(o.pos[2]) <= room_half);
    o.pos = .{ 0.2, 0, -0.5 };
    o.confine();
    try std.testing.expect(@abs(o.pos[0]) >= 1.35 or @abs(o.pos[2]) >= 1.35);
}

test "projection puts the point you look at in the screen center" {
    const o = Observer.initOrbit(4);
    const p = o.project(.{ 0, 0, 0 }, 0.55, 1280, 720).?;
    try std.testing.expectApproxEqAbs(@as(f32, 640), p[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 360), p[1], 0.01);
}
