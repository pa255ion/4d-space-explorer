#include <hip/hip_runtime.h>

// ---------------------------------------------------------------------------
// 4D renderer. The world is a set of 4-balls ("planets") whose surfaces are
// 3-spheres displaced by 4D value-noise terrain. The camera is a 4D eye with
// a 3D retina: voxel (u, v, s) of the retina sees along the 4D ray
//     dir = fwd + tan_half_fov * (u*right + v*up + s*ana)
// `march` fills the retina, `retina_alpha` turns it into an RGBA volume with
// silhouette emphasis, and `composite` volume-renders that cube onto the 2D
// screen for a 3D observer. `march_slice` renders just the s = 0 layer at
// screen resolution (the 3D cross-section view).
//
// The terrain functions (hash4 .. terrain_height) are mirrored exactly in
// src/world.zig for CPU-side collision; keep the two in sync (`zig build
// gpucheck` compares them).
// ---------------------------------------------------------------------------

#define MAX_BODIES 8
#define MAX_OCTAVES 9

struct Body {
    float c[4];       // center, relative to the camera
    float radius;
    float amp;        // terrain amplitude in metres (0 = smooth sphere)
    float sea;        // ocean surface height above radius; < -amp means no ocean
    float feature;    // base terrain wavelength in metres
    float atmo_h;     // atmosphere scale height (0 = none)
    float atmo_rgb[3];
    float col_low[3];
    float col_mid[3];
    float col_high[3];
    float col_sea[3];
    float emissive;   // > 0: a star, drawn as pure emission
    unsigned seed;
};

struct Params {
    float right[4], up[4], fwd[4], ana[4];
    float tan_half_fov;
    int n;            // retina resolution (n^3 voxels)
    float slab;       // only retina layers with |s| <= slab are rendered
    int shadows;
    float sun_rgb[3];
    int sun_index;
    int num_bodies;
    int width, height;
    float obs_yaw, obs_pitch, obs_dist;
    float base_alpha, edge_gain;
    float marker[4];  // retina-space (u, v, s) of the target marker, w > 0 = visible
    Body bodies[MAX_BODIES];
};

struct v4 { float x, y, z, w; };

__device__ __host__ inline v4 mk(float x, float y, float z, float w) { v4 r = {x, y, z, w}; return r; }
__device__ __host__ inline v4 ld(const float* a) { return mk(a[0], a[1], a[2], a[3]); }
__device__ __host__ inline v4 operator+(v4 a, v4 b) { return mk(a.x + b.x, a.y + b.y, a.z + b.z, a.w + b.w); }
__device__ __host__ inline v4 operator-(v4 a, v4 b) { return mk(a.x - b.x, a.y - b.y, a.z - b.z, a.w - b.w); }
__device__ __host__ inline v4 operator*(v4 a, float s) { return mk(a.x * s, a.y * s, a.z * s, a.w * s); }
__device__ __host__ inline float dot(v4 a, v4 b) { return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w; }
__device__ __host__ inline float len(v4 a) { return sqrtf(dot(a, a)); }
__device__ __host__ inline v4 normalize(v4 a) { return a * (1.0f / len(a)); }

