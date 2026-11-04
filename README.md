# 4D Space Explorer

Fly a spaceship through a small solar system in four spatial dimensions.
Written in Zig (host: physics, input, HUD) and AMD HIP (GPU: rendering),
following the pattern of `~/Documents/zig-hip`: kernels are compiled with
`hipcc --genco` and loaded at runtime; HIP and SDL2 are called through
hand-written `extern fn`s.

```sh
nix develop
zig build run                 # default arch gfx1032; -Doffload-arch=<gfx...> for others
zig build test                # CPU unit tests: 4D math, noise, physics
zig build gpucheck            # CPU and GPU terrain functions agree
```

## Browser version

The same game runs in the browser via WebAssembly and WebGPU:

```sh
zig build web       # static site in zig-out/web/
zig build serve     # ...and serve it on http://localhost:8000
zig build webcheck -- --check   # headless check (Deno WebGPU): WGSL vs Zig terrain
```

`zig-out/web/` holds five files (`index.html`, `app.js`, `gpu.js`,
`shaders.wgsl`, `space4d.wasm`, about 200 KB in all) and needs no server-side
support, so it can be uploaded to any static host. On Neocities, upload the
folder's contents. `.wasm` isn't on the free tier's file-type list, but
supporter accounts can upload it.

To publish into a site repository, run `nix develop -c tools/publish.sh
../neocities-pa255ion`. It builds the web version, copies it into
`4d-space-explorer/` in the site, and stamps the commit hash into the file
URLs (`app.js?v=…`), so caches never serve a visitor a mix of old and new
files. Then commit and push the site and upload it with the site repo's
`./deploy.sh` (`--dry-run` first to see the list). It uploads only files git
tracks and never `.git/`; avoid `neocities push .`, which walks the whole
directory, `.git/` included.

- **Same game, different frontend.** All logic (physics, menu, bindings, HUD)
  is the shared Zig code in `src/game.zig`, compiled to wasm by `src/web.zig`.
  `web/app.js` only forwards raw input and runs the GPU passes.
  `web/shaders.wgsl` is a port of `src/kernels.hip`; keep the two in sync.
- **Needs WebGPU**: current Chrome or Edge, Safari 26+, or Firefox on Windows.
  Other browsers get a message instead of the game. On Linux, Chromium-based
  browsers (Chrome, Brave, Edge) need four flags in `chrome://flags` /
  `brave://flags`: `#enable-unsafe-webgpu`, `#enable-vulkan`, `#use-angle` =
  Vulkan and `#ignore-gpu-blocklist`. With fewer, Brave Origin 1.98 and
  Chromium 156 give no adapter or the software renderer.
  - **Security:** "Unsafe WebGPU" enables WebGPU for every site, on a GPU
    stack the browser hasn't finished reviewing; "Override software rendering
    list" uses drivers the browser has blocked. A malicious page could
    exploit WebGPU or driver bugs. Prefer a separate browser instance with its
    own profile for this (e.g. `brave-browser --user-data-dir=...
    --enable-unsafe-webgpu --enable-features=Vulkan --use-angle=vulkan
    --ignore-gpu-blocklist`), or turn the flags off afterwards. The page
    explains this too.
  - **Software rendering:** without GPU access, the unsafe flag can give
    Chromium's CPU renderer (SwiftShader). The game detects that, warns on
    the HUD and starts at the lowest settings, but it will still be slow.
  - **Diagnostics:** the console logs the WebGPU adapter in use. Typing
    `space4d` in the console shows the adapter, rendered and skipped frames,
    and the last frame's GPU time.
- **Differences from native.**
  - Thrust down defaults to **Z** rather than Ctrl, since Ctrl+W closes the tab.
  - Esc only releases the mouse; click the view to capture it again.
  - Settings are saved in the browser's local storage.
  - The retina resolution goes up to 96³.
- **GRAPHICS QUALITY: LOW** (menu, native too) caps terrain detail at 5
  octaves with a coarser LOD, turns off shadows and floor reflections, takes
  fewer, looser ray steps and halves the cube's compositing samples. That
  halves the frame time at the same resolution, and the new 32³ retina size
  goes much further. Collision still uses the full-detail terrain, so landed
  ships can sit a few metres off the smoothed surface.
- **RENDER RESOLUTION** (menu, web only) defaults to AUTO, which adapts to
  the visitor's GPU. In slice view it lowers the pixel count, because that
  view's cost grows with pixels. In cube view it lowers the retina
  resolution instead (capped by RETINA RESOLUTION), because the N³ rays
  dominate there and compositing is cheap. The HUD shows what is in use. If
  frames stay under 30 FPS at the lowest level, it switches to low quality
  once and says so.

## How to read the retina cube

An ordinary 3D camera loses one dimension. Rays fan out from the eye
through a **2D** film, so a 3D world becomes a 2D picture, and depth survives
only as cues like perspective, shading and occlusion.

