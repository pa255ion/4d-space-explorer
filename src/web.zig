const std = @import("std");
const world = @import("world.zig");
const hud = @import("hud.zig");
const settings_mod = @import("settings.zig");
const game = @import("game.zig");
const Game = game.Game;
const Analog = game.Analog;

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

// ---------------------------------------------------------------------------
// VR (WebXR + WebGPU). You stand in the observatory around the retina cube;
// the controllers fly the ship through the gamepad mapping (app.js converts
// the XR controllers to the standard layout). For each view JS writes 12
// floats in XR local-floor space: eye position, the ray direction through
// the view's top-left corner, and the direction steps across its full width
// and height. The game turns each into an Eye and a parameter block.
//
// Y opens a floating panel with the HUD, its buttons and the menu; either
// controller points at it and its trigger clicks (the touch code handles
// the clicks, in HUD pixels).
//
// The slice view is traced once, for a "cyclops" camera between the eyes
// whose frustum covers both, and each eye reprojects it by ray direction
// (the slice is at planetary distances, so the missing stereo is invisible
// except right next to terrain). That halves its cost.
// ---------------------------------------------------------------------------

const observer = @import("observer.zig");
const V3 = [3]f32;

fn add3(a: V3, b: V3) V3 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}
fn sub3(a: V3, b: V3) V3 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}
fn mul3(a: V3, k: f32) V3 {
    return .{ a[0] * k, a[1] * k, a[2] * k };
}
fn dot3(a: V3, b: V3) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}
fn cross3(a: V3, b: V3) V3 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}
fn norm3(a: V3) V3 {
    const l = @sqrt(dot3(a, a));
    return if (l > 0) mul3(a, 1 / l) else a;
}

var vr_views: [2][12]f32 = undefined;
/// Controller rays from JS, per hand (0 left, 1 right): valid, origin, direction.
var vr_ctrl: [2][7]f32 = [_][7]f32{[_]f32{0} ** 7} ** 2;
/// Parameter blocks: one per eye, and [2] for the cyclops slice camera.
var vr_params: [3]world.Params = undefined;
/// Per-eye presentation block for `vr_blit_fs` (see VrBlit in shaders.wgsl).
var vr_blit: [2][72]f32 = undefined;
var vr_eye_w: u32 = 0;
var vr_eye_h: u32 = 0;
var vr_cyc_w: u32 = 0;
var vr_cyc_h: u32 = 0;
var in_vr = false;
var vr_floor_offset: f32 = 0; // XR y of the floor (non-zero if no local-floor space)
var vr_saved_low = false;
var vr_saved_view: settings_mod.View = .retina;
var vr_saved_touch = false;

/// Fraction of the headset's recommended per-eye resolution rendered. The
/// cube view (whose cost is mostly the retina) stops at `vr_cube_floor`.
const vr_scales = [_]f32{ 0.15, 0.2, 0.25, 0.3, 0.375, 0.45, 0.55, 0.65, 0.75 };
const vr_cube_floor = 2;
var vr_scale_level: usize = 4;
var vr_avg_dt: f64 = 0;
var vr_timer: f64 = 0;
var vr_hold: f64 = 0;
var vr_last_view: settings_mod.View = .retina;

const Panel = struct {
    open: bool = false,
    c: V3 = .{ 0, 0, 0 },
    r: V3 = .{ 0, 0, 0 }, // half width
    u: V3 = .{ 0, 0, 0 }, // half height
    y_prev: bool = false,
    trig_prev: [2]bool = .{ false, false },
    touching: [2]bool = .{ false, false },
    cursor: ?[2]f32 = null, // panel uv of the pointing hand
    beam: [2]f32 = .{ 0, 0 }, // beam length per hand (0 = none)
};
var panel = Panel{};
const panel_half_w: f32 = 0.625;
const panel_dist: f32 = 0.95;

