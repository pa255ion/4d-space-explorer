const std = @import("std");
const hud = @import("hud.zig");
const settings_mod = @import("settings.zig");
const menu_mod = @import("menu.zig");
const game_mod = @import("game.zig");
const Action = settings_mod.Action;
const Analog = game_mod.Analog;
const Game = game_mod.Game;

// ---------------------------------------------------------------------------
// On-screen touch controls (phones, tablets, the Quest's laser pointer).
// Everything is in HUD coordinates (1280x720); the frontend converts.
//
//   left side:  a floating stick (thrust / strafe; in 4D mode ana/kata
//               thrust and the right<->ana turn)
//   right side: drag to look (in 4D mode: turn forward / up into ana),
//               buttons for up/down, ana/kata, boost and roll
//   top row:    menu, view, axes, room, target, fullscreen
//   bottom left: 4D mode, flight assist, cube orbit
//
// With the menu open, rows can be tapped (tap the selected row again to
// change it) and side buttons stand in for the arrow keys.
// ---------------------------------------------------------------------------

const Kind = union(enum) {
    hold: Action, // held while touched
    tap: Action, // pressed once
    menu,
    fullscreen,
    mode4d,
    orbit,
};

const Button = struct { label: []const u8, x: i32, y: i32, w: i32, h: i32, kind: Kind };

const bw = 104;
const bh = 60;
const gap = 8;
const top_y = 84;

fn topBtn(comptime i: i32, label: []const u8, kind: Kind) Button {
    return .{ .label = label, .x = 1280 - gap - (i + 1) * (bw + gap) + gap, .y = top_y, .w = bw, .h = 52, .kind = kind };
}

const buttons = [_]Button{
    topBtn(0, "MENU", .menu),
    topBtn(1, "VIEW", .{ .tap = .view }),
    topBtn(2, "AXES", .{ .tap = .view_axes }),
    topBtn(3, "ROOM", .{ .tap = .room_mode }),
    topBtn(4, "TGT", .{ .tap = .target }),
    topBtn(5, "FULL", .fullscreen),
    // thrust cluster, bottom right
    .{ .label = "ANA", .x = 1056, .y = 380, .w = bw, .h = bh, .kind = .{ .hold = .ana } },
    .{ .label = "UP", .x = 1168, .y = 380, .w = bw, .h = bh, .kind = .{ .hold = .up } },
    .{ .label = "KATA", .x = 1056, .y = 448, .w = bw, .h = bh, .kind = .{ .hold = .kata } },
    .{ .label = "DOWN", .x = 1168, .y = 448, .w = bw, .h = bh, .kind = .{ .hold = .down } },
    .{ .label = "BOOST", .x = 1056, .y = 516, .w = 2 * bw + gap, .h = bh, .kind = .{ .hold = .boost } },
    .{ .label = "ROLL L", .x = 1056, .y = 584, .w = bw, .h = bh, .kind = .{ .hold = .roll_left } },
    .{ .label = "ROLL R", .x = 1168, .y = 584, .w = bw, .h = bh, .kind = .{ .hold = .roll_right } },
    // bottom left
    .{ .label = "4D", .x = 16, .y = 652, .w = 88, .h = 56, .kind = .mode4d },
    .{ .label = "ASSIST", .x = 112, .y = 652, .w = 104, .h = 56, .kind = .{ .tap = .assist } },
    .{ .label = "ORBIT", .x = 224, .y = 652, .w = 104, .h = 56, .kind = .orbit },
};

// Menu stand-ins for the arrow keys, right of the menu panel.
const MenuBtn = struct { label: []const u8, y: i32, sc: u16 };
const menu_x = 1090;
const menu_w = 176;
const menu_buttons = [_]MenuBtn{
    .{ .label = "UP", .y = 120, .sc = menu_mod.sc_keys.up },
    .{ .label = "DOWN", .y = 196, .sc = menu_mod.sc_keys.down },
    .{ .label = "<", .y = 300, .sc = menu_mod.sc_keys.left },
    .{ .label = ">", .y = 376, .sc = menu_mod.sc_keys.right },
    .{ .label = "OK", .y = 480, .sc = menu_mod.sc_keys.enter },
    .{ .label = "CLOSE", .y = 584, .sc = menu_mod.grave },
};

const stick_home = [2]f32{ 200, 520 };
const stick_r: f32 = 90;
const stick_zone_x: f32 = 560; // touches starting left of this (and below the top row) drive the stick
const look_gain: f32 = 2.0; // HUD pixels -> mouse pixels

const Role = union(enum) { none, stick, look, button: usize, menu };

const Slot = struct {
    id: u32 = 0,
    used: bool = false,
    role: Role = .none,
    x: f32 = 0,
    y: f32 = 0,
    // menu drags: where the finger was when the cursor last moved
    anchor_y: f32 = 0,
};

pub const Result = struct {
    /// Press this key (an SDL scancode) through the normal key path.
    key: ?u16 = null,
    fullscreen: bool = false,
};

