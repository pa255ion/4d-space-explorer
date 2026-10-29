const std = @import("std");
const sdl = @import("sdl.zig");
const m4 = @import("math4.zig");
const world = @import("world.zig");
const physics = @import("physics.zig");
const render = @import("render.zig");
const hud = @import("hud.zig");
const V4 = m4.V4;
const SC = sdl.Scancode;

const kernel_path = "kernels.hsaco";

const Settings = struct {
    view: render.View = .retina,
    n: i32 = 96,
    slab: f32 = 1.0,
    base_alpha: f32 = 0.10,
    edge_gain: f32 = 0.9,
    obs_yaw: f32 = 0.55,
    obs_pitch: f32 = 0.3,
    obs_dist: f32 = 3.6,
    tan_half_fov: f32 = 0.75,
    shadows: bool = true,
    target: usize = 2,
    help: bool = false,
};

const retina_sizes = [_]i32{ 48, 64, 80, 96, 128, 160 };

// ---------------------------------------------------------------------------
// Spawning
// ---------------------------------------------------------------------------

fn spawn(planet: usize, alt: f64) physics.Ship {
    const pl = &world.planets[planet];
    const sun = world.planets[world.sun_index].pos;
    // Day side, a little off the sub-solar point so the light is oblique.
    const to_sun = m4.normalize(sun - pl.pos);
    const up = m4.normalize(to_sun + V4{ 0.1, 0.6, 0.25, 0.2 });
    const base = pl.pos + m4.scale(up, pl.gpu.radius);
    const ground = world.surfaceGap(pl, base);
    var frame = m4.Frame.lookUp(up, V4{ 0, 0, 1, 0 });
    frame.rotate(m4.up, m4.fwd, -0.3); // pitch down toward the horizon
    return .{ .pos = base + m4.scale(up, alt - ground), .frame = frame };
}

// ---------------------------------------------------------------------------
// Per-frame GPU parameters
// ---------------------------------------------------------------------------

const Marker = struct { u: f32, v: f32, s: f32, ahead: bool };

fn targetRetinaCoords(ship: *const physics.Ship, s: *const Settings) Marker {
    const l = ship.frame.toLocal(world.planets[s.target].pos - ship.pos);
    const f: f32 = @floatCast(l[m4.fwd]);
    if (f <= 0) return .{ .u = 0, .v = 0, .s = 0, .ahead = false };
    const k = 1.0 / (f * s.tan_half_fov);
    return .{
        .u = @as(f32, @floatCast(l[m4.right])) * k,
        .v = @as(f32, @floatCast(l[m4.up])) * k,
        .s = @as(f32, @floatCast(l[m4.ana])) * k,
        .ahead = true,
    };
}

fn toF32x4(v: V4) [4]f32 {
    return .{ @floatCast(v[0]), @floatCast(v[1]), @floatCast(v[2]), @floatCast(v[3]) };
}

fn buildParams(ship: *const physics.Ship, s: *const Settings, width: u32, height: u32) world.Params {
    var p = world.Params{
        .right = toF32x4(ship.frame.axes[m4.right]),
        .up = toF32x4(ship.frame.axes[m4.up]),
        .fwd = toF32x4(ship.frame.axes[m4.fwd]),
        .ana = toF32x4(ship.frame.axes[m4.ana]),
        .tan_half_fov = s.tan_half_fov,
        .n = s.n,
        .slab = s.slab,
        .shadows = @intFromBool(s.shadows),
        .sun_rgb = .{ 1.0, 0.94, 0.85 },
        .sun_index = world.sun_index,
        .num_bodies = world.planets.len,
        .width = @intCast(width),
        .height = @intCast(height),
        .obs_yaw = s.obs_yaw,
        .obs_pitch = s.obs_pitch,
        .obs_dist = s.obs_dist,
        .base_alpha = s.base_alpha,
        .edge_gain = s.edge_gain,
        .marker = .{ 0, 0, 0, 0 },
        .bodies = undefined,
    };
    for (world.planets, 0..) |pl, i| {
        p.bodies[i] = pl.gpu;
        p.bodies[i].c = toF32x4(pl.pos - ship.pos);
    }
    const mk = targetRetinaCoords(ship, s);
    if (mk.ahead and @abs(mk.u) <= 1 and @abs(mk.v) <= 1 and @abs(mk.s) <= s.slab) {
        p.marker = .{ mk.u, mk.v, mk.s, 1 };
    }
    return p;
}