export fn vrViewsPtr() [*]f32 {
    return @ptrCast(&vr_views);
}
export fn vrCtrlPtr() [*]f32 {
    return @ptrCast(&vr_ctrl);
}

/// `floor_y`: XR y of the floor (0 for a local-floor space; about -1.6 when
/// only a 'local' space at eye height was available).
export fn vrEnter(floor_y: f32) void {
    in_vr = true;
    vr_floor_offset = floor_y;
    vr_saved_low = g.s.low_quality;
    vr_saved_view = g.s.view;
    vr_saved_touch = g.touch.enabled;
    // Headsets have phone-class GPUs and need two views at 72+ Hz.
    g.s.low_quality = true;
    g.s.view = .retina; // B toggles the slice view
    g.touch.clear();
    g.touch.enabled = true;
    g.touch.vr = true;
    g.menu.touch = true;
    panel = .{};
    auto_retina.level = 1; // 48^3
    vr_scale_level = 4;
    vr_avg_dt = 0;
    log("space4d: entered VR", .{});
}

export fn vrExit() void {
    in_vr = false;
    g.eye = null;
    if (g.menu.open) _ = press(@import("menu.zig").grave, false);
    g.touch.clear();
    g.touch.vr = false;
    g.touch.enabled = vr_saved_touch;
    g.s.low_quality = vr_saved_low;
    g.s.view = vr_saved_view;
    log("space4d: left VR", .{});
}

export fn vrPanelOpen() bool {
    return panel.open;
}

fn eyeOf(v: [12]f32, aspect: f32) game.Eye {
    var e: game.Eye = .{ .pos = .{ v[0], v[1], v[2] }, .fwd = undefined, .right = undefined, .up = undefined };
    for (0..3) |k| {
        e.fwd[k] = v[3 + k] + v[6 + k] / 2 + v[9 + k] / 2;
        e.right[k] = v[6 + k] / (2 * aspect);
        e.up[k] = -v[9 + k] / 2;
    }
    return e;
}

fn placePanel(head: V3, fwd: V3) void {
    var f = V3{ fwd[0], 0, fwd[2] };
    f = if (dot3(f, f) < 1e-4) .{ 0, 0, -1 } else norm3(f);
    panel.r = .{ -f[2] * panel_half_w, 0, f[0] * panel_half_w };
    panel.u = .{ 0, panel_half_w * hud_h / hud_w, 0 };
    panel.c = add3(add3(head, mul3(f, panel_dist)), .{ 0, -0.12, 0 });
}

/// Where a ray (XR space) meets the panel: uv in [0, 1] (v down) and the
/// distance along the normalized direction.
fn panelHit(o: V3, d0: V3) ?struct { uv: [2]f32, t: f32 } {
    const d = norm3(d0);
    const n = cross3(panel.r, panel.u);
    const den = dot3(d, n);
    if (@abs(den) < 1e-6) return null;
    const t = dot3(sub3(panel.c, o), n) / den;
    if (t <= 0) return null;
    const q = sub3(add3(o, mul3(d, t)), panel.c);
    const a = dot3(q, panel.r) / dot3(panel.r, panel.r);
    const b = dot3(q, panel.u) / dot3(panel.u, panel.u);
    if (@abs(a) > 1 or @abs(b) > 1) return null;
    return .{ .uv = .{ a * 0.5 + 0.5, 0.5 - b * 0.5 }, .t = t };
}

