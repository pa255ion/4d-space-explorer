const std = @import("std");
const world = @import("world.zig");
const hud = @import("hud.zig");
const settings_mod = @import("settings.zig");
const game = @import("game.zig");
const Game = game.Game;

// ---------------------------------------------------------------------------
// Browser frontend (wasm32-freestanding). web/app.js is the plumbing: it
// forwards raw input here, calls `frame` once per animation frame, then
// uploads `params` and the HUD `overlay` to WebGPU and runs web/shaders.wgsl.
// Every decision (bindings, menu, physics, what to render) is made here and
// in the shared game code.
// ---------------------------------------------------------------------------

extern "env" fn js_log(ptr: [*]const u8, len: usize) void;
extern "env" fn js_panic(ptr: [*]const u8, len: usize) void;

pub const panic = std.debug.FullPanic(panicFn);

fn panicFn(msg: []const u8, _: ?usize) noreturn {
    js_panic(msg.ptr, msg.len);
    @trap();
}

fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    js_log(text.ptr, text.len);
}

/// The HUD is always laid out at this size; the 3D image is rendered at
/// `render_scale` of it and upscaled underneath.
const hud_w = 1280;
const hud_h = 720;

var g: Game = undefined;
var params: world.Params = undefined;
/// HUD and menu, premultiplied RGBA, transparent where the 3D view shows.
var overlay: [hud_w * hud_h * 4]u8 = undefined;
var keys = [_]u8{0} ** 512;
var mouse_dx: f32 = 0;
var mouse_dy: f32 = 0;
var save_pending = false;
/// Text exchange with JS (settings in and out).
var scratch: [8192]u8 = undefined;

var render_w: u32 = hud_w;
var render_h: u32 = hud_h;

export fn scratchPtr() [*]u8 {
    return &scratch;
}
export fn scratchLen() usize {
    return scratch.len;
}

/// Start the game with the saved settings JS wrote to `scratch[0..len]`.
export fn init(settings_len: usize) void {
    var s = settings_mod.Settings{};
    settings_mod.applyAll(&s, scratch[0..@min(settings_len, scratch.len)]);
    g = Game.init(s);
    g.captured = false;
    log("space4d: retina {d}^3, render scale {s}", .{ s.n, if (s.render_scale == 0) "auto" else "fixed" });
}

/// 0 = nothing, 1 = menu opened (release the pointer), 2 = menu closed
/// (capture the pointer again), 3 = escape.
export fn keyDown(sc: u32, repeat: bool) u32 {
    if (sc >= keys.len) return 0;
    keys[sc] = 1;
    return press(@intCast(sc), repeat);
}

/// A key press from the keyboard, a touch button or a gamepad.
fn press(sc: u16, repeat: bool) u32 {
    const r = g.keyDown(sc, repeat);
    if (r == .menu_closed) save_pending = true;
    if (r == .menu_opened) g.orbiting = false;
    if (r == .menu_opened or r == .menu_closed) capture_request = @intFromEnum(r);
    return @intFromEnum(r);
}

/// Menu transitions caused outside a key event (touch, gamepad): JS polls
/// this after each frame and pointer event. Same codes as `keyDown`.
var capture_request: u32 = 0;
export fn takeCaptureRequest() u32 {
    defer capture_request = 0;
    return capture_request;
}

// Touch / pen / Quest laser pointer, in HUD pixels. Bit 0 of the result:
// toggle fullscreen (JS must do it inside the event handler).
export fn touchDown(id: u32, x: f32, y: f32) u32 {
    return touchResult(g.touch.down(&g, id, x, y));
}
export fn touchMove(id: u32, x: f32, y: f32) u32 {
    return touchResult(g.touch.move(&g, id, x, y));
}
export fn touchUp(id: u32) void {
    g.touch.up(id);
}
fn touchResult(r: @import("touch.zig").Result) u32 {
    if (r.key) |sc| _ = press(sc, false);
    return @intFromBool(r.fullscreen);
}

