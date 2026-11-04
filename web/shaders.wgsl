// ---------------------------------------------------------------------------
// WebGPU port of src/kernels.hip (the browser build). Same scene, same
// terrain, same lighting; keep the two in sync. Differences from the HIP
// version:
//   - The RGBA retina volume is a premultiplied rgba16float 3D texture, so
//     the compositor's trilinear lookup is one hardware-filtered sample
//     (the HIP version filters 8 premultiplied voxels by hand: same result).
//   - The frame texture is allocated at the HUD size; a lower render scale
//     only uses its top-left width x height corner.
//   - No recursion in WGSL: the floor reflection calls a non-reflecting copy.
//   - `blit` composites the HUD overlay over the (upscaled) frame.
// tools/webcheck.js compares this file's terrain with the Zig CPU mirror.
// ---------------------------------------------------------------------------

const MAX_OCTAVES: f32 = 9.0;

// Byte layout = struct Body / struct Params in kernels.hip and world.zig.
// Only 4-byte-aligned members (arrays, no vec3/vec4), so there is no padding.
struct Body {
    c: array<f32, 4>,
    radius: f32,
    amp: f32,
    sea: f32,
    feature: f32,
    atmo_h: f32,
    atmo_rgb: array<f32, 3>,
    col_low: array<f32, 3>,
    col_mid: array<f32, 3>,
    col_high: array<f32, 3>,
    col_sea: array<f32, 3>,
    emissive: f32,
    seed: u32,
}

struct Params {
    right: array<f32, 4>,
    up: array<f32, 4>,
    fwd: array<f32, 4>,
    ana: array<f32, 4>,
    tan_half_fov: f32,
    n: i32,
    slab: f32,
    shadows: i32,
    sun_rgb: array<f32, 3>,
    sun_index: i32,
    num_bodies: i32,
    width: i32,
    height: i32,
    obs_pos: array<f32, 3>,
    obs_fwd: array<f32, 3>,
    obs_right: array<f32, 3>,
    obs_up: array<f32, 3>,
    obs_fov: f32,
    room: i32,
    base_alpha: f32,
    edge_gain: f32,
    marker: array<f32, 4>,
    bodies: array<Body, 8>,
}

@group(0) @binding(0) var<storage, read> P: Params;
@group(0) @binding(1) var<storage, read_write> retina: array<vec4f>;
@group(0) @binding(2) var vol_out: texture_storage_3d<rgba16float, write>;
@group(0) @binding(3) var vol_tex: texture_3d<f32>;
@group(0) @binding(4) var lin: sampler;
@group(0) @binding(5) var frame_out: texture_storage_2d<rgba8unorm, write>;

fn a4(a: array<f32, 4>) -> vec4f { return vec4f(a[0], a[1], a[2], a[3]); }
fn a3(a: array<f32, 3>) -> vec3f { return vec3f(a[0], a[1], a[2]); }
fn center(i: i32) -> vec4f { return a4(P.bodies[i].c); }
fn sun_rgb() -> vec3f { return a3(P.sun_rgb); }

