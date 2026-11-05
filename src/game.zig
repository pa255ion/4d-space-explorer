const std = @import("std");
const m4 = @import("math4.zig");
const world = @import("world.zig");
const system = @import("system.zig");
const physics = @import("physics.zig");
const hud = @import("hud.zig");
const settings_mod = @import("settings.zig");
const menu_mod = @import("menu.zig");
const observer = @import("observer.zig");
const touch_mod = @import("touch.zig");
const pad_mod = @import("pad.zig");
const Observer = observer.Observer;
pub const V4 = m4.V4;
const Settings = settings_mod.Settings;
const Action = settings_mod.Action;

// ---------------------------------------------------------------------------
// Everything about the game that doesn't depend on the platform: state,
// key/mouse handling, the fixed-step simulation, the GPU parameter block and
// the HUD. main.zig (SDL + HIP) and web.zig (browser + WebGPU) are thin
// frontends around this.
// ---------------------------------------------------------------------------

pub const obs_fov: f32 = 0.6;

/// Analog input for one frame from touch controls or a gamepad, added to
/// the keyboard's. Values are -1..1 in the same sense as the actions
/// (thrust: right, up, fwd, ana; turns: positive toward ana / roll right).
pub const Analog = struct {
    thrust: [4]f64 = .{ 0, 0, 0, 0 },
    roll: f64 = 0,
    turn_right_ana: f64 = 0,
    turn_up_ana: f64 = 0,
    turn_fwd_ana: f64 = 0,
    boost: bool = false,
    /// Look movement this frame in mouse-pixel units (ship yaw/pitch, or
    /// the room view / cube orbit).
    look: [2]f32 = .{ 0, 0 },
    /// Direct 4D turn this frame, same units: [fwd->ana, up->ana].
    look4d: [2]f32 = .{ 0, 0 },
    orbit: bool = false,

    pub fn add(a: Analog, b: Analog) Analog {
        var r = a;
        for (&r.thrust, b.thrust) |*x, y| x.* += y;
        r.roll += b.roll;
        r.turn_right_ana += b.turn_right_ana;
        r.turn_up_ana += b.turn_up_ana;
        r.turn_fwd_ana += b.turn_fwd_ana;
        r.boost = a.boost or b.boost;
        r.look = .{ a.look[0] + b.look[0], a.look[1] + b.look[1] };
        r.look4d = .{ a.look4d[0] + b.look4d[0], a.look4d[1] + b.look4d[1] };
        r.orbit = a.orbit or b.orbit;
        return r;
    }
};

