// ---------------------------------------------------------------------------
// Minimal hand-written SDL2 bindings: window + streaming texture for the
// frame, plus keyboard state and relative mouse input. No @cImport.
// ---------------------------------------------------------------------------

pub const SDL_INIT_VIDEO: u32 = 0x00000020;
pub const SDL_INIT_GAMECONTROLLER: u32 = 0x00002000;
pub const SDL_WINDOW_SHOWN: u32 = 0x00000004;
pub const SDL_WINDOWPOS_CENTERED: c_int = 0x2FFF0000;
pub const SDL_RENDERER_ACCELERATED: u32 = 0x00000002;
pub const SDL_RENDERER_PRESENTVSYNC: u32 = 0x00000004;
pub const SDL_TEXTUREACCESS_STREAMING: c_int = 1;

// Little-endian alias of SDL_PIXELFORMAT_ABGR8888: bytes land as r, g, b, a.
pub const SDL_PIXELFORMAT_RGBA32: u32 = 0x16762004;

pub const SDL_QUIT: u32 = 0x100;
pub const SDL_KEYDOWN: u32 = 0x300;
pub const SDL_MOUSEBUTTONDOWN: u32 = 0x401;
pub const SDL_MOUSEBUTTONUP: u32 = 0x402;
pub const SDL_MOUSEWHEEL: u32 = 0x403;

pub const SDL_BUTTON_LEFT: u8 = 1;
pub const SDL_BUTTON_RIGHT: u8 = 3;

/// SDL scancodes (USB HID usage IDs) for the keys we use.
pub const Scancode = struct {
    pub fn letter(comptime c: u8) usize {
        return 4 + (c - 'A');
    }
    pub const space = 44;
    pub const escape = 41;
    pub const backspace = 42;
    pub const tab = 43;
    pub const minus = 45;
    pub const equals = 46;
    pub const leftbracket = 47;
    pub const rightbracket = 48;
    pub const f1 = 58;
    pub const lctrl = 224;
    pub const lshift = 225;
};

/// SDL_Event is a 56-byte C union; we read the few variants we need at their
/// documented field offsets instead of translating the whole union.
pub const SDL_Event = extern struct {
    bytes: [64]u8 align(8) = undefined,

    pub fn kind(self: *const SDL_Event) u32 {
        return self.get(u32, 0);
    }
    /// SDL_KeyboardEvent: repeat at 13, keysym.scancode at 16.
    pub fn keyScancode(self: *const SDL_Event) i32 {
        return self.get(i32, 16);
    }
    pub fn keyRepeat(self: *const SDL_Event) bool {
        return self.bytes[13] != 0;
    }
    /// SDL_MouseWheelEvent: y at 20.
    pub fn wheelY(self: *const SDL_Event) i32 {
        return self.get(i32, 20);
    }
    /// SDL_MouseButtonEvent: button at 16.
    pub fn mouseButton(self: *const SDL_Event) u8 {
        return self.bytes[16];
    }
    fn get(self: *const SDL_Event, comptime T: type, comptime off: usize) T {
        return @as(*align(1) const T, @ptrCast(self.bytes[off..].ptr)).*;
    }
};

pub extern fn SDL_Init(flags: u32) c_int;

// Game controllers (polled; SDL_PollEvent keeps their state current).
pub const GameController = opaque {};
pub extern fn SDL_NumJoysticks() c_int;
pub extern fn SDL_IsGameController(index: c_int) c_int;
pub extern fn SDL_GameControllerOpen(index: c_int) ?*GameController;
pub extern fn SDL_GameControllerClose(c: *GameController) void;
pub extern fn SDL_GameControllerGetAttached(c: *GameController) c_int;
pub extern fn SDL_GameControllerGetAxis(c: *GameController, axis: c_int) i16;
pub extern fn SDL_GameControllerGetButton(c: *GameController, button: c_int) u8;
pub extern fn SDL_Quit() void;
pub extern fn SDL_GetError() [*:0]const u8;
pub extern fn SDL_CreateWindow(title: [*:0]const u8, x: c_int, y: c_int, w: c_int, h: c_int, flags: u32) ?*anyopaque;
pub extern fn SDL_DestroyWindow(window: ?*anyopaque) void;
pub extern fn SDL_CreateRenderer(window: ?*anyopaque, index: c_int, flags: u32) ?*anyopaque;
pub extern fn SDL_DestroyRenderer(renderer: ?*anyopaque) void;
pub extern fn SDL_CreateTexture(renderer: ?*anyopaque, format: u32, access: c_int, w: c_int, h: c_int) ?*anyopaque;
pub extern fn SDL_DestroyTexture(texture: ?*anyopaque) void;
pub extern fn SDL_UpdateTexture(texture: ?*anyopaque, rect: ?*const anyopaque, pixels: ?*const anyopaque, pitch: c_int) c_int;
pub extern fn SDL_RenderClear(renderer: ?*anyopaque) c_int;
pub extern fn SDL_RenderCopy(renderer: ?*anyopaque, texture: ?*anyopaque, srcrect: ?*const anyopaque, dstrect: ?*const anyopaque) c_int;
pub extern fn SDL_RenderPresent(renderer: ?*anyopaque) void;
pub extern fn SDL_PollEvent(event: *SDL_Event) c_int;
pub extern fn SDL_GetKeyboardState(numkeys: ?*c_int) [*]const u8;
pub extern fn SDL_SetRelativeMouseMode(enabled: c_int) c_int;
pub extern fn SDL_GetRelativeMouseState(x: *c_int, y: *c_int) u32;
pub extern fn SDL_GetPerformanceCounter() u64;
pub extern fn SDL_GetPerformanceFrequency() u64;