// ---------------------------------------------------------------------------
// HUD
// ---------------------------------------------------------------------------

fn sign(x: f64) u8 {
    return if (x < 0) '-' else '+';
}

fn drawHud(c: hud.Canvas, ship: *const physics.Ship, s: *const Settings, fps: f64) void {
    var buf: [160]u8 = undefined;
    const white = [3]u8{ 230, 235, 240 };
    const dim = [3]u8{ 150, 165, 180 };
    const warn = [3]u8{ 255, 90, 70 };
    const good = [3]u8{ 120, 230, 140 };
    const amber = [3]u8{ 255, 210, 80 };

    const near = physics.nearest(ship.pos);
    const npl = &world.planets[near.index];
    const up = m4.normalize(ship.pos - npl.pos);
    const g = physics.gravity(ship.pos);
    const vl = ship.frame.toLocal(ship.vel);

    c.shade(0, 0, c.width, 74);
    var y: isize = 6;
    const lines = [_][]const u8{
        std.fmt.bufPrint(&buf, "SPD {d:.1} M/S   ALT {d:.0} M OVER {s}   VS {d:.1}   G {d:.2}", .{
            m4.len(ship.vel), near.gap - physics.ship_radius, npl.name, m4.dot(ship.vel, up), m4.len(g),
        }) catch "",
    };
    c.text(8, y, 2, white, lines[0]);
    y += 22;
    const vline = std.fmt.bufPrint(&buf, "VEL  R{c}{d:.1}  U{c}{d:.1}  F{c}{d:.1}  A{c}{d:.1}", .{
        sign(vl[0]), @abs(vl[0]), sign(vl[1]), @abs(vl[1]), sign(vl[2]), @abs(vl[2]), sign(vl[3]), @abs(vl[3]),
    }) catch "";
    c.text(8, y, 2, dim, vline);

    // Target: distance and direction in ship-local (right, up, fwd, ana) terms.
    const tpl = &world.planets[s.target];
    const td = tpl.pos - ship.pos;
    const tl = ship.frame.toLocal(m4.normalize(td));
    const tline = std.fmt.bufPrint(&buf, "TGT {s} {d:.0} M  R{c}{d:.2} U{c}{d:.2} F{c}{d:.2} A{c}{d:.2}", .{
        tpl.name,       world.surfaceGap(tpl, ship.pos), sign(tl[0]), @abs(tl[0]), sign(tl[1]), @abs(tl[1]),
        sign(tl[2]),    @abs(tl[2]),                     sign(tl[3]), @abs(tl[3]),
    }) catch "";
    c.text(@as(isize, @intCast(c.width)) - @as(isize, @intCast(hud.textWidth(tline, 2))) - 8, y, 2, amber, tline);
    y += 22;

    const view_name = if (s.view == .retina) "RETINA" else "SLICE";
    const sline = std.fmt.bufPrint(&buf, "ASSIST {s}   VIEW {s} N{d} SLAB {d:.2} OPAC {d:.2}   {d:.0} FPS   F1 HELP", .{
        if (ship.assist) "ON " else "OFF", view_name, s.n, s.slab, s.base_alpha, fps,
    }) catch "";
    c.text(8, y, 2, if (ship.assist) good else amber, sline);

    // Ship-local thrust readout bar (R U F A), bottom left.
    if (ship.crashed) {
        const msg = std.fmt.bufPrint(&buf, "CRASHED AT {d:.1} M/S - BACKSPACE TO RESPAWN", .{ship.last_impact}) catch "";
        const w = hud.textWidth(msg, 3);
        const x: isize = @intCast((c.width -| w) / 2);
        c.text(x, @intCast(c.height / 2 - 10), 3, warn, msg);
    } else if (ship.landed) {
        c.text(8, @as(isize, @intCast(c.height)) - 24, 2, good, "LANDED");
    }

    // Slice view: draw the target marker on the screen ourselves (the GPU
    // composite does it for the retina view).
    if (s.view == .slice) {
        const l = ship.frame.toLocal(td);
        if (l[m4.fwd] > 0) {
            const aspect = @as(f64, @floatFromInt(c.width)) / @as(f64, @floatFromInt(c.height));
            const k = 1.0 / (l[m4.fwd] * s.tan_half_fov);
            const sx = (l[m4.right] * k / aspect + 1) * 0.5 * @as(f64, @floatFromInt(c.width));
            const sy = (1 - l[m4.up] * k) * 0.5 * @as(f64, @floatFromInt(c.height));
            if (sx > -100 and sx < 1e5 and sy > -100 and sy < 1e5) {
                c.ring(@intFromFloat(sx), @intFromFloat(sy), 9, amber);
            }
        }
    }

    if (s.help) drawHelp(c);
}