/// Controller pointing while the panel is open. Triggers of hands aimed at
/// the panel (or still dragging on it) click instead of thrusting.
fn pointers(st: *[pad.n_axes + pad.n_buttons]f32) void {
    panel.cursor = null;
    var h: usize = 2;
    while (h > 0) { // right hand first: its cursor wins
        h -= 1;
        panel.beam[h] = 0;
        const c = vr_ctrl[h];
        const ti = pad.n_axes + @as(usize, if (h == 0) pad.B.lt else pad.B.rt);
        const trig = st[ti] > 0.6;
        defer panel.trig_prev[h] = trig;
        const id: u32 = 1000 + @as(u32, @intCast(h));
        if (c[0] < 0.5) {
            if (panel.touching[h]) g.touch.up(id);
            panel.touching[h] = false;
            continue;
        }
        const o = V3{ c[1], c[2], c[3] };
        const hit = panelHit(o, .{ c[4], c[5], c[6] });
        panel.beam[h] = if (hit) |x| x.t else 1.5;
        if (hit) |x| {
            if (panel.cursor == null) panel.cursor = x.uv;
        }
        const px = if (hit) |x| x.uv[0] * hud_w else 0;
        const py = if (hit) |x| x.uv[1] * hud_h else 0;
        if (panel.touching[h]) {
            if (st[ti] > 0.3) {
                if (hit != null) _ = touchResult(g.touch.move(&g, id, px, py));
            } else {
                g.touch.up(id);
                panel.touching[h] = false;
            }
            st[ti] = 0;
        } else if (hit != null) {
            if (trig and !panel.trig_prev[h]) {
                _ = touchResult(g.touch.down(&g, id, px, py));
                panel.touching[h] = true;
            }
            st[ti] = 0;
        }
    }
}