pub const Game = struct {
    ship: physics.Ship,
    sys: system.System,
    s: Settings,
    obs: Observer = Observer.initOrbit(4.2),
    room_mode: bool = false,
    menu: menu_mod.Menu = .{},
    spawn_planet: usize = 1,
    spawn_alt: f64 = 250,
    /// Frontend state the game needs to know about.
    captured: bool = true, // mouse captured (relative mode / pointer lock)
    orbiting: bool = false, // right button held
    accum: f64 = 0,
    fps: f64 = 0,
    /// Shown on the HUD when set (web: the current render scale).
    res_pct: ?u8 = null,
    /// Retina resolution actually rendered, if not `s.n` (web auto quality).
    n_eff: ?i32 = null,
    /// A message shown mid-screen for `notice_time` seconds.
    notice: []const u8 = "",
    notice_time: f64 = 0,
    /// Shown permanently under the HUD bar (web: software renderer warning).
    warning: []const u8 = "",
    /// On-screen touch controls (web; enabled by the first touch).
    touch: touch_mod.Touch = .{},
    /// Gamepad mapping state.
    pad: pad_mod.Pad = .{},
    /// VR: the eye currently being rendered replaces the observer camera.
    eye: ?Eye = null,

    pub fn init(s: Settings) Game {
        var g = Game{ .ship = undefined, .sys = system.System.init(s.motion), .s = s };
        g.respawn();
        return g;
    }

    pub fn respawn(g: *Game) void {
        g.ship = spawn(&g.sys, g.spawn_planet, g.spawn_alt);
        g.ship.crash_speed = g.s.crash_speed;
    }

    /// Swap in a new solar system, carrying the ship along with whichever
    /// body it is nearest to (same relative position and velocity).
    pub fn replaceSystem(g: *Game, new: system.System) void {
        const i = g.sys.nearest(g.ship.pos).index;
        g.ship.pos = g.ship.pos - g.sys.pos[i] + new.pos[i];
        g.ship.vel = g.ship.vel - g.sys.vel[i] + new.vel[i];
        g.sys = new;
    }

    /// The ship's frame with axes permuted by the view-axes preset:
    /// [screen right, screen up, view direction, retina depth].
    pub fn viewAxes(g: *const Game) [4]V4 {
        const map = settings_mod.axis_presets[g.s.axes].map;
        return .{ g.ship.frame.axes[map[0]], g.ship.frame.axes[map[1]], g.ship.frame.axes[map[2]], g.ship.frame.axes[map[3]] };
    }

    /// Advance the world by one physics step.
    pub fn tick(g: *Game, in: physics.Input) void {
        g.sys.step(physics.dt);
        if (g.ship.crashed) {
            // Wreck stays put on the body it hit.
            g.ship.pos += m4.scale(g.sys.vel[g.ship.ref], physics.dt);
            g.ship.vel = g.sys.vel[g.ship.ref];
        } else {
            physics.step(&g.ship, &g.sys, in);
        }
    }

    /// Mouse-style look: `dx`, `dy` in mouse pixels (y down).
    fn look(g: *Game, dx: f32, dy: f32, orbit: bool) void {
        if (dx == 0 and dy == 0) return;
        const s = &g.s;
        const fx = dx * s.mouse_sens;
        const fy = dy * s.mouse_sens * @as(f32, if (s.invert_y) -1 else 1);
        if (orbit) {
            g.obs.orbit(-fx * 0.005, fy * 0.005);
        } else if (g.room_mode) {
            g.obs.look(fx * 0.0025, -fy * 0.0025);
        } else if (!g.ship.crashed) {
            // Mouse look acts like reaction wheels: direct attitude change.
            g.ship.frame.rotate(m4.right, m4.fwd, @as(f64, fx) * 0.0022);
            g.ship.frame.rotate(m4.up, m4.fwd, -@as(f64, fy) * 0.0022);
            g.ship.frame.orthonormalize();
        }
    }

    pub const KeyResult = enum { none, menu_opened, menu_closed, escape };

    /// A key went down (`sc` is an SDL scancode). The result tells the
    /// frontend about menu transitions (mouse capture, saving settings).
    pub fn keyDown(g: *Game, sc: u16, repeat: bool) KeyResult {
        if (g.menu.open) {
            // Menu navigation repeats when held; rebinding doesn't.
            if (repeat and g.menu.rebinding != null) return .none;
            const cmd = g.menu.key(&g.s, sc);
            switch (cmd) {
                .none, .close => {},
                .respawn => g.respawn(),
                .reset_system, .motion_changed => g.replaceSystem(system.System.init(g.s.motion)),
            }
            g.ship.crash_speed = g.s.crash_speed;
            return if (cmd == .close) .menu_closed else .none;
        }
        if (repeat) return .none;
        if (sc == menu_mod.grave) {
            g.menu.open = true;
            return .menu_opened;
        }
        if (sc == scancode_escape) return .escape;
        if (g.s.actionFor(sc)) |a| g.pressAction(a);
        return .none;
    }

    /// Toggle-style actions on key press (continuous ones are polled each frame).
    fn pressAction(g: *Game, a: Action) void {
        const s = &g.s;
        switch (a) {
            .assist => g.ship.assist = !g.ship.assist,
            .view => s.view = if (s.view == .retina) .slice else .retina,
            .view_axes => s.axes = @intCast((s.axes + 1) % settings_mod.axis_presets.len),
            .room_mode => {
                g.room_mode = !g.room_mode;
                if (g.room_mode) {
                    s.view = .retina;
                    // Step down to eye height where you stand.
                    g.obs.pos[1] = observer.room_floor + observer.eye_height;
                    g.obs.confine();
                }
            },
            .target => s.target = (s.target + 1) % world.planets.len,
            .shadows => s.shadows = !s.shadows,
            .respawn => g.respawn(),
            .retina_down => s.stepRetina(-1),
            .retina_up => s.stepRetina(1),
            .opacity_down => s.base_alpha = @max(s.base_alpha - 0.02, 0.0),
            .opacity_up => s.base_alpha = @min(s.base_alpha + 0.02, 1.0),
            else => {},
        }
    }

    /// Mouse wheel: slab thickness. `dy` > 0 is away from the user.
    pub fn wheel(g: *Game, dy: f32) void {
        const s = &g.s;
        s.slab = std.math.clamp(s.slab * std.math.pow(f32, 1.25, dy), 0.0, 1.0);
        if (dy < 0 and s.slab < 0.02) s.slab = 0;
        if (dy > 0 and s.slab < 0.02) s.slab = 0.02;
    }

    /// One displayed frame: poll held keys (`keys[scancode]` != 0) and the
    /// mouse motion since the last frame, then run as many fixed physics
    /// steps as `frame_dt` (times the warp) covers.
    pub fn update(g: *Game, keys: []const u8, mouse_dx: f32, mouse_dy: f32, an: Analog, frame_dt: f64) void {
        g.notice_time -= frame_dt;
        if (frame_dt > 0) g.fps = if (g.fps == 0) 1 / frame_dt else g.fps * 0.92 + 0.08 / frame_dt;
        const s = &g.s;
        const held = struct {
            fn f(ks: []const u8, st: *const Settings, a: Action) f64 {
                const k = st.key(a);
                return if (k < ks.len and ks[k] != 0) 1 else 0;
            }
        }.f;
        const axis = struct {
            fn f(ks: []const u8, st: *const Settings, pos: Action, neg: Action) f64 {
                return held(ks, st, pos) - held(ks, st, neg);
            }
        }.f;
        const c1 = struct {
            fn f(x: f64) f64 {
                return std.math.clamp(x, -1, 1);
            }
        }.f;
        var in = physics.Input{};
        const controls_live = !g.menu.open;
        const thrust = [4]f64{
            c1(axis(keys, s, .right, .left) + an.thrust[0]),
            c1(axis(keys, s, .up, .down) + an.thrust[1]),
            c1(axis(keys, s, .fwd, .back) + an.thrust[2]),
            c1(axis(keys, s, .ana, .kata) + an.thrust[3]),
        };
        const boost = held(keys, s, .boost) > 0 or an.boost;
        if (controls_live and g.room_mode) {
            const run: f64 = if (boost) 5.0 else 2.5;
            g.obs.walk(.{
                @floatCast(thrust[0] * run),
                @floatCast(thrust[1] * 1.5),
                @floatCast(thrust[2] * run),
            }, @floatCast(frame_dt));
        } else if (controls_live) {
            in.thrust = thrust;
            in.boost = boost;
            // Plane order: (R,U) (R,F) (R,A) (U,F) (U,A) (F,A); positive turns
            // the second axis toward the first.
            in.rot = .{
                c1(axis(keys, s, .roll_right, .roll_left) + an.roll),
                axis(keys, s, .yaw_right, .yaw_left),
                -c1(axis(keys, s, .turn_right_ana, .turn_right_kata) + an.turn_right_ana),
                axis(keys, s, .pitch_up, .pitch_down),
                -c1(axis(keys, s, .turn_up_ana, .turn_up_kata) + an.turn_up_ana),
                -c1(axis(keys, s, .turn_fwd_ana, .turn_fwd_kata) + an.turn_fwd_ana),
            };
        }

        if (controls_live) {
            const mx: f32 = if (g.captured) mouse_dx else 0;
            const my: f32 = if (g.captured) mouse_dy else 0;
            g.look(mx + an.look[0], my + an.look[1], g.orbiting or an.orbit);
            if (!g.room_mode and !g.ship.crashed and (an.look4d[0] != 0 or an.look4d[1] != 0)) {
                // Direct 4D turns (touch drags in 4D mode): forward toward
                // ana, and up toward ana.
                g.ship.frame.rotate(m4.ana, m4.fwd, @as(f64, an.look4d[0] * s.mouse_sens) * 0.0022);
                g.ship.frame.rotate(m4.ana, m4.up, -@as(f64, an.look4d[1] * s.mouse_sens) * 0.0022);
                g.ship.frame.orthonormalize();
            }
        }

        const paused = g.menu.open and s.pause_in_menu;
        if (!paused) {
            const warp: f64 = @floatFromInt(settings_mod.warps[s.warp]);
            g.accum = @min(g.accum + frame_dt * warp, 0.1 * warp);
            while (g.accum >= physics.dt) : (g.accum -= physics.dt) g.tick(in);
        }
    }
};

