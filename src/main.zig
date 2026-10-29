const std = @import("std");
const sdl = @import("sdl.zig");
const m4 = @import("math4.zig");
const world = @import("world.zig");
const system = @import("system.zig");
const physics = @import("physics.zig");
const render = @import("render.zig");
const hud = @import("hud.zig");
const settings_mod = @import("settings.zig");
const menu_mod = @import("menu.zig");
const Observer = @import("observer.zig").Observer;
const V4 = m4.V4;
const Settings = settings_mod.Settings;
const Action = settings_mod.Action;

const kernel_path = "kernels.hsaco";

// ---------------------------------------------------------------------------
// Game state
// ---------------------------------------------------------------------------

const Game = struct {
    ship: physics.Ship,
    sys: system.System,
    s: Settings,
    obs: Observer = Observer.initOrbit(4.2),
    room_mode: bool = false,
    menu: menu_mod.Menu = .{},
    spawn_planet: usize = 1,
    spawn_alt: f64 = 250,

    fn respawn(g: *Game) void {
        g.ship = spawn(&g.sys, g.spawn_planet, g.spawn_alt);
        g.ship.crash_speed = g.s.crash_speed;
    }

    /// Swap in a new solar system, carrying the ship along with whichever
    /// body it is nearest to (same relative position and velocity).
    fn replaceSystem(g: *Game, new: system.System) void {
        const i = g.sys.nearest(g.ship.pos).index;
        g.ship.pos = g.ship.pos - g.sys.pos[i] + new.pos[i];
        g.ship.vel = g.ship.vel - g.sys.vel[i] + new.vel[i];
        g.sys = new;
    }

    /// The ship's frame with axes permuted by the view-axes preset:
    /// [screen right, screen up, view direction, retina depth].
    fn viewAxes(g: *const Game) [4]V4 {
        const map = settings_mod.axis_presets[g.s.axes].map;
        return .{ g.ship.frame.axes[map[0]], g.ship.frame.axes[map[1]], g.ship.frame.axes[map[2]], g.ship.frame.axes[map[3]] };
    }

    /// Advance the world by one physics step.
    fn tick(g: *Game, in: physics.Input) void {
        g.sys.step(physics.dt);
        if (g.ship.crashed) {
            // Wreck stays put on the body it hit.
            g.ship.pos += m4.scale(g.sys.vel[g.ship.ref], physics.dt);
            g.ship.vel = g.sys.vel[g.ship.ref];
        } else {
            physics.step(&g.ship, &g.sys, in);
        }
    }
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

fn toF32x4(v: V4) [4]f32 {
    return .{ @floatCast(v[0]), @floatCast(v[1]), @floatCast(v[2]), @floatCast(v[3]) };
}

/// Retina coordinates (u, v, s) of a world direction, or null if behind.
fn retinaCoords(axes: [4]V4, d: V4, tan_half: f32) ?[3]f32 {
    const f = m4.dot(d, axes[2]);
    if (f <= 0) return null;
    const k = 1.0 / (f * tan_half);
    return .{ @floatCast(m4.dot(d, axes[0]) * k), @floatCast(m4.dot(d, axes[1]) * k), @floatCast(m4.dot(d, axes[3]) * k) };
}

fn buildParams(g: *const Game, width: u32, height: u32) world.Params {
    const s = &g.s;
    const axes = g.viewAxes();
    const b = g.obs.basis();
    var p = world.Params{
        .right = toF32x4(axes[0]),
        .up = toF32x4(axes[1]),
        .fwd = toF32x4(axes[2]),
        .ana = toF32x4(axes[3]),
        .tan_half_fov = s.tanHalfFov(),
        .n = s.n,
        .slab = s.slab,
        .shadows = @intFromBool(s.shadows),
        .sun_rgb = .{ 1.0, 0.94, 0.85 },
        .sun_index = world.sun_index,
        .num_bodies = world.planets.len,
        .width = @intCast(width),
        .height = @intCast(height),
        .obs_pos = g.obs.pos,
        .obs_fwd = b.fwd,
        .obs_right = b.right,
        .obs_up = b.up,
        .obs_fov = obs_fov,
        .room = @intFromBool(s.room),
        .base_alpha = s.base_alpha,
        .edge_gain = s.edge_gain,
        .marker = .{ 0, 0, 0, 0 },
        .bodies = undefined,
    };
    for (world.planets, 0..) |pl, i| {
        p.bodies[i] = pl.gpu;
        p.bodies[i].c = toF32x4(g.sys.pos[i] - g.ship.pos);
    }
    if (retinaCoords(axes, g.sys.pos[s.target] - g.ship.pos, s.tanHalfFov())) |m| {
        if (@abs(m[0]) <= 1 and @abs(m[1]) <= 1 and @abs(m[2]) <= s.slab) p.marker = .{ m[0], m[1], m[2], 1 };
    }
    return p;
}

const obs_fov: f32 = 0.6;

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

fn drawHud(c: hud.Canvas, g: *const Game, fps: f64) void {
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
    const view_name = if (s.view == .retina) "RETINA" else "SLICE";
    const axes_name = settings_mod.axis_presets[s.axes].name;
    c.text(8, y, 2, if (ship.assist) good else amber, std.fmt.bufPrint(&buf, "ASSIST {s}  {s} N{d}  {s}  {s} X{d}  {d:.0} FPS   ` MENU", .{
        if (ship.assist) "ON " else "OFF", view_name, s.n, axes_name[0..std.mem.indexOfScalar(u8, axes_name, ' ').?], motion, settings_mod.warps[s.warp], fps,
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
}

// ---------------------------------------------------------------------------
// Output helpers (libc stdio: stable across Zig std churn)
// ---------------------------------------------------------------------------

const FILE = opaque {};
extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern fn fwrite(ptr: *const anyopaque, size: usize, n: usize, f: *FILE) usize;
extern fn fclose(f: *FILE) c_int;

fn writePpm(path: [*:0]const u8, rgba: []const u8, width: u32, height: u32) !void {
    const f = fopen(path, "wb") orelse return error.OpenFailed;
    defer _ = fclose(f);
    var hdr: [64]u8 = undefined;
    const h = try std.fmt.bufPrint(&hdr, "P6\n{d} {d}\n255\n", .{ width, height });
    _ = fwrite(h.ptr, 1, h.len, f);
    var row: [4096 * 3]u8 = undefined;
    for (0..height) |y| {
        for (0..width) |x| {
            const i = (y * width + x) * 4;
            row[x * 3 ..][0..3].* = rgba[i..][0..3].*;
        }
        _ = fwrite(&row, 1, width * 3, f);
    }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

const Options = struct {
    shot: ?[:0]const u8 = null,
    gpucheck: bool = false,
    sim_secs: f64 = 0,
    turns: [8][3]f64 = undefined,
    n_turns: usize = 0,
    menu: bool = false,
    width: u32 = 1280,
    height: u32 = 720,
};

pub fn main(init: std.process.Init.Minimal) !void {
    var opt = Options{};
    var g = Game{ .ship = undefined, .sys = undefined, .s = .{} };
    var it = init.args.iterate();
    _ = it.next();
    const arg = struct {
        fn f(i: anytype) ![:0]const u8 {
            return i.next() orelse error.MissingArg;
        }
        fn num(comptime T: type, i: anytype) !T {
            const a = try f(i);
            return if (@typeInfo(T) == .float) std.fmt.parseFloat(T, a) else std.fmt.parseInt(T, a, 10);
        }
    };
    var eye: ?[5]f32 = null;
    const interactive_run = blk: {
        // Settings from the config file apply to interactive runs only, so
        // headless screenshots are reproducible.
        var probe = init.args.iterate();
        _ = probe.next();
        while (probe.next()) |a| if (std.mem.eql(u8, a, "--shot") or std.mem.eql(u8, a, "--gpucheck")) break :blk false;
        break :blk true;
    };
    if (interactive_run) settings_mod.load(&g.s);
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--shot")) {
            opt.shot = try arg.f(&it);
        } else if (std.mem.eql(u8, a, "--gpucheck")) {
            opt.gpucheck = true;
        } else if (std.mem.eql(u8, a, "--slice")) {
            g.s.view = .slice;
        } else if (std.mem.eql(u8, a, "--n")) {
            g.s.n = try arg.num(i32, &it);
        } else if (std.mem.eql(u8, a, "--slab")) {
            g.s.slab = try arg.num(f32, &it);
        } else if (std.mem.eql(u8, a, "--opacity")) {
            g.s.base_alpha = try arg.num(f32, &it);
        } else if (std.mem.eql(u8, a, "--axes")) {
            g.s.axes = try arg.num(u8, &it);
        } else if (std.mem.eql(u8, a, "--motion")) {
            g.s.motion = std.meta.stringToEnum(system.Motion, try arg.f(&it)) orelse return error.BadArgs;
        } else if (std.mem.eql(u8, a, "--obs")) {
            const yaw = try arg.num(f32, &it);
            const pitch = try arg.num(f32, &it);
            const dist = try arg.num(f32, &it);
            g.obs = .{ .yaw = yaw, .pitch = pitch };
            g.obs = Observer{ .yaw = yaw, .pitch = pitch, .pos = -g.obs.basis().fwd * @as(@Vector(3, f32), @splat(dist)) };
        } else if (std.mem.eql(u8, a, "--eye")) {
            var e: [5]f32 = undefined;
            for (&e) |*v| v.* = try arg.num(f32, &it);
            eye = e;
        } else if (std.mem.eql(u8, a, "--no-room")) {
            g.s.room = false;
        } else if (std.mem.eql(u8, a, "--menu")) {
            opt.menu = true;
        } else if (std.mem.eql(u8, a, "--spawn")) {
            g.spawn_planet = try arg.num(usize, &it);
            g.spawn_alt = try arg.num(f64, &it);
        } else if (std.mem.eql(u8, a, "--sim")) {
            opt.sim_secs = try arg.num(f64, &it);
        } else if (std.mem.eql(u8, a, "--turn")) {
            // --turn A B ANGLE : rotate local axis B toward A (0=R 1=U 2=F 3=A)
            if (opt.n_turns == opt.turns.len) return error.TooManyTurns;
            for (0..3) |k| opt.turns[opt.n_turns][k] = try arg.num(f64, &it);
            opt.n_turns += 1;
        } else if (std.mem.eql(u8, a, "--target")) {
            g.s.target = try arg.num(usize, &it);
        } else if (std.mem.eql(u8, a, "--no-shadows")) {
            g.s.shadows = false;
        } else {
            std.debug.print("unknown argument: {s}\n", .{a});
            return error.BadArgs;
        }
    }
    if (eye) |e| g.obs = .{ .pos = .{ e[0], e[1], e[2] }, .yaw = e[3], .pitch = e[4] };
    if (g.spawn_planet >= world.planets.len or g.spawn_planet == world.sun_index) return error.BadSpawn;
    g.s.n = std.math.clamp(g.s.n, 16, render.max_retina);
    g.s.axes %= settings_mod.axis_presets.len;
    g.s.warp = @min(g.s.warp, settings_mod.warps.len - 1);

    g.sys = system.System.init(g.s.motion);
    g.respawn();
    for (opt.turns[0..opt.n_turns]) |t| g.ship.frame.rotate(@intFromFloat(t[0]), @intFromFloat(t[1]), t[2]);

    if (opt.gpucheck) return gpuCheck();
    if (opt.shot) |path| return screenshot(path, &g, opt);
    defer settings_mod.save(&g.s);
    return interactive(&g, opt);
}

fn screenshot(path: [:0]const u8, g: *Game, opt: Options) !void {
    const steps: usize = @intFromFloat(opt.sim_secs / physics.dt);
    for (0..steps) |_| g.tick(.{});

    var r = try render.Renderer.init(opt.width, opt.height, kernel_path);
    defer r.deinit();
    const pixels = try std.heap.page_allocator.alloc(u8, @as(usize, opt.width) * opt.height * 4);
    defer std.heap.page_allocator.free(pixels);

    const params = buildParams(g, opt.width, opt.height);
    try r.frame(&params, g.s.view, pixels); // warm-up
    const t0 = sdl.SDL_GetPerformanceCounter();
    try r.frame(&params, g.s.view, pixels);
    const t1 = sdl.SDL_GetPerformanceCounter();
    const ms = @as(f64, @floatFromInt(t1 - t0)) * 1000.0 / @as(f64, @floatFromInt(sdl.SDL_GetPerformanceFrequency()));
    const canvas = hud.Canvas{ .pixels = pixels, .width = opt.width, .height = opt.height };
    drawHud(canvas, g, 1000.0 / ms);
    if (opt.menu) g.menu.draw(canvas, &g.s);
    try writePpm(path, pixels, opt.width, opt.height);
    std.debug.print("wrote {s}: frame {d:.1} ms\n", .{ path, ms });
}

fn gpuCheck() !void {
    var r = try render.Renderer.init(64, 64, kernel_path);
    defer r.deinit();
    var params: world.Params = undefined;
    for (world.planets, 0..) |pl, i| params.bodies[i] = pl.gpu;

    const count = 4096;
    var dirs: [count][4]f32 = undefined;
    var gpu: [count]f32 = undefined;
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    for (&dirs) |*d| {
        d.* = toF32x4(m4.normalize(V4{ rnd.floatNorm(f64), rnd.floatNorm(f64), rnd.floatNorm(f64), rnd.floatNorm(f64) }));
    }
    var worst: f32 = 0;
    for (1..world.planets.len) |b| {
        try r.probeTerrain(&params, @intCast(b), world.max_octaves, &dirs, &gpu);
        for (dirs, gpu) |d, gh| {
            const ch = world.terrainHeight(&params.bodies[b], d, world.max_octaves);
            worst = @max(worst, @abs(ch - gh));
        }
    }
    std.debug.print("CPU vs GPU terrain: max abs difference {d:.6} m over {d} samples per body\n", .{ worst, count });
    if (worst > 0.01) return error.TerrainMismatch;
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
                g.obs.pos[1] = @import("observer.zig").room_floor + @import("observer.zig").eye_height;
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

fn interactive(g: *Game, opt: Options) !void {
    if (sdl.SDL_Init(sdl.SDL_INIT_VIDEO) != 0) {
        std.debug.print("SDL_Init failed: {s}\n", .{sdl.SDL_GetError()});
        return error.SdlInitFailed;
    }
    defer sdl.SDL_Quit();

    const w = opt.width;
    const h = opt.height;
    const window = sdl.SDL_CreateWindow("4D Space Explorer", sdl.SDL_WINDOWPOS_CENTERED, sdl.SDL_WINDOWPOS_CENTERED, @intCast(w), @intCast(h), sdl.SDL_WINDOW_SHOWN) orelse {
        std.debug.print("SDL_CreateWindow failed: {s}\n", .{sdl.SDL_GetError()});
        return error.SdlWindowFailed;
    };
    defer sdl.SDL_DestroyWindow(window);
    const renderer = sdl.SDL_CreateRenderer(window, -1, sdl.SDL_RENDERER_ACCELERATED) orelse {
        std.debug.print("SDL_CreateRenderer failed: {s}\n", .{sdl.SDL_GetError()});
        return error.SdlRendererFailed;
    };
    defer sdl.SDL_DestroyRenderer(renderer);
    const texture = sdl.SDL_CreateTexture(renderer, sdl.SDL_PIXELFORMAT_RGBA32, sdl.SDL_TEXTUREACCESS_STREAMING, @intCast(w), @intCast(h)) orelse {
        std.debug.print("SDL_CreateTexture failed: {s}\n", .{sdl.SDL_GetError()});
        return error.SdlTextureFailed;
    };
    defer sdl.SDL_DestroyTexture(texture);

    var gpu = try render.Renderer.init(w, h, kernel_path);
    defer gpu.deinit();
    const pixels = try std.heap.page_allocator.alloc(u8, @as(usize, w) * h * 4);
    defer std.heap.page_allocator.free(pixels);

    var mouse_captured = true;
    _ = sdl.SDL_SetRelativeMouseMode(1);
    var orbiting = false;
    var ev: sdl.SDL_Event = .{};
    const freq: f64 = @floatFromInt(sdl.SDL_GetPerformanceFrequency());
    var last = sdl.SDL_GetPerformanceCounter();
    var accum: f64 = 0;
    var fps: f64 = 0;

    main_loop: while (true) {
        while (sdl.SDL_PollEvent(&ev) != 0) {
            switch (ev.kind()) {
                sdl.SDL_QUIT => break :main_loop,
                sdl.SDL_KEYDOWN => {
                    const sc: u16 = @intCast(ev.keyScancode());
                    if (g.menu.open) {
                        // Menu navigation repeats when held; rebinding doesn't.
                        if (ev.keyRepeat() and g.menu.rebinding != null) continue;
                        switch (g.menu.key(&g.s, sc)) {
                            .none => {},
                            .close => {
                                settings_mod.save(&g.s);
                                mouse_captured = true;
                                _ = sdl.SDL_SetRelativeMouseMode(1);
                            },
                            .respawn => g.respawn(),
                            .reset_system => g.replaceSystem(system.System.init(g.s.motion)),
                            .motion_changed => g.replaceSystem(system.System.init(g.s.motion)),
                        }
                        g.ship.crash_speed = g.s.crash_speed;
                        continue;
                    }
                    if (ev.keyRepeat()) continue;
                    if (sc == menu_mod.grave) {
                        g.menu.open = true;
                        mouse_captured = false;
                        _ = sdl.SDL_SetRelativeMouseMode(0);
                        continue;
                    }
                    if (sc == sdl.Scancode.escape) {
                        if (!mouse_captured) break :main_loop;
                        mouse_captured = false;
                        _ = sdl.SDL_SetRelativeMouseMode(0);
                        continue;
                    }
                    if (g.s.actionFor(sc)) |a| pressAction(g, a);
                },
                sdl.SDL_MOUSEBUTTONDOWN => {
                    if (g.menu.open) continue;
                    if (!mouse_captured) {
                        mouse_captured = true;
                        _ = sdl.SDL_SetRelativeMouseMode(1);
                    } else if (ev.mouseButton() == sdl.SDL_BUTTON_RIGHT) orbiting = true;
                },
                sdl.SDL_MOUSEBUTTONUP => {
                    if (ev.mouseButton() == sdl.SDL_BUTTON_RIGHT) orbiting = false;
                },
                sdl.SDL_MOUSEWHEEL => {
                    const dy: f32 = @floatFromInt(ev.wheelY());
                    const s = &g.s;
                    s.slab = std.math.clamp(s.slab * std.math.pow(f32, 1.25, dy), 0.0, 1.0);
                    if (dy < 0 and s.slab < 0.02) s.slab = 0;
                    if (dy > 0 and s.slab < 0.02) s.slab = 0.02;
                },
                else => {},
            }
        }

        const now = sdl.SDL_GetPerformanceCounter();
        const frame_dt = @as(f64, @floatFromInt(now - last)) / freq;
        last = now;
        fps = if (fps == 0) 1 / frame_dt else fps * 0.92 + 0.08 / frame_dt;

        // --- input -----------------------------------------------------------
        const keys = sdl.SDL_GetKeyboardState(null);
        const s = &g.s;
        const held = struct {
            fn f(ks: [*]const u8, st: *const Settings, a: Action) f64 {
                return @floatFromInt(ks[st.key(a)]);
            }
        }.f;
        const axis = struct {
            fn f(ks: [*]const u8, st: *const Settings, pos: Action, neg: Action) f64 {
                return held(ks, st, pos) - held(ks, st, neg);
            }
        }.f;
        var in = physics.Input{};
        const controls_live = !g.menu.open;
        if (controls_live and g.room_mode) {
            const run: f32 = if (held(keys, s, .boost) > 0) 5.0 else 2.5;
            g.obs.walk(.{
                @floatCast(axis(keys, s, .right, .left) * run),
                @floatCast(axis(keys, s, .up, .down) * 1.5),
                @floatCast(axis(keys, s, .fwd, .back) * run),
            }, @floatCast(frame_dt));
        } else if (controls_live) {
            in.thrust = .{
                axis(keys, s, .right, .left),
                axis(keys, s, .up, .down),
                axis(keys, s, .fwd, .back),
                axis(keys, s, .ana, .kata),
            };
            in.boost = held(keys, s, .boost) > 0;
            // Plane order: (R,U) (R,F) (R,A) (U,F) (U,A) (F,A); positive turns
            // the second axis toward the first.
            in.rot = .{
                axis(keys, s, .roll_right, .roll_left),
                axis(keys, s, .yaw_right, .yaw_left),
                -axis(keys, s, .turn_right_ana, .turn_right_kata),
                axis(keys, s, .pitch_up, .pitch_down),
                -axis(keys, s, .turn_up_ana, .turn_up_kata),
                -axis(keys, s, .turn_fwd_ana, .turn_fwd_kata),
            };
        }

        var mdx: c_int = 0;
        var mdy: c_int = 0;
        _ = sdl.SDL_GetRelativeMouseState(&mdx, &mdy);
        if (mouse_captured and controls_live) {
            const fx: f32 = @as(f32, @floatFromInt(mdx)) * s.mouse_sens;
            const fy: f32 = @as(f32, @floatFromInt(mdy)) * s.mouse_sens * @as(f32, if (s.invert_y) -1 else 1);
            if (orbiting) {
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

        // --- simulate ----------------------------------------------------------
        const paused = g.menu.open and s.pause_in_menu;
        if (!paused) {
            const warp: f64 = @floatFromInt(settings_mod.warps[s.warp]);
            accum = @min(accum + frame_dt * warp, 0.1 * warp);
            while (accum >= physics.dt) : (accum -= physics.dt) g.tick(in);
        }

        // --- render ------------------------------------------------------------
        const params = buildParams(g, w, h);
        try gpu.frame(&params, s.view, pixels);
        const canvas = hud.Canvas{ .pixels = pixels, .width = w, .height = h };
        drawHud(canvas, g, fps);
        if (g.menu.open) g.menu.draw(canvas, s);
        _ = sdl.SDL_UpdateTexture(texture, null, pixels.ptr, @intCast(w * 4));
        _ = sdl.SDL_RenderClear(renderer);
        _ = sdl.SDL_RenderCopy(renderer, texture, null, null);
        sdl.SDL_RenderPresent(renderer);
    }
}