A 4D eye does the same thing one dimension up. Its rays fan out through a
**3D** film, so the 4D world becomes a 3D picture: the retina cube. Every
voxel is one pixel of that picture, and its colour is whatever the ray in
that direction hits.

- Left/right and up/down in the cube mean what they do in a normal picture:
  rays aimed further right or further up.
- The cube's **depth** axis is *not* distance. It's the 4th direction of
  aim: voxels on the ANA face look slightly toward ana, voxels on the KATA
  face slightly toward kata. Distance is lost, exactly as in a photo.
- The **middle layer** (s = 0) is the ordinary 3D view, the rays in your
  right/up/forward hyperplane. That's what slice view (V) shows. The cube is
  that view plus all its neighbours tilted into ana and kata, stacked.
- A 4D creature would see every voxel at once, including the inside. We
  can't, so the cube is drawn semi-transparent with outlines boosted, and you
  look at it from outside. Walking around it or orbiting it (right-drag)
  changes only *your* view of the picture, never what the ship sees.

Examples:
- **Flying low over terrain.** The ground below you is a 3D hyperplane, so it
  fills the whole bottom half of the cube, through its full depth: a solid
  slab, not a flat strip.
- **A planet off to one side in ana.** It shows up as a blob pushed toward
  the cube's ANA face. Turn toward it (I/K) and the blob slides to the middle
  layer.
- **A planet's horizon.** It's a 2D surface curving through the cube, the 4D
  counterpart of the horizon line in a photo.

Rule of thumb: start in slice view, then widen the slab (mouse wheel) and
watch the extra layers appear around the familiar picture.

## Views and the room

- **V** switches between the retina cube and slice view.
- **B** (or the menu) picks which three ship axes the view shows, in X=right,
  Y=up, Z=forward, W=ana terms: XYZ, XY-ANA, X-ANA-Z or ANA-YZ. The left-over
  axis becomes the cube's depth. In XY-ANA you look along ana while still
  flying forward.
- The cube floats over a pedestal in an observatory. **C** gets up from the
  helm and lets you walk the room with the movement keys and mouse
  (Space/Ctrl raise or lower your eyes, Shift runs). The ship keeps flying
  (assist holds it). Press **C** again to return. At the helm, right-drag
  orbits the cube.
- The mouse wheel sets the slab thickness (how much of the cube's depth is
  shown). The yellow ring marks the target planet's centre.

## Options menu (`)

Opens with the backtick key: arrows navigate and change values, Enter
activates or rebinds, and Esc or ` closes. It covers planet motion, time
warp, crash speed, pausing while the menu is open, resetting the solar
system, view and axes, FOV, retina resolution, opacity, edges, slab, shadows,
the room, face labels, mouse sensitivity and invert, and every key binding.
Settings are saved to `~/.config/space4d.cfg`.

## Physics

- Gravity obeys Gauss's law in four spatial dimensions: `a = GM/r³`, with
  potential `-GM/(2r²)`. As a result, circular-orbit speed equals escape speed
  (`√GM / r`), and circular orbits are neutrally unstable. Any error spirals
  you in or out.
- Because 1/r³ gravity has such a short reach, the sun is very heavy (1 m/s²
  of pull at TERRA's 60 km orbit) and the planets sit 40–70 km apart. That
  keeps each planet's motion sun-dominated, with mutual pulls under 2%.
- **Planet motion** (menu):
  - *Static*: planets fixed in place.
  - *Rails*: exact circular orbits of 14–26 minutes. Planets don't feel each
    other, but the ship feels every body.
  - *N-body*: full mutual gravity. It starts on the same circles and drifts
    slowly, because 4D has no stable orbits.
  - Switching mode carries you along with the nearest planet.
- The ship is Newtonian, with bounded thrust on its four axes (main engine
  40 m/s², RCS 25 m/s²) and angular velocity in all six rotation planes,
  integrated at 240 Hz. Time warp runs more steps; it never makes them bigger.
- **Flight assist** (Tab) uses the same thrusters to null your velocity
  relative to the nearest body (the HUD's REF) and to cancel gravity relative
  to that body's own free fall. With assist off, rotation keys apply angular
  acceleration and spin persists.
- Contact uses the touched body's frame, so you can land on and ride along
  with an orbiting planet. Touching down faster than the crash speed
  (default 12 m/s) is a crash.

## Default controls

| Key | Action |
| --- | --- |
| W / S, A / D | thrust forward / back, strafe |
| Space / Ctrl (web: Z) | thrust up / down |
| R / F | thrust ana / kata (the 4th axis) |
| Shift | boost ×8 |
| Mouse or arrows | yaw, pitch |
| Q / E | roll |
| I / K | turn forward toward ana / kata |
| J / L | turn right toward kata / ana |
| U / O | turn up toward ana / kata |
| Tab | flight assist on/off |
| V / B | retina / slice view; cycle view axes |
| C | walk the observatory room |
| Right-drag, wheel | orbit the cube; slab thickness |
| - / =, [ / ] | surface opacity; retina resolution |
| T, H | cycle target; shadows |
| Backspace | respawn |
| ` | options menu |
| Esc | release mouse; again to quit |

