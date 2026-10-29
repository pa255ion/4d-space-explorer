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

## What you're looking at

You are a 4D being, so your eye has a **3D retina**. Voxel `(u, v, s)` of the
retina sees along the 4D ray `fwd + tan(fov/2)·(u·right + v·up + s·ana)`.
The GPU raymarches all n³ retina rays, then the cube is volume-rendered onto
your 2D screen. Surfaces are semi-transparent and silhouettes (depth
discontinuities) are opaque and dark, so you can see into the whole volume.

- **Right-drag** orbits the retina cube to look at it from other angles.
- **Mouse wheel** thins the visible slab of the retina around `s = 0`. At zero
  thickness you see only the rays in your right/up/forward hyperplane — the
  ordinary 3D cross-section.
- **V** switches to that cross-section ("slice") view at full screen
  resolution, which is easier to fly with.
- The yellow ring marks the current target planet's center.

## Physics

- Gravity obeys Gauss's law in four spatial dimensions: `a = GM/r³`, with
  potential `-GM/(2r²)`. As a result, circular-orbit speed equals escape speed
  (`√GM / r`), and circular orbits are neutrally unstable. Any error spirals
  you in or out, so orbits need active correction.
- The ship is Newtonian. It has bounded thrust on its four axes (main engine
  40 m/s², RCS 25 m/s², both above Terra's 9.81 m/s²) and angular velocity in
  all six rotation planes. It's integrated with semi-implicit Euler at 240 Hz.
- **Flight assist** (Tab) drives the same thrusters to null your velocity and
  hold against gravity whenever you're not commanding an axis. It also turns
  the rotation keys into rate commands. With assist off, rotation keys apply
  angular acceleration and spin persists.
- Contact: touching down slower than 12 m/s lands (with Coulomb friction).
  Anything faster is a crash.

## Controls

| Key | Action |
| --- | --- |
| W / S | thrust forward / back |
| A / D | strafe left / right |
| Space / Ctrl | thrust up / down |
| R / F | thrust ana / kata (the 4th axis) |
| Shift | boost ×8 |
| Mouse | yaw, pitch |
| Q / E | roll |
| I / K | turn forward toward ana / kata |
| J / L | turn right toward ana / kata |
| U / O | turn up toward ana / kata |
| Tab | flight assist on/off |
| Right-drag | orbit the retina cube |
| Wheel | retina slab thickness |
| - / = | surface opacity |
| [ / ] | retina resolution (48–160) |
| V | retina / slice view |
| T | cycle target |
| H | shadows on/off |
| Backspace | respawn |
| F1 | help overlay |
| Esc | release mouse; again to quit |

## Headless screenshots

`space4d --shot out.ppm` renders one frame without opening a window. Options:
`--slice`, `--n N`, `--slab S`, `--opacity A`, `--obs YAW PITCH`,
`--spawn PLANET ALT`, `--sim SECONDS`, `--turn A B ANGLE` (rotate local axis B
toward A; 0=right 1=up 2=fwd 3=ana), `--target I`, `--no-shadows`.

## Files

- `src/kernels.hip`: 4D terrain, raymarcher, retina → volume, compositor, slice view.
- `src/world.zig`: planets, GPU-shared structs, CPU mirror of the terrain function.
- `src/physics.zig`: gravity, thrusters, assist, collision (+ tests).
- `src/math4.zig`: 4D vectors and rotation frames (+ tests).
- `src/render.zig`: HIP module/buffers/launches.
- `src/main.zig`: game loop, input, HUD, headless modes.
- `src/hud.zig`: built-in 5×7 bitmap font.
- `src/hip.zig`, `src/sdl.zig`: hand-written C API bindings.