const help_lines = [_][]const u8{
    "W/S        THRUST FORWARD / BACK",
    "A/D        STRAFE LEFT / RIGHT",
    "SPACE/CTRL THRUST UP / DOWN",
    "R/F        THRUST ANA / KATA  (4TH AXIS)",
    "SHIFT      BOOST X8",
    "MOUSE      YAW + PITCH        Q/E ROLL",
    "I/K        TURN FORWARD TOWARD ANA / KATA",
    "J/L        TURN RIGHT TOWARD ANA / KATA",
    "U/O        TURN UP TOWARD ANA / KATA",
    "TAB        FLIGHT ASSIST ON/OFF",
    "",
    "RIGHT DRAG ORBIT THE RETINA CUBE",
    "WHEEL      RETINA SLAB THICKNESS",
    "- / =      SURFACE OPACITY",
    "[ / ]      RETINA RESOLUTION",
    "V          RETINA / SLICE VIEW",
    "T          NEXT TARGET    H SHADOWS",
    "BACKSPACE  RESPAWN        ESC MOUSE / QUIT",
};

fn drawHelp(c: hud.Canvas) void {
    const w = 46 * 12 + 24;
    const h = help_lines.len * 20 + 20;
    const x0 = (c.width -| w) / 2;
    const y0 = (c.height -| h) / 2;
    c.shade(x0, y0, w, h);
    c.shade(x0, y0, w, h);
    for (help_lines, 0..) |l, i| {
        c.text(@intCast(x0 + 12), @intCast(y0 + 12 + i * 20), 2, .{ 220, 230, 240 }, l);
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
    spawn_planet: usize = 1,
    spawn_alt: f64 = 250,
    sim_secs: f64 = 0,
    turns: [8][3]f64 = undefined,
    n_turns: usize = 0,
    width: u32 = 1280,
    height: u32 = 720,
};

pub fn main(init: std.process.Init.Minimal) !void {
    var opt = Options{};
    var settings = Settings{};
    var it = init.args.iterate();
    _ = it.next();
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--shot")) {
            opt.shot = it.next() orelse return error.MissingArg;
        } else if (std.mem.eql(u8, a, "--gpucheck")) {
            opt.gpucheck = true;
        } else if (std.mem.eql(u8, a, "--slice")) {
            settings.view = .slice;
        } else if (std.mem.eql(u8, a, "--n")) {
            settings.n = try std.fmt.parseInt(i32, it.next() orelse return error.MissingArg, 10);
        } else if (std.mem.eql(u8, a, "--slab")) {
            settings.slab = try std.fmt.parseFloat(f32, it.next() orelse return error.MissingArg);
        } else if (std.mem.eql(u8, a, "--opacity")) {
            settings.base_alpha = try std.fmt.parseFloat(f32, it.next() orelse return error.MissingArg);
        } else if (std.mem.eql(u8, a, "--obs")) {
            settings.obs_yaw = try std.fmt.parseFloat(f32, it.next() orelse return error.MissingArg);
            settings.obs_pitch = try std.fmt.parseFloat(f32, it.next() orelse return error.MissingArg);
        } else if (std.mem.eql(u8, a, "--spawn")) {
            opt.spawn_planet = try std.fmt.parseInt(usize, it.next() orelse return error.MissingArg, 10);
            opt.spawn_alt = try std.fmt.parseFloat(f64, it.next() orelse return error.MissingArg);
        } else if (std.mem.eql(u8, a, "--sim")) {
            opt.sim_secs = try std.fmt.parseFloat(f64, it.next() orelse return error.MissingArg);
        } else if (std.mem.eql(u8, a, "--turn")) {
            // --turn A B ANGLE : rotate local axis B toward A (0=R 1=U 2=F 3=A)
            if (opt.n_turns == opt.turns.len) return error.TooManyTurns;
            for (0..3) |k| opt.turns[opt.n_turns][k] = try std.fmt.parseFloat(f64, it.next() orelse return error.MissingArg);
            opt.n_turns += 1;
        } else if (std.mem.eql(u8, a, "--target")) {
            settings.target = try std.fmt.parseInt(usize, it.next() orelse return error.MissingArg, 10);
        } else if (std.mem.eql(u8, a, "--no-shadows")) {
            settings.shadows = false;
        } else {
            std.debug.print("unknown argument: {s}\n", .{a});
            return error.BadArgs;
        }
    }
    if (opt.spawn_planet >= world.planets.len or opt.spawn_planet == world.sun_index) return error.BadSpawn;
    settings.n = std.math.clamp(settings.n, 16, render.max_retina);

    var ship = spawn(opt.spawn_planet, opt.spawn_alt);
    for (opt.turns[0..opt.n_turns]) |t| ship.frame.rotate(@intFromFloat(t[0]), @intFromFloat(t[1]), t[2]);

    if (opt.gpucheck) return gpuCheck();
    if (opt.shot) |path| return screenshot(path, &ship, &settings, opt);
    return interactive(&ship, &settings, opt);
}