// Gamepad state, written by JS before each `frame` (standard mapping).
const pad = @import("pad.zig");
var pad_state: [pad.n_axes + pad.n_buttons]f32 = [_]f32{0} ** (pad.n_axes + pad.n_buttons);
var pad_connected = false;
export fn padPtr() [*]f32 {
    return &pad_state;
}
export fn setPadConnected(on: bool) void {
    pad_connected = on;
    if (!on) g.pad.connected = false;
}

export fn keyUp(sc: u32) void {
    if (sc < keys.len) keys[sc] = 0;
}

/// Window lost focus: no key-up events will arrive for held keys.
export fn clearKeys() void {
    @memset(&keys, 0);
    g.orbiting = false;
    g.touch.clear();
}

export fn mouseMove(dx: f32, dy: f32) void {
    mouse_dx += dx;
    mouse_dy += dy;
}

/// DOM button numbers: 0 left, 2 right.
export fn mouseButton(button: u32, down: bool) void {
    if (button == 2) g.orbiting = down and g.captured and !g.menu.open;
}

export fn wheel(dy: f32) void {
    if (!g.menu.open) g.wheel(dy);
}

export fn setCaptured(on: bool) void {
    g.captured = on;
    if (!on) g.orbiting = false;
}

/// The browser gave us a software (CPU) WebGPU adapter: it will be very
/// slow, so start in low quality and say why.
export fn softwareRenderer() void {
    g.s.low_quality = true;
    // CPU rendering is orders of magnitude slower: start at the smallest
    // sizes (auto can still climb if there's headroom).
    g.s.render_scale = 0;
    auto_retina.level = 0;
    auto_slice.level = 0;
    g.warning = "SOFTWARE RENDERER - THE BROWSER IS NOT USING YOUR GPU (SEE THE NOTE BELOW)";
}

export fn menuOpen() bool {
    return g.menu.open;
}

/// Run headless for `secs` of game time (test harness).
export fn simulate(secs: f64) void {
    const physics = @import("physics.zig");
    const steps: usize = @intFromFloat(secs / physics.dt);
    for (0..steps) |_| g.tick(.{});
}

/// One animation frame: input, simulation, GPU parameters and HUD.
export fn frame(raw_dt: f64) void {
    const dt = std.math.clamp(raw_dt, 0, 0.1);
    var an = g.touch.analog();
    if (pad_connected) {
        const o = g.pad.update(&g, pad_state[0..pad.n_axes].*, pad_state[pad.n_axes..].*, @floatCast(dt));
        for (o.presses[0..o.n]) |sc| _ = press(sc, false);
        an = an.add(o.analog);
    }
    g.update(&keys, mouse_dx, mouse_dy, an, dt);
    mouse_dx = 0;
    mouse_dy = 0;
    updateScale(raw_dt);
    params = game.buildParams(&g, render_w, render_h);
    @memset(&overlay, 0);
    game.drawHud(.{ .pixels = &overlay, .width = hud_w, .height = hud_h }, &g);
}

// Automatic quality. Slice view cost scales with pixels, cube view cost with
// the n^3 retina (compositing is cheap), so auto mode steps the render scale
// in slice view and the retina resolution in cube view. A level that proved
// too slow is retried only after a growing hold-off, so it doesn't oscillate.
const Auto = struct {
    level: usize,
    too_slow_at: usize = std.math.maxInt(usize),
    hold: f64 = 0,
    backoff: f64 = 20, // doubles each time a level proves too slow

    fn judge(self: *Auto, dt: f64, top: usize) void {
        if (dt > 1.0 / 45.0 and self.level > 0) {
            self.too_slow_at = self.level;
            self.hold = self.backoff;
            self.backoff = @min(self.backoff * 2, 600);
            self.level -= 1;
        } else if (dt < 1.0 / 56.0 and self.level < top and (self.hold <= 0 or self.level + 1 < self.too_slow_at)) {
            self.level += 1;
        }
    }
};

const auto_scales = [_]f32{ 0.375, 0.5, 0.625, 0.75, 0.875, 1.0 };
var auto_slice = Auto{ .level = 3 }; // 0.75
var auto_retina = Auto{ .level = std.mem.indexOfScalar(i32, &settings_mod.retina_sizes, 64).? };
var avg_dt: f64 = 0;
/// Consecutive judgments at the lowest level that were still far too slow;
/// after a few, auto mode switches to low quality (once per session).
var hopeless: u32 = 0;
var auto_lowered = false;
var judge_timer: f64 = 0;
var last_view: settings_mod.View = .retina;

