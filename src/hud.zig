const std = @import("std");

// ---------------------------------------------------------------------------
// HUD text: a built-in 5x7 bitmap font drawn straight into the RGBA frame.
// ---------------------------------------------------------------------------

const Glyph = [7]u8; // one row per byte, bit 4 = leftmost column

fn g(comptime rows: []const u8) Glyph {
    var out: Glyph = undefined;
    var row: usize = 0;
    var bits: u8 = 0;
    var n: usize = 0;
    for (rows) |c| {
        if (c == ' ') continue;
        bits = (bits << 1) | @intFromBool(c == '#');
        n += 1;
        if (n == 5) {
            out[row] = bits;
            row += 1;
            bits = 0;
            n = 0;
        }
    }
    if (row != 7) @compileError("glyph needs 7 rows of 5");
    return out;
}

const font = blk: {
    @setEvalBranchQuota(100_000);
    var f = [_]?Glyph{null} ** 128;
    f['A'] = g(".###. #...# #...# ##### #...# #...# #...#");
    f['B'] = g("####. #...# #...# ####. #...# #...# ####.");
    f['C'] = g(".###. #...# #.... #.... #.... #...# .###.");
    f['D'] = g("####. #...# #...# #...# #...# #...# ####.");
    f['E'] = g("##### #.... #.... ####. #.... #.... #####");
    f['F'] = g("##### #.... #.... ####. #.... #.... #....");
    f['G'] = g(".###. #...# #.... #.### #...# #...# .####");
    f['H'] = g("#...# #...# #...# ##### #...# #...# #...#");
    f['I'] = g(".###. ..#.. ..#.. ..#.. ..#.. ..#.. .###.");
    f['J'] = g("..### ...#. ...#. ...#. ...#. #..#. .##..");
    f['K'] = g("#...# #..#. #.#.. ##... #.#.. #..#. #...#");
    f['L'] = g("#.... #.... #.... #.... #.... #.... #####");
    f['M'] = g("#...# ##.## #.#.# #.#.# #...# #...# #...#");
    f['N'] = g("#...# #...# ##..# #.#.# #..## #...# #...#");
    f['O'] = g(".###. #...# #...# #...# #...# #...# .###.");
    f['P'] = g("####. #...# #...# ####. #.... #.... #....");
    f['Q'] = g(".###. #...# #...# #...# #.#.# #..#. .##.#");
    f['R'] = g("####. #...# #...# ####. #.#.. #..#. #...#");
    f['S'] = g(".#### #.... #.... .###. ....# ....# ####.");
    f['T'] = g("##### ..#.. ..#.. ..#.. ..#.. ..#.. ..#..");
    f['U'] = g("#...# #...# #...# #...# #...# #...# .###.");
    f['V'] = g("#...# #...# #...# #...# #...# .#.#. ..#..");
    f['W'] = g("#...# #...# #...# #.#.# #.#.# #.#.# .#.#.");
    f['X'] = g("#...# #...# .#.#. ..#.. .#.#. #...# #...#");
    f['Y'] = g("#...# #...# #...# .#.#. ..#.. ..#.. ..#..");
    f['Z'] = g("##### ....# ...#. ..#.. .#... #.... #####");
    f['0'] = g(".###. #...# #..## #.#.# ##..# #...# .###.");
    f['1'] = g("..#.. .##.. ..#.. ..#.. ..#.. ..#.. .###.");
    f['2'] = g(".###. #...# ....# ...#. ..#.. .#... #####");
    f['3'] = g("##### ...#. ..#.. ...#. ....# #...# .###.");
    f['4'] = g("...#. ..##. .#.#. #..#. ##### ...#. ...#.");
    f['5'] = g("##### #.... ####. ....# ....# #...# .###.");
    f['6'] = g("..##. .#... #.... ####. #...# #...# .###.");
    f['7'] = g("##### ....# ...#. ..#.. .#... .#... .#...");
    f['8'] = g(".###. #...# #...# .###. #...# #...# .###.");
    f['9'] = g(".###. #...# #...# .#### ....# ...#. .##..");
    f['.'] = g("..... ..... ..... ..... ..... .##.. .##..");
    f[','] = g("..... ..... ..... ..... .##.. ..#.. .#...");
    f['-'] = g("..... ..... ..... ##### ..... ..... .....");
    f['+'] = g("..... ..#.. ..#.. ##### ..#.. ..#.. .....");
    f[':'] = g("..... .##.. .##.. ..... .##.. .##.. .....");
    f['/'] = g("..... ....# ...#. ..#.. .#... #.... .....");
    f['('] = g("...#. ..#.. .#... .#... .#... ..#.. ...#.");
    f[')'] = g(".#... ..#.. ...#. ...#. ...#. ..#.. .#...");
    f['['] = g(".###. .#... .#... .#... .#... .#... .###.");
    f[']'] = g(".###. ...#. ...#. ...#. ...#. ...#. .###.");
    f['='] = g("..... ..... ##### ..... ##### ..... .....");
    f['^'] = g("..#.. .#.#. #...# ..... ..... ..... .....");
    f['>'] = g(".#... ..#.. ...#. ....# ...#. ..#.. .#...");
    f['<'] = g("...#. ..#.. .#... #.... .#... ..#.. ...#.");
    f['%'] = g("##... ##..# ...#. ..#.. .#... #..## ...##");
    f['*'] = g("..... ..#.. #.#.# .###. #.#.# ..#.. .....");
    f['|'] = g("..#.. ..#.. ..#.. ..#.. ..#.. ..#.. ..#..");
    f['`'] = g(".#... ..#.. ..... ..... ..... ..... .....");
    f[';'] = g("..... .##.. .##.. ..... .##.. ..#.. .#...");
    f['\''] = g("..#.. ..#.. .#... ..... ..... ..... .....");
    f['\\'] = g("..... #.... .#... ..#.. ...#. ....# .....");
    f['?'] = g(".###. #...# ....# ...#. ..#.. ..... ..#..");
    break :blk f;
};

