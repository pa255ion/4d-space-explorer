const std = @import("std");
const builtin = @import("builtin");
const system = @import("system.zig");
const m4 = @import("math4.zig");

/// The browser build (web.zig): smaller defaults, no Ctrl in the default
/// bindings (Ctrl+W closes the tab), a render-scale option.
pub const is_web = builtin.cpu.arch.isWasm();

pub const View = enum { retina, slice };

// ---------------------------------------------------------------------------
// User settings, key bindings, and their persistence in
// $HOME/.config/space4d.cfg (plain "name value" lines).
// ---------------------------------------------------------------------------

pub const Action = enum {
    fwd,
    back,
    left,
    right,
    up,
    down,
    ana,
    kata,
    boost,
    roll_left,
    roll_right,
    yaw_left,
    yaw_right,
    pitch_up,
    pitch_down,
    turn_fwd_ana,
    turn_fwd_kata,
    turn_right_ana,
    turn_right_kata,
    turn_up_ana,
    turn_up_kata,
    assist,
    view,
    view_axes,
    room_mode,
    target,
    shadows,
    respawn,
    retina_down,
    retina_up,
    opacity_down,
    opacity_up,
};

pub const n_actions = @typeInfo(Action).@"enum".fields.len;

pub fn actionLabel(a: Action) []const u8 {
    return switch (a) {
        .fwd => "THRUST FORWARD",
        .back => "THRUST BACK",
        .left => "STRAFE LEFT",
        .right => "STRAFE RIGHT",
        .up => "THRUST UP",
        .down => "THRUST DOWN",
        .ana => "THRUST ANA",
        .kata => "THRUST KATA",
        .boost => "BOOST X8",
        .roll_left => "ROLL LEFT",
        .roll_right => "ROLL RIGHT",
        .yaw_left => "YAW LEFT",
        .yaw_right => "YAW RIGHT",
        .pitch_up => "PITCH UP",
        .pitch_down => "PITCH DOWN",
        .turn_fwd_ana => "TURN FWD TO ANA",
        .turn_fwd_kata => "TURN FWD TO KATA",
        .turn_right_ana => "TURN RIGHT TO ANA",
        .turn_right_kata => "TURN RIGHT TO KATA",
        .turn_up_ana => "TURN UP TO ANA",
        .turn_up_kata => "TURN UP TO KATA",
        .assist => "FLIGHT ASSIST",
        .view => "RETINA / SLICE VIEW",
        .view_axes => "CYCLE VIEW AXES",
        .room_mode => "WALK THE ROOM",
        .target => "NEXT TARGET",
        .shadows => "SHADOWS",
        .respawn => "RESPAWN",
        .retina_down => "RETINA RES DOWN",
        .retina_up => "RETINA RES UP",
        .opacity_down => "OPACITY DOWN",
        .opacity_up => "OPACITY UP",
    };
}

const L = struct {
    fn k(comptime c: u8) u16 {
        return 4 + (c - 'A');
    }
};

pub const default_bindings = blk: {
    var b: [n_actions]u16 = undefined;
    const pairs = .{
        .{ Action.fwd, L.k('W') },         .{ Action.back, L.k('S') },
        .{ Action.left, L.k('A') },        .{ Action.right, L.k('D') },
        .{ Action.up, 44 },                .{ Action.down, if (is_web) L.k('Z') else 224 },
        .{ Action.ana, L.k('R') },         .{ Action.kata, L.k('F') },
        .{ Action.boost, 225 },            .{ Action.roll_left, L.k('Q') },
        .{ Action.roll_right, L.k('E') },  .{ Action.yaw_left, 80 },
        .{ Action.yaw_right, 79 },         .{ Action.pitch_up, 82 },
        .{ Action.pitch_down, 81 },        .{ Action.turn_fwd_ana, L.k('I') },
        .{ Action.turn_fwd_kata, L.k('K') }, .{ Action.turn_right_ana, L.k('L') },
        .{ Action.turn_right_kata, L.k('J') }, .{ Action.turn_up_ana, L.k('U') },
        .{ Action.turn_up_kata, L.k('O') }, .{ Action.assist, 43 },
        .{ Action.view, L.k('V') },        .{ Action.view_axes, L.k('B') },
        .{ Action.room_mode, L.k('C') },   .{ Action.target, L.k('T') },
        .{ Action.shadows, L.k('H') },     .{ Action.respawn, 42 },
        .{ Action.retina_down, 47 },       .{ Action.retina_up, 48 },
        .{ Action.opacity_down, 45 },      .{ Action.opacity_up, 46 },
    };
    if (pairs.len != n_actions) @compileError("every action needs a default key");
    for (pairs) |p| b[@intFromEnum(p[0])] = p[1];
    break :blk b;
};

