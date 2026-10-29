const std = @import("std");
const hud = @import("hud.zig");
const settings_mod = @import("settings.zig");
const system = @import("system.zig");
const Settings = settings_mod.Settings;
const Action = settings_mod.Action;

// ---------------------------------------------------------------------------
// The ` options menu: keyboard-driven list of settings and key bindings.
//   Up/Down select, Left/Right change, Enter activates / rebinds,
//   Esc or ` closes (Esc cancels a pending rebind).
// ---------------------------------------------------------------------------

const Opt = enum {
    motion,
    warp,
    crash_speed,
    pause_in_menu,
    reset_system,
    respawn,
    view,
    axes,
    fov,
    retina,
    opacity,
    edges,
    slab,
    shadows,
    room,
    labels,
    mouse_sens,
    invert_y,
    reset_controls,
};

const Item = union(enum) {
    header: []const u8,
    opt: Opt,
    bind: Action,
};

const items = blk: {
    var list: []const Item = &.{
        .{ .header = "SIMULATION" },
        .{ .opt = .motion },
        .{ .opt = .warp },
        .{ .opt = .crash_speed },
        .{ .opt = .pause_in_menu },
        .{ .opt = .reset_system },
        .{ .opt = .respawn },
        .{ .header = "VIEW" },
        .{ .opt = .view },
        .{ .opt = .axes },
        .{ .opt = .fov },
        .{ .opt = .retina },
        .{ .opt = .opacity },
        .{ .opt = .edges },
        .{ .opt = .slab },
        .{ .opt = .shadows },
        .{ .opt = .room },
        .{ .opt = .labels },
        .{ .header = "INPUT" },
        .{ .opt = .mouse_sens },
        .{ .opt = .invert_y },
        .{ .opt = .reset_controls },
        .{ .header = "CONTROLS  (ENTER TO REBIND)" },
    };
    for (0..settings_mod.n_actions) |i| list = list ++ .{Item{ .bind = @enumFromInt(i) }};
    break :blk list;
};

pub const Command = enum { none, close, respawn, reset_system, motion_changed };

pub const grave = 53;
const sc_escape = 41;
const sc_enter = 40;
const sc_kp_enter = 88;
const sc_right = 79;
const sc_left = 80;
const sc_down = 81;
const sc_up = 82;
const sc_pgdn = 78;
const sc_pgup = 75;

