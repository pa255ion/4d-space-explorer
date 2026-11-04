const std = @import("std");
const settings_mod = @import("settings.zig");
const menu_mod = @import("menu.zig");
const game_mod = @import("game.zig");
const Action = settings_mod.Action;
const Analog = game_mod.Analog;
const Game = game_mod.Game;

// ---------------------------------------------------------------------------
// Gamepads, in the W3C "standard" layout (the browser Gamepad API's; the SDL
// frontend converts to it). Flying:
//   left stick    thrust forward/back, strafe (walks in room mode)
//   right stick   look (in 4D mode: turn right / up toward ana)
//   LT / RT       thrust down / up          LB / RB   thrust kata / ana
//   A (hold)      boost                     B         retina / slice view
//   X             flight assist             Y         cycle view axes
//   D-pad up/down turn forward toward ana / kata
//   D-pad l/r     roll                      L3        4D mode on/off
//   R3            next target               Back      walk the room
//   Start         menu
// In the menu: D-pad navigates (repeats when held), A = enter, B or Start
// closes, LB/RB page.
// ---------------------------------------------------------------------------

pub const n_axes = 4;
pub const n_buttons = 17;

pub const B = struct {
    pub const a = 0;
    pub const b = 1;
    pub const x = 2;
    pub const y = 3;
    pub const lb = 4;
    pub const rb = 5;
    pub const lt = 6;
    pub const rt = 7;
    pub const back = 8;
    pub const start = 9;
    pub const l3 = 10;
    pub const r3 = 11;
    pub const up = 12;
    pub const down = 13;
    pub const left = 14;
    pub const right = 15;
};

const deadzone: f32 = 0.15;
const look_speed: f32 = 900; // mouse pixels per second at full deflection

pub const Output = struct {
    analog: Analog = .{},
    /// Keys to press this frame (SDL scancodes, through the normal key path).
    presses: [8]u16 = undefined,
    n: usize = 0,

    fn press(self: *Output, sc: u16) void {
        if (self.n < self.presses.len) {
            self.presses[self.n] = sc;
            self.n += 1;
        }
    }
};

/// Radial deadzone, rescaled so motion starts smoothly at its edge.
fn stick(x: f32, y: f32) [2]f32 {
    const l = @sqrt(x * x + y * y);
    if (l < deadzone) return .{ 0, 0 };
    const k = @min((l - deadzone) / (1 - deadzone), 1) / l;
    return .{ x * k, y * k };
}

pub const Pad = struct {
    connected: bool = false,
    mode4d: bool = false,
    prev: [n_buttons]bool = [_]bool{false} ** n_buttons,
    repeat_t: [n_buttons]f32 = [_]f32{0} ** n_buttons,

    /// One frame of pad state: `axes` = left x, left y, right x, right y
    /// (y down), `buttons` 0..1 (triggers analog).
    pub fn update(self: *Pad, g: *const Game, axes: [n_axes]f32, buttons: [n_buttons]f32, dt: f32) Output {
        var out = Output{};
        self.connected = true;
        var now: [n_buttons]bool = undefined;
        for (buttons, 0..) |v, i| now[i] = v > 0.5;
        const pressedNow = struct {
            fn f(p: *const Pad, n: *const [n_buttons]bool, i: usize) bool {
                return n[i] and !p.prev[i];
            }
        }.f;
        defer self.prev = now;

        if (g.menu.open) {
            const nav = [_][2]u16{
                .{ B.up, menu_mod.sc_keys.up },     .{ B.down, menu_mod.sc_keys.down },
                .{ B.left, menu_mod.sc_keys.left }, .{ B.right, menu_mod.sc_keys.right },
            };
            for (nav) |m| {
                const i = m[0];
                if (pressedNow(self, &now, i)) {
                    out.press(m[1]);
                    self.repeat_t[i] = 0.35;
                } else if (now[i]) {
                    self.repeat_t[i] -= dt;
                    if (self.repeat_t[i] <= 0) {
                        out.press(m[1]);
                        self.repeat_t[i] = 0.08;
                    }
                }
            }
            if (pressedNow(self, &now, B.a)) out.press(menu_mod.sc_keys.enter);
            if (pressedNow(self, &now, B.b) or pressedNow(self, &now, B.start)) out.press(menu_mod.grave);
            if (pressedNow(self, &now, B.lb)) out.press(75); // page up
            if (pressedNow(self, &now, B.rb)) out.press(78); // page down
            return out;
        }

        const taps = [_]struct { b: usize, a: Action }{
            .{ .b = B.b, .a = .view },        .{ .b = B.x, .a = .assist },
            .{ .b = B.y, .a = .view_axes },   .{ .b = B.back, .a = .room_mode },
            .{ .b = B.r3, .a = .target },
        };
        for (taps) |t| if (pressedNow(self, &now, t.b)) out.press(@intCast(g.s.key(t.a)));
        if (pressedNow(self, &now, B.start)) out.press(menu_mod.grave);
        if (pressedNow(self, &now, B.l3)) self.mode4d = !self.mode4d;

        const l = stick(axes[0], axes[1]);
        const r = stick(axes[2], axes[3]);
        const f = struct {
            fn f(b: bool) f64 {
                return if (b) 1 else 0;
            }
        }.f;
        var an = &out.analog;
        an.thrust = .{
            l[0],
            @as(f64, buttons[B.rt]) - @as(f64, buttons[B.lt]),
            -l[1],
            f(now[B.rb]) - f(now[B.lb]),
        };
        an.boost = now[B.a];
        an.roll = f(now[B.right]) - f(now[B.left]);
        an.turn_fwd_ana = f(now[B.up]) - f(now[B.down]);
        if (self.mode4d) {
            an.turn_right_ana = r[0];
            an.turn_up_ana = -r[1];
        } else {
            // Squared response: fine aim near the centre, fast turns at the edge.
            an.look = .{ r[0] * @abs(r[0]) * look_speed * dt, r[1] * @abs(r[1]) * look_speed * dt };
        }
        return out;
    }
};

test "pad maps sticks and triggers, buttons press once" {
    var g = Game.init(.{});
    var p = Pad{};
    var btn = [_]f32{0} ** n_buttons;
    btn[B.rt] = 1;
    btn[B.x] = 1;
    var o = p.update(&g, .{ 0, -1, 0, 0 }, btn, 1.0 / 60.0);
    try std.testing.expectApproxEqAbs(@as(f64, 1), o.analog.thrust[2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 1), o.analog.thrust[1], 1e-6);
    try std.testing.expectEqual(@as(usize, 1), o.n);
    try std.testing.expectEqual(@as(u16, @intCast(g.s.key(.assist))), o.presses[0]);
    o = p.update(&g, .{ 0.05, 0, 0, 0 }, btn, 1.0 / 60.0); // held: no repeat; inside deadzone
    try std.testing.expectEqual(@as(usize, 0), o.n);
    try std.testing.expectEqual(@as(f64, 0), o.analog.thrust[0]);
}