/// Which ship axes the view shows: screen right, screen up, viewing
/// direction, and the remaining one, which becomes the retina cube's depth.
/// Named in X=right Y=up Z=forward W=ana terms.
pub const axis_presets = [_]struct { name: []const u8, map: [4]u2 }{
    .{ .name = "XYZ   (ANA IS DEPTH)", .map = .{ m4.right, m4.up, m4.fwd, m4.ana } },
    .{ .name = "XY-ANA  (FWD IS DEPTH)", .map = .{ m4.right, m4.up, m4.ana, m4.fwd } },
    .{ .name = "X-ANA-Z (UP IS DEPTH)", .map = .{ m4.right, m4.ana, m4.fwd, m4.up } },
    .{ .name = "ANA-YZ (RIGHT IS DEPTH)", .map = .{ m4.ana, m4.up, m4.fwd, m4.right } },
};

pub const warps = [_]u8{ 1, 2, 4, 8, 16 };
pub const retina_sizes = [_]i32{ 48, 64, 80, 96, 128, 160 };
pub const max_retina: i32 = if (is_web) 96 else 160;
/// Web only: fraction of the 1280x720 frame actually rendered. Index 0 is
/// auto, which in slice view picks the scale and in cube view the retina
/// resolution (up to `n`), whichever dominates the cost there.
pub const render_scales = [_]f32{ 0, 0.5, 0.625, 0.75, 0.875, 1.0 };

pub const Settings = struct {
    // Simulation
    motion: system.Motion = .rails,
    warp: u8 = 0, // index into `warps`
    crash_speed: f32 = 12,
    pause_in_menu: bool = true,
    // View
    view: View = .retina,
    axes: u8 = 0,
    fov_deg: f32 = 74,
    n: i32 = 96,
    slab: f32 = 1.0,
    base_alpha: f32 = 0.10,
    edge_gain: f32 = 0.9,
    shadows: bool = true,
    room: bool = true,
    labels: bool = true,
    render_scale: u8 = 0, // index into `render_scales` (web only)
    // Input
    mouse_sens: f32 = 1.0,
    invert_y: bool = false,
    bindings: [n_actions]u16 = default_bindings,
    // Runtime only (not saved)
    target: usize = 2,

    pub fn tanHalfFov(self: *const Settings) f32 {
        return @tan(self.fov_deg * std.math.pi / 360.0);
    }

    pub fn key(self: *const Settings, a: Action) usize {
        return self.bindings[@intFromEnum(a)];
    }

    /// Action bound to `scancode`, if any (first match).
    pub fn actionFor(self: *const Settings, scancode: usize) ?Action {
        for (self.bindings, 0..) |b, i| if (b == scancode) return @enumFromInt(i);
        return null;
    }

    pub fn stepRetina(self: *Settings, dir: i32) void {
        var idx: usize = 0;
        for (retina_sizes, 0..) |rs, i| if (rs <= self.n) {
            idx = i;
        };
        if (dir < 0 and idx > 0) idx -= 1;
        if (dir > 0 and idx + 1 < retina_sizes.len and retina_sizes[idx + 1] <= max_retina) idx += 1;
        self.n = retina_sizes[idx];
    }
};

