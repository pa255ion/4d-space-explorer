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
| Space / Ctrl | thrust up / down |
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

## Headless screenshots

`space4d --shot out.ppm` renders one frame without opening a window. Options:
`--slice`, `--n N`, `--slab S`, `--opacity A`,
`--spawn PLANET ALT`, `--sim SECONDS`, `--turn A B ANGLE` (rotate local axis B
toward A; 0=right 1=up 2=fwd 3=ana), `--target I`, `--no-shadows`,
`--axes K`, `--motion static|rails|nbody`, `--obs YAW PITCH DIST` (orbit
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
- `src/main.zig`: game loop, input, HUD and face labels, headless modes.
- `src/hud.zig`: built-in 5×7 bitmap font.
- `src/hip.zig`, `src/sdl.zig`: hand-written C API bindings.
