const std = @import("std");
const sdl = @import("sdl.zig");
const m4 = @import("math4.zig");
const world = @import("world.zig");
const system = @import("system.zig");
const physics = @import("physics.zig");
const render = @import("render.zig");
const hud = @import("hud.zig");
const settings_mod = @import("settings.zig");
const game = @import("game.zig");
const Observer = @import("observer.zig").Observer;
const V4 = m4.V4;
const Game = game.Game;
const toF32x4 = game.toF32x4;
const buildParams = game.buildParams;

const kernel_path = "kernels.hsaco";

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
        } else if (std.mem.eql(u8, a, "--low")) {
            g.s.low_quality = true;
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
    g.captured = opt.shot == null;
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
    g.fps = 1000.0 / ms;
    g.captured = true;
    g.menu.open = opt.menu;
    game.drawHud(canvas, g);
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

    g.captured = true;
    _ = sdl.SDL_SetRelativeMouseMode(1);
    var ev: sdl.SDL_Event = .{};
    const freq: f64 = @floatFromInt(sdl.SDL_GetPerformanceFrequency());
    var last = sdl.SDL_GetPerformanceCounter();

    main_loop: while (true) {
        while (sdl.SDL_PollEvent(&ev) != 0) {
            switch (ev.kind()) {
                sdl.SDL_QUIT => break :main_loop,
                sdl.SDL_KEYDOWN => switch (g.keyDown(@intCast(ev.keyScancode()), ev.keyRepeat())) {
                    .none => {},
                    .menu_opened => setCapture(g, false),
                    .menu_closed => {
                        settings_mod.save(&g.s);
                        setCapture(g, true);
                    },
                    // Esc releases the mouse; a second Esc quits.
                    .escape => if (g.captured) setCapture(g, false) else break :main_loop,
                },
                sdl.SDL_MOUSEBUTTONDOWN => {
                    if (g.menu.open) continue;
                    if (!g.captured) {
                        setCapture(g, true);
                    } else if (ev.mouseButton() == sdl.SDL_BUTTON_RIGHT) g.orbiting = true;
                },
                sdl.SDL_MOUSEBUTTONUP => {
                    if (ev.mouseButton() == sdl.SDL_BUTTON_RIGHT) g.orbiting = false;
                },
                sdl.SDL_MOUSEWHEEL => g.wheel(@floatFromInt(ev.wheelY())),
                else => {},
            }
        }

        const now = sdl.SDL_GetPerformanceCounter();
        const frame_dt = @as(f64, @floatFromInt(now - last)) / freq;
        last = now;

        var mdx: c_int = 0;
        var mdy: c_int = 0;
        _ = sdl.SDL_GetRelativeMouseState(&mdx, &mdy);
        g.update(sdl.SDL_GetKeyboardState(null)[0..512], @floatFromInt(mdx), @floatFromInt(mdy), frame_dt);

        const params = buildParams(g, w, h);
        try gpu.frame(&params, g.s.view, pixels);
        game.drawHud(.{ .pixels = pixels, .width = w, .height = h }, g);
        _ = sdl.SDL_UpdateTexture(texture, null, pixels.ptr, @intCast(w * 4));
        _ = sdl.SDL_RenderClear(renderer);
        _ = sdl.SDL_RenderCopy(renderer, texture, null, null);
        sdl.SDL_RenderPresent(renderer);
    }
}

fn setCapture(g: *Game, on: bool) void {
    g.captured = on;
    _ = sdl.SDL_SetRelativeMouseMode(@intFromBool(on));
}