// ---------------------------------------------------------------------------
// Persistence (libc stdio, like the screenshot writer)
// ---------------------------------------------------------------------------

const FILE = opaque {};
extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern fn fclose(f: *FILE) c_int;
extern fn fputs(s: [*:0]const u8, f: *FILE) c_int;
extern fn fgets(buf: [*]u8, n: c_int, f: *FILE) ?[*:0]u8;
extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

fn configPath(buf: []u8) ?[:0]const u8 {
    const home = getenv("HOME") orelse return null;
    return std.fmt.bufPrintZ(buf, "{s}/.config/space4d.cfg", .{std.mem.span(home)}) catch null;
}

const saved_fields = blk: {
    var names: []const []const u8 = &.{};
    for (std.meta.fields(Settings)) |f| {
        if (std.mem.eql(u8, f.name, "bindings") or std.mem.eql(u8, f.name, "target")) continue;
        names = names ++ .{f.name};
    }
    break :blk names;
};

/// The settings as "name value" lines (what `save` writes and `apply` reads).
pub fn serialize(s: *const Settings, out: []u8) []const u8 {
    var len: usize = 0;
    inline for (saved_fields) |name| {
        const v = @field(s, name);
        const res = switch (@typeInfo(@TypeOf(v))) {
            .bool => std.fmt.bufPrint(out[len..], "{s} {d}\n", .{ name, @intFromBool(v) }),
            .int, .float => std.fmt.bufPrint(out[len..], "{s} {d}\n", .{ name, v }),
            .@"enum" => std.fmt.bufPrint(out[len..], "{s} {s}\n", .{ name, @tagName(v) }),
            else => @compileError("unsupported setting type"),
        };
        if (res) |text| len += text.len else |_| {}
    }
    for (s.bindings, 0..) |b, i| {
        const a: Action = @enumFromInt(i);
        const text = std.fmt.bufPrint(out[len..], "bind.{s} {d}\n", .{ @tagName(a), b }) catch continue;
        len += text.len;
    }
    return out[0..len];
}

/// Apply every line of a serialized config.
pub fn applyAll(s: *Settings, text: []const u8) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| apply(s, std.mem.trim(u8, l, " \r\t"));
    s.n = std.math.clamp(s.n, 16, max_retina);
    s.axes %= axis_presets.len;
    s.warp = @min(s.warp, warps.len - 1);
    s.render_scale = @min(s.render_scale, render_scales.len - 1);
}

pub fn save(s: *const Settings) void {
    var pbuf: [512]u8 = undefined;
    const path = configPath(&pbuf) orelse return;
    const f = fopen(path, "w") orelse return;
    defer _ = fclose(f);
    var buf: [4096]u8 = undefined;
    const text = serialize(s, buf[0 .. buf.len - 1]);
    buf[text.len] = 0;
    _ = fputs(buf[0..text.len :0], f);
}

pub fn load(s: *Settings) void {
    var pbuf: [512]u8 = undefined;
    const path = configPath(&pbuf) orelse return;
    const f = fopen(path, "r") orelse return;
    defer _ = fclose(f);
    var buf: [256]u8 = undefined;
    while (fgets(&buf, buf.len, f)) |l| {
        apply(s, std.mem.trim(u8, std.mem.span(l), " \r\n\t"));
    }
    applyAll(s, "");
}

