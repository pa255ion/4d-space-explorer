const std = @import("std");
const m4 = @import("math4.zig");
const world = @import("world.zig");
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
// cheats physics.
// ---------------------------------------------------------------------------

pub const dt: f64 = 1.0 / 240.0;

pub const ship_radius = 3.0;
pub const crash_speed = 12.0; // m/s into the ground
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
    /// Speed of the last impact, for the HUD.
    last_impact: f64 = 0,
    /// Commanded thrust (local, m/s^2), for the HUD.
    thrust_out: V4 = @splat(0),
};

pub fn gravityFrom(pl: *const world.Planet, pos: V4) V4 {
    const d = pl.pos - pos;
    const r2 = m4.dot(d, d);
    return m4.scale(d, pl.gm() / (r2 * r2));
}

pub fn gravity(pos: V4) V4 {
    var a: V4 = @splat(0);
    for (&world.planets) |*pl| a += gravityFrom(pl, pos);
    return a;
}

/// Specific orbital energy w.r.t. one body (kinetic + 4D potential).
pub fn orbitalEnergy(pl: *const world.Planet, pos: V4, vel: V4) f64 {
    const r = m4.len(pos - pl.pos);
    return 0.5 * m4.dot(vel, vel) - pl.gm() / (2 * r * r);
}

pub const Nearest = struct { index: usize, gap: f64 };

/// The body whose surface is closest (by radial clearance).
pub fn nearest(pos: V4) Nearest {
    var best = Nearest{ .index = 0, .gap = std.math.inf(f64) };
    for (&world.planets, 0..) |*pl, i| {
        const g = world.surfaceGap(pl, pos);
        if (g < best.gap) best = .{ .index = i, .gap = g };
    }
    return best;
}

fn clampAxis(x: f64, lo: f64, hi: f64) f64 {
    return @min(@max(x, lo), hi);
}