## Touch screens and gamepads

**Touch** (web; phones, tablets, and the Meta Quest browser's laser pointer):
the on-screen controls appear with the first touch.

- Left side: a floating stick for thrust and strafe (it walks you in the
  room).
- Right side: drag to look. With ORBIT on, dragging orbits the cube.
- Buttons for UP/DOWN, ANA/KATA, BOOST and ROLL. The top row has MENU,
  VIEW, AXES, ROOM, TGT and FULL (fullscreen, landscape on phones).
- **4D** mode turns the stick into ana/kata thrust and the right-to-ana
  turn. Drags then turn forward and up into ana.
- In the menu, tap a row to select it and tap it again to change it. Drag to
  move through the list. The buttons on the right stand in for the arrow
  keys.
- On the Quest only one laser acts at a time, so you can't hold the stick
  and look at once. Use VR (below) for real controller input.

**VR** (web, experimental): under the view, a status line says whether VR
is available and why not. When it is, ENTER VR puts you in the observatory
around the cube at real scale, standing on its floor 2.6 m in front of it.
Walk around it physically, and fly the ship with the controllers:

- Left stick: thrust and strafe. Right stick: look.
- Left / right trigger: down / up. Left / right grip: kata / ana.
- A: boost. B: view. X: flight assist. Y: cycle view axes.
- Left stick click: 4D mode (the right stick then turns toward ana).
  Right stick click: next target.

It needs WebXR with the WebGPU binding. On Meta Quest that means Quest
Browser 146+ with "WebXR experimental features" enabled in `chrome://flags`.
VR runs in low quality and adapts the per-eye resolution, then the retina
(48–64³), to the headset's frame rate. There's no HUD or menu in VR yet.
Leave VR to change settings.

**Gamepads** (web through the Gamepad API, desktop through SDL; standard
Xbox/PlayStation layout):

| Input | Action |
| --- | --- |
| Left stick | thrust forward/back, strafe |
| Right stick | look (in 4D mode: turn right / up toward ana) |
| LT / RT | thrust down / up |
| LB / RB | thrust kata / ana |
| A (hold) | boost |
| B / X / Y | retina/slice view, assist, cycle view axes |
| D-pad up/down | turn forward toward ana / kata |
| D-pad left/right | roll |
| L3 / R3 | 4D mode / next target |
| Back / Start | walk the room / menu |

In the menu, the D-pad navigates (it repeats when held), A selects, B or
Start closes, and LB/RB page.

## Headless screenshots

`space4d --shot out.ppm` renders one frame without opening a window. Options:
`--slice`, `--n N`, `--slab S`, `--opacity A`,
`--spawn PLANET ALT`, `--sim SECONDS`, `--turn A B ANGLE` (rotate local axis B
toward A; 0=right 1=up 2=fwd 3=ana), `--target I`, `--no-shadows`,
`--axes K`, `--motion static|rails|nbody`, `--low`, `--obs YAW PITCH DIST` (orbit
view), `--eye X Y Z YAW PITCH` (standing in the room), `--no-room`, `--menu`.

## Files

- `src/kernels.hip`: 4D terrain, raymarcher, retina → volume, observatory room + compositor, slice view.
- `src/world.zig`: planets, GPU-shared structs, CPU mirror of the terrain function.
- `src/system.zig`: static / rails / N-body motion of the bodies (+ tests).
- `src/settings.zig`, `src/menu.zig`: options, key bindings, config file, the ` menu.
- `src/observer.zig`: the 3D observer in the room (+ tests).
- `src/physics.zig`: gravity, thrusters, assist, collision (+ tests).
- `src/math4.zig`: 4D vectors and rotation frames (+ tests).
- `src/render.zig`: HIP module/buffers/launches.
- `src/game.zig`: platform-independent game: state, input handling, simulation step, GPU params, HUD.
- `src/touch.zig`, `src/pad.zig`: on-screen touch controls and gamepad mapping (+ tests).
- `src/main.zig`: native frontend (SDL window, HIP renderer, headless screenshots).
- `src/web.zig`: browser frontend (wasm exports, auto quality).
- `web/`: page, JS plumbing (`app.js` DOM/input, `gpu.js` WebGPU), `shaders.wgsl`.
- `tools/webcheck.js`: headless WebGPU test of the web build (Deno).
- `src/hud.zig`: built-in 5×7 bitmap font.
- `src/hip.zig`, `src/sdl.zig`: hand-written C API bindings.