fn updateScale(raw_dt: f64) void {
    const s = &g.s;
    const auto = s.render_scale == 0;
    if (s.view != last_view) {
        last_view = s.view;
        avg_dt = 0;
        judge_timer = 0;
    }
    if (raw_dt > 0 and raw_dt < 0.25) { // ignore hiccups like a hidden tab
        avg_dt = if (avg_dt == 0) raw_dt else avg_dt * 0.9 + raw_dt * 0.1;
        judge_timer += raw_dt;
        auto_slice.hold -= raw_dt;
        auto_retina.hold -= raw_dt;
    }
    // Highest retina level allowed: the user's setting.
    var top_n: usize = 0;
    for (settings_mod.retina_sizes, 0..) |rs, i| if (rs <= s.n) {
        top_n = i;
    };
    auto_retina.level = @min(auto_retina.level, top_n);
    if (auto and judge_timer >= 1.0 and !g.menu.open) {
        judge_timer = 0;
        const a = switch (s.view) {
            .slice => &auto_slice,
            .retina => &auto_retina,
        };
        a.judge(avg_dt, if (s.view == .slice) auto_scales.len - 1 else top_n);
        hopeless = if (a.level == 0 and avg_dt > 1.0 / 30.0) hopeless + 1 else 0;
        if (hopeless >= 3 and !s.low_quality and !auto_lowered) {
            auto_lowered = true;
            s.low_quality = true;
            save_pending = true;
            g.notice = "STILL SLOW AT THE LOWEST RESOLUTION: SWITCHED TO LOW QUALITY (` MENU TO CHANGE)";
            g.notice_time = 6;
        }
    }
    const scale = if (!auto) settings_mod.render_scales[s.render_scale] else switch (s.view) {
        .slice => auto_scales[auto_slice.level],
        .retina => 1.0,
    };
    g.n_eff = if (auto) settings_mod.retina_sizes[auto_retina.level] else null;
    render_w = @intFromFloat(@round(hud_w * scale));
    render_h = @intFromFloat(@round(hud_h * scale));
    g.res_pct = @intFromFloat(@round(scale * 100));
}

export fn paramsPtr() *const world.Params {
    return &params;
}
export fn paramsSize() usize {
    return @sizeOf(world.Params);
}
export fn overlayPtr() [*]const u8 {
    return &overlay;
}
export fn hudWidth() u32 {
    return hud_w;
}
export fn hudHeight() u32 {
    return hud_h;
}
export fn renderWidth() u32 {
    return render_w;
}
export fn renderHeight() u32 {
    return render_h;
}
export fn maxRetina() u32 {
    return @intCast(settings_mod.max_retina);
}
/// 0 = retina cube, 1 = slice.
export fn view() u32 {
    return @intFromEnum(g.s.view);
}
export fn retinaN() u32 {
    return @intCast(g.n_eff orelse g.s.n);
}

/// True once after settings changed (menu closed): JS should call
/// `settingsText` and store the result.
export fn takeSaveRequest() bool {
    defer save_pending = false;
    return save_pending;
}

/// Serialize the settings into `scratch`; returns the length.
export fn settingsText() usize {
    return settings_mod.serialize(&g.s, &scratch).len;
}

// CPU side of the CPU/GPU terrain cross-check (tools/webcheck.js).
var probe_dirs: [4096][4]f32 = undefined;
var probe_out: [4096]f32 = undefined;

export fn probeDirsPtr() [*][4]f32 {
    return &probe_dirs;
}
export fn probeOutPtr() [*]f32 {
    return &probe_out;
}
export fn probeCpu(body: u32, octaves: u32, count: u32) void {
    for (probe_dirs[0..count], probe_out[0..count]) |d, *o| {
        o.* = world.terrainHeight(&params.bodies[body], d, octaves);
    }
}
export fn maxOctaves() u32 {
    return world.max_octaves;
}
export fn numBodies() u32 {
    return world.planets.len;
}
