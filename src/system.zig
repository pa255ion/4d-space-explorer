const std = @import("std");
const m4 = @import("math4.zig");
const world = @import("world.zig");
const V4 = m4.V4;

// ---------------------------------------------------------------------------
// Motion of the celestial bodies.
//
//   static: bodies fixed at their t = 0 positions.
//   rails:  each planet follows the exact circular orbit the sun alone would
//           give it (omega^2 a = GM_sun / a^3); planets ignore each other.
//           Stable forever. The sun stays at the origin.
//   nbody:  every body attracts every other (1/r^3) and the whole system is
//           integrated. Starts on the same circular orbits, then drifts:
//           4D circular orbits are neutrally unstable, so mutual
//           perturbations slowly spiral planets in or out.
//
// The ship always feels the real gravity of every body at its current
// position; only how the bodies themselves move differs.
// ---------------------------------------------------------------------------

pub const n = world.planets.len;

pub const Motion = enum { static, rails, nbody };

pub const System = struct {
    motion: Motion,
    time: f64 = 0,
    pos: [n]V4,
    vel: [n]V4,
    /// Current acceleration of each body (used as the ship's reference frame).
    acc: [n]V4,

    pub fn init(motion: Motion) System {
        var s = System{ .motion = motion, .pos = undefined, .vel = undefined, .acc = undefined };
        for (world.planets, 0..) |pl, i| {
            s.pos[i] = pl.pos;
            s.vel[i] = @splat(0);
            s.acc[i] = @splat(0);
        }
        if (motion == .static) return s;
        for (1..n) |i| {
            const o = orbit(i);
            s.vel[i] = m4.scale(o.e2, o.a * o.omega);
            s.acc[i] = m4.scale(o.e1, -o.a * o.omega * o.omega);
        }
        if (motion == .nbody) {
            // Zero total momentum so the system's barycenter stays put.
            var p: V4 = @splat(0);
            for (1..n) |i| p += m4.scale(s.vel[i], world.planets[i].gm());
            s.vel[world.sun_index] = m4.scale(p, -1.0 / world.planets[world.sun_index].gm());
            s.computeAccel();
        }
        return s;
    }

    pub fn step(self: *System, dt: f64) void {
        self.time += dt;
        switch (self.motion) {
            .static => {},
            .rails => for (1..n) |i| {
                const o = orbit(i);
                const th = o.omega * self.time;
                const c = @cos(th);
                const sn = @sin(th);
                self.pos[i] = m4.scale(o.e1, o.a * c) + m4.scale(o.e2, o.a * sn);
                self.vel[i] = m4.scale(o.e1, -o.a * o.omega * sn) + m4.scale(o.e2, o.a * o.omega * c);
                self.acc[i] = m4.scale(self.pos[i], -o.omega * o.omega);
            },
            .nbody => {
                // Semi-implicit Euler, like the ship.
                for (0..n) |i| self.vel[i] += m4.scale(self.acc[i], dt);
                for (0..n) |i| self.pos[i] += m4.scale(self.vel[i], dt);
                self.computeAccel();
            },
        }
    }

    fn computeAccel(self: *System) void {
        for (0..n) |i| {
            self.acc[i] = @splat(0);
            for (0..n) |j| {
                if (i != j) self.acc[i] += gravityFrom(j, self.pos[j], self.pos[i]);
            }
        }
    }

    /// Total gravitational acceleration at `p` from every body.
    pub fn gravityAt(self: *const System, p: V4) V4 {
        var a: V4 = @splat(0);
        for (0..n) |i| a += gravityFrom(i, self.pos[i], p);
        return a;
    }

    /// Body whose surface is closest to `p`, with the clearance.
    pub fn nearest(self: *const System, p: V4) struct { index: usize, gap: f64 } {
        var best: usize = 0;
        var best_gap = std.math.inf(f64);
        for (&world.planets, 0..) |*pl, i| {
            const g = world.surfaceGap(pl, self.pos[i], p);
            if (g < best_gap) {
                best = i;
                best_gap = g;
            }
        }
        return .{ .index = best, .gap = best_gap };
    }

    /// Total energy (kinetic + pairwise potential -GM_i GM_j / (2 r^2)),
    /// in units where "mass" is GM. Conserved by N-body; for tests.
    pub fn energy(self: *const System) f64 {
        var e: f64 = 0;
        for (0..n) |i| {
            const mi = world.planets[i].gm();
            e += 0.5 * mi * m4.dot(self.vel[i], self.vel[i]);
            for (i + 1..n) |j| {
                const d = self.pos[i] - self.pos[j];
                e -= mi * world.planets[j].gm() / (2 * m4.dot(d, d));
            }
        }
        return e;
    }
};