/// Apply one "name value" line; unknown or malformed lines are ignored, so
/// old config files keep working as settings come and go.
pub fn apply(s: *Settings, line: []const u8) void {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const name = it.next() orelse return;
    const val = it.next() orelse return;
    if (std.mem.startsWith(u8, name, "bind.")) {
        const a = std.meta.stringToEnum(Action, name[5..]) orelse return;
        s.bindings[@intFromEnum(a)] = std.fmt.parseInt(u16, val, 10) catch return;
        return;
    }
    inline for (saved_fields) |fname| {
        if (std.mem.eql(u8, name, fname)) {
            const T = @TypeOf(@field(s, fname));
            @field(s, fname) = switch (@typeInfo(T)) {
                .bool => (std.fmt.parseInt(u8, val, 10) catch return) != 0,
                .int => std.fmt.parseInt(T, val, 10) catch return,
                .float => std.fmt.parseFloat(T, val) catch return,
                .@"enum" => std.meta.stringToEnum(T, val) orelse return,
                else => unreachable,
            };
        }
    }
}

/// Display name for an SDL scancode.
pub fn keyName(sc: u16, buf: []u8) []const u8 {
    return switch (sc) {
        4...29 => std.fmt.bufPrint(buf, "{c}", .{@as(u8, @intCast('A' + sc - 4))}) catch "?",
        30...38 => std.fmt.bufPrint(buf, "{c}", .{@as(u8, @intCast('1' + sc - 30))}) catch "?",
        39 => "0",
        40 => "ENTER",
        41 => "ESC",
        42 => "BACKSPACE",
        43 => "TAB",
        44 => "SPACE",
        45 => "-",
        46 => "=",
        47 => "[",
        48 => "]",
        49 => "\\",
        51 => ";",
        52 => "'",
        53 => "`",
        54 => ",",
        55 => ".",
        56 => "/",
        57 => "CAPS",
        58...69 => std.fmt.bufPrint(buf, "F{d}", .{sc - 57}) catch "?",
        73 => "INSERT",
        74 => "HOME",
        75 => "PGUP",
        76 => "DELETE",
        77 => "END",
        78 => "PGDN",
        79 => "RIGHT",
        80 => "LEFT",
        81 => "DOWN",
        82 => "UP",
        89...97 => std.fmt.bufPrint(buf, "KP{d}", .{sc - 88}) catch "?",
        98 => "KP0",
        224 => "LCTRL",
        225 => "LSHIFT",
        226 => "LALT",
        228 => "RCTRL",
        229 => "RSHIFT",
        230 => "RALT",
        else => std.fmt.bufPrint(buf, "KEY{d}", .{sc}) catch "?",
    };
}

test "settings round-trip through config lines" {
    var a = Settings{};
    a.motion = .nbody;
    a.fov_deg = 90;
    a.invert_y = true;
    a.bindings[@intFromEnum(Action.fwd)] = 82;
    var b = Settings{};
    apply(&b, "motion nbody");
    apply(&b, "fov_deg 90");
    apply(&b, "invert_y 1");
    apply(&b, "bind.fwd 82");
    apply(&b, "garbage line here");
    apply(&b, "fov_deg notanumber");
    try std.testing.expectEqual(a.motion, b.motion);
    try std.testing.expectEqual(a.fov_deg, b.fov_deg);
    try std.testing.expectEqual(a.invert_y, b.invert_y);
    try std.testing.expectEqualSlices(u16, &a.bindings, &b.bindings);
}

test "serialize then applyAll restores the settings" {
    var a = Settings{};
    a.motion = .static;
    a.slab = 0.35;
    a.labels = false;
    a.bindings[@intFromEnum(Action.view)] = 60;
    var buf: [4096]u8 = undefined;
    var b = Settings{};
    applyAll(&b, serialize(&a, &buf));
    try std.testing.expectEqual(a.motion, b.motion);
    try std.testing.expectEqual(a.slab, b.slab);
    try std.testing.expectEqual(a.labels, b.labels);
    try std.testing.expectEqualSlices(u16, &a.bindings, &b.bindings);
}

test "default bindings have no duplicates" {
    for (default_bindings, 0..) |x, i| for (default_bindings[i + 1 ..]) |y| {
        try std.testing.expect(x != y);
    };
}