pub const Canvas = struct {
    pixels: []u8,
    width: usize,
    height: usize,

    pub fn put(self: Canvas, x: isize, y: isize, rgb: [3]u8) void {
        if (x < 0 or y < 0) return;
        const ux: usize = @intCast(x);
        const uy: usize = @intCast(y);
        if (ux >= self.width or uy >= self.height) return;
        const i = (uy * self.width + ux) * 4;
        self.pixels[i] = rgb[0];
        self.pixels[i + 1] = rgb[1];
        self.pixels[i + 2] = rgb[2];
        self.pixels[i + 3] = 255;
    }

    /// Darken a rectangle (backdrop behind text) to a third. Alpha follows
    /// premultiplied "over" rules, so on a transparent overlay (the web
    /// build) the result darkens whatever is drawn underneath the same way.
    pub fn shade(self: Canvas, x0: usize, y0: usize, w: usize, h: usize) void {
        var y = y0;
        while (y < @min(y0 + h, self.height)) : (y += 1) {
            var x = x0;
            while (x < @min(x0 + w, self.width)) : (x += 1) {
                const i = (y * self.width + x) * 4;
                for (0..3) |c| self.pixels[i + c] = self.pixels[i + c] / 3;
                self.pixels[i + 3] = 255 - (255 - self.pixels[i + 3]) / 3;
            }
        }
    }

    pub fn text(self: Canvas, x: isize, y: isize, scale: isize, rgb: [3]u8, s: []const u8) void {
        var cx = x;
        for (s) |ch0| {
            const ch = std.ascii.toUpper(ch0);
            if (ch < 128) if (font[ch]) |gl| {
                for (gl, 0..) |row, ry| for (0..5) |rx| {
                    if (row & (@as(u8, 0x10) >> @intCast(rx)) == 0) continue;
                    var dy: isize = 0;
                    while (dy < scale) : (dy += 1) {
                        var dx: isize = 0;
                        while (dx < scale) : (dx += 1) {
                            const px = cx + @as(isize, @intCast(rx)) * scale + dx;
                            const py = y + @as(isize, @intCast(ry)) * scale + dy;
                            self.put(px + 1, py + 1, .{ 0, 0, 0 });
                            self.put(px, py, rgb);
                        }
                    }
                };
            };
            cx += 6 * scale;
        }
    }

    pub fn ring(self: Canvas, cx: isize, cy: isize, r: f32, rgb: [3]u8) void {
        var a: f32 = 0;
        while (a < 6.2832) : (a += 0.05) {
            self.put(cx + @as(isize, @intFromFloat(@cos(a) * r)), cy + @as(isize, @intFromFloat(@sin(a) * r)), rgb);
        }
    }
};

/// Width in pixels of `s` at `scale`.
pub fn textWidth(s: []const u8, scale: usize) usize {
    return s.len * 6 * scale;
}