fn smoothc(a: f32, b: f32, x: f32) -> f32 {
    let t = clamp((x - a) / (b - a), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

// ---------------------------------------------------------------------------
// Terrain (mirrored in world.zig)
// ---------------------------------------------------------------------------

fn hash4(x: i32, y: i32, z: i32, w: i32, seed: u32) -> u32 {
    var h = seed;
    h ^= bitcast<u32>(x) * 0x8da6b343u;
    h ^= bitcast<u32>(y) * 0xd8163841u;
    h ^= bitcast<u32>(z) * 0xcb1ab31fu;
    h ^= bitcast<u32>(w) * 0x165667b1u;
    h ^= h >> 15u;
    h *= 0x2c1b3c6du;
    h ^= h >> 12u;
    h *= 0x297a2d39u;
    h ^= h >> 15u;
    return h;
}

fn corner(i: vec4i, seed: u32) -> f32 {
    return f32(hash4(i.x, i.y, i.z, i.w, seed)) * (2.0 / 4294967296.0) - 1.0;
}

// Interpolate along x at one (y, z, w) corner offset.
fn xedge(i: vec4i, dy: i32, dz: i32, dw: i32, seed: u32, ux: f32) -> f32 {
    let a = corner(i + vec4i(0, dy, dz, dw), seed);
    let b = corner(i + vec4i(1, dy, dz, dw), seed);
    return a + (b - a) * ux;
}

fn yedge(i: vec4i, dz: i32, dw: i32, seed: u32, u: vec4f) -> f32 {
    let y0 = xedge(i, 0, dz, dw, seed, u.x);
    let y1 = xedge(i, 1, dz, dw, seed, u.x);
    return y0 + (y1 - y0) * u.y;
}

fn zedge(i: vec4i, dw: i32, seed: u32, u: vec4f) -> f32 {
    let z0 = yedge(i, 0, dw, seed, u);
    let z1 = yedge(i, 1, dw, seed, u);
    return z0 + (z1 - z0) * u.z;
}

// 4D value noise in [-1, 1], quintic interpolation over the 16 cell corners.
fn vnoise(p: vec4f, seed: u32) -> f32 {
    let f = floor(p);
    let i = vec4i(f);
    let t = p - f;
    let u = t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
    let w0 = zedge(i, 0, seed, u);
    let w1 = zedge(i, 1, seed, u);
    return w0 + (w1 - w0) * u.w;
}

fn terrain_height(bi: i32, dir: vec4f, octaves: i32) -> f32 {
    let seed = P.bodies[bi].seed;
    var p = dir * (P.bodies[bi].radius / P.bodies[bi].feature);
    var base = 0.0;
    var ridge = 0.0;
    var a = 1.0;
    var norm = 0.0;
    for (var i = 0; i < octaves; i++) {
        let n = vnoise(p, seed + u32(i));
        base += a * n;
        if (i >= 1) {
            let r = 1.0 - abs(vnoise(p * 0.5 + vec4f(5.2, 1.3, 7.7, 3.1), seed ^ 0x9e3779b9u));
            ridge += a * r * r;
        }
        norm += a;
        a *= 0.48;
        p = p * 2.03 + vec4f(1.7, 9.2, 3.4, 6.1);
    }
    base /= norm;
    ridge /= norm;
    let land = base * 1.6;
    let mountains = max(land + 0.05, 0.0) * ridge * 2.2;
    return P.bodies[bi].amp * (land + mountains);
}

// ---------------------------------------------------------------------------
// Scene distance
// ---------------------------------------------------------------------------

// mat: 0 terrain, 1 sea, 2 star. `shell`: d is only the distance to a body's
// bounding shell (a loose lower bound), not to an actual surface.
struct Hit {
    d: f32,
    body: i32,
    mat: i32,
    shell: bool,
}

fn lod_octaves(bi: i32, t: f32, footprint: f32) -> i32 {
    // Stop adding octaves once their wavelength is below ~2 retina voxels.
    let px = max(t * footprint, 0.05);
    let o = log2(P.bodies[bi].feature / (2.0 * px)) + 1.0;
    return i32(clamp(o, 1.0, MAX_OCTAVES));
}

// shadow = true is the variant for shadow rays: stars are skipped, the sea is
// skipped and terrain below sea level counts as being at sea level.
fn scene(p: vec4f, t: f32, footprint: f32, shadow: bool) -> Hit {
    var h = Hit(1e30, -1, 0, false);
    for (var i = 0; i < P.num_bodies; i++) {
        let emissive = P.bodies[i].emissive;
        if (shadow && emissive > 0.0) {
            continue;
        }
        let radius = P.bodies[i].radius;
        let amp = P.bodies[i].amp;
        let sea = P.bodies[i].sea;
        let rel = p - center(i);
        let r = length(rel);
        var d: f32;
        var mat = 0;
        var shell = false;
        if (emissive > 0.0 || amp <= 0.0) {
            d = r - radius;
            mat = select(0, 2, emissive > 0.0);
        } else {
            let bound = radius + amp * 2.6 + 1.0;
            if (r > bound + 10.0) {
                d = r - bound;
                shell = true;
            } else {
                var hgt = terrain_height(i, rel * (1.0 / r), lod_octaves(i, t, footprint));
                if (shadow && sea > -amp) {
                    hgt = max(hgt, sea);
                }
                d = (r - radius - hgt) * 0.5; // Lipschitz safety for steep noise
                if (!shadow && sea > -amp) {
                    let ds = r - radius - sea;
                    if (ds < d) {
                        d = ds;
                        mat = 1;
                    }
                }
            }
        }
        if (d < h.d) {
            h = Hit(d, i, mat, shell);
        }
    }
    return h;
}

fn march(ro: vec4f, rd: vec4f, tmax: f32, footprint: f32, out: ptr<function, Hit>) -> f32 {
    var t = 0.05;
    for (var i = 0; i < 220; i++) {
        let h = scene(ro + rd * t, t, footprint, false);
        if (h.d < 0.0008 * t + 0.01) {
            *out = h;
            return t;
        }
        t += h.d;
        if (t > tmax) {
            break;
        }
    }
    (*out).body = -1;
    return -1.0;
}

fn soft_shadow(ro: vec4f, rd: vec4f, footprint: f32, t0: f32, tmax: f32) -> f32 {
    var res = 1.0;
    var t = 0.5;
    for (var i = 0; i < 64; i++) {
        let h = scene(ro + rd * t, t0 + t, footprint, true);
        if (h.d < 0.002 * t) {
            return 0.0;
        }
        if (!h.shell) {
            res = min(res, 12.0 * h.d / t);
        }
        t += max(h.d, 0.2);
        if (t > tmax) {
            break;
        }
    }
    return clamp(res, 0.0, 1.0);
}

fn sun_pos() -> vec4f {
    if (P.sun_index >= 0) {
        return center(P.sun_index);
    }
    return vec4f(0.0);
}

// Sky radiance along a ray that escaped: atmosphere glow near planets + sun glare.
fn sky(rd: vec4f, tmax: f32) -> vec3f {
    var col = vec3f(0.004, 0.005, 0.012);
    let sunp = sun_pos();
    for (var i = 0; i < P.num_bodies; i++) {
        let c = center(i);
        let dc = length(c);
        let radius = P.bodies[i].radius;
        if (P.bodies[i].emissive > 0.0) {
            let ang = acos(clamp(dot(c, rd) / dc, -1.0, 1.0));
            let ar = asin(min(radius / dc, 1.0));
            col += sun_rgb() * (0.5 * ar * ar / (ang * ang + ar * ar * 0.3));
        } else if (P.bodies[i].atmo_h > 0.0) {
            let tc = min(dot(c, rd), tmax);
            let H = P.bodies[i].atmo_h;
            let graze = sqrt(1.5708 * radius * H);
            var column: f32;
            var pc: vec4f;
            if (tc <= 0.0) {
                let h0 = max(dc - radius, 0.0);
                let mu = -dot(c, rd) / dc;
                column = exp(-h0 / H) * min(H / max(mu, 1e-3), graze);
                pc = vec4f(0.0);
            } else {
                pc = rd * tc;
                let h0 = max(length(c - pc) - radius, 0.0);
                let hc = max(dc - radius, 0.0);
                column = exp(-h0 / H) * graze * (2.0 - exp(-(hc - h0) / H));
            }
            let tau = column * (0.3 / H);
            let upc = normalize(pc - c);
            let lit = 0.08 + max(dot(upc, normalize(sunp - pc)) + 0.15, 0.0);
            col += a3(P.bodies[i].atmo_rgb) * ((1.0 - exp(-tau)) * lit * 0.9);
        }
    }
    return col;
}

fn fdiff(bi: i32, q: vec4f, oct: i32, f0: f32) -> f32 {
    let rq = length(q);
    return (rq - P.bodies[bi].radius - terrain_height(bi, q * (1.0 / rq), oct)) - f0;
}

fn shade(ro: vec4f, rd: vec4f, t: f32, h: Hit, footprint: f32) -> vec3f {
    let bi = h.body;
    if (h.mat == 2) {
        return sun_rgb() * P.bodies[bi].emissive;
    }
    let radius = P.bodies[bi].radius;
    let amp = P.bodies[bi].amp;
    let sea = P.bodies[bi].sea;
    let p = ro + rd * t;
    let rel = p - center(bi);
    let r = length(rel);
    let up = rel * (1.0 / r);
    let oct = lod_octaves(bi, t, footprint);
    var n: vec4f;
    var hgt: f32;
    if (h.mat == 1 || amp <= 0.0) {
        n = up;
        hgt = sea;
    } else {
        let e = max(0.002 * t, 0.02);
        hgt = terrain_height(bi, up, oct);
        let f0 = r - radius - hgt;
        n = normalize(vec4f(
            fdiff(bi, rel + vec4f(e, 0.0, 0.0, 0.0), oct, f0),
            fdiff(bi, rel + vec4f(0.0, e, 0.0, 0.0), oct, f0),
            fdiff(bi, rel + vec4f(0.0, 0.0, e, 0.0), oct, f0),
            fdiff(bi, rel + vec4f(0.0, 0.0, 0.0, e), oct, f0)));
    }

    var albedo: vec3f;
    if (h.mat == 1) {
        albedo = a3(P.bodies[bi].col_sea);
    } else {
        let hn = (hgt - sea) / amp;
        let slope = 1.0 - dot(n, up);
        albedo = mix(a3(P.bodies[bi].col_low), a3(P.bodies[bi].col_mid), smoothc(0.05, 0.35, hn));
        albedo = mix(albedo, vec3f(0.33, 0.31, 0.3), smoothc(0.08, 0.25, slope));
        albedo = mix(albedo, a3(P.bodies[bi].col_high), smoothc(0.75, 1.05, hn) * (1.0 - smoothc(0.15, 0.35, slope)));
    }

    let sunp = sun_pos();
    let L = normalize(sunp - p);
    var diff = max(dot(n, L), 0.0);
    if (diff > 0.0 && P.shadows != 0) {
        var sun_r = 0.0;
        if (P.sun_index >= 0) {
            sun_r = P.bodies[P.sun_index].radius;
        }
        let to_sun = length(sunp - p) - sun_r;
        diff *= soft_shadow(p + n * max(0.003 * t, 0.05), L, footprint, t, to_sun);
    }
    let skyl = 0.06 + 0.06 * max(dot(n, up), 0.0);
    var col = albedo * (sun_rgb() * diff + vec3f(0.35, 0.45, 0.7) * skyl);
    if (h.mat == 1 && diff > 0.0) {
        let hv = normalize(L - rd);
        col += sun_rgb() * (pow(max(dot(n, hv), 0.0), 80.0) * 0.8);
    }

    // Aerial perspective: the planet's own atmosphere tints distant terrain.
    let atmo_h = P.bodies[bi].atmo_h;
    if (atmo_h > 0.0) {
        let fog = 1.0 - exp(-t / (atmo_h * 40.0));
        col = mix(col, a3(P.bodies[bi].atmo_rgb) * (0.3 + 0.7 * max(dot(up, L), 0.0)), fog * 0.85);
    }
    return col;
}

fn retina_dir(u: f32, v: f32, s: f32) -> vec4f {
    return normalize(a4(P.fwd) + (a4(P.right) * u + a4(P.up) * v + a4(P.ana) * s) * P.tan_half_fov);
}

fn tonemap(x0: f32) -> f32 {
    let x = x0 / (1.0 + x0 * 0.6) * 1.25; // soft shoulder
    return pow(clamp(x, 0.0, 1.0), 1.0 / 2.2); // gamma
}

fn tonemap3(c: vec3f) -> vec3f {
    return vec3f(tonemap(c.x), tonemap(c.y), tonemap(c.z));
}

// ---------------------------------------------------------------------------
// Retina kernels
// ---------------------------------------------------------------------------

fn vidx(i: i32, j: i32, k: i32, n: i32) -> i32 {
    return (k * n + j) * n + i;
}

// One thread per retina voxel. Output: rgb + depth (-1 = sky, -2 = outside slab).
@compute @workgroup_size(8, 8, 4)
fn march_retina(@builtin(global_invocation_id) id: vec3u) {
    let n = P.n;
    let i = i32(id.x);
    let j = i32(id.y);
    let k = i32(id.z);
    if (i >= n || j >= n || k >= n) {
        return;
    }
    let nf = f32(n);
    let u = ((f32(i) + 0.5) / nf) * 2.0 - 1.0;
    let v = 1.0 - ((f32(j) + 0.5) / nf) * 2.0;
    let s = ((f32(k) + 0.5) / nf) * 2.0 - 1.0;
    let idx = vidx(i, j, k, n);
    if (abs(s) > P.slab + 1.0 / nf) {
        retina[idx] = vec4f(0.0, 0.0, 0.0, -2.0);
        return;
    }
    let footprint = 2.0 * P.tan_half_fov / nf;
    let ro = vec4f(0.0);
    let rd = retina_dir(u, v, s);
    var h: Hit;
    let t = march(ro, rd, 2e5, footprint, &h);
    var c: vec3f;
    if (t > 0.0) {
        c = shade(ro, rd, t, h, footprint);
    } else {
        c = sky(rd, 2e5);
    }
    retina[idx] = vec4f(c, select(-1.0, t, t > 0.0 && h.mat != 2));
}

// Turn the retina into a premultiplied RGBA volume with silhouette emphasis.
@compute @workgroup_size(8, 8, 4)
fn retina_alpha(@builtin(global_invocation_id) id: vec3u) {
    let n = P.n;
    let i = i32(id.x);
    let j = i32(id.y);
    let k = i32(id.z);
    if (i >= n || j >= n || k >= n) {
        return;
    }
    let c = retina[vidx(i, j, k, n)];
    if (c.w == -2.0) {
        textureStore(vol_out, vec3i(i, j, k), vec4f(0.0));
        return;
    }
    var edge = 0.0;
    for (var q = 0; q < 6; q++) {
        var o = vec3i(0);
        o[q / 2] = select(1, -1, (q & 1) == 1);
        let a = vec3i(i, j, k) + o;
        if (any(a < vec3i(0)) || any(a >= vec3i(n))) {
            continue;
        }
        let tn = retina[vidx(a.x, a.y, a.z, n)].w;
        if (tn == -2.0) {
            continue;
        }
        if ((tn < 0.0) != (c.w < 0.0)) {
            edge = 1.0;
        } else if (c.w > 0.0) {
            edge = max(edge, abs(log(tn / c.w)) * 6.0);
        }
    }
    edge = clamp(edge, 0.0, 1.0);

    let lum = 0.3 * c.x + 0.6 * c.y + 0.1 * c.z;
    var a: f32;
    var shadek = 1.0;
    if (c.w < 0.0) {
        a = clamp(lum * 1.5, 0.0, 0.9) * P.base_alpha * 2.0;
    } else {
        a = clamp(P.base_alpha + P.edge_gain * edge, 0.0, 1.0);
        shadek = 1.0 - 0.6 * edge;
    }
    textureStore(vol_out, vec3i(i, j, k), vec4f(tonemap3(c.xyz * shadek) * a, a));
}

// Trilinear volume sample at voxel coordinates; returns straight rgb + alpha.
fn sample_vol(p: vec3f) -> vec4f {
    let nf = f32(P.n);
    let q = clamp(p, vec3f(0.5), vec3f(nf - 0.501));
    let s = textureSampleLevel(vol_tex, lin, q / nf, 0.0);
    if (s.w > 1e-5) {
        return vec4f(s.xyz / s.w, s.w);
    }
    return vec4f(0.0);
}

// ---------------------------------------------------------------------------
// The observatory (plain 3D; y up, cube [-1,1]^3 at the origin, metres)
// ---------------------------------------------------------------------------

const ROOM_X: f32 = 9.0;
const ROOM_FLOOR: f32 = -2.3;
const ROOM_CEIL: f32 = 3.5;
const PED_HALF: f32 = 0.55;
const PED_TOP: f32 = -1.45;

struct Box {
    hit: bool,
    t0: f32,
    t1: f32,
    face: i32,
}

fn box_hit(ro: vec3f, rd: vec3f, lo: vec3f, hi: vec3f) -> Box {
    var b = Box(false, -1e30, 1e30, 0);
    for (var a = 0; a < 3; a++) {
        let inv = 1.0 / rd[a];
        let ta = (lo[a] - ro[a]) * inv;
        let tb = (hi[a] - ro[a]) * inv;
        let tn = min(ta, tb);
        let tf = max(ta, tb);
        if (tn > b.t0) {
            b.t0 = tn;
            b.face = a;
        }
        b.t1 = min(b.t1, tf);
    }
    b.hit = b.t1 > max(b.t0, 0.0);
    return b;
}

// Front-to-back compositing of the retina volume along a ray, up to tmax.
fn composite_cube(ro: vec3f, rd: vec3f, tmax: f32) -> vec4f {
    let n = f32(P.n);
    var acc = vec4f(0.0);
    let b = box_hit(ro, rd, vec3f(-1.0, -1.0, -P.slab - 1.0 / n), vec3f(1.0, 1.0, P.slab + 1.0 / n));
    if (!b.hit) {
        return acc;
    }
    let t0 = max(b.t0, 0.0);
    let t1 = min(b.t1, tmax);
    let dt = 1.0 / n; // half a voxel (cube is 2 units wide)
    let vox = 2.0 / n;
    for (var t = t0 + dt * 0.5; t < t1; t += dt) {
        let p = ro + rd * t;
        let s = sample_vol(vec3f((p.x + 1.0) * 0.5 * n, (1.0 - p.y) * 0.5 * n, (p.z + 1.0) * 0.5 * n));
        let a = 1.0 - pow(1.0 - min(s.w, 0.999), dt / vox);
        let w = (1.0 - acc.w) * a;
        acc += vec4f(s.xyz * w, w);
        if (acc.w > 0.985) {
            break;
        }
    }
    return acc;
}

fn cube_frame(ro: vec3f, rd: vec3f, tmax: f32, lw: f32) -> f32 {
    let b = box_hit(ro, rd, vec3f(-1.0), vec3f(1.0));
    if (!b.hit) {
        return 0.0;
    }
    var k = 0.0;
    for (var e = 0; e < 2; e++) {
        let t = select(b.t1, b.t0, e == 0);
        if (t < 0.0 || t > tmax) {
            continue;
        }
        let p = abs(abs(ro + rd * t) - vec3f(1.0)) < vec3f(lw);
        let near = i32(p.x) + i32(p.y) + i32(p.z);
        if (near >= 2) {
            k = max(k, select(0.2, 0.45, e == 0));
        }
    }
    return k;
}

struct RoomHit {
    t: f32,
    p: vec3f,
    n: vec3f,
    kind: i32, // 0 floor, 1 ceiling, 2 wall, 3 pedestal
}

fn face_normal(axis: i32, rd: vec3f) -> vec3f {
    var n = vec3f(0.0);
    n[axis] = select(-1.0, 1.0, rd[axis] < 0.0);
    return n;
}

fn trace_room(ro: vec3f, rd: vec3f) -> RoomHit {
    var h: RoomHit;
    var best = 1e30;
    var axis = 0;
    let lo = vec3f(-ROOM_X, ROOM_FLOOR, -ROOM_X);
    let hi = vec3f(ROOM_X, ROOM_CEIL, ROOM_X);
    for (var a = 0; a < 3; a++) {
        let d = rd[a];
        let t = (select(lo[a], hi[a], d > 0.0) - ro[a]) / d;
        if (t < best) {
            best = t;
            axis = a;
        }
    }
    h.t = best;
    h.n = face_normal(axis, rd);
    h.kind = select(2, select(1, 0, rd.y < 0.0), axis == 1);
    let b = box_hit(ro, rd, vec3f(-PED_HALF, ROOM_FLOOR, -PED_HALF), vec3f(PED_HALF, PED_TOP, PED_HALF));
    if (b.hit && b.t0 > 0.0 && b.t0 < h.t) {
        h.t = b.t0;
        h.kind = 3;
        h.n = face_normal(b.face, rd);
    }
    h.p = ro + rd * h.t;
    return h;
}

fn hash2(x: i32, y: i32) -> f32 {
    return f32(hash4(x, y, 7, 3, 99u) & 0xffffu) / 65535.0;
}

// Three ceiling light strips (along z at x = -4, 0, 4) plus the cube's glow.
fn room_light(p: vec3f, n: vec3f) -> vec3f {
    var L = vec3f(0.22, 0.23, 0.27);
    for (var s = -1; s <= 1; s++) {
        let lp = vec3f(f32(s) * 4.0, ROOM_CEIL - 0.05, clamp(p.z, -ROOM_X + 1.0, ROOM_X - 1.0));
        let d = lp - p;
        let r2 = dot(d, d);
        let cosn = max(dot(n, d * inverseSqrt(r2)), 0.0);
        let cosl = max(-d.y * inverseSqrt(r2), 0.0);
        L += vec3f(1.0, 0.95, 0.88) * (55.0 * cosn * cosl / (r2 + 4.0));
    }
    let d = -p;
    let r2 = dot(d, d);
    L += vec3f(0.35, 0.55, 0.9) * (4.0 * max(dot(n, d * inverseSqrt(r2)), 0.0) / (r2 + 1.0));
    return L;
}

struct Surface {
    col: vec3f,
    gloss: f32,
}

fn room_surface(h: RoomHit) -> Surface {
    let p = h.p;
    let edge = min(ROOM_X - abs(p.x), ROOM_X - abs(p.z));
    var ao = 0.55 + 0.45 * smoothc(0.0, 1.5, edge);
    if (h.kind == 0) {
        // Dark glossy tiles with grout lines; occluded around the pedestal.
        let fx = p.x - floor(p.x);
        let fz = p.z - floor(p.z);
        let grout = min(min(fx, 1.0 - fx), min(fz, 1.0 - fz));
        let g = smoothc(0.008, 0.02, grout);
        let v = 0.85 + 0.3 * hash2(i32(floor(p.x)), i32(floor(p.z)));
        let pd = max(abs(p.x), abs(p.z)) - PED_HALF;
        ao *= 0.5 + 0.5 * smoothc(0.0, 0.8, pd);
        let base = mix(vec3f(0.02, 0.02, 0.025), vec3f(0.11, 0.115, 0.13) * v, g);
        return Surface(base * room_light(p, h.n) * ao, 0.85 * g);
    }
    if (h.kind == 1) {
        // Ceiling with emissive light strips.
        var strip = 0.0;
        for (var s = -1; s <= 1; s++) {
            strip = max(strip, 1.0 - smoothc(0.12, 0.18, abs(p.x - f32(s) * 4.0)));
        }
        strip *= 1.0 - smoothc(ROOM_X - 1.2, ROOM_X - 1.0, abs(p.z));
        return Surface(vec3f(0.03, 0.03, 0.035) * ao + vec3f(1.0, 0.95, 0.88) * (2.5 * strip), 0.0);
    }
    if (h.kind == 2) {
        // Panelled walls: dark wainscot, lighter upper panels, glowing baseboard.
        let u = select(p.x, p.z, abs(h.n.x) > 0.5);
        let hgt = p.y - ROOM_FLOOR;
        let fu = u / 1.5 - floor(u / 1.5);
        let seam = smoothc(0.0, 0.015, min(fu, 1.0 - fu));
        let rail = smoothc(0.01, 0.03, abs(hgt - 1.0));
        var base = select(vec3f(0.3, 0.31, 0.34), vec3f(0.12, 0.12, 0.135), hgt < 1.0);
        base *= 0.5 + 0.5 * seam * rail;
        var c = base * room_light(p, h.n) * ao;
        if (hgt < 0.06) {
            c += vec3f(0.15, 0.6, 0.85) * 1.2;
        }
        return Surface(c, 0.0);
    }
    // Pedestal: dark metal, glowing rim at the top.
    var c = vec3f(0.12, 0.125, 0.14) * room_light(p, h.n);
    if (PED_TOP - p.y < 0.05 && h.n.y < 0.5) {
        c += vec3f(0.15, 0.6, 0.85) * 2.0;
    }
    if (h.n.y > 0.5) {
        c += vec3f(0.1, 0.15, 0.25) * 0.5;
    }
    return Surface(c, 0.0);
}

// Cube volume and frame over a background that ends at tsurf.
fn over_background(ro: vec3f, rd: vec3f, bg: vec3f, tsurf: f32) -> vec3f {
    let acc = composite_cube(ro, rd, tsurf);
    let col = acc.xyz + bg * (1.0 - acc.w);
    let fr = cube_frame(ro, rd, tsurf, 0.012);
    return col * (1.0 - fr) + vec3f(0.75, 0.8, 0.85) * fr;
}

fn void_bg(rd: vec3f) -> vec3f {
    let k = 0.02 + 0.03 * (0.5 + 0.5 * rd.y);
    return vec3f(k * 0.6, k * 0.7, k);
}

// What the floor reflects: the same scene without a further reflection.
fn observe_reflected(ro: vec3f, rd: vec3f) -> vec3f {
    let h = trace_room(ro, rd);
    return over_background(ro, rd, room_surface(h).col, h.t);
}

fn observe(ro: vec3f, rd: vec3f) -> vec3f {
    if (P.room == 0) {
        return over_background(ro, rd, void_bg(rd), 1e30);
    }
    let h = trace_room(ro, rd);
    let s = room_surface(h);
    var bg = s.col;
    if (s.gloss > 0.0) {
        let cosi = abs(rd.y);
        let fres = 0.05 + 0.95 * pow(1.0 - cosi, 5.0);
        let refl = observe_reflected(h.p + vec3f(0.0, 0.001, 0.0), vec3f(rd.x, -rd.y, rd.z));
        bg += refl * (s.gloss * (0.25 + 0.75 * fres));
    }
    return over_background(ro, rd, bg, h.t);
}

@compute @workgroup_size(16, 16)
fn composite(@builtin(global_invocation_id) id: vec3u) {
    let px = i32(id.x);
    let py = i32(id.y);
    if (px >= P.width || py >= P.height) {
        return;
    }
    let W = f32(P.width);
    let H = f32(P.height);
    let aspect = W / H;
    let sx = ((f32(px) + 0.5) / W * 2.0 - 1.0) * aspect;
    let sy = 1.0 - (f32(py) + 0.5) / H * 2.0;
    let fwd = a3(P.obs_fwd);
    let rgt = a3(P.obs_right);
    let upv = a3(P.obs_up);
    let ro = a3(P.obs_pos);
    let rd = normalize(fwd + (rgt * sx + upv * sy) * P.obs_fov);

    var col = observe(ro, rd);
    // Room surfaces are linear radiance; only the room gets a gentle curve.
    col = col / (1.0 + col * 0.35);

    // Target marker: a ring where the target body's center projects into the
    // retina volume (sized for the 720-line HUD whatever the render scale).
    if (P.marker[3] > 0.0) {
        let rel = vec3f(P.marker[0], P.marker[1], P.marker[2]) - ro;
        let tz = dot(rel, fwd);
        if (tz > 0.0) {
            let mx = dot(rel, rgt) / (tz * P.obs_fov);
            let my = dot(rel, upv) / (tz * P.obs_fov);
            let d = length(vec2f(sx - mx, sy - my)) * 360.0;
            if (abs(d - 9.0) < 1.2 * max(720.0 / H, 1.0)) {
                col = vec3f(1.0, 0.85, 0.2);
            }
        }
    }
    textureStore(frame_out, vec2i(px, py), vec4f(clamp(col, vec3f(0.0), vec3f(1.0)), 1.0));
}

// The s = 0 retina layer at full screen resolution: the 3D cross-section.
@compute @workgroup_size(16, 16)
fn march_slice(@builtin(global_invocation_id) id: vec3u) {
    let px = i32(id.x);
    let py = i32(id.y);
    if (px >= P.width || py >= P.height) {
        return;
    }
    let W = f32(P.width);
    let H = f32(P.height);
    let u = ((f32(px) + 0.5) / W * 2.0 - 1.0) * (W / H);
    let v = 1.0 - (f32(py) + 0.5) / H * 2.0;
    let footprint = 2.0 * P.tan_half_fov / H;
    let ro = vec4f(0.0);
    let rd = retina_dir(u, v, 0.0);
    var h: Hit;
    let t = march(ro, rd, 2e5, footprint, &h);
    var c: vec3f;
    if (t > 0.0) {
        c = shade(ro, rd, t, h, footprint);
    } else {
        c = sky(rd, 2e5);
    }
    textureStore(frame_out, vec2i(px, py), vec4f(tonemap3(c), 1.0));
}

// ---------------------------------------------------------------------------
// CPU/GPU terrain cross-check (tools/webcheck.js)
// ---------------------------------------------------------------------------

struct Probe {
    count: u32,
    body: i32,
    octaves: i32,
}

@group(0) @binding(6) var<storage, read> probe_dirs: array<vec4f>;
@group(0) @binding(7) var<storage, read_write> probe_out: array<f32>;
@group(0) @binding(8) var<storage, read> probe: Probe;

@compute @workgroup_size(64)
fn terrain_probe(@builtin(global_invocation_id) id: vec3u) {
    if (id.x >= probe.count) {
        return;
    }
    probe_out[id.x] = terrain_height(probe.body, probe_dirs[id.x], probe.octaves);
}

// ---------------------------------------------------------------------------
// Present: the frame (rendered in the top-left `scale` part of its texture)
// upscaled to the canvas, with the premultiplied HUD overlay on top.
// ---------------------------------------------------------------------------

struct Blit {
    scale: vec2f, // render size / hud size
    hud: vec2f, // hud size in pixels
}

@group(0) @binding(10) var<uniform> blit: Blit;
@group(0) @binding(11) var frame_tex: texture_2d<f32>;
@group(0) @binding(12) var overlay_tex: texture_2d<f32>;
@group(0) @binding(13) var blit_lin: sampler;

@vertex
fn blit_vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
    let p = vec2f(f32((i << 1u) & 2u), f32(i & 2u));
    return vec4f(p * 2.0 - 1.0, 0.0, 1.0);
}

@fragment
fn blit_fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
    let uv = pos.xy / blit.hud;
    // Keep bilinear taps inside the rendered corner.
    let half_texel = 0.5 / blit.hud;
    let fuv = clamp(uv * blit.scale, half_texel, blit.scale - half_texel);
    let f = textureSampleLevel(frame_tex, blit_lin, fuv, 0.0);
    let o = textureSampleLevel(overlay_tex, blit_lin, uv, 0.0);
    return vec4f(o.rgb + f.rgb * (1.0 - o.a), 1.0);
}