pub const scancode_escape = 41;

/// A camera given as rays (VR eyes, possibly asymmetric frusta): the ray
/// through screen point (sx, sy) is fwd + right*sx + up*sy, with sx in
/// [-aspect, aspect] and sy in [-1, 1], as the composite kernel computes it.
pub const Eye = struct {
    pos: [3]f32,
    fwd: [3]f32,
    right: [3]f32,
    up: [3]f32,
};

fn spawn(sys: *const system.System, planet: usize, alt: f64) physics.Ship {
    const pl = &world.planets[planet];
    const c = sys.pos[planet];
    // Day side, a little off the sub-solar point so the light is oblique.
    const to_sun = m4.normalize(sys.pos[world.sun_index] - c);
    const up = m4.normalize(to_sun + V4{ 0.1, 0.6, 0.25, 0.2 });
    const base = c + m4.scale(up, pl.gpu.radius);
    const ground = world.surfaceGap(pl, c, base);
    var frame = m4.Frame.lookUp(up, V4{ 0, 0, 1, 0 });
    frame.rotate(m4.up, m4.fwd, -0.3); // pitch down toward the horizon
    return .{ .pos = base + m4.scale(up, alt - ground), .vel = sys.vel[planet], .frame = frame, .ref = planet };
}

// ---------------------------------------------------------------------------
// Per-frame GPU parameters
// ---------------------------------------------------------------------------