pub const Touch = struct {
    /// Set by the first touch; the controls are drawn from then on.
    enabled: bool = false,
    mode4d: bool = false,
    orbit: bool = false,
    slots: [10]Slot = [_]Slot{.{}} ** 10,
    stick_base: [2]f32 = stick_home,
    stick: [2]f32 = .{ 0, 0 },
    look_acc: [2]f32 = .{ 0, 0 },

    fn slot(self: *Touch, id: u32) ?*Slot {
        for (&self.slots) |*s| if (s.used and s.id == id) return s;
        return null;
    }

    fn hit(b: anytype, x: f32, y: f32) bool {
        const bx: f32 = @floatFromInt(b.x);
        const by: f32 = @floatFromInt(b.y);
        return x >= bx and x < bx + @as(f32, @floatFromInt(b.w)) and y >= by and y < by + @as(f32, @floatFromInt(b.h));
    }

    pub fn down(self: *Touch, g: *Game, id: u32, x: f32, y: f32) Result {
        self.enabled = true;
        g.menu.touch = true;
        var free: ?*Slot = null;
        for (&self.slots) |*s| if (!s.used) {
            free = s;
            break;
        };
        const s = free orelse return .{};
        s.* = .{ .id = id, .used = true, .x = x, .y = y, .anchor_y = y };

        if (g.menu.open) {
            s.role = .menu;
            for (menu_buttons) |b| {
                if (hit(.{ .x = menu_x, .y = b.y, .w = menu_w, .h = 68 }, x, y)) return .{ .key = b.sc };
            }
            // Waiting for a key to rebind: touches can't provide one, so cancel.
            if (g.menu.rebinding != null) return .{ .key = menu_mod.sc_keys.escape };
            if (g.menu.rowAt(1280, 720, x, y)) |idx| {
                if (idx == g.menu.cursor) {
                    // Tapping the selected row changes it (bindings: no-op).
                    if (!menu_mod.Menu.isBinding(idx)) return .{ .key = menu_mod.sc_keys.right };
                } else g.menu.cursor = idx;
            }
            return .{};
        }

        for (buttons, 0..) |b, i| if (hit(b, x, y)) {
            s.role = .{ .button = i };
            return switch (b.kind) {
                .hold => .{},
                .tap => |a| .{ .key = @intCast(g.s.key(a)) },
                .menu => .{ .key = menu_mod.grave },
                .fullscreen => .{ .fullscreen = true },
                .mode4d => blk: {
                    self.mode4d = !self.mode4d;
                    break :blk .{};
                },
                .orbit => blk: {
                    self.orbit = !self.orbit;
                    break :blk .{};
                },
            };
        };
        if (x < stick_zone_x and y > top_y + 60 and !self.stickActive()) {
            s.role = .stick;
            self.stick_base = .{ x, y };
            self.stick = .{ 0, 0 };
        } else {
            s.role = .look;
        }
        return .{};
    }

    pub fn move(self: *Touch, g: *Game, id: u32, x: f32, y: f32) Result {
        const s = self.slot(id) orelse return .{};
        var r = Result{};
        switch (s.role) {
            .stick => {
                var v = [2]f32{ (x - self.stick_base[0]) / stick_r, (y - self.stick_base[1]) / stick_r };
                const l = @sqrt(v[0] * v[0] + v[1] * v[1]);
                if (l > 1) v = .{ v[0] / l, v[1] / l };
                self.stick = v;
            },
            .look => {
                self.look_acc[0] += (x - s.x) * look_gain;
                self.look_acc[1] += (y - s.y) * look_gain;
            },
            .menu => {
                // Dragging through the menu moves the selection a row at a time.
                const step: f32 = 22;
                if (g.menu.open and g.menu.rebinding == null and @abs(y - s.anchor_y) >= step) {
                    r.key = if (y > s.anchor_y) menu_mod.sc_keys.down else menu_mod.sc_keys.up;
                    s.anchor_y += if (y > s.anchor_y) step else -step;
                }
            },
            else => {},
        }
        s.x = x;
        s.y = y;
        return r;
    }

    pub fn up(self: *Touch, id: u32) void {
        const s = self.slot(id) orelse return;
        if (s.role == .stick) {
            self.stick = .{ 0, 0 };
            self.stick_base = stick_home;
        }
        s.used = false;
    }

    /// Window lost focus or the browser cancelled every touch.
    pub fn clear(self: *Touch) void {
        for (&self.slots) |*s| s.used = false;
        self.stick = .{ 0, 0 };
        self.stick_base = stick_home;
        self.look_acc = .{ 0, 0 };
    }

    fn stickActive(self: *const Touch) bool {
        for (self.slots) |s| if (s.used and s.role == .stick) return true;
        return false;
    }

    fn held(self: *const Touch, a: Action) bool {
        for (self.slots) |s| if (s.used) switch (s.role) {
            .button => |i| switch (buttons[i].kind) {
                .hold => |h| if (h == a) return true,
                else => {},
            },
            else => {},
        };
        return false;
    }

    /// This frame's analog input (consumes the accumulated look movement).
    pub fn analog(self: *Touch) Analog {
        var an = Analog{};
        if (!self.enabled) return an;
        const f = struct {
            fn f(b: bool) f64 {
                return if (b) 1 else 0;
            }
        }.f;
        const sx: f64 = self.stick[0];
        const sy: f64 = -self.stick[1]; // screen y is down; push up = forward
        if (self.mode4d) {
            an.thrust = .{ 0, 0, 0, sy };
            an.turn_right_ana = sx;
            an.look4d = self.look_acc;
        } else {
            an.thrust = .{ sx, 0, sy, 0 };
            an.look = self.look_acc;
        }
        an.thrust[1] += f(self.held(.up)) - f(self.held(.down));
        an.thrust[3] += f(self.held(.ana)) - f(self.held(.kata));
        an.roll = f(self.held(.roll_right)) - f(self.held(.roll_left));
        an.boost = self.held(.boost);
        an.orbit = self.orbit;
        self.look_acc = .{ 0, 0 };
        return an;
    }

    pub fn draw(self: *const Touch, c: hud.Canvas, g: *const Game) void {
        if (!self.enabled) return;
        const dim = [3]u8{ 170, 185, 200 };
        const lit = [3]u8{ 110, 200, 255 };
        if (g.menu.open) {
            for (menu_buttons) |b| drawButton(c, menu_x, b.y, menu_w, 68, b.label, false, dim, lit);
            return;
        }
        for (buttons, 0..) |b, i| {
            const on = switch (b.kind) {
                .mode4d => self.mode4d,
                .orbit => self.orbit,
                else => self.pressed(i),
            };
            drawButton(c, b.x, b.y, b.w, b.h, b.label, on, dim, lit);
        }
        // Stick: base ring and knob.
        const bx: isize = @intFromFloat(self.stick_base[0]);
        const by: isize = @intFromFloat(self.stick_base[1]);
        const col = if (self.mode4d) lit else dim;
        c.ring(bx, by, stick_r, col);
        c.ring(bx, by, stick_r - 1, col);
        const kx: isize = @intFromFloat(self.stick_base[0] + self.stick[0] * stick_r);
        const ky: isize = @intFromFloat(self.stick_base[1] + self.stick[1] * stick_r);
        c.tint(kx - 26, ky - 26, 52, 52, col, 0.35);
        c.ring(kx, ky, 30, col);
        if (self.mode4d) {
            const msg = "4D MODE: STICK = ANA/KATA + TURN RIGHT TO ANA, DRAG = TURN INTO ANA";
            c.text(@intCast((c.width -| hud.textWidth(msg, 2)) / 2), 150, 2, lit, msg);
        }
    }

    fn pressed(self: *const Touch, i: usize) bool {
        for (self.slots) |s| if (s.used) switch (s.role) {
            .button => |j| if (j == i) return true,
            else => {},
        };
        return false;
    }
};

