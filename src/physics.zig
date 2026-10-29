const std = @import("std");
const m4 = @import("math4.zig");
const world = @import("world.zig");
const system = @import("system.zig");
const V4 = m4.V4;

// ---------------------------------------------------------------------------
// Ship dynamics.
//
// Gravity follows Gauss's law in four spatial dimensions: flux through a
// 3-sphere of area 2*pi^2*r^3 is constant, so the field falls off as 1/r^3:
//     a = GM * (c - p) / |c - p|^4
// The corresponding potential is -GM / (2 r^2). Two consequences you'll feel
// in flight: circular-orbit speed sqrt(GM)/r equals escape speed, and
// circular orbits are neutrally unstable -- any perturbation spirals in or out.
//
// Thrusters are ordinary Newtonian: bounded accelerations along the four
// ship axes. Flight assist only commands those same thrusters; it never
// cheats physics. Its reference frame is the nearest body: it nulls your
// velocity relative to that body and cancels gravity relative to that body's
// own free fall (planets on orbits are falling toward the sun too).
// ---------------------------------------------------------------------------

pub const dt: f64 = 1.0 / 240.0;

pub const ship_radius = 3.0;
pub const default_crash_speed = 12.0; // m/s into the ground
pub const friction = 0.9; // Coulomb coefficient on contact

/// Max thruster acceleration per local axis, m/s^2 (right, up, fwd, ana).
/// Forward is the main engine; the rest are RCS. All exceed Terra's 9.81.
pub const thrust_pos = V4{ 25, 25, 40, 25 };
pub const thrust_neg = V4{ 25, 25, 25, 25 };
pub const boost_factor = 8.0;

pub const max_rate = 1.2; // rad/s, keyboard rotation rate with assist on
pub const ang_accel = 2.5; // rad/s^2

pub const Input = struct {
    /// -1..1 per local axis (right, up, fwd, ana).
    thrust: V4 = @splat(0),
    /// -1..1 per rotation plane (see m4.planes).
    rot: [6]f64 = .{ 0, 0, 0, 0, 0, 0 },
    boost: bool = false,
};

pub const Ship = struct {
    pos: V4,
    vel: V4 = @splat(0),
    frame: m4.Frame = .{},
    omega: [6]f64 = .{ 0, 0, 0, 0, 0, 0 },
    assist: bool = true,
    landed: bool = false,
    crashed: bool = false,
    crash_speed: f64 = default_crash_speed,
    /// Speed of the last impact, for the HUD.
    last_impact: f64 = 0,
    /// Commanded thrust (local, m/s^2), for the HUD.
    thrust_out: V4 = @splat(0),
    /// Body used as the reference frame (nearest surface).
    ref: usize = 1,
};

fn clampAxis(x: f64, lo: f64, hi: f64) f64 {
    return @min(@max(x, lo), hi);
}