pub fn toF32x4(v: V4) [4]f32 {
    return .{ @floatCast(v[0]), @floatCast(v[1]), @floatCast(v[2]), @floatCast(v[3]) };
}

/// Retina coordinates (u, v, s) of a world direction, or null if behind.
fn retinaCoords(axes: [4]V4, d: V4, tan_half: f32) ?[3]f32 {
    const f = m4.dot(d, axes[2]);
    if (f <= 0) return null;
    const k = 1.0 / (f * tan_half);
    return .{ @floatCast(m4.dot(d, axes[0]) * k), @floatCast(m4.dot(d, axes[1]) * k), @floatCast(m4.dot(d, axes[3]) * k) };
}

/// The GPU parameter block for a `width` x `height` render.
pub fn buildParams(g: *const Game, width: u32, height: u32) world.Params {
    const s = &g.s;
    const axes = g.viewAxes();
    const b = g.obs.basis();
    const eye: Eye = g.eye orelse .{ .pos = g.obs.pos, .fwd = b.fwd, .right = b.right, .up = b.up };
    var p = world.Params{
        .right = toF32x4(axes[0]),
        .up = toF32x4(axes[1]),
        .fwd = toF32x4(axes[2]),
        .ana = toF32x4(axes[3]),
        .tan_half_fov = s.tanHalfFov(),
        .n = g.n_eff orelse s.n,
        .slab = s.slab,
        .shadows = @intFromBool(s.shadows and !s.low_quality),
        .sun_rgb = .{ 1.0, 0.94, 0.85 },
        .sun_index = world.sun_index,
        .num_bodies = world.planets.len,
        .width = @intCast(width),
        .height = @intCast(height),
        .obs_pos = eye.pos,
        .obs_fwd = eye.fwd,
        .obs_right = eye.right,
        .obs_up = eye.up,
        .obs_fov = if (g.eye != null) 1 else obs_fov,
        .room = @intFromBool(s.room),
        .base_alpha = s.base_alpha,
        .edge_gain = s.edge_gain,
        .marker = .{ 0, 0, 0, 0 },
        .low = @intFromBool(s.low_quality),
        .bodies = undefined,
    };
    for (world.planets, 0..) |pl, i| {
        p.bodies[i] = pl.gpu;
        p.bodies[i].c = toF32x4(g.sys.pos[i] - g.ship.pos);
    }
    for (world.planets.len..world.max_bodies) |i| p.bodies[i] = .{ .radius = 0 };
    if (retinaCoords(axes, g.sys.pos[s.target] - g.ship.pos, s.tanHalfFov())) |m| {
        if (@abs(m[0]) <= 1 and @abs(m[1]) <= 1 and @abs(m[2]) <= s.slab) p.marker = .{ m[0], m[1], m[2], 1 };
    }
    return p;
}

// ---------------------------------------------------------------------------
// HUD
// ---------------------------------------------------------------------------

fn sign(x: f64) u8 {
    return if (x < 0) '-' else '+';
}