/// One XR frame: input, simulation, and a parameter block per view for a
/// view port of `vp_w` x `vp_h` (the recommended per-eye size).
export fn vrFrame(raw_dt: f64, n_views: u32, vp_w: u32, vp_h: u32) void {
    const dt = std.math.clamp(raw_dt, 0, 0.1);
    const nv = @max(1, @min(n_views, 2));
    const grave = @import("menu.zig").grave;

    var st = pad_state;
    // Y opens and closes the panel (on the panel, AXES cycles the view axes).
    const yi = pad.n_axes + pad.B.y;
    const y_now = st[yi] > 0.5;
    st[yi] = 0;
    if (y_now and !panel.y_prev) {
        panel.open = !panel.open;
        if (panel.open) {
            const e = eyeOf(vr_views[0], 1);
            var head = V3{ 0, 0, 0 };
            for (0..nv) |i| head = add3(head, mul3(.{ vr_views[i][0], vr_views[i][1], vr_views[i][2] }, 1 / @as(f32, @floatFromInt(nv))));
            placePanel(head, e.fwd);
        } else {
            for (0..2) |h| if (panel.touching[h]) g.touch.up(1000 + @as(u32, @intCast(h)));
            panel.touching = .{ false, false };
            if (g.menu.open) _ = press(grave, false);
        }
    }
    panel.y_prev = y_now;
    if (panel.open) pointers(&st) else panel.cursor = null;

    var an = Analog{};
    if (pad_connected) {
        const o = g.pad.update(&g, st[0..pad.n_axes].*, st[pad.n_axes..].*, @floatCast(dt));
        // The menu needs the panel to be seen: Start alone doesn't open it.
        for (o.presses[0..o.n]) |sc| if (sc != grave or panel.open or g.menu.open) {
            _ = press(sc, false);
        };
        an = o.analog;
    }
    g.update(&keys, 0, 0, an, dt);
    vrQuality(raw_dt);

    const slice = g.s.view == .slice;
    const scale = vr_scales[vr_scale_level];
    vr_eye_w = @max(64, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(vp_w)) * scale))));
    vr_eye_h = @max(64, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(vp_h)) * scale))));
    g.res_pct = @intFromFloat(@round(scale * 100));
    const aspect = @as(f32, @floatFromInt(vr_eye_w)) / @as(f32, @floatFromInt(vr_eye_h));
    // XR origin (where you stood at session start, facing -z) maps to 2.6 m
    // in front of the cube, standing on the observatory floor.
    const rig = [3]f32{ 0, observer.room_floor - vr_floor_offset, 2.6 };
    var eyes: [2]game.Eye = undefined;
    for (0..2) |i| {
        eyes[i] = eyeOf(vr_views[@min(i, nv - 1)], aspect);
        var e = eyes[i];
        e.pos = add3(e.pos, rig);
        g.eye = e;
        vr_params[i] = game.buildParams(&g, vr_eye_w, vr_eye_h);
    }
    g.eye = null;
    g.n_eff = settings_mod.retina_sizes[auto_retina.level];
    for (&vr_params) |*p| p.n = g.n_eff.?;

    // Cyclops camera: eye 0's orientation, a frustum covering both eyes.
    const cr = norm3(eyes[0].right);
    const cu = norm3(eyes[0].up);
    const cf = cross3(cu, cr);
    var ext = [4]f32{ 1e9, -1e9, 1e9, -1e9 }; // x0 x1 y0 y1 on the plane at 1
    for (eyes[0..nv]) |e| for ([_][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ -1, 1 }, .{ 1, 1 } }) |k| {
        const d = add3(e.fwd, add3(mul3(e.right, k[0] * aspect), mul3(e.up, k[1])));
        const z = @max(dot3(d, cf), 1e-3);
        const x = dot3(d, cr) / z;
        const y = dot3(d, cu) / z;
        ext = .{ @min(ext[0], x), @max(ext[1], x), @min(ext[2], y), @max(ext[3], y) };
    };
    if (slice) {
        const hx = (ext[1] - ext[0]) / 2;
        const hy = (ext[3] - ext[2]) / 2;
        const t_eye = @sqrt(dot3(eyes[0].up, eyes[0].up));
        vr_cyc_h = @max(64, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(vr_eye_h)) * hy / t_eye))));
        vr_cyc_w = @max(64, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(vr_cyc_h)) * hx / hy))));
        var head = V3{ 0, 0, 0 };
        for (eyes[0..nv]) |e| head = add3(head, mul3(e.pos, 1 / @as(f32, @floatFromInt(nv))));
        const cam = game.Eye{
            .pos = head,
            .fwd = add3(cf, add3(mul3(cr, (ext[0] + ext[1]) / 2), mul3(cu, (ext[2] + ext[3]) / 2))),
            .right = mul3(cr, hy),
            .up = mul3(cu, hy),
        };
        vr_params[2] = vr_params[0];
        vr_params[2].width = @intCast(vr_cyc_w);
        vr_params[2].height = @intCast(vr_cyc_h);
        sliceEye(&vr_params[2], g.viewAxes(), cam, .{ head[0], head[1] - vr_floor_offset - observer.eye_height, head[2] });
    }

    // Presentation blocks (JS fills the first 8 floats: view port and scale).
    for (0..2) |i| {
        const e = eyes[i];
        var b = &vr_blit[i];
        @memset(b, 0);
        b[7] = if (slice) 1 else 0;
        b[8..11].* = e.pos;
        b[11] = aspect;
        b[12..15].* = e.fwd;
        b[16..19].* = e.right;
        b[20..23].* = e.up;
        b[24..27].* = cr;
        b[28..31].* = cu;
        b[32..35].* = cf;
        b[36..40].* = ext;
        b[40..43].* = panel.c;
        b[43] = if (panel.open) 1 else 0;
        b[44..47].* = panel.r;
        b[48..51].* = panel.u;
        if (panel.cursor) |cu_| {
            b[52] = cu_[0];
            b[53] = cu_[1];
            b[54] = 1;
        }
        for (0..2) |h| {
            const c = vr_ctrl[h];
            const o = 56 + h * 8;
            @memcpy(b[o .. o + 3], &[3]f32{ c[1], c[2], c[3] });
            @memcpy(b[o + 4 .. o + 7], &norm3(.{ c[4], c[5], c[6] }));
            b[o + 7] = if (panel.open) panel.beam[h] else 0;
        }
    }

    if (panel.open) {
        @memset(&overlay, 0);
        game.drawHud(.{ .pixels = &overlay, .width = hud_w, .height = hud_h }, &g);
    }
}