fn screenshot(path: [:0]const u8, ship: *physics.Ship, settings: *Settings, opt: Options) !void {
    const steps: usize = @intFromFloat(opt.sim_secs / physics.dt);
    for (0..steps) |_| physics.step(ship, .{});

    var r = try render.Renderer.init(opt.width, opt.height, kernel_path);
    defer r.deinit();
    const pixels = try std.heap.page_allocator.alloc(u8, @as(usize, opt.width) * opt.height * 4);
    defer std.heap.page_allocator.free(pixels);

    const params = buildParams(ship, settings, opt.width, opt.height);
    try r.frame(&params, settings.view, pixels); // warm-up (module load, JIT caches)
    const t0 = sdl.SDL_GetPerformanceCounter();
    try r.frame(&params, settings.view, pixels);
    const t1 = sdl.SDL_GetPerformanceCounter();
    const ms = @as(f64, @floatFromInt(t1 - t0)) * 1000.0 / @as(f64, @floatFromInt(sdl.SDL_GetPerformanceFrequency()));
    drawHud(.{ .pixels = pixels, .width = opt.width, .height = opt.height }, ship, settings, 1000.0 / ms);
    try writePpm(path, pixels, opt.width, opt.height);
    std.debug.print("wrote {s}: frame {d:.1} ms\n", .{ path, ms });
}