pub const Menu = struct {
    open: bool = false,
    cursor: usize = 1,
    scroll: usize = 0,
    rebinding: ?Action = null,

    pub fn key(self: *Menu, s: *Settings, sc: u16) Command {
        if (self.rebinding) |a| {
            self.rebinding = null;
            if (sc != sc_escape and sc != grave) s.bindings[@intFromEnum(a)] = sc;
            return .none;
        }
        switch (sc) {
            sc_escape, grave => {
                self.open = false;
                return .close;
            },
            sc_up => self.move(-1),
            sc_down => self.move(1),
            sc_pgup => for (0..8) |_| self.move(-1),
            sc_pgdn => for (0..8) |_| self.move(1),
            sc_left => return adjust(s, items[self.cursor], -1),
            sc_right => return adjust(s, items[self.cursor], 1),
            sc_enter, sc_kp_enter => switch (items[self.cursor]) {
                .bind => |a| self.rebinding = a,
                else => return adjust(s, items[self.cursor], 1),
            },
            else => {},
        }
        return .none;
    }

    fn move(self: *Menu, dir: isize) void {
        var c: isize = @intCast(self.cursor);
        while (true) {
            c += dir;
            if (c < 0 or c >= items.len) return;
            if (items[@intCast(c)] != .header) break;
        }
        self.cursor = @intCast(c);
    }

    pub fn draw(self: *Menu, c: hud.Canvas, s: *const Settings) void {
        const line_h = 20;
        const w = 860;
        const top = 120;
        const visible = (c.height - top - 70) / line_h;
        // Keep the cursor in view (and its section header when near the top).
        if (self.cursor < self.scroll + 1) self.scroll = self.cursor -| 1;
        if (self.cursor >= self.scroll + visible) self.scroll = self.cursor + 1 - visible;

        const x0 = (c.width -| w) / 2;
        c.shade(x0, top - 40, w, visible * line_h + 90);
        c.shade(x0, top - 40, w, visible * line_h + 90);
        const xi: isize = @intCast(x0);
        c.text(xi + 16, top - 30, 2, .{ 255, 210, 80 }, "OPTIONS");
        c.text(xi + 140, top - 30, 2, .{ 150, 165, 180 }, "UP/DOWN SELECT  LEFT/RIGHT CHANGE  ENTER SET  ` CLOSE");

        var buf: [96]u8 = undefined;
        var kbuf: [16]u8 = undefined;
        for (0..visible) |row| {
            const idx = self.scroll + row;
            if (idx >= items.len) break;
            const y: isize = @intCast(top + row * line_h);
            const sel = idx == self.cursor;
            const fg = if (sel) [3]u8{ 255, 255, 255 } else [3]u8{ 185, 195, 205 };
            if (sel) c.text(xi + 16, y, 2, .{ 255, 210, 80 }, ">");
            switch (items[idx]) {
                .header => |h| c.text(xi + 16, y, 2, .{ 110, 200, 255 }, h),
                .opt => |o| {
                    c.text(xi + 40, y, 2, fg, optLabel(o));
                    c.text(xi + 420, y, 2, if (sel) .{ 255, 210, 80 } else fg, optValue(o, s, &buf));
                },
                .bind => |a| {
                    c.text(xi + 40, y, 2, fg, settings_mod.actionLabel(a));
                    const sc = s.bindings[@intFromEnum(a)];
                    var dup = false;
                    for (s.bindings, 0..) |b, j| if (b == sc and j != @intFromEnum(a)) {
                        dup = true;
                    };
                    const waiting = self.rebinding != null and self.rebinding.? == a;
                    const txt = if (waiting) "PRESS A KEY (ESC CANCELS)" else settings_mod.keyName(sc, &kbuf);
                    const col: [3]u8 = if (waiting) .{ 120, 230, 140 } else if (dup) .{ 255, 90, 70 } else if (sel) .{ 255, 210, 80 } else fg;
                    c.text(xi + 420, y, 2, col, txt);
                    if (dup and !waiting) c.text(xi + 560, y, 2, .{ 255, 90, 70 }, "CONFLICT");
                },
            }
        }
        if (optHint(items[self.cursor])) |hint| {
            c.text(xi + 16, @intCast(top + visible * line_h + 16), 2, .{ 150, 165, 180 }, hint);
        }
    }
};

fn optLabel(o: Opt) []const u8 {
    return switch (o) {
        .motion => "PLANET MOTION",
        .warp => "TIME WARP",
        .crash_speed => "CRASH SPEED",
        .pause_in_menu => "PAUSE IN MENU",
        .reset_system => "RESET SOLAR SYSTEM",
        .respawn => "RESPAWN SHIP",
        .view => "VIEW",
        .axes => "VIEW AXES",
        .fov => "FIELD OF VIEW",
        .retina => "RETINA RESOLUTION",
        .opacity => "SURFACE OPACITY",
        .edges => "EDGE EMPHASIS",
        .slab => "RETINA SLAB",
        .shadows => "SHADOWS",
        .room => "OBSERVATORY ROOM",
        .labels => "CUBE FACE LABELS",
        .mouse_sens => "MOUSE SENSITIVITY",
        .invert_y => "INVERT MOUSE Y",
        .reset_controls => "RESTORE DEFAULT CONTROLS",
    };
}

fn optHint(it: Item) ?[]const u8 {
    return switch (it) {
        .opt => |o| switch (o) {
            .motion => "RAILS: EXACT CIRCLES. N-BODY: FULL MUTUAL GRAVITY - ORBITS SLOWLY DECAY",
            .warp => "SPEEDS UP EVERYTHING, SHIP INCLUDED",
            .axes => "WHICH 3 SHIP AXES THE VIEW SHOWS; THE 4TH BECOMES CUBE DEPTH",
            .slab => "HOW MUCH OF THE RETINA'S DEPTH IS SHOWN (0 = PURE CROSS-SECTION)",
            .reset_system => "PUTS PLANETS BACK ON THEIR START ORBITS; YOU MOVE WITH THE NEAREST",
            else => null,
        },
        .bind => "MOUSE YAWS/PITCHES TOO. KEYS ALSO WALK YOU IN ROOM MODE",
        else => null,
    };
}