/// 4D gravity: a = GM (c - p) / |c - p|^4.
pub fn gravityFrom(body: usize, center: V4, p: V4) V4 {
    const d = center - p;
    const r2 = m4.dot(d, d);
    return m4.scale(d, world.planets[body].gm() / (r2 * r2));
}

const Orbit = struct { a: f64, omega: f64, e1: V4, e2: V4 };

/// Circular orbit of planet i around the sun: radius, angular rate, and the
/// orthonormal plane basis (e1 = initial direction, e2 = direction of motion).
pub fn orbit(i: usize) Orbit {
    const pl = world.planets[i];
    const a = m4.len(pl.pos);
    const e1 = m4.scale(pl.pos, 1 / a);
    const e2 = m4.normalize(pl.tangent - m4.scale(e1, m4.dot(pl.tangent, e1)));
    // Circular: omega^2 a = GM / a^3.
    const omega = @sqrt(world.planets[world.sun_index].gm()) / (a * a);
    return .{ .a = a, .omega = omega, .e1 = e1, .e2 = e2 };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "rails orbits accelerate exactly as the sun's gravity says" {
    var s = System.init(.rails);
    for (0..1000) |_| s.step(1.0);
    for (1..n) |i| {
        const g = gravityFrom(world.sun_index, s.pos[0], s.pos[i]);
        try std.testing.expectApproxEqRel(m4.len(g), m4.len(s.acc[i]), 1e-9);
        try std.testing.expect(m4.dot(m4.normalize(g), m4.normalize(s.acc[i])) > 1 - 1e-9);
    }
}

test "orbital periods are minutes, not hours" {
    for (1..n) |i| {
        const period = 2 * std.math.pi / orbit(i).omega;
        try std.testing.expect(period > 5 * 60 and period < 40 * 60);
    }
}

test "the sun dominates every planet's motion, at every point on the rails" {
    var s = System.init(.rails);
    var t: f64 = 0;
    while (t < 3 * 3600) : (t += 30) {
        s.step(30);
        for (1..n) |i| {
            const sun = m4.len(gravityFrom(0, s.pos[0], s.pos[i]));
            var others: f64 = 0;
            for (1..n) |j| if (j != i) {
                others += m4.len(gravityFrom(j, s.pos[j], s.pos[i]));
            };
            try std.testing.expect(others < 0.02 * sun);
            // Bodies never overlap.
            for (1..n) |j| if (j != i) {
                const d = m4.len(s.pos[i] - s.pos[j]);
                try std.testing.expect(d > world.planets[i].gpu.radius + world.planets[j].gpu.radius + 1000);
            };
        }
    }
}

test "solar tides are small next to each planet's surface gravity" {
    for (1..n) |i| {
        const pl = world.planets[i];
        const a = m4.len(pl.pos);
        // Radial gradient of GM/r^3 is 3 GM / r^4.
        const tide = 3 * world.planets[0].gm() / (a * a * a * a) * pl.gpu.radius;
        try std.testing.expect(tide < 0.06 * pl.surface_g);
    }
}

test "n-body conserves energy and momentum" {
    var s = System.init(.nbody);
    const e0 = s.energy();
    // Circular 1/r^3 orbits have exactly zero energy (circular speed = escape
    // speed), so the total is near zero; measure drift against kinetic energy.
    var ke: f64 = 0;
    for (0..n) |i| ke += 0.5 * world.planets[i].gm() * m4.dot(s.vel[i], s.vel[i]);
    for (0..240 * 600) |_| s.step(1.0 / 240.0);
    try std.testing.expect(@abs(s.energy() - e0) < 1e-6 * ke);
    var p: V4 = @splat(0);
    for (0..n) |i| p += m4.scale(s.vel[i], world.planets[i].gm());
    try std.testing.expect(m4.len(p) / world.planets[0].gm() < 1e-9);
}