fn gpuCheck() !void {
    var r = try render.Renderer.init(64, 64, kernel_path);
    defer r.deinit();
    const ship = spawn(1, 100);
    const settings = Settings{};
    const params = buildParams(&ship, &settings, 64, 64);

    const count = 4096;
    var dirs: [count][4]f32 = undefined;
    var gpu: [count]f32 = undefined;
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    for (&dirs) |*d| {
        const v = m4.normalize(V4{ rnd.floatNorm(f64), rnd.floatNorm(f64), rnd.floatNorm(f64), rnd.floatNorm(f64) });
        d.* = toF32x4(v);
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

fn interactive(ship: *physics.Ship, settings: *Settings, opt: Options) !void {
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
    const spawn_planet = opt.spawn_planet;
    const spawn_alt = opt.spawn_alt;

    main_loop: while (true) {
        while (sdl.SDL_PollEvent(&ev) != 0) {
            switch (ev.kind()) {
                sdl.SDL_QUIT => break :main_loop,
                sdl.SDL_KEYDOWN => {
                    if (ev.keyRepeat()) continue;
                    const sc: usize = @intCast(ev.keyScancode());
                    switch (sc) {
                        SC.escape => {
                            if (!mouse_captured) break :main_loop;
                            mouse_captured = false;
                            _ = sdl.SDL_SetRelativeMouseMode(0);
                        },
                        SC.tab => ship.assist = !ship.assist,
                        SC.backspace => ship.* = spawn(spawn_planet, spawn_alt),
                        SC.f1 => settings.help = !settings.help,
                        SC.minus => settings.base_alpha = @max(settings.base_alpha - 0.02, 0.0),
                        SC.equals => settings.base_alpha = @min(settings.base_alpha + 0.02, 1.0),
                        SC.leftbracket, SC.rightbracket => {
                            var idx: usize = 0;
                            for (retina_sizes, 0..) |rs, i| if (rs <= settings.n) {
                                idx = i;
                            };
                            if (sc == SC.leftbracket and idx > 0) idx -= 1;
                            if (sc == SC.rightbracket and idx + 1 < retina_sizes.len) idx += 1;
                            settings.n = retina_sizes[idx];
                        },
                        SC.letter('V') => settings.view = if (settings.view == .retina) .slice else .retina,
                        SC.letter('H') => settings.shadows = !settings.shadows,
                        SC.letter('T') => {
                            settings.target = (settings.target + 1) % world.planets.len;
                        },
                        else => {},
                    }
                },
                sdl.SDL_MOUSEBUTTONDOWN => {
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
                    settings.slab = std.math.clamp(settings.slab * std.math.pow(f32, 1.25, dy), 0.0, 1.0);
                    if (dy < 0 and settings.slab < 0.02) settings.slab = 0;
                    if (dy > 0 and settings.slab < 0.02) settings.slab = 0.02;
                },
                else => {},
            }
        }

        // --- input -----------------------------------------------------------
        const keys = sdl.SDL_GetKeyboardState(null);
        const k = struct {
            fn axis(ks: [*]const u8, pos: usize, neg: usize) f64 {
                return @as(f64, @floatFromInt(ks[pos])) - @as(f64, @floatFromInt(ks[neg]));
            }
        }.axis;
        var in = physics.Input{};
        if (!ship.crashed) {
            in.thrust = .{
                k(keys, SC.letter('D'), SC.letter('A')),
                k(keys, SC.space, SC.lctrl),
                k(keys, SC.letter('W'), SC.letter('S')),
                k(keys, SC.letter('R'), SC.letter('F')),
            };
            in.boost = keys[SC.lshift] != 0;
            // Plane order: (R,U) (R,F) (R,A) (U,F) (U,A) (F,A); positive turns
            // the second axis toward the first.
            in.rot = .{
                k(keys, SC.letter('E'), SC.letter('Q')),
                0,
                -k(keys, SC.letter('L'), SC.letter('J')),
                0,
                -k(keys, SC.letter('U'), SC.letter('O')),
                -k(keys, SC.letter('I'), SC.letter('K')),
            };
        }

        var mdx: c_int = 0;
        var mdy: c_int = 0;
        _ = sdl.SDL_GetRelativeMouseState(&mdx, &mdy);
        if (mouse_captured) {
            const fx: f32 = @floatFromInt(mdx);
            const fy: f32 = @floatFromInt(mdy);
            if (orbiting) {
                settings.obs_yaw -= fx * 0.005;
                settings.obs_pitch = std.math.clamp(settings.obs_pitch + fy * 0.005, -1.5, 1.5);
            } else if (!ship.crashed) {
                // Mouse look acts like reaction wheels: direct attitude change.
                ship.frame.rotate(m4.right, m4.fwd, @as(f64, fx) * 0.0022);
                ship.frame.rotate(m4.up, m4.fwd, -@as(f64, fy) * 0.0022);
                ship.frame.orthonormalize();
            }
        }

        // --- simulate ----------------------------------------------------------
        const now = sdl.SDL_GetPerformanceCounter();
        const frame_dt = @as(f64, @floatFromInt(now - last)) / freq;
        last = now;
        fps = if (fps == 0) 1 / frame_dt else fps * 0.92 + 0.08 / frame_dt;
        accum = @min(accum + frame_dt, 0.1);
        while (accum >= physics.dt) : (accum -= physics.dt) {
            if (!ship.crashed) physics.step(ship, in);
        }

        // --- render ------------------------------------------------------------
        const params = buildParams(ship, settings, w, h);
        try gpu.frame(&params, settings.view, pixels);
        drawHud(.{ .pixels = pixels, .width = w, .height = h }, ship, settings, fps);
        _ = sdl.SDL_UpdateTexture(texture, null, pixels.ptr, @intCast(w * 4));
        _ = sdl.SDL_RenderClear(renderer);
        _ = sdl.SDL_RenderCopy(renderer, texture, null, null);
        sdl.SDL_RenderPresent(renderer);
    }
}