__device__ inline float clampf(float x, float a, float b) { return fminf(fmaxf(x, a), b); }
__device__ inline float mixf(float a, float b, float t) { return a + (b - a) * t; }
__device__ inline float smooth(float a, float b, float x) {
    float t = clampf((x - a) / (b - a), 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

struct c3 { float r, g, b; };
__device__ inline c3 rgb(float r, float g, float b) { c3 c = {r, g, b}; return c; }
__device__ inline c3 ldc(const float* a) { return rgb(a[0], a[1], a[2]); }
__device__ inline c3 operator+(c3 a, c3 b) { return rgb(a.r + b.r, a.g + b.g, a.b + b.b); }
__device__ inline c3 operator*(c3 a, float s) { return rgb(a.r * s, a.g * s, a.b * s); }
__device__ inline c3 operator*(c3 a, c3 b) { return rgb(a.r * b.r, a.g * b.g, a.b * b.b); }
__device__ inline c3 mixc(c3 a, c3 b, float t) { return a * (1.0f - t) + b * t; }

// ---------------------------------------------------------------------------
// Terrain (mirrored in world.zig)
// ---------------------------------------------------------------------------

__device__ __host__ inline unsigned hash4(int x, int y, int z, int w, unsigned seed) {
    unsigned h = seed;
    h ^= (unsigned)x * 0x8da6b343u;
    h ^= (unsigned)y * 0xd8163841u;
    h ^= (unsigned)z * 0xcb1ab31fu;
    h ^= (unsigned)w * 0x165667b1u;
    h ^= h >> 15; h *= 0x2c1b3c6du;
    h ^= h >> 12; h *= 0x297a2d39u;
    h ^= h >> 15;
    return h;
}

// 4D value noise in [-1, 1], quintic interpolation over the 16 cell corners.
__device__ __host__ inline float vnoise(v4 p, unsigned seed) {
    float fx = floorf(p.x), fy = floorf(p.y), fz = floorf(p.z), fw = floorf(p.w);
    int ix = (int)fx, iy = (int)fy, iz = (int)fz, iw = (int)fw;
    float tx = p.x - fx, ty = p.y - fy, tz = p.z - fz, tw = p.w - fw;
    float ux = tx * tx * tx * (tx * (tx * 6.0f - 15.0f) + 10.0f);
    float uy = ty * ty * ty * (ty * (ty * 6.0f - 15.0f) + 10.0f);
    float uz = tz * tz * tz * (tz * (tz * 6.0f - 15.0f) + 10.0f);
    float uw = tw * tw * tw * (tw * (tw * 6.0f - 15.0f) + 10.0f);
    float lw[2];
    for (int dw = 0; dw < 2; dw++) {
        float lz[2];
        for (int dz = 0; dz < 2; dz++) {
            float ly[2];
            for (int dy = 0; dy < 2; dy++) {
                float a = (float)hash4(ix, iy + dy, iz + dz, iw + dw, seed) * (2.0f / 4294967296.0f) - 1.0f;
                float b = (float)hash4(ix + 1, iy + dy, iz + dz, iw + dw, seed) * (2.0f / 4294967296.0f) - 1.0f;
                ly[dy] = a + (b - a) * ux;
            }
            lz[dz] = ly[0] + (ly[1] - ly[0]) * uy;
        }
        lw[dw] = lz[0] + (lz[1] - lz[0]) * uz;
    }
    return lw[0] + (lw[1] - lw[0]) * uw;
}

// Height of the terrain above `radius` in direction `dir` (unit 4-vector from
// the body center). `octaves` controls detail; the GPU lowers it with distance.
__device__ __host__ inline float terrain_height(const Body& b, v4 dir, int octaves) {
    v4 q = dir * (b.radius / b.feature);
    float base = 0.0f, ridge = 0.0f, a = 1.0f, norm = 0.0f;
    v4 p = q;
    for (int i = 0; i < octaves; i++) {
        float n = vnoise(p, b.seed + (unsigned)i);
        base += a * n;
        if (i >= 1) {
            float r = 1.0f - fabsf(vnoise(p * 0.5f + mk(5.2f, 1.3f, 7.7f, 3.1f), b.seed ^ 0x9e3779b9u));
            ridge += a * r * r;
        }
        norm += a;
        a *= 0.48f;
        p = p * 2.03f + mk(1.7f, 9.2f, 3.4f, 6.1f);
    }
    base /= norm;
    ridge /= norm;
    float land = base * 1.6f;
    float mountains = fmaxf(land + 0.05f, 0.0f) * ridge * 2.2f;
    return b.amp * (land + mountains);
}

// ---------------------------------------------------------------------------
// Scene distance
// ---------------------------------------------------------------------------

// mat: 0 terrain, 1 sea, 2 star. `shell`: d is only the distance to a body's
// bounding shell (a loose lower bound), not to an actual surface.
struct Hit { float d; int body; int mat; bool shell; };

__device__ inline int lod_octaves(const Body& b, float t, float footprint) {
    // Stop adding octaves once their wavelength is below ~2 retina voxels.
    float px = fmaxf(t * footprint, 0.05f);
    float o = log2f(b.feature / (2.0f * px)) + 1.0f;
    return (int)clampf(o, 1.0f, (float)MAX_OCTAVES);
}

// shadow = true is the variant for shadow rays: stars are skipped (they're
// the light, not occluders), the sea itself is skipped (a spherical sea can't
// occlude itself) and terrain below sea level counts as being at sea level,
// so the soft-shadow penumbra doesn't "see" the seabed.
template <bool shadow = false>
__device__ inline Hit scene(const Params& P, v4 p, float t, float footprint) {
    Hit h = {1e30f, -1, 0, false};
    for (int i = 0; i < P.num_bodies; i++) {
        const Body& b = P.bodies[i];
        if (shadow && b.emissive > 0.0f) continue;
        v4 rel = p - ld(b.c);
        float r = len(rel);
        float d;
        int mat = 0;
        bool shell = false;
        if (b.emissive > 0.0f || b.amp <= 0.0f) {
            d = r - b.radius;
            mat = b.emissive > 0.0f ? 2 : 0;
        } else {
            float bound = b.radius + b.amp * 2.6f + 1.0f;
            if (r > bound + 10.0f) {
                d = r - bound;
                shell = true;
            } else {
                float hgt = terrain_height(b, rel * (1.0f / r), lod_octaves(b, t, footprint));
                if (shadow && b.sea > -b.amp) hgt = fmaxf(hgt, b.sea);
                d = (r - b.radius - hgt) * 0.5f;  // Lipschitz safety for steep noise
                if (!shadow && b.sea > -b.amp) {
                    float ds = r - b.radius - b.sea;
                    if (ds < d) { d = ds; mat = 1; }
                }
            }
        }
        if (d < h.d) { h.d = d; h.body = i; h.mat = mat; h.shell = shell; }
    }
    return h;
}

__device__ inline float march(const Params& P, v4 ro, v4 rd, float tmax, float footprint, Hit& out) {
    float t = 0.05f;
    for (int i = 0; i < 220; i++) {
        Hit h = scene(P, ro + rd * t, t, footprint);
        if (h.d < 0.0008f * t + 0.01f) { out = h; return t; }
        t += h.d;
        if (t > tmax) break;
    }
    out.body = -1;
    return -1.0f;
}

// `t0` is the primary ray's hit distance: shadow rays use terrain LOD for
// t0 + t so they see the same (coarser) surface the primary ray hit, instead
// of fine detail that would poke through it and self-shadow.
__device__ inline float shadow(const Params& P, v4 ro, v4 rd, float footprint, float t0, float tmax) {
    float res = 1.0f, t = 0.5f;
    for (int i = 0; i < 64; i++) {
        Hit h = scene<true>(P, ro + rd * t, t0 + t, footprint);
        if (h.d < 0.002f * t) return 0.0f;
        if (!h.shell) res = fminf(res, 12.0f * h.d / t);
        t += fmaxf(h.d, 0.2f);
        if (t > tmax) break;
    }
    return clampf(res, 0.0f, 1.0f);
}

// Sky radiance along a ray that escaped: atmosphere glow near planets + sun glare.
__device__ inline c3 sky(const Params& P, v4 rd, float tmax) {
    c3 col = rgb(0.004f, 0.005f, 0.012f);
    v4 sunp = P.sun_index >= 0 ? ld(P.bodies[P.sun_index].c) : mk(0, 0, 0, 0);
    for (int i = 0; i < P.num_bodies; i++) {
        const Body& b = P.bodies[i];
        v4 c = ld(b.c);
        float dc = len(c);
        if (b.emissive > 0.0f) {
            // Glare falls off with angle from the sun relative to its angular radius.
            float ang = acosf(clampf(dot(c, rd) / dc, -1.0f, 1.0f));
            float ar = asinf(fminf(b.radius / dc, 1.0f));
            col = col + ldc(P.sun_rgb) * (0.5f * ar * ar / (ang * ang + ar * ar * 0.3f));
        } else if (b.atmo_h > 0.0f) {
            // Column density of an exponential atmosphere along the ray,
            // Chapman-style: zenith column H/mu, capped near the horizon at
            // the grazing value sqrt(pi R H / 2) per half pass.
            float tc = fminf(dot(c, rd), tmax);
            float H = b.atmo_h;
            float graze = sqrtf(1.5708f * b.radius * H);
            float column;
            v4 pc;  // point where density peaks: the camera or the closest approach
            if (tc <= 0.0f) {
                float h0 = fmaxf(dc - b.radius, 0.0f);
                float mu = -dot(c, rd) / dc;  // cos(zenith angle) at the camera
                column = expf(-h0 / H) * fminf(H / fmaxf(mu, 1e-3f), graze);
                pc = mk(0, 0, 0, 0);
            } else {
                pc = rd * tc;
                float h0 = fmaxf(len(c - pc) - b.radius, 0.0f);
                float hc = fmaxf(dc - b.radius, 0.0f);
                // Far side half pass + the part between camera and closest approach.
                column = expf(-h0 / H) * graze * (2.0f - expf(-(hc - h0) / H));
            }
            float tau = column * (0.3f / H);
            v4 upc = normalize(pc - c);
            float lit = 0.08f + fmaxf(dot(upc, normalize(sunp - pc)) + 0.15f, 0.0f);
            col = col + ldc(b.atmo_rgb) * ((1.0f - expf(-tau)) * lit * 0.9f);
        }
    }
    return col;
}

__device__ inline c3 shade(const Params& P, v4 ro, v4 rd, float t, Hit h, float footprint) {
    const Body& b = P.bodies[h.body];
    if (h.mat == 2) return ldc(P.sun_rgb) * b.emissive;

    v4 p = ro + rd * t;
    v4 rel = p - ld(b.c);
    float r = len(rel);
    v4 up = rel * (1.0f / r);
    int oct = lod_octaves(b, t, footprint);
    v4 n;
    float hgt;
    if (h.mat == 1 || b.amp <= 0.0f) {
        n = up;
        hgt = b.sea;
    } else {
        // Normal of the surface F(p) = |p - c| - R - h(dir) by forward differences.
        float e = fmaxf(0.002f * t, 0.02f);
        hgt = terrain_height(b, up, oct);
        float f0 = r - b.radius - hgt;
        float g[4];
        for (int k = 0; k < 4; k++) {
            v4 q = rel;
            if (k == 0) q.x += e; else if (k == 1) q.y += e; else if (k == 2) q.z += e; else q.w += e;
            float rq = len(q);
            g[k] = (rq - b.radius - terrain_height(b, q * (1.0f / rq), oct)) - f0;
        }
        n = normalize(mk(g[0], g[1], g[2], g[3]));
    }

    c3 albedo;
    if (h.mat == 1) {
        albedo = ldc(b.col_sea);
    } else {
        float hn = (hgt - b.sea) / b.amp;  // height above sea, in amplitudes
        float slope = 1.0f - dot(n, up);
        albedo = mixc(ldc(b.col_low), ldc(b.col_mid), smooth(0.05f, 0.35f, hn));
        albedo = mixc(albedo, rgb(0.33f, 0.31f, 0.3f), smooth(0.08f, 0.25f, slope));
        albedo = mixc(albedo, ldc(b.col_high), smooth(0.75f, 1.05f, hn) * (1.0f - smooth(0.15f, 0.35f, slope)));
    }

    v4 sunp = P.sun_index >= 0 ? ld(P.bodies[P.sun_index].c) : mk(0, 0, 0, 0);
    v4 L = normalize(sunp - p);
    float diff = fmaxf(dot(n, L), 0.0f);
    if (diff > 0.0f && P.shadows) {
        float to_sun = len(sunp - p) - (P.sun_index >= 0 ? P.bodies[P.sun_index].radius : 0.0f);
        diff *= shadow(P, p + n * fmaxf(0.003f * t, 0.05f), L, footprint, t, to_sun);
    }
    float skyl = 0.06f + 0.06f * fmaxf(dot(n, up), 0.0f);
    c3 col = albedo * (ldc(P.sun_rgb) * diff + rgb(0.35f, 0.45f, 0.7f) * skyl);
    if (h.mat == 1) {
        v4 hv = normalize(L - rd);
        col = col + ldc(P.sun_rgb) * (powf(fmaxf(dot(n, hv), 0.0f), 80.0f) * 0.8f * (diff > 0.0f ? 1.0f : 0.0f));
    }

    // Aerial perspective: the planet's own atmosphere tints distant terrain.
    if (b.atmo_h > 0.0f) {
        float fog = 1.0f - expf(-t / (b.atmo_h * 40.0f));
        col = mixc(col, ldc(b.atmo_rgb) * (0.3f + 0.7f * fmaxf(dot(up, L), 0.0f)), fog * 0.85f);
    }
    return col;
}

__device__ inline v4 retina_dir(const Params& P, float u, float v, float s) {
    return normalize(ld(P.fwd) + (ld(P.right) * u + ld(P.up) * v + ld(P.ana) * s) * P.tan_half_fov);
}

// ---------------------------------------------------------------------------
// Kernels
// ---------------------------------------------------------------------------

// One thread per retina voxel. Output: rgb + depth (-1 = sky).
extern "C" __global__ void march_retina(const Params* __restrict__ Pp, float4* __restrict__ out) {
    const Params& P = *Pp;
    int n = P.n;
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    int j = blockIdx.y * blockDim.y + threadIdx.y;
    int k = blockIdx.z * blockDim.z + threadIdx.z;
    if (i >= n || j >= n || k >= n) return;
    float u = ((i + 0.5f) / n) * 2.0f - 1.0f;
    float v = 1.0f - ((j + 0.5f) / n) * 2.0f;
    float s = ((k + 0.5f) / n) * 2.0f - 1.0f;
    int idx = (k * n + j) * n + i;
    if (fabsf(s) > P.slab + 1.0f / n) { out[idx] = make_float4(0, 0, 0, -2.0f); return; }

    float footprint = 2.0f * P.tan_half_fov / n;
    v4 ro = mk(0, 0, 0, 0);
    v4 rd = retina_dir(P, u, v, s);
    Hit h;
    float t = march(P, ro, rd, 2e5f, footprint, h);
    c3 c = t > 0.0f ? shade(P, ro, rd, t, h, footprint) : sky(P, rd, 2e5f);
    out[idx] = make_float4(c.r, c.g, c.b, t > 0.0f && h.mat != 2 ? t : -1.0f);
}

__device__ inline unsigned char tonemap(float x) {
    x = x / (1.0f + x * 0.6f) * 1.25f;              // soft shoulder
    x = powf(clampf(x, 0.0f, 1.0f), 1.0f / 2.2f);   // gamma
    return (unsigned char)(x * 255.0f + 0.5f);
}

// Turn the retina into an RGBA volume. Surfaces get `base_alpha`; voxels on a
// depth discontinuity (silhouettes, ridges, the planet limb) get boosted
// opacity and are darkened, which is what makes the 3D image legible.
extern "C" __global__ void retina_alpha(const Params* __restrict__ Pp, const float4* __restrict__ in, uchar4* __restrict__ out) {
    const Params& P = *Pp;
    int n = P.n;
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    int j = blockIdx.y * blockDim.y + threadIdx.y;
    int k = blockIdx.z * blockDim.z + threadIdx.z;
    if (i >= n || j >= n || k >= n) return;
    int idx = (k * n + j) * n + i;
    float4 c = in[idx];
    if (c.w == -2.0f) { out[idx] = make_uchar4(0, 0, 0, 0); return; }

    float edge = 0.0f;
    const int di[6] = {1, -1, 0, 0, 0, 0}, dj[6] = {0, 0, 1, -1, 0, 0}, dk[6] = {0, 0, 0, 0, 1, -1};
    for (int q = 0; q < 6; q++) {
        int a = i + di[q], b = j + dj[q], e = k + dk[q];
        if (a < 0 || b < 0 || e < 0 || a >= n || b >= n || e >= n) continue;
        float tn = in[(e * n + b) * n + a].w;
        if (tn == -2.0f) continue;
        if ((tn < 0.0f) != (c.w < 0.0f)) edge = 1.0f;
        else if (c.w > 0.0f) edge = fmaxf(edge, fabsf(logf(tn / c.w)) * 6.0f);
    }
    edge = clampf(edge, 0.0f, 1.0f);

    float lum = 0.3f * c.x + 0.6f * c.y + 0.1f * c.z;
    float a;
    float shadek = 1.0f;
    if (c.w < 0.0f) {
        // Sky: only bright things (sun, atmosphere glow) are visible in the volume.
        a = clampf(lum * 1.5f, 0.0f, 0.9f) * P.base_alpha * 2.0f;
    } else {
        a = clampf(P.base_alpha + P.edge_gain * edge, 0.0f, 1.0f);
        shadek = 1.0f - 0.6f * edge;
    }
    out[idx] = make_uchar4(tonemap(c.x * shadek), tonemap(c.y * shadek), tonemap(c.z * shadek), (unsigned char)(a * 255.0f + 0.5f));
}

__device__ inline float4 sample_vol(const uchar4* vol, int n, float x, float y, float z) {
    // x, y, z in voxel units; trilinear.
    x = clampf(x - 0.5f, 0.0f, n - 1.001f);
    y = clampf(y - 0.5f, 0.0f, n - 1.001f);
    z = clampf(z - 0.5f, 0.0f, n - 1.001f);
    int x0 = (int)x, y0 = (int)y, z0 = (int)z;
    float fx = x - x0, fy = y - y0, fz = z - z0;
    float4 acc = make_float4(0, 0, 0, 0);
    for (int c = 0; c < 8; c++) {
        int dx = c & 1, dy = (c >> 1) & 1, dz = c >> 2;
        int xi = min(x0 + dx, n - 1), yi = min(y0 + dy, n - 1), zi = min(z0 + dz, n - 1);
        float w = (dx ? fx : 1.0f - fx) * (dy ? fy : 1.0f - fy) * (dz ? fz : 1.0f - fz);
        uchar4 v = vol[(zi * n + yi) * n + xi];
        float al = v.w * (1.0f / 255.0f) * w;
        // Accumulate premultiplied so empty voxels don't bleed black into edges.
        acc.x += v.x * al; acc.y += v.y * al; acc.z += v.z * al; acc.w += al;
    }
    float inv = acc.w > 1e-5f ? 1.0f / (acc.w * 255.0f) : 0.0f;
    return make_float4(acc.x * inv, acc.y * inv, acc.z * inv, acc.w);
}

// A 3D observer looks at the retina cube [-1,1]^3 (u right, v up, s toward
// the observer's "depth") from an orbit camera, compositing front to back.
extern "C" __global__ void composite(const Params* __restrict__ Pp, const uchar4* __restrict__ vol, uchar4* __restrict__ pixels) {
    const Params& P = *Pp;
    int px = blockIdx.x * blockDim.x + threadIdx.x;
    int py = blockIdx.y * blockDim.y + threadIdx.y;
    if (px >= P.width || py >= P.height) return;
    int n = P.n;

    float aspect = (float)P.width / P.height;
    float sx = ((px + 0.5f) / P.width * 2.0f - 1.0f) * aspect;
    float sy = 1.0f - (py + 0.5f) / P.height * 2.0f;

    float cy = cosf(P.obs_yaw), syw = sinf(P.obs_yaw), cp = cosf(P.obs_pitch), sp = sinf(P.obs_pitch);
    // Observer basis. At yaw = pitch = 0 the observer looks along +s, so the
    // s = 0 layer (the ordinary 3D-slice view) faces the screen.
    float fwd[3] = {syw * cp, sp, cy * cp};
    float rgt[3] = {cy, 0.0f, -syw};
    float upv[3] = {-syw * sp, cp, -cy * sp};
    float ro[3], rd[3];
    const float fov = 0.55f;
    for (int a = 0; a < 3; a++) {
        ro[a] = -fwd[a] * P.obs_dist;
        rd[a] = fwd[a] + (rgt[a] * sx + upv[a] * sy) * fov;
    }
    float rl = sqrtf(rd[0] * rd[0] + rd[1] * rd[1] + rd[2] * rd[2]);
    for (int a = 0; a < 3; a++) rd[a] /= rl;

    // Background: subtle vertical gradient.
    float bgk = 0.02f + 0.03f * (1.0f - (py + 0.5f) / P.height);
    float col[3] = {bgk * 0.6f, bgk * 0.7f, bgk};
    float acc[3] = {0, 0, 0}, A = 0.0f;

    // Slab box intersection.
    float lo[3] = {-1, -1, -P.slab - 1.0f / n}, hi[3] = {1, 1, P.slab + 1.0f / n};
    float t0 = 0.0f, t1 = 1e9f;
    for (int a = 0; a < 3; a++) {
        float inv = 1.0f / rd[a];
        float ta = (lo[a] - ro[a]) * inv, tb = (hi[a] - ro[a]) * inv;
        t0 = fmaxf(t0, fminf(ta, tb));
        t1 = fminf(t1, fmaxf(ta, tb));
    }
    if (t1 > t0) {
        // Frame lines on the cube's edges (front brighter than back).
        float pe[3], px2[3];
        for (int a = 0; a < 3; a++) { pe[a] = ro[a] + rd[a] * t0; px2[a] = ro[a] + rd[a] * t1; }
        float lw = 0.006f * P.obs_dist;
        int ne = 0, nx = 0;
        for (int a = 0; a < 3; a++) {
            if (fabsf(fabsf(pe[a]) - hi[a]) < lw) ne++;
            if (fabsf(fabsf(px2[a]) - hi[a]) < lw) nx++;
        }

        float step = 1.0f / n;  // half a voxel (cube is 2 units wide)
        float vox = 2.0f / n;
        for (float t = t0 + step * 0.5f; t < t1; t += step) {
            float x = ro[0] + rd[0] * t, y = ro[1] + rd[1] * t, z = ro[2] + rd[2] * t;
            float4 s = sample_vol(vol, n, (x + 1.0f) * 0.5f * n, (1.0f - y) * 0.5f * n, (z + 1.0f) * 0.5f * n);
            float a = 1.0f - powf(1.0f - fminf(s.w, 0.999f), step / vox);
            float w = (1.0f - A) * a;
            acc[0] += w * s.x; acc[1] += w * s.y; acc[2] += w * s.z;
            A += w;
            if (A > 0.985f) break;
        }
        for (int a = 0; a < 3; a++) col[a] = acc[a] + (1.0f - A) * col[a];
        if (ne >= 2) for (int a = 0; a < 3; a++) col[a] = col[a] * 0.6f + 0.4f * 0.75f;
        else if (nx >= 2) for (int a = 0; a < 3; a++) col[a] = col[a] * 0.8f + 0.2f * 0.5f;
    }

    // Target marker: a small ring where the target body's center projects
    // into the retina volume.
    if (P.marker[3] > 0.0f) {
        float m[3] = {P.marker[0], P.marker[1], P.marker[2]};
        float rel[3] = {m[0] - ro[0], m[1] - ro[1], m[2] - ro[2]};
        float tz = rel[0] * fwd[0] + rel[1] * fwd[1] + rel[2] * fwd[2];
        if (tz > 0.0f) {
            float mx = (rel[0] * rgt[0] + rel[1] * rgt[1] + rel[2] * rgt[2]) / (tz * fov);
            float my = (rel[0] * upv[0] + rel[1] * upv[1] + rel[2] * upv[2]) / (tz * fov);
            float dx = (sx - mx) * P.height * 0.5f, dy = (sy - my) * P.height * 0.5f;
            float d = sqrtf(dx * dx + dy * dy);
            if (fabsf(d - 9.0f) < 1.2f) { col[0] = 1.0f; col[1] = 0.85f; col[2] = 0.2f; }
        }
    }

    pixels[py * P.width + px] = make_uchar4(
        (unsigned char)(clampf(col[0], 0, 1) * 255.0f + 0.5f),
        (unsigned char)(clampf(col[1], 0, 1) * 255.0f + 0.5f),
        (unsigned char)(clampf(col[2], 0, 1) * 255.0f + 0.5f), 255);
}

// The s = 0 retina layer at full screen resolution: a 3D cross-section of
// the 4D world through the ship's right/up/forward hyperplane.
extern "C" __global__ void march_slice(const Params* __restrict__ Pp, uchar4* __restrict__ pixels) {
    const Params& P = *Pp;
    int px = blockIdx.x * blockDim.x + threadIdx.x;
    int py = blockIdx.y * blockDim.y + threadIdx.y;
    if (px >= P.width || py >= P.height) return;
    float aspect = (float)P.width / P.height;
    float u = ((px + 0.5f) / P.width * 2.0f - 1.0f) * aspect;
    float v = 1.0f - (py + 0.5f) / P.height * 2.0f;
    float footprint = 2.0f * P.tan_half_fov / P.height;
    v4 ro = mk(0, 0, 0, 0);
    v4 rd = retina_dir(P, u, v, 0.0f);
    Hit h;
    float t = march(P, ro, rd, 2e5f, footprint, h);
    c3 c = t > 0.0f ? shade(P, ro, rd, t, h, footprint) : sky(P, rd, 2e5f);
    pixels[py * P.width + px] = make_uchar4(tonemap(c.r), tonemap(c.g), tonemap(c.b), 255);
}

// Evaluate terrain_height on a batch of directions (for the CPU/GPU cross-check).
extern "C" __global__ void terrain_probe(const Params* __restrict__ Pp, const float4* __restrict__ dirs, float* __restrict__ out, int count, int body, int octaves) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= count) return;
    float4 d = dirs[i];
    out[i] = terrain_height(Pp->bodies[body], mk(d.x, d.y, d.z, d.w), octaves);
}