/// Advance the ship by one physics step. Call after `sys.step(dt)`.
pub fn step(ship: *Ship, sys: *const system.System, in: Input) void {
    const boost: f64 = if (in.boost) boost_factor else 1;
    ship.ref = sys.nearest(ship.pos).index;
    const ref_vel = sys.vel[ship.ref];
    const g = sys.gravityAt(ship.pos);
    // Gravity and velocity as seen from the reference body's falling frame.
    const g_local = ship.frame.toLocal(g - sys.acc[ship.ref]);
    const v_local = ship.frame.toLocal(ship.vel - ref_vel);

    // --- translation -------------------------------------------------------
    var cmd: V4 = undefined;
    inline for (0..4) |k| {
        const hi = thrust_pos[k] * boost;
        const lo = -thrust_neg[k] * boost;
        if (in.thrust[k] != 0) {
            cmd[k] = if (in.thrust[k] > 0) in.thrust[k] * hi else -in.thrust[k] * lo;
        } else if (ship.assist and !ship.landed) {
            // Null relative velocity along this axis and hold against gravity.
            const tau = 0.6;
            cmd[k] = clampAxis(-v_local[k] / tau - g_local[k], lo, hi);
        } else {
            cmd[k] = 0;
        }
    }
    ship.thrust_out = cmd;
    const accel = g + ship.frame.toWorld(cmd);

    // Semi-implicit Euler: symplectic, so orbits don't gain energy over time.
    ship.vel += m4.scale(accel, dt);
    ship.pos += m4.scale(ship.vel, dt);

    // --- rotation ----------------------------------------------------------
    for (&ship.omega, in.rot) |*w, r| {
        if (ship.assist) {
            const target = r * max_rate;
            const dw = clampAxis(target - w.*, -ang_accel * 2 * dt, ang_accel * 2 * dt);
            w.* += dw;
        } else {
            w.* += r * ang_accel * dt;
        }
    }
    ship.frame.spin(ship.omega, dt);

    // --- contact (in the touched body's frame) -----------------------------
    ship.landed = false;
    for (&world.planets, 0..) |*pl, i| {
        const center = sys.pos[i];
        const gap = world.surfaceGap(pl, center, ship.pos) - ship_radius;
        // A few cm of tolerance so resting contact is stable on slopes.
        if (gap >= 0.05) continue;
        const body_vel = sys.vel[i];
        if (i == world.sun_index) {
            ship.crashed = true;
            ship.last_impact = m4.len(ship.vel - body_vel);
            return;
        }
        const n = world.surfaceNormal(pl, center, ship.pos);
        if (gap < 0) ship.pos += m4.scale(n, -gap);
        var vrel = ship.vel - body_vel;
        const vn = m4.dot(vrel, n);
        if (vn < 0) {
            ship.last_impact = -vn;
            if (-vn > ship.crash_speed) {
                ship.crashed = true;
                return;
            }
            vrel -= m4.scale(n, vn);
        }
        // Coulomb friction from the impact impulse plus the normal load.
        const load = @max(-m4.dot(accel - sys.acc[i], n), 0) * dt + @max(-vn, 0);
        const vt = vrel - m4.scale(n, m4.dot(vrel, n));
        const vt_len = m4.len(vt);
        if (vt_len > 0) {
            const k = @max(vt_len - friction * load, 0) / vt_len;
            vrel = vrel - vt + m4.scale(vt, k);
        }
        ship.vel = body_vel + vrel;
        ship.landed = m4.dot(cmd, ship.frame.toLocal(n)) <= 0 or m4.len(vrel) < 0.5;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const terra_i = 1;
const terra = &world.planets[terra_i];

fn shipAbove(sys: *const system.System, alt: f64) Ship {
    const up = m4.normalize(V4{ -1, 0.4, 0.2, -0.1 });
    const c = sys.pos[terra_i];
    // Start above the local surface (or sea), whatever its height.
    const base = c + m4.scale(up, terra.gpu.radius);
    const ground = world.surfaceGap(terra, c, base);
    return .{
        .pos = base + m4.scale(up, alt - ground),
        .vel = sys.vel[terra_i],
        .frame = m4.Frame.lookUp(up, .{ 0, 0, 1, 0 }),
    };
}

fn run(ship: *Ship, sys: *system.System, secs: f64, in: Input) void {
    const steps: usize = @intFromFloat(secs / dt);
    for (0..steps) |_| {
        sys.step(dt);
        step(ship, sys, in);
        if (ship.crashed) return;
    }
}

test "surface gravity of each body matches its configured g" {
    for (&world.planets, 0..) |*pl, i| {
        const p = pl.pos + V4{ 0, pl.gpu.radius, 0, 0 };
        try std.testing.expectApproxEqRel(pl.surface_g, m4.len(system.gravityFrom(i, pl.pos, p)), 1e-9);
    }
}

test "gravity falls off as 1/r^3" {
    const a1 = m4.len(system.gravityFrom(terra_i, terra.pos, terra.pos + V4{ 0, 0, 0, 3000 }));
    const a2 = m4.len(system.gravityFrom(terra_i, terra.pos, terra.pos + V4{ 0, 0, 0, 6000 }));
    try std.testing.expectApproxEqRel(@as(f64, 8), a1 / a2, 1e-9);
}

test "circular orbit speed equals escape speed in 4D" {
    const gm = terra.gm();
    const r = 5000.0;
    const v = @sqrt(gm) / r;
    try std.testing.expectApproxEqRel(v * v / r, gm / (r * r * r), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0), 0.5 * v * v - gm / (2 * r * r), 1e-9);
}

test "integrator conserves orbital energy in a 1/r^3 field" {
    const gm = terra.gm();
    var pos = terra.pos + V4{ 0, 0, 4000, 0 };
    var vel = V4{ 0, 0, 0, @sqrt(gm) / 4000 * 0.9 };
    const energy = struct {
        fn f(p: V4, v: V4, k: f64) f64 {
            const r = m4.len(p - terra.pos);
            return 0.5 * m4.dot(v, v) - k / (2 * r * r);
        }
    }.f;
    const e0 = energy(pos, vel, gm);
    for (0..240 * 20) |_| {
        vel += m4.scale(system.gravityFrom(terra_i, terra.pos, pos), dt);
        pos += m4.scale(vel, dt);
    }
    try std.testing.expectApproxEqRel(e0, energy(pos, vel, gm), 1e-3);
}

test "assist hovers in place with no input" {
    for ([_]system.Motion{ .static, .rails, .nbody }) |mo| {
        var sys = system.System.init(mo);
        var s = shipAbove(&sys, 200);
        run(&s, &sys, 10, .{});
        const rel = s.pos - sys.pos[terra_i];
        const s0 = shipAbove(&sys, 200);
        try std.testing.expect(!s.crashed);
        try std.testing.expect(m4.len(rel - (s0.pos - sys.pos[terra_i])) < 2.0);
    }
}

test "landed ship rides along with an orbiting planet" {
    var sys = system.System.init(.rails);
    var s = shipAbove(&sys, 4);
    s.assist = false;
    run(&s, &sys, 60, .{});
    try std.testing.expect(!s.crashed);
    try std.testing.expect(s.landed);
    try std.testing.expect(m4.len(s.vel - sys.vel[terra_i]) < 0.5);
}

test "unassisted free fall from low altitude lands softly" {
    var sys = system.System.init(.static);
    var s = shipAbove(&sys, 6);
    s.assist = false;
    run(&s, &sys, 5, .{});
    try std.testing.expect(!s.crashed);
    try std.testing.expect(s.landed);
}

test "falling from high altitude crashes" {
    var sys = system.System.init(.static);
    var s = shipAbove(&sys, 300);
    s.assist = false;
    run(&s, &sys, 20, .{});
    try std.testing.expect(s.crashed);
    try std.testing.expect(s.last_impact > s.crash_speed);
}

test "full forward thrust accelerates at the main engine rating" {
    var sys = system.System.init(.static);
    var s = shipAbove(&sys, 500);
    s.assist = false;
    const v0 = s.vel;
    const g0 = sys.gravityAt(s.pos);
    step(&s, &sys, .{ .thrust = .{ 0, 0, 1, 0 } });
    const a = m4.scale(s.vel - v0, 1 / dt) - g0;
    try std.testing.expectApproxEqRel(thrust_pos[2], m4.dot(a, s.frame.axes[m4.fwd]), 1e-6);
}
