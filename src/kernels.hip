#include <hip/hip_runtime.h>

// ---------------------------------------------------------------------------
// 4D renderer. The world is a set of 4-balls ("planets") whose surfaces are
// 3-spheres displaced by 4D value-noise terrain. The camera is a 4D eye with
// a 3D retina: voxel (u, v, s) of the retina sees along the 4D ray
//     dir = fwd + tan_half_fov * (u*right + v*up + s*ana)
// `march` fills the retina, `retina_alpha` turns it into an RGBA volume with
// silhouette emphasis, and `composite` volume-renders that cube onto the 2D
// screen for a 3D observer standing in a room around it. `march_slice` renders just the s = 0 layer at
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
    float obs_pos[3], obs_fwd[3], obs_right[3], obs_up[3];  // observer camera (room space)
    float obs_fov;    // tan of the observer's half field of view
    int room;         // draw the observatory room (else a dark void)
    float base_alpha, edge_gain;
    float marker[4];  // retina-space (u, v, s) of the target marker, w > 0 = visible
    int low;          // low quality: fewer octaves and steps, no reflections (shadows are off too)
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

// Low quality caps terrain octaves here and coarsens the LOD by 2x.
#define LOW_OCTAVES 5

__device__ inline int lod_octaves(const Body& b, float t, float footprint, int low) {
    // Stop adding octaves once their wavelength is below ~2 retina voxels
    // (~4 in low quality).
    float px = fmaxf(t * footprint, 0.05f) * (low ? 2.0f : 1.0f);
    float o = log2f(b.feature / (2.0f * px)) + 1.0f;
    return (int)clampf(o, 1.0f, (float)(low ? LOW_OCTAVES : MAX_OCTAVES));
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
                float hgt = terrain_height(b, rel * (1.0f / r), lod_octaves(b, t, footprint, P.low));
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
    int steps = P.low ? 120 : 220;
    float eps_t = P.low ? 0.002f : 0.0008f, eps_0 = P.low ? 0.02f : 0.01f;
    for (int i = 0; i < steps; i++) {
        Hit h = scene(P, ro + rd * t, t, footprint);
        if (h.d < eps_t * t + eps_0) { out = h; return t; }
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
    int oct = lod_octaves(b, t, footprint, P.low);
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

// ---------------------------------------------------------------------------
// The observatory: the retina cube [-1,1]^3 floats over a pedestal in the
// middle of a room, and a 3D observer (you) looks at it. Everything here is
// ordinary 3D. Room coordinates: y up, cube centered at the origin, 1 unit = 1 m.
// ---------------------------------------------------------------------------

struct f3 { float x, y, z; };
__device__ inline f3 m3(float x, float y, float z) { f3 r = {x, y, z}; return r; }
__device__ inline f3 ld3(const float* a) { return m3(a[0], a[1], a[2]); }
__device__ inline f3 operator+(f3 a, f3 b) { return m3(a.x + b.x, a.y + b.y, a.z + b.z); }
__device__ inline f3 operator-(f3 a, f3 b) { return m3(a.x - b.x, a.y - b.y, a.z - b.z); }
__device__ inline f3 operator*(f3 a, float s) { return m3(a.x * s, a.y * s, a.z * s); }
__device__ inline float dot3(f3 a, f3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
__device__ inline float ax(f3 v, int a) { return a == 0 ? v.x : (a == 1 ? v.y : v.z); }

#define ROOM_X 9.0f
#define ROOM_FLOOR -2.3f
#define ROOM_CEIL 3.5f
#define PED_HALF 0.55f
#define PED_TOP -1.45f

// Ray/AABB slab test. Returns entry/exit distances and the entry face axis.
__device__ inline bool box_hit(f3 ro, f3 rd, f3 lo, f3 hi, float& t0, float& t1, int& face) {
    t0 = -1e30f; t1 = 1e30f; face = 0;
    for (int a = 0; a < 3; a++) {
        float inv = 1.0f / ax(rd, a);
        float ta = (ax(lo, a) - ax(ro, a)) * inv, tb = (ax(hi, a) - ax(ro, a)) * inv;
        float tn = fminf(ta, tb), tf = fmaxf(ta, tb);
        if (tn > t0) { t0 = tn; face = a; }
        t1 = fminf(t1, tf);
    }
    return t1 > fmaxf(t0, 0.0f);
}

// Front-to-back compositing of the retina volume along a ray, up to tmax.
__device__ inline void composite_cube(const Params& P, const uchar4* vol, f3 ro, f3 rd, float tmax, float acc[3], float& A) {
    int n = P.n;
    float t0, t1; int face;
    f3 lo = m3(-1, -1, -P.slab - 1.0f / n), hi = m3(1, 1, P.slab + 1.0f / n);
    if (!box_hit(ro, rd, lo, hi, t0, t1, face)) return;
    t0 = fmaxf(t0, 0.0f);
    t1 = fminf(t1, tmax);
    float step = (P.low ? 2.0f : 1.0f) / n;  // half a voxel (cube is 2 units wide); a whole one in low quality
    float vox = 2.0f / n;
    for (float t = t0 + step * 0.5f; t < t1; t += step) {
        f3 p = ro + rd * t;
        float4 s = sample_vol(vol, n, (p.x + 1.0f) * 0.5f * n, (1.0f - p.y) * 0.5f * n, (p.z + 1.0f) * 0.5f * n);
        float a = 1.0f - powf(1.0f - fminf(s.w, 0.999f), step / vox);
        float w = (1.0f - A) * a;
        acc[0] += w * s.x; acc[1] += w * s.y; acc[2] += w * s.z;
        A += w;
        if (A > 0.985f) break;
    }
}

// Faint cube frame: brighten where the ray's entry/exit point is on an edge.
__device__ inline float cube_frame(f3 ro, f3 rd, float tmax, float lw) {
    float t0, t1; int face;
    if (!box_hit(ro, rd, m3(-1, -1, -1), m3(1, 1, 1), t0, t1, face)) return 0.0f;
    float k = 0.0f;
    for (int e = 0; e < 2; e++) {
        float t = e == 0 ? t0 : t1;
        if (t < 0.0f || t > tmax) continue;
        f3 p = ro + rd * t;
        int near = (fabsf(fabsf(p.x) - 1.0f) < lw) + (fabsf(fabsf(p.y) - 1.0f) < lw) + (fabsf(fabsf(p.z) - 1.0f) < lw);
        if (near >= 2) k = fmaxf(k, e == 0 ? 0.45f : 0.2f);
    }
    return k;
}

struct RoomHit { float t; f3 p; f3 n; int kind; };  // kind: 0 floor, 1 ceiling, 2 wall, 3 pedestal

__device__ inline RoomHit trace_room(f3 ro, f3 rd) {
    RoomHit h;
    // Interior of the room box: nearest exit plane.
    float best = 1e30f; int axis = 0;
    f3 lo = m3(-ROOM_X, ROOM_FLOOR, -ROOM_X), hi = m3(ROOM_X, ROOM_CEIL, ROOM_X);
    for (int a = 0; a < 3; a++) {
        float d = ax(rd, a);
        float t = ((d > 0.0f ? ax(hi, a) : ax(lo, a)) - ax(ro, a)) / d;
        if (t < best) { best = t; axis = a; }
    }
    h.t = best;
    h.n = m3(axis == 0 ? -copysignf(1.0f, rd.x) : 0.0f, axis == 1 ? -copysignf(1.0f, rd.y) : 0.0f, axis == 2 ? -copysignf(1.0f, rd.z) : 0.0f);
    h.kind = axis == 1 ? (rd.y < 0.0f ? 0 : 1) : 2;
    float t0, t1; int face;
    if (box_hit(ro, rd, m3(-PED_HALF, ROOM_FLOOR, -PED_HALF), m3(PED_HALF, PED_TOP, PED_HALF), t0, t1, face) && t0 > 0.0f && t0 < h.t) {
        h.t = t0;
        h.kind = 3;
        h.n = m3(face == 0 ? -copysignf(1.0f, rd.x) : 0.0f, face == 1 ? -copysignf(1.0f, rd.y) : 0.0f, face == 2 ? -copysignf(1.0f, rd.z) : 0.0f);
    }
    h.p = ro + rd * h.t;
    return h;
}

__device__ inline float hash2(int x, int y) { return (hash4(x, y, 7, 3, 99u) & 0xffff) / 65535.0f; }

// Illumination from the three ceiling light strips (running along z at
// x = -4, 0, 4) plus the cube's own glow.
__device__ inline c3 room_light(f3 p, f3 n) {
    c3 L = rgb(0.22f, 0.23f, 0.27f);
    for (int s = -1; s <= 1; s++) {
        f3 lp = m3(s * 4.0f, ROOM_CEIL - 0.05f, fminf(fmaxf(p.z, -ROOM_X + 1.0f), ROOM_X - 1.0f));
        f3 d = lp - p;
        float r2 = dot3(d, d);
        float cosn = fmaxf(dot3(n, d * rsqrtf(r2)), 0.0f);
        float cosl = fmaxf(-d.y * rsqrtf(r2), 0.0f);
        L = L + rgb(1.0f, 0.95f, 0.88f) * (55.0f * cosn * cosl / (r2 + 4.0f));
    }
    f3 d = m3(0, 0, 0) - p;
    float r2 = dot3(d, d);
    L = L + rgb(0.35f, 0.55f, 0.9f) * (4.0f * fmaxf(dot3(n, d * rsqrtf(r2)), 0.0f) / (r2 + 1.0f));
    return L;
}

__device__ inline c3 room_surface(const RoomHit& h, float& gloss) {
    f3 p = h.p;
    gloss = 0.0f;
    // Soft occlusion where surfaces meet.
    float edge = fminf(ROOM_X - fabsf(p.x), ROOM_X - fabsf(p.z));
    float ao = 0.55f + 0.45f * smooth(0.0f, 1.5f, edge);
    if (h.kind == 0) {
        // Dark glossy tiles with grout lines; occluded around the pedestal.
        float fx = p.x - floorf(p.x), fz = p.z - floorf(p.z);
        float grout = fminf(fminf(fx, 1.0f - fx), fminf(fz, 1.0f - fz));
        float g = smooth(0.008f, 0.02f, grout);
        float v = 0.85f + 0.3f * hash2((int)floorf(p.x), (int)floorf(p.z));
        float pd = fmaxf(fabsf(p.x), fabsf(p.z)) - PED_HALF;
        ao *= 0.5f + 0.5f * smooth(0.0f, 0.8f, pd);
        gloss = 0.85f * g;
        c3 base = mixc(rgb(0.02f, 0.02f, 0.025f), rgb(0.11f, 0.115f, 0.13f) * v, g);
        return base * room_light(p, h.n) * ao;
    }
    if (h.kind == 1) {
        // Ceiling with emissive light strips.
        float strip = 0.0f;
        for (int s = -1; s <= 1; s++) strip = fmaxf(strip, 1.0f - smooth(0.12f, 0.18f, fabsf(p.x - s * 4.0f)));
        strip *= 1.0f - smooth(ROOM_X - 1.2f, ROOM_X - 1.0f, fabsf(p.z));
        return rgb(0.03f, 0.03f, 0.035f) * ao + rgb(1.0f, 0.95f, 0.88f) * (2.5f * strip);
    }
    if (h.kind == 2) {
        // Panelled walls: dark wainscot, lighter upper panels, glowing baseboard.
        float u = fabsf(h.n.x) > 0.5f ? p.z : p.x;
        float hgt = p.y - ROOM_FLOOR;
        float fu = u / 1.5f - floorf(u / 1.5f);
        float seam = smooth(0.0f, 0.015f, fminf(fu, 1.0f - fu));
        float rail = smooth(0.01f, 0.03f, fabsf(hgt - 1.0f));
        c3 base = hgt < 1.0f ? rgb(0.12f, 0.12f, 0.135f) : rgb(0.3f, 0.31f, 0.34f);
        base = base * (0.5f + 0.5f * seam * rail);
        c3 c = base * room_light(p, h.n) * ao;
        if (hgt < 0.06f) c = c + rgb(0.15f, 0.6f, 0.85f) * 1.2f;
        return c;
    }
    // Pedestal: dark metal, glowing rim at the top.
    c3 c = rgb(0.12f, 0.125f, 0.14f) * room_light(p, h.n);
    if (PED_TOP - p.y < 0.05f && h.n.y < 0.5f) c = c + rgb(0.15f, 0.6f, 0.85f) * 2.0f;
    if (h.n.y > 0.5f) c = c + rgb(0.1f, 0.15f, 0.25f) * 0.5f;
    return c;
}

// Color seen along a ray: the cube volume composited over the room (or over
// a dark void if the room is off). Floor reflections recurse once.
template <bool allow_reflection>
__device__ inline c3 observe(const Params& P, const uchar4* vol, f3 ro, f3 rd, float aspect_y) {
    c3 bg;
    float tsurf = 1e30f;
    if (P.room) {
        RoomHit h = trace_room(ro, rd);
        tsurf = h.t;
        float gloss;
        bg = room_surface(h, gloss);
        if (allow_reflection && gloss > 0.0f && !P.low) {
            float cosi = fabsf(rd.y);
            float fres = 0.05f + 0.95f * powf(1.0f - cosi, 5.0f);
            f3 rr = m3(rd.x, -rd.y, rd.z);
            c3 refl = observe<false>(P, vol, h.p + m3(0, 0.001f, 0), rr, aspect_y);
            bg = bg + refl * (gloss * (0.25f + 0.75f * fres));
        }
    } else {
        float k = 0.02f + 0.03f * (0.5f + 0.5f * rd.y);
        bg = rgb(k * 0.6f, k * 0.7f, k);
    }
    float acc[3] = {0, 0, 0}, A = 0.0f;
    composite_cube(P, vol, ro, rd, tsurf, acc, A);
    c3 col = rgb(acc[0], acc[1], acc[2]) + bg * (1.0f - A);
    float fr = cube_frame(ro, rd, tsurf, 0.012f);
    return col * (1.0f - fr) + rgb(0.75f, 0.8f, 0.85f) * fr;
}

extern "C" __global__ void composite(const Params* __restrict__ Pp, const uchar4* __restrict__ vol, uchar4* __restrict__ pixels) {
    const Params& P = *Pp;
    int px = blockIdx.x * blockDim.x + threadIdx.x;
    int py = blockIdx.y * blockDim.y + threadIdx.y;
    if (px >= P.width || py >= P.height) return;

    float aspect = (float)P.width / P.height;
    float sx = ((px + 0.5f) / P.width * 2.0f - 1.0f) * aspect;
    float sy = 1.0f - (py + 0.5f) / P.height * 2.0f;
    f3 fwd = ld3(P.obs_fwd), rgt = ld3(P.obs_right), upv = ld3(P.obs_up);
    f3 ro = ld3(P.obs_pos);
    f3 rd = fwd + (rgt * sx + upv * sy) * P.obs_fov;
    rd = rd * rsqrtf(dot3(rd, rd));

    c3 c = observe<true>(P, vol, ro, rd, aspect);
    // Room surfaces are linear radiance; cube voxels are already display
    // values, so only the room gets a gentle tone curve.
    float col[3] = {c.r, c.g, c.b};
    for (int a = 0; a < 3; a++) col[a] = col[a] / (1.0f + col[a] * 0.35f);

    // Target marker: a ring where the target body's center projects into the
    // retina volume.
    if (P.marker[3] > 0.0f) {
        f3 rel = m3(P.marker[0], P.marker[1], P.marker[2]) - ro;
        float tz = dot3(rel, fwd);
        if (tz > 0.0f) {
            float mx = dot3(rel, rgt) / (tz * P.obs_fov);
            float my = dot3(rel, upv) / (tz * P.obs_fov);
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