const white = [3]u8{ 230, 235, 240 };
const dim = [3]u8{ 150, 165, 180 };
const warn = [3]u8{ 255, 90, 70 };
const good = [3]u8{ 120, 230, 140 };
const amber = [3]u8{ 255, 210, 80 };
const cyan = [3]u8{ 110, 200, 255 };

fn axisName(axis: u2, positive: bool) []const u8 {
    return switch (axis) {
        m4.right => if (positive) "RIGHT" else "LEFT",
        m4.up => if (positive) "UP" else "DOWN",
        m4.fwd => if (positive) "FWD" else "BACK",
        m4.ana => if (positive) "ANA" else "KATA",
    };
}

/// Draw the HUD (and the menu, if open) into `c`.
pub fn drawHud(c: hud.Canvas, g: *Game) void {
    var buf: [160]u8 = undefined;
    const s = &g.s;
    const ship = &g.ship;
    const ref = ship.ref;
    const rpl = &world.planets[ref];
    const rel_vel = ship.vel - g.sys.vel[ref];
    const up = m4.normalize(ship.pos - g.sys.pos[ref]);
    const grav = g.sys.gravityAt(ship.pos) - g.sys.acc[ref];
    const vl = ship.frame.toLocal(rel_vel);
    const alt = world.surfaceGap(rpl, g.sys.pos[ref], ship.pos) - physics.ship_radius;

    // Cube face labels: which ship direction each face of the retina is.
    if (s.view == .retina and s.labels) {
        const map = settings_mod.axis_presets[s.axes].map;
        const W: f32 = @floatFromInt(c.width);
        const H: f32 = @floatFromInt(c.height);
        const faces = [_]struct { p: [3]f32, axis: u2, pos: bool }{
            .{ .p = .{ 1.18, 0, 0 }, .axis = map[0], .pos = true },
            .{ .p = .{ -1.18, 0, 0 }, .axis = map[0], .pos = false },
            .{ .p = .{ 0, 1.15, 0 }, .axis = map[1], .pos = true },
            .{ .p = .{ 0, -1.15, 0 }, .axis = map[1], .pos = false },
            .{ .p = .{ 0, 0, s.slab + 0.15 }, .axis = map[3], .pos = true },
            .{ .p = .{ 0, 0, -s.slab - 0.15 }, .axis = map[3], .pos = false },
        };
        for (faces) |f| {
            const sp = g.obs.project(f.p, obs_fov, W, H) orelse continue;
            const name = axisName(f.axis, f.pos);
            const tw: f32 = @floatFromInt(hud.textWidth(name, 2));
            if (sp[0] < -100 or sp[0] > W + 100 or sp[1] < -100 or sp[1] > H + 100) continue;
            c.text(@intFromFloat(sp[0] - tw / 2), @intFromFloat(sp[1] - 7), 2, cyan, name);
        }
        // The view direction pierces the cube's center.
        if (g.obs.project(.{ 0, 0, 0 }, obs_fov, W, H)) |sp| {
            const name = axisName(map[2], true);
            const tw: f32 = @floatFromInt(hud.textWidth(name, 1));
            c.text(@intFromFloat(sp[0] - tw / 2), @intFromFloat(sp[1] - 3), 1, .{ 200, 220, 240 }, name);
        }
    }

    c.shade(0, 0, c.width, 74);
    var y: isize = 6;
    c.text(8, y, 2, white, std.fmt.bufPrint(&buf, "SPD {d:.1} M/S   ALT {d:.0} M   VS {d:.1}   G {d:.2}   REF {s}", .{
        m4.len(rel_vel), alt, m4.dot(rel_vel, up), m4.len(grav), rpl.name,
    }) catch "");
    y += 22;
    c.text(8, y, 2, dim, std.fmt.bufPrint(&buf, "VEL  R{c}{d:.1}  U{c}{d:.1}  F{c}{d:.1}  A{c}{d:.1}", .{
        sign(vl[0]), @abs(vl[0]), sign(vl[1]), @abs(vl[1]), sign(vl[2]), @abs(vl[2]), sign(vl[3]), @abs(vl[3]),
    }) catch "");

    // Target: distance and direction in ship-local (right, up, fwd, ana) terms.
    const tpl = &world.planets[s.target];
    const td = g.sys.pos[s.target] - ship.pos;
    const tl = ship.frame.toLocal(m4.normalize(td));
    const tline = std.fmt.bufPrint(&buf, "TGT {s} {d:.0} M  R{c}{d:.2} U{c}{d:.2} F{c}{d:.2} A{c}{d:.2}", .{
        tpl.name,    world.surfaceGap(tpl, g.sys.pos[s.target], ship.pos), sign(tl[0]), @abs(tl[0]), sign(tl[1]), @abs(tl[1]),
        sign(tl[2]), @abs(tl[2]),                                           sign(tl[3]), @abs(tl[3]),
    }) catch "";
    c.text(@as(isize, @intCast(c.width)) - @as(isize, @intCast(hud.textWidth(tline, 2))) - 8, y, 2, amber, tline);
    y += 22;

    const motion = switch (g.sys.motion) {
        .static => "STATIC",
        .rails => "RAILS",
        .nbody => "N-BODY",
    };
    const view_name = if (s.view == .retina)
        (if (s.low_quality) "RETINA LOW" else "RETINA")
    else
        (if (s.low_quality) "SLICE LOW" else "SLICE");
    const axes_name = settings_mod.axis_presets[s.axes].name;
    var rbuf: [16]u8 = undefined;
    const res = if (g.res_pct) |pct| std.fmt.bufPrint(&rbuf, "  RES {d}%", .{pct}) catch "" else "";
    c.text(8, y, 2, if (ship.assist) good else amber, std.fmt.bufPrint(&buf, "ASSIST {s}  {s} N{d}  {s}  {s} X{d}  {d:.0} FPS{s}   ` MENU", .{
        if (ship.assist) "ON " else "OFF", view_name, g.n_eff orelse s.n, axes_name[0..std.mem.indexOfScalar(u8, axes_name, ' ').?], motion, settings_mod.warps[s.warp], g.fps, res,
    }) catch "");

    const bottom: isize = @as(isize, @intCast(c.height)) - 24;
    if (ship.crashed) {
        var kb: [16]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "CRASHED AT {d:.1} M/S - {s} TO RESPAWN", .{ ship.last_impact, settings_mod.keyName(@intCast(s.key(.respawn)), &kb) }) catch "";
        const w = hud.textWidth(msg, 3);
        c.text(@intCast((c.width -| w) / 2), @intCast(c.height / 2 - 10), 3, warn, msg);
    } else if (ship.landed) {
        c.text(8, bottom, 2, good, "LANDED");
    }
    if (g.room_mode) {
        var kb: [16]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "ROOM MODE - WALK WITH MOVE KEYS, {s} TO RETURN TO THE HELM", .{settings_mod.keyName(@intCast(s.key(.room_mode)), &kb)}) catch "";
        c.text(@intCast((c.width -| hud.textWidth(msg, 2)) / 2), bottom, 2, cyan, msg);
    }
    if (g.warning.len > 0) c.text(8, 80, 2, warn, g.warning);
    if (g.notice_time > 0 and !g.menu.open) {
        c.text(@intCast((c.width -| hud.textWidth(g.notice, 2)) / 2), 110, 2, amber, g.notice);
    }
    if (!g.captured and !g.menu.open and !g.touch.enabled) {
        const msg = "CLICK TO CAPTURE THE MOUSE";
        c.text(@intCast((c.width -| hud.textWidth(msg, 2)) / 2), bottom - 26, 2, amber, msg);
    }

    // Slice view: draw the target marker on the screen ourselves (the GPU
    // composite does it for the retina view).
    if (s.view == .slice) {
        if (retinaCoords(g.viewAxes(), td, s.tanHalfFov())) |m| {
            const W: f64 = @floatFromInt(c.width);
            const H: f64 = @floatFromInt(c.height);
            const sx = (m[0] * H / W + 1) * 0.5 * W;
            const sy = (1 - m[1]) * 0.5 * H;
            if (sx > -100 and sx < W + 100 and sy > -100 and sy < H + 100) c.ring(@intFromFloat(sx), @intFromFloat(sy), 9, amber);
        }
    }
    if (g.pad.connected and g.pad.mode4d and !g.menu.open) {
        const msg = "PAD 4D MODE: RIGHT STICK TURNS INTO ANA (L3 TO EXIT)";
        c.text(@intCast((c.width -| hud.textWidth(msg, 2)) / 2), bottom - 52, 2, cyan, msg);
    }
    if (g.menu.open) g.menu.draw(c, s);
    g.touch.draw(c, g);
}