/// Slice view in VR: you are the ship, inside the 3D cross-section. XR
/// space maps onto the slice (x -> right, y -> up, -z -> forward), so the
/// headset turns the view and head motion moves the camera 1:1 in metres.
/// The slice kernel's ray is fwd + (right*u + up*v)*tan_half_fov with
/// u in [-aspect, aspect], the same convention as the eye's rays.
fn sliceEye(p: *world.Params, axes: [4]game.V4, e: game.Eye, head: [3]f32) void {
    const map = struct {
        fn f(ax: [4]game.V4, d: [3]f32) game.V4 {
            return ax[0] * @as(game.V4, @splat(d[0])) + ax[1] * @as(game.V4, @splat(d[1])) - ax[2] * @as(game.V4, @splat(d[2]));
        }
    }.f;
    const t = @sqrt(dot3(e.up, e.up));
    const k = 1 / t;
    p.fwd = game.toF32x4(map(axes, e.fwd));
    p.right = game.toF32x4(map(axes, mul3(e.right, k)));
    p.up = game.toF32x4(map(axes, mul3(e.up, k)));
    p.tan_half_fov = t;
    // Bodies are given relative to the camera: shift them by the head offset.
    const off = game.toF32x4(map(axes, head));
    for (&p.bodies) |*b| for (0..4) |c| {
        b.c[c] -= off[c];
    };
}

/// Lower the per-eye resolution first, then the retina, when the headset
/// can't keep its frame rate; raise the retina (to 64^3) and then the
/// resolution when there's headroom. The slice view only has the resolution.
fn vrQuality(raw_dt: f64) void {
    if (g.s.view != vr_last_view) {
        vr_last_view = g.s.view;
        vr_avg_dt = 0;
        vr_timer = 0;
        vr_hold = 0;
        if (g.s.view == .retina) vr_scale_level = @max(vr_scale_level, vr_cube_floor);
    }
    if (raw_dt <= 0 or raw_dt > 0.25) return;
    vr_avg_dt = if (vr_avg_dt == 0) raw_dt else vr_avg_dt * 0.9 + raw_dt * 0.1;
    vr_timer += raw_dt;
    vr_hold -= raw_dt;
    if (vr_timer < 1.0) return;
    vr_timer = 0;
    const n64 = comptime std.mem.indexOfScalar(i32, &settings_mod.retina_sizes, 64).?;
    const slice = g.s.view == .slice;
    const floor: usize = if (slice) 0 else vr_cube_floor;
    if (vr_avg_dt > 1.0 / 55.0) {
        vr_hold = 10;
        if (vr_scale_level > floor) vr_scale_level -= 1 else if (!slice and auto_retina.level > 0) auto_retina.level -= 1;
    } else if (vr_avg_dt < 1.0 / 66.0 and vr_hold <= 0) {
        if (!slice and auto_retina.level < n64) auto_retina.level += 1 else if (vr_scale_level + 1 < vr_scales.len) vr_scale_level += 1;
    }
}

export fn vrParamsPtr(i: u32) *const world.Params {
    return &vr_params[@min(i, 2)];
}
export fn vrBlitPtr(i: u32) [*]const f32 {
    return &vr_blit[@min(i, 1)];
}
export fn vrEyeWidth() u32 {
    return vr_eye_w;
}
export fn vrEyeHeight() u32 {
    return vr_eye_h;
}
export fn vrCycWidth() u32 {
    return vr_cyc_w;
}
export fn vrCycHeight() u32 {
    return vr_cyc_h;
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
    // In VR, quality and view are forced: save what they will be again after.
    var s = g.s;
    if (in_vr) {
        s.low_quality = vr_saved_low;
        s.view = vr_saved_view;
    }
    return settings_mod.serialize(&s, &scratch).len;
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