pub fn step(ship: *Ship, in: Input) void {
    const boost: f64 = if (in.boost) boost_factor else 1;
    const g = gravity(ship.pos);
    const g_local = ship.frame.toLocal(g);
    const v_local = ship.frame.toLocal(ship.vel);

    // --- translation -------------------------------------------------------
    var cmd: V4 = undefined;
    inline for (0..4) |k| {
        const hi = thrust_pos[k] * boost;
        const lo = -thrust_neg[k] * boost;
        if (in.thrust[k] != 0) {
            cmd[k] = if (in.thrust[k] > 0) in.thrust[k] * hi else -in.thrust[k] * lo;
        } else if (ship.assist and !ship.landed) {
            // Null velocity along this axis and hold against gravity.
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

    // --- contact -----------------------------------------------------------
    ship.landed = false;
    for (&world.planets, 0..) |*pl, i| {
        const gap = world.surfaceGap(pl, ship.pos) - ship_radius;
        // A few cm of tolerance so resting contact is stable on slopes.
        if (gap >= 0.05) continue;
        if (i == world.sun_index) {
            ship.crashed = true;
            ship.last_impact = m4.len(ship.vel);
            return;
        }
        const n = world.surfaceNormal(pl, ship.pos);
        if (gap < 0) ship.pos += m4.scale(n, -gap);
        const vn = m4.dot(ship.vel, n);
        if (vn < 0) {
            ship.last_impact = -vn;
            if (-vn > crash_speed) {
                ship.crashed = true;
                return;
            }
            ship.vel -= m4.scale(n, vn);
        }
        // Coulomb friction from the impact impulse plus the normal load.
        const load = @max(-m4.dot(accel, n), 0) * dt + @max(-vn, 0);
        const vt = ship.vel - m4.scale(n, m4.dot(ship.vel, n));
        const vt_len = m4.len(vt);
        if (vt_len > 0) {
            const k = @max(vt_len - friction * load, 0) / vt_len;
            ship.vel = ship.vel - vt + m4.scale(vt, k);
        }
        ship.landed = m4.dot(cmd, ship.frame.toLocal(n)) <= 0 or m4.len(ship.vel) < 0.5;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const terra = &world.planets[1];
const sol = &world.planets[world.sun_index];

test "surface gravity of each body matches its configured g" {
    for (&world.planets) |*pl| {
        const p = pl.pos + V4{ 0, pl.gpu.radius, 0, 0 };
        try std.testing.expectApproxEqRel(pl.surface_g, m4.len(gravityFrom(pl, p)), 1e-9);
    }
}

test "gravity falls off as 1/r^3" {
    const a1 = m4.len(gravityFrom(terra, terra.pos + V4{ 0, 0, 0, 3000 }));
    const a2 = m4.len(gravityFrom(terra, terra.pos + V4{ 0, 0, 0, 6000 }));
    try std.testing.expectApproxEqRel(@as(f64, 8), a1 / a2, 1e-9);
}

test "integrator conserves orbital energy around the sun" {
    // A smooth body, far from everything else, so only its field matters
    // to good approximation; use gravityFrom directly to be exact.
    var pos = sol.pos + V4{ 0, 0, 6000, 0 };
    var vel = V4{ 0, 0, 0, @sqrt(sol.gm()) / 6000 * 0.9 }; // sub-circular: falls inward a bit
    const e0 = orbitalEnergy(sol, pos, vel);
    for (0..240 * 20) |_| {
        vel += m4.scale(gravityFrom(sol, pos), dt);
        pos += m4.scale(vel, dt);
        if (m4.len(pos - sol.pos) < sol.gpu.radius) break;
    }
    try std.testing.expectApproxEqRel(e0, orbitalEnergy(sol, pos, vel), 1e-3);
}

test "circular orbit speed equals escape speed in 4D" {
    const r = 5000.0;
    const v = @sqrt(sol.gm()) / r;
    // Circular: v^2 / r = GM / r^3.
    try std.testing.expectApproxEqRel(v * v / r, sol.gm() / (r * r * r), 1e-12);
    // Escape: total energy exactly zero.
    try std.testing.expectApproxEqAbs(@as(f64, 0), 0.5 * v * v - sol.gm() / (2 * r * r), 1e-6);
}

fn shipAbove(alt: f64) Ship {
    const up = m4.normalize(V4{ -1, 0.4, 0.2, -0.1 });
    // Start above the local surface (or sea), whatever its height.
    const base = terra.pos + m4.scale(up, terra.gpu.radius);
    const ground = world.surfaceGap(terra, base);
    return .{
        .pos = base + m4.scale(up, alt - ground),
        .frame = m4.Frame.lookUp(up, .{ 0, 0, 1, 0 }),
    };
}

test "assist hovers in place with no input" {
    var s = shipAbove(200);
    const p0 = s.pos;
    for (0..240 * 10) |_| step(&s, .{});
    try std.testing.expect(m4.len(s.pos - p0) < 1.0);
    try std.testing.expect(!s.crashed);
}

test "unassisted free fall from low altitude lands softly" {
    var s = shipAbove(6);
    s.assist = false;
    for (0..240 * 5) |_| step(&s, .{});
    try std.testing.expect(!s.crashed);
    try std.testing.expect(s.landed);
    try std.testing.expect(m4.len(s.vel) < 0.5);
}

test "falling from high altitude crashes" {
    var s = shipAbove(300);
    s.assist = false;
    for (0..240 * 20) |_| {
        step(&s, .{});
        if (s.crashed) break;
    }
    try std.testing.expect(s.crashed);
    try std.testing.expect(s.last_impact > crash_speed);
}

test "full forward thrust accelerates at the main engine rating" {
    var s = shipAbove(500);
    s.assist = false;
    const v0 = s.vel;
    step(&s, .{ .thrust = .{ 0, 0, 1, 0 } });
    const a = m4.scale(s.vel - v0, 1 / dt) - gravity(s.pos - m4.scale(s.vel, dt));
    try std.testing.expectApproxEqRel(thrust_pos[2], m4.dot(a, s.frame.axes[m4.fwd]), 1e-3);
}