fn drawButton(c: hud.Canvas, x: i32, y: i32, w: i32, h: i32, label: []const u8, on: bool, dim: [3]u8, lit: [3]u8) void {
    c.tint(x, y, w, h, if (on) lit else .{ 10, 14, 20 }, if (on) 0.5 else 0.45);
    c.rect(x, y, w, h, if (on) lit else dim);
    const tw: i32 = @intCast(hud.textWidth(label, 2));
    c.text(x + @divTrunc(w - tw, 2), y + @divTrunc(h - 14, 2), 2, if (on) .{ 255, 255, 255 } else dim, label);
}

test "stick pushes forward, look drags accumulate, buttons hold" {
    var g = Game.init(.{});
    var t = Touch{};
    _ = t.down(&g, 1, 200, 520); // stick
    _ = t.move(&g, 1, 200, 520 - stick_r * 2); // full forward (clamped)
    _ = t.down(&g, 2, 800, 300); // look
    _ = t.move(&g, 2, 810, 300);
    _ = t.down(&g, 3, 1180, 400); // UP button
    const an = t.analog();
    try std.testing.expectApproxEqAbs(@as(f64, 1), an.thrust[2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 1), an.thrust[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 10 * look_gain), an.look[0], 1e-6);
    t.up(1);
    try std.testing.expectEqual(@as(f64, 0), t.analog().thrust[2]);
}

test "tap buttons press their bound key; menu rows select then change" {
    var g = Game.init(.{});
    var t = Touch{};
    const r = t.down(&g, 1, 1280 - gap - 2 * (bw + gap) + gap + 10, top_y + 10); // VIEW
    try std.testing.expectEqual(@as(?u16, @intCast(g.s.key(.view))), r.key);
    t.up(1);
    g.menu.open = true;
    g.menu.scroll = 0;
    const y_row2: f32 = 120 + 2 * 20 + 5; // item 2 (TIME WARP)
    _ = t.down(&g, 2, 640, y_row2);
    t.up(2);
    try std.testing.expectEqual(@as(usize, 2), g.menu.cursor);
    const again = t.down(&g, 3, 640, y_row2);
    try std.testing.expectEqual(@as(?u16, menu_mod.sc_keys.right), again.key);
}