fn onOff(b: bool) []const u8 {
    return if (b) "ON" else "OFF";
}

fn optValue(o: Opt, s: *const Settings, buf: []u8) []const u8 {
    return switch (o) {
        .motion => switch (s.motion) {
            .static => "STATIC",
            .rails => "ORBITS ON RAILS",
            .nbody => "N-BODY",
        },
        .warp => std.fmt.bufPrint(buf, "X{d}", .{settings_mod.warps[s.warp]}) catch "",
        .crash_speed => std.fmt.bufPrint(buf, "{d:.0} M/S", .{s.crash_speed}) catch "",
        .pause_in_menu => onOff(s.pause_in_menu),
        .reset_system, .respawn, .reset_controls => "[ENTER]",
        .view => if (s.view == .retina) "RETINA CUBE" else "SLICE",
        .axes => settings_mod.axis_presets[s.axes].name,
        .fov => std.fmt.bufPrint(buf, "{d:.0} DEG", .{s.fov_deg}) catch "",
        .retina => std.fmt.bufPrint(buf, "{d}^3", .{s.n}) catch "",
        .opacity => std.fmt.bufPrint(buf, "{d:.2}", .{s.base_alpha}) catch "",
        .edges => std.fmt.bufPrint(buf, "{d:.1}", .{s.edge_gain}) catch "",
        .slab => std.fmt.bufPrint(buf, "{d:.2}", .{s.slab}) catch "",
        .shadows => onOff(s.shadows),
        .room => onOff(s.room),
        .labels => onOff(s.labels),
        .mouse_sens => std.fmt.bufPrint(buf, "{d:.1}X", .{s.mouse_sens}) catch "",
        .invert_y => onOff(s.invert_y),
    };
}

fn cycle(comptime T: type, v: T, dir: i32) T {
    const n: i32 = @typeInfo(T).@"enum".fields.len;
    return @enumFromInt(@mod(@as(i32, @intFromEnum(v)) + dir, n));
}

fn adjust(s: *Settings, it: Item, dir: i32) Command {
    const o = switch (it) {
        .opt => |o| o,
        else => return .none,
    };
    const fd: f32 = @floatFromInt(dir);
    switch (o) {
        .motion => {
            s.motion = cycle(system.Motion, s.motion, dir);
            return .motion_changed;
        },
        .warp => s.warp = @intCast(std.math.clamp(@as(i32, s.warp) + dir, 0, @as(i32, settings_mod.warps.len - 1))),
        .crash_speed => s.crash_speed = std.math.clamp(s.crash_speed + 2 * fd, 4, 60),
        .pause_in_menu => s.pause_in_menu = !s.pause_in_menu,
        .reset_system => return .reset_system,
        .respawn => return .respawn,
        .view => s.view = cycle(@TypeOf(s.view), s.view, dir),
        .axes => s.axes = @intCast(@mod(@as(i32, s.axes) + dir, @as(i32, settings_mod.axis_presets.len))),
        .fov => s.fov_deg = std.math.clamp(s.fov_deg + 4 * fd, 40, 130),
        .retina => s.stepRetina(dir),
        .opacity => s.base_alpha = std.math.clamp(s.base_alpha + 0.02 * fd, 0, 1),
        .edges => s.edge_gain = std.math.clamp(s.edge_gain + 0.1 * fd, 0, 2),
        .slab => s.slab = std.math.clamp(s.slab + 0.05 * fd, 0, 1),
        .shadows => s.shadows = !s.shadows,
        .room => s.room = !s.room,
        .labels => s.labels = !s.labels,
        .mouse_sens => s.mouse_sens = std.math.clamp(s.mouse_sens + 0.1 * fd, 0.1, 5),
        .invert_y => s.invert_y = !s.invert_y,
        .reset_controls => s.bindings = settings_mod.default_bindings,
    }
    return .none;
}
