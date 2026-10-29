#include <metal_stdlib>
#include "Spectral.h"
using namespace metal;

// --- Stroke Rendering ---

struct StrokeVertexIn {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
    float  opacity  [[attribute(2)]];
};

struct StrokeVertexOut {
    float4 position [[position]];
    float2 texCoord;
    float  opacity;
};

vertex StrokeVertexOut strokeVertex(
    StrokeVertexIn in [[stage_in]],
    constant float4x4 &transform [[buffer(1)]]
) {
    StrokeVertexOut out;
    out.position = transform * float4(in.position, 0.0, 1.0);
    out.texCoord = in.texCoord;
    out.opacity = in.opacity;
    return out;
}

// Canvas textures hold premultiplied alpha: the compositor blends with (one, 1 - srcAlpha),
// so every stroke shader has to return colour already scaled by its coverage.
static inline float4 premultiplied(float3 rgb, float alpha) {
    alpha = saturate(alpha);
    return float4(rgb * alpha, alpha);
}

// --- Pigment mixing ---
//
// A brush that mixes pigments combines its paint with what is under it the way paints mix
// (Kubelka-Munk; see Spectral.h) rather than by averaging light, so yellow over blue makes
// green. Coverage still adds up as it does for any stroke; only the colour of the mixture
// is different.

/// The straight colour of a premultiplied pixel.
static inline float3 straight(float4 p) { return p.a > 1e-5 ? p.rgb / p.a : float3(0.0); }

/// `src` over `dst`, both premultiplied, the overlap's colour mixed as pigments.
static inline float4 pigmentOver(float4 src, float4 dst) {
    float outA = src.a + dst.a * (1.0 - src.a);
    if (src.a <= 1e-5) return dst;
    if (dst.a <= 1e-5 || outA <= 1e-5) return src;
    // The new paint's share of what is there afterwards
    float t = src.a / outA;
    return float4(spectral::mixP3(straight(dst), straight(src), t) * outA, outA);
}

/// mix(dst, paint, k) for premultiplied pixels, the colour mixed as pigments.
static inline float4 pigmentLerp(float4 dst, float4 paint, float k) {
    float a = mix(dst.a, paint.a, k);
    float wp = paint.a * k, wd = dst.a * (1.0 - k);
    if (wp <= 1e-5) return dst * (1.0 - k);
    if (wd <= 1e-5) return paint * k;
    return float4(spectral::mixP3(straight(dst), straight(paint), wp / (wp + wd)) * a, a);
}

// Round tip: uses 2D radial distance from the center of the quad.
// Used for stroke caps (start/end) to produce smooth rounded endpoints like Procreate.
fragment float4 strokeRadialFragment(
    StrokeVertexOut in [[stage_in]],
    constant float4 &brushColor [[buffer(0)]],
    constant float &hardness [[buffer(1)]]
) {
    float dist = distance(in.texCoord, float2(0.5, 0.5)) * 2.0;

    float alpha;
    if (hardness >= 0.99) {
        alpha = 1.0 - step(1.0, dist);
    } else {
        float inner = hardness;
        alpha = 1.0 - smoothstep(inner, 1.0, dist);
    }
    return premultiplied(brushColor.rgb, brushColor.a * alpha * in.opacity);
}

// Procedural brush: uses texCoord.x as cross-stroke distance (0=left edge, 1=right edge)
// For triangle strip rendering, the stroke is a continuous ribbon.
fragment float4 strokeProceduralFragment(
    StrokeVertexOut in [[stage_in]],
    constant float4 &brushColor [[buffer(0)]],
    constant float &hardness [[buffer(1)]]
) {
    // Cross-stroke distance: 0 at left edge, 0.5 at center, 1 at right edge
    float dist = abs(in.texCoord.x - 0.5) * 2.0; // 0 at center, 1 at edge

    float alpha;
    if (hardness >= 0.99) {
        alpha = 1.0 - step(1.0, dist);
    } else {
        float inner = hardness;
        alpha = 1.0 - smoothstep(inner, 1.0, dist);
    }

    return premultiplied(brushColor.rgb, brushColor.a * alpha * in.opacity);
}

// --- Stamp (dab) rendering ---
//
// A stamp brush draws many copies of its tip along the stroke. Each dab is one instance:
// a quad placed, sized and turned in the vertex shader. Dabs blend source-over into the
// stroke texture, so they add up the way flow does in any paint program.

struct StampInstance {
    packed_float2 center;   // canvas pixels
    float size;             // diameter in canvas pixels
    float angle;            // radians
    float opacity;
    float seed;             // 0..<1, different for every dab
    float reach;            // 0..1: how firmly the dab is pressed into the paper's tooth
    float aspect;           // length-to-width ratio along the dab's x axis
    float pathDistance;     // how far along the stroke the dab sits
    float secondAngle;      // rotation of the second tip, radians
    float fan;              // how wide a bristle bundle is here, 0...1 of its full width
    float gap;              // how far its clumps have parted, 0...1
    float strokeSeed;       // the stroke's, 0...65535: marks are laid out afresh each stroke
};

struct StampVertexOut {
    float4 position [[position]];
    float2 uv;          // 0..1 across the dab
    float2 canvas;      // canvas pixels
    float2 along;       // canvas pixels along and across the stroke, for stroke-attached grain
    float  opacity;
    float  seed;
    float  reach;
    float  secondAngle;
    float  fan;
    float  gap;
    float  size;        // the dab's diameter, canvas pixels
    float  strokeSeed;
};

struct StampParams {
    float4 color;
    float  hardness;
    int    tipIsTexture;
    int    grainMode;        // 0 = none, 1 = multiply, 2 = height
    float  grainScale;       // texture pixels per canvas pixel
    float  grainDepth;
    int    grainOnStroke;    // 0 = fixed to the canvas, 1 = runs along the stroke
    int    hasSecondTip;
    float  secondTipScale;   // size of the second tip relative to the dab
    float  thickness;        // height one dab at full coverage adds (impasto)
    int    usesCarry;        // 1: the dab's colour and amount come from the carry texture
    float2 carryTexels;      // texels of the carry in use
    float  grooves;          // grooves along the stroke cut into the height a dab leaves, 0...1
    int    bristleCount;     // above 0, the tip is a bundle of this many clumps (see bristleBundle)
    float  dryBrush;         // how much a light touch skips the paper's valleys, 0...1
    int    grainProcedural;  // 1: the grain is bristleStreaks, not the grain texture
};

// --- Noise for the marks ---
//
// Value noise on a hashed lattice: the same wherever a mark is drawn again (undo, replay,
// the goldens), and never tiling. `seed` is the stroke's, so no two strokes share a layout.

static inline float latticeHash(int2 p, uint seed) {
    uint h = uint(p.x) * 374761393u + uint(p.y) * 668265263u + seed * 2246822519u;
    h = (h ^ (h >> 13)) * 1274126177u;
    return float((h ^ (h >> 16)) & 0xFFFFFFu) / 16777216.0;
}

static inline float valueNoise(float2 p, uint seed) {
    float2 i = floor(p), f = p - i;
    float2 u = f * f * (3.0 - 2.0 * f);
    int2 c = int2(i);
    float a = latticeHash(c, seed), b = latticeHash(c + int2(1, 0), seed);
    float d = latticeHash(c + int2(0, 1), seed), e = latticeHash(c + int2(1, 1), seed);
    return mix(mix(a, b, u.x), mix(d, e, u.x), u.y);
}

// The marks a loaded brush's bristles leave, as a height 0...1: streaks fine across the
// stroke and slowly varying along it, with breaks, that slide sideways as the stroke goes on
// rather than running dead straight, laid out afresh for every stroke. In place of the
// bristle grain image, which tiled and was the same stripes in every stroke. `along` is
// canvas pixels along and across the stroke; `scale` the brush's grain scale.
static inline float bristleStreaks(float2 along, float scale, uint seed) {
    float2 p = along * scale;
    float drift = 3.0 * sin(p.x / 60.0 + float(seed & 0xFFu) * 0.1);
    float stripe = valueNoise(float2(p.x / 73.0, (p.y + drift) / 4.6), seed) * 0.65
                 + valueNoise(float2(p.x / 36.0, (p.y + drift) / 2.3), seed ^ 0xA7u) * 0.35;
    float breaks = valueNoise(p / 18.0, seed ^ 0x3Cu);
    float h = stripe * 0.8 + breaks * 0.2;
    // Spread over 0...1 nearly as widely as the image's ranked heights were (a spread of
    // 0.26 against 0.29, with 6% at the ends rather than none)
    return saturate((h - 0.5) * 2.0 + 0.5);
}

// --- Bristles ---
//
// The tip as a bundle: clumps of bristles across the dab, each a streak along it with its
// own width and length, at homes in the dab's space that are laid out afresh for every
// stroke and wander as the stroke goes on, crossing and parting, swelling and thinning; two
// stray hairs beyond the bundle come and go. All within the tip's disc. At a light touch
// the bundle narrows about its middle (`fan` below 1); at speed the clumps thin apart
// (`gap` above 0), so the stroke breaks into streaks. A pixel takes the clump that covers
// it most, and reads a loaded brush's carry at that clump's home (its home, not where it
// has wandered to), so each clump keeps its own paint wherever the bundle has put it.

// Four random bytes for a clump from one hash: the loop below runs per pixel, per clump,
// under twenty overlapping dabs, so every hash and sine in it counts.
static inline uint bristleBits(int k, int salt, uint seed) {
    uint h = uint(k + 1) * 2654435761u ^ (uint(salt) + seed * 7919u) * 2246822519u;
    h ^= h >> 13; h *= 3266489917u; h ^= h >> 16;
    return h;
}
static inline float byteUnit(uint h, int byte) { return float((h >> (8 * byte)) & 0xFFu) / 255.0; }

struct Bundle {
    float coverage;
    float2 carryUV;    // where in the carry this pixel's clump keeps its paint
};

// One clump of the bundle at a point of the stroke: its home across the dab, where it is
// now, and its own width and length.
struct Clump {
    float home;
    float pos;
    float halfWidth;
    float halfLength;
};

static inline Clump clumpAt(int k, int count, float fan, float along, float swayPhase, uint seed) {
    uint bits = bristleBits(k, 1, seed), more = bristleBits(k, 2, seed);
    Clump c;
    // Evenly across the dab, each a little off its place
    c.home = 0.05 + 0.9 * (float(k) + 0.5 + (byteUnit(bits, 0) - 0.5) * 0.4) / float(count);
    // Wandering as the stroke goes on: the tuft sways as a whole (over six and a half
    // diameters), and each clump a little on its own, so now and then two cross or part
    float phase = byteUnit(bits, 1) * 6.2832;
    float sway = 0.07 * sin(along * 0.9666 + swayPhase + c.home * 2.5);
    float own = 0.025 * sin(along * 6.2832 / (4.0 + 5.0 * byteUnit(bits, 2)) + phase);
    c.pos = 0.5 + (c.home - 0.5 + sway + own) * fan;
    // Swelling and thinning along the way
    float swell = 1.0 + 0.15 * sin(along * 6.2832 / (2.0 + 3.0 * byteUnit(more, 0)) + phase * 2.3);
    c.halfWidth = (0.6 / float(count)) * (0.8 + 0.6 * byteUnit(bits, 3)) * swell;
    c.halfLength = 0.5 * (0.6 + 0.4 * byteUnit(more, 1));
    return c;
}

// `edge` is the antialiasing width in dab units (a pixel's, or a constant in a kernel);
// `along` how far along the stroke this pixel is, in diameters; `seed` the stroke's.
// `strays` lays the stray hairs: not for the carry's home layout, which has no use for them.
static inline Bundle bristleBundle(float2 uv, float fan, float gap, int count, float edge, float along, uint seed, bool strays) {
    Bundle b;
    b.coverage = 0.0;
    b.carryUV = uv;
    // The bundle sits in the tip's disc, so the stroke's ends are round, if ragged
    float disc = 1.0 - smoothstep(0.8, 1.0, distance(uv, float2(0.5)) * 2.0);
    if (disc <= 0.0) return b;
    float swayPhase = byteUnit(bristleBits(0, 8, seed), 0) * 6.2832;
    // Each clump once, its neighbour carried over (no arrays: a fragment spills those)
    Clump next = clumpAt(0, count, fan, along, swayPhase, seed);
    float toNext = 0.0;
    for (int k = 0; k < count; k++) {
        Clump c = next;
        if (k + 1 < count) {
            next = clumpAt(k + 1, count, fan, along, swayPhase, seed);
            toNext = abs(next.pos - c.pos);
        }
        // Wide enough to overlap the next clump, wherever both have got to (three quarters
        // of the way to it: the sides are soft, so the tone still dips where clumps meet),
        // until the bundle parts: a gap through the stroke comes from speed, not wandering
        float halfWidth = max(c.halfWidth, toNext * 0.75) * (1.0 - 0.65 * gap);
        float2 d = abs(uv - float2(0.5, c.pos));
        // A rounded bristle: soft at its sides, so where clumps meet the tone dips
        float soft = max(edge, halfWidth * 0.6);
        float cov = (1.0 - smoothstep(max(0.0, halfWidth - soft), halfWidth, d.y))
                  * (1.0 - smoothstep(max(0.0, c.halfLength - 0.06), c.halfLength, d.x));
        if (cov > b.coverage) {
            b.coverage = cov;
            b.carryUV = float2(uv.x, c.home + (uv.y - c.pos));
        }
    }
    if (strays) {
        // Two stray hairs: out at the bundle's full width whatever the touch, so they stand
        // apart when the bundle narrows, there for a stretch of the stroke and gone for one
        for (int k = 0; k < 2; k++) {
            float home = k == 0 ? 0.06 : 0.94;
            float there = valueNoise(float2(along * 0.35 + byteUnit(bristleBits(count + k, 5, seed), 0) * 50.0, 0.5), seed ^ 0x5742u);
            if (there < 0.62) continue;
            float halfWidth = 0.012 * (1.0 - 0.5 * gap), halfLength = 0.4;
            float2 d = abs(uv - float2(0.5, home));
            float soft = max(edge, halfWidth * 0.6);
            float cov = (1.0 - smoothstep(max(0.0, halfWidth - soft), halfWidth, d.y))
                      * (1.0 - smoothstep(max(0.0, halfLength - 0.06), halfLength, d.x));
            if (cov > b.coverage) {
                b.coverage = cov;
                b.carryUV = float2(uv.x, home + (uv.y - home));
            }
        }
    }
    b.coverage *= disc;
    return b;
}

static inline float bristleCoverageFlat(float2 uv, float fan, float gap, int count, float along, uint seed, bool strays) {
    return bristleBundle(uv, fan, gap, count, 0.02, along, seed, strays).coverage;
}

/// The paint a loaded brush's carry holds under this fragment: premultiplied, its alpha
/// how much paint the bristle has. Sampled from texel centre to texel centre, as a
/// smudge's carry is.
static inline float4 carriedPaint(float2 uv, constant StampParams &params, texture2d<float> carry, sampler carrySampler) {
    float2 texel = 0.5 + uv * (params.carryTexels - 1.0);
    return carry.sample(carrySampler, texel / float2(carry.get_width(), carry.get_height()));
}

vertex StampVertexOut stampVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    const device StampInstance *dabs [[buffer(0)]],
    constant float4x4 &transform [[buffer(1)]]
) {
    const float2 corners[6] = {
        float2(-0.5, -0.5), float2(0.5, -0.5), float2(0.5, 0.5),
        float2(-0.5, -0.5), float2(0.5, 0.5), float2(-0.5, 0.5),
    };
    StampInstance dab = dabs[instanceID];
    float2 corner = corners[vertexID];
    float c = cos(dab.angle), sn = sin(dab.angle);
    float2 stretched = float2(corner.x * dab.aspect, corner.y) * dab.size;
    float2 offset = float2(stretched.x * c - stretched.y * sn, stretched.x * sn + stretched.y * c);
    float2 canvas = float2(dab.center) + offset;

    StampVertexOut out;
    out.position = transform * float4(canvas, 0.0, 1.0);
    out.uv = corner + 0.5;
    out.canvas = canvas;
    out.along = float2(dab.pathDistance + stretched.x, stretched.y);
    out.opacity = dab.opacity;
    out.seed = dab.seed;
    out.reach = dab.reach;
    out.secondAngle = dab.secondAngle;
    out.fan = dab.fan;
    out.gap = dab.gap;
    out.size = dab.size;
    out.strokeSeed = dab.strokeSeed;
    return out;
}

/// A dab's coverage at this fragment: the tip's shape (or the bristle bundle's), the second
/// tip's mask, grain, and dry-brushing over the paper. `carryUV` comes back as where a
/// loaded brush's carry is read for this pixel: the pixel itself, or its clump's home.
static inline float stampCoverage(
    StampVertexOut in, constant StampParams &params,
    texture2d<float> tip, texture2d<float> grain, texture2d<float> secondTip, texture2d<float> paper,
    sampler tipSampler, sampler grainSampler, thread float2 &carryUV
) {
    float coverage;
    carryUV = in.uv;
    if (params.bristleCount > 0) {
        Bundle bundle = bristleBundle(in.uv, in.fan, in.gap, params.bristleCount, fwidth(in.uv.x),
                                      in.along.x / max(in.size, 1.0), uint(in.strokeSeed), true);
        coverage = bundle.coverage;
        carryUV = bundle.carryUV;
    } else if (params.tipIsTexture != 0) {
        coverage = tip.sample(tipSampler, in.uv).r;
    } else {
        float dist = distance(in.uv, float2(0.5)) * 2.0;
        if (params.hardness >= 0.99) {
            // One pixel of antialiasing on a hard edge
            float edge = fwidth(dist);
            coverage = 1.0 - smoothstep(1.0 - edge, 1.0, dist);
        } else {
            coverage = 1.0 - smoothstep(params.hardness, 1.0, dist);
        }
    }

    if (params.hasSecondTip != 0) {
        // The second tip is sampled in the dab's own space, turned and scaled about its
        // centre; the repeating sampler lets a small one tile across the dab.
        float c = cos(in.secondAngle), sn = sin(in.secondAngle);
        float2 centred = (in.uv - 0.5) / params.secondTipScale;
        float2 uv = float2(centred.x * c - centred.y * sn, centred.x * sn + centred.y * c) + 0.5;
        coverage *= secondTip.sample(grainSampler, uv).r;
    }

    float alpha = coverage * in.opacity;

    if (params.grainMode != 0) {
        // Paper is fixed to the canvas, so every stroke meets the same tooth; bristle
        // streaks run along the stroke and bend with it.
        float2 where = params.grainOnStroke != 0 ? in.along : in.canvas;
        float height;
        if (params.grainProcedural != 0) {
            // Bristle streaks, laid out for this stroke; streakier the faster the stroke
            height = bristleStreaks(where, params.grainScale, uint(in.strokeSeed));
            height = saturate((height - 0.5) * (1.0 + 0.4 * in.gap) + 0.5);
        } else {
            height = grain.sample(grainSampler, where * params.grainScale / float(grain.get_width())).r;
        }
        if (params.grainMode == 1) {
            alpha *= mix(1.0, height, params.grainDepth);
        } else {
            // Pigment lands on the paper's peaks first and only reaches the valleys as the
            // pen presses harder. `grainDepth` is how much pressure the deepest valley
            // takes to reach; the ramp below it keeps the edge of each fleck soft. Pressure
            // falls off towards a soft tip's edge, so the edge stays on the peaks longer.
            float press = in.reach * mix(1.0, coverage, 0.5);
            alpha *= saturate((press - (1.0 - height) * params.grainDepth) / 0.3);
        }
    }
    if (params.dryBrush > 0.0) {
        // Dry-brushing: a light touch reaches only the peaks of the paper's tooth; pressed
        // fully it reaches the valleys too
        float height = paper.sample(grainSampler, in.canvas / float(paper.get_width())).r;
        alpha *= saturate((in.reach - (1.0 - height) * params.dryBrush * 0.7) / 0.3);
    }
    return alpha;
}

fragment float4 stampFragment(
    StampVertexOut in [[stage_in]],
    texture2d<float> tip [[texture(0)]],
    texture2d<float> grain [[texture(1)]],
    texture2d<float> secondTip [[texture(2)]],
    texture2d<float> carry [[texture(3)]],
    texture2d<float> paper [[texture(5)]],
    sampler tipSampler [[sampler(0)]],
    sampler grainSampler [[sampler(1)]],
    sampler carrySampler [[sampler(2)]],
    constant StampParams &params [[buffer(0)]]
) {
    float2 carryUV;
    float alpha = stampCoverage(in, params, tip, grain, secondTip, paper, tipSampler, grainSampler, carryUV);
    if (params.usesCarry != 0) {
        // The carry is premultiplied by the bristle's load: a bristle out of paint leaves nothing
        return carriedPaint(saturate(carryUV), params, carry, carrySampler) * saturate(params.color.a * alpha);
    }
    return premultiplied(params.color.rgb, params.color.a * alpha);
}

// The same dab as paint thickness, added to the layer's height map (impasto). Grain
// shapes it as it shapes the colour, so bristle streaks stand up as ridges.
fragment float4 stampHeightFragment(
    StampVertexOut in [[stage_in]],
    texture2d<float> tip [[texture(0)]],
    texture2d<float> grain [[texture(1)]],
    texture2d<float> secondTip [[texture(2)]],
    texture2d<float> carry [[texture(3)]],
    texture2d<float> paper [[texture(5)]],
    sampler tipSampler [[sampler(0)]],
    sampler grainSampler [[sampler(1)]],
    sampler carrySampler [[sampler(2)]],
    constant StampParams &params [[buffer(0)]]
) {
    float2 carryUV;
    float alpha = stampCoverage(in, params, tip, grain, secondTip, paper, tipSampler, grainSampler, carryUV);
    // Less paint on the bristle, less thickness left behind
    float load = params.usesCarry != 0 ? carriedPaint(saturate(carryUV), params, carry, carrySampler).a : 1.0;
    // The bristles leave grooves along the stroke, cut into the height: the bristle streaks,
    // attached to the stroke, so they run with it and bend with it, and line up with the
    // streaks a brush grained with them has in its colour (at that brush's grain scale)
    float groove = params.grooves > 0.0
        ? 1.0 - params.grooves * (1.0 - bristleStreaks(in.along, params.grainProcedural != 0 ? params.grainScale : 1.0, uint(in.strokeSeed))) : 1.0;
    return float4(alpha * params.thickness * load * groove, 0.0, 0.0, 1.0);
}

// --- Smudge ---
//
// A smudge brush carries paint. For every dab it first lays down what it carries, straight
// into the layer, then picks up what is under it to carry on to the next dab. The carried
// paint lives in a small texture mapped to the dab's quad (the "carry"); laying it down
// blends the layer towards it by the dab's strength, alpha included, so paint dragged off
// its edge thins that edge the way a finger would.

struct SmudgeParams {
    float4 color;
    float  hardness;
    int    tipIsTexture;
    float  colorRate;        // how much of the brush's own colour goes in with the carried paint
    float2 carryTexels;      // texels of the carry texture in use, from the last pickup
    uint2  backdropOrigin;   // where the backdrop's copy of the layer starts, in layer pixels
    int    mixPigments;
};

static inline float tipCoverage(float2 uv, float hardness, int tipIsTexture,
                                texture2d<float> tip, sampler tipSampler) {
    if (tipIsTexture != 0) return tip.sample(tipSampler, uv).r;
    float dist = distance(uv, float2(0.5)) * 2.0;
    if (hardness >= 0.99) {
        float edge = fwidth(dist);
        return 1.0 - smoothstep(1.0 - edge, 1.0, dist);
    }
    return 1.0 - smoothstep(hardness, 1.0, dist);
}

// The dab's quad is drawn with `stampVertex` straight onto the layer, with no blending:
// the layer pixel comes in through `backdrop`, a copy of the patch under the dab, and the
// fragment writes mix(layer, paint, k) itself, alpha included.
fragment float4 smudgeDepositFragment(
    StampVertexOut in [[stage_in]],
    texture2d<float> tip [[texture(0)]],
    texture2d<float> carry [[texture(1)]],
    texture2d<float> backdrop [[texture(2)]],
    sampler tipSampler [[sampler(0)]],
    sampler carrySampler [[sampler(1)]],
    constant SmudgeParams &params [[buffer(0)]]
) {
    float k = tipCoverage(in.uv, params.hardness, params.tipIsTexture, tip, tipSampler) * in.opacity;
    float4 layer = backdrop.read(uint2(in.position.xy) - params.backdropOrigin);
    // Sample from texel centre to texel centre so nothing outside the picked-up area bleeds in
    float2 texel = 0.5 + in.uv * (params.carryTexels - 1.0);
    float4 paint = carry.sample(carrySampler, texel / float2(carry.get_width(), carry.get_height()));
    float4 own = premultiplied(params.color.rgb, params.color.a);
    if (params.mixPigments != 0) {
        paint = pigmentLerp(paint, own, params.colorRate);
        return pigmentLerp(layer, paint, k);
    }
    paint = mix(paint, own, params.colorRate);
    return mix(layer, paint, k);
}

// The carried paint's thickness, likewise: a plain mix. The brush's own colour brings
// no thickness with it.
fragment float4 smudgeDepositHeightFragment(
    StampVertexOut in [[stage_in]],
    texture2d<float> tip [[texture(0)]],
    texture2d<float> carry [[texture(1)]],
    texture2d<float> backdrop [[texture(2)]],
    sampler tipSampler [[sampler(0)]],
    sampler carrySampler [[sampler(1)]],
    constant SmudgeParams &params [[buffer(0)]]
) {
    float k = tipCoverage(in.uv, params.hardness, params.tipIsTexture, tip, tipSampler) * in.opacity;
    float layer = backdrop.read(uint2(in.position.xy) - params.backdropOrigin).r;
    float2 texel = 0.5 + in.uv * (params.carryTexels - 1.0);
    float carried = carry.sample(carrySampler, texel / float2(carry.get_width(), carry.get_height())).r;
    carried *= 1.0 - params.colorRate;
    return float4(mix(layer, carried, k), 0.0, 0.0, 1.0);
}

struct SmudgePickupParams {
    float2 center;           // the dab, in canvas pixels
    float  size;
    float  angle;
    float  aspect;
    float2 canvasSize;
    float2 carryTexels;      // the part of the carry texture being written
    int    dulling;          // 1: pick up one average colour instead of the paint's layout
    float  hardness;
    int    tipIsTexture;
};

struct SmudgePickupOut {
    float4 position [[position]];
    float2 uv;
};

// Fills the viewport.
vertex SmudgePickupOut smudgePickupVertex(uint vertexID [[vertex_id]]) {
    const float2 corners[6] = {
        float2(-1, -1), float2(1, -1), float2(1, 1),
        float2(-1, -1), float2(1, 1), float2(-1, 1),
    };
    SmudgePickupOut out;
    out.position = float4(corners[vertexID], 0, 1);
    // Texel (0, 0), top-left of the viewport, holds the dab's uv (0, 0); deposit reads the
    // texels in the same order.
    out.uv = float2(corners[vertexID].x * 0.5 + 0.5, 0.5 - corners[vertexID].y * 0.5);
    return out;
}

static inline float4 layerUnderDab(float2 uv, constant SmudgePickupParams &p,
                                   texture2d<float> layer, sampler canvasSampler) {
    float2 stretched = (uv - 0.5) * float2(p.size * p.aspect, p.size);
    float c = cos(p.angle), sn = sin(p.angle);
    float2 canvas = p.center + float2(stretched.x * c - stretched.y * sn, stretched.x * sn + stretched.y * c);
    return layer.sample(canvasSampler, float2(canvas.x / p.canvasSize.x, 1.0 - canvas.y / p.canvasSize.y));
}

fragment float4 smudgePickupFragment(
    SmudgePickupOut in [[stage_in]],
    texture2d<float> layer [[texture(0)]],
    texture2d<float> tip [[texture(1)]],
    sampler canvasSampler [[sampler(0)]],
    sampler tipSampler [[sampler(1)]],
    constant SmudgePickupParams &p [[buffer(0)]]
) {
    if (p.dulling != 0) {
        // One colour for the whole dab: the paint under it, weighted by the tip's shape.
        // Premultiplied values average correctly as they are.
        const int taps = 8;
        float4 sum = 0.0;
        float weight = 0.0;
        for (int j = 0; j < taps; j++) {
            for (int i = 0; i < taps; i++) {
                float2 uv = (float2(i, j) + 0.5) / float(taps);
                float w = tipCoverage(uv, p.hardness, p.tipIsTexture, tip, tipSampler);
                sum += layerUnderDab(uv, p, layer, canvasSampler) * w;
                weight += w;
            }
        }
        return weight > 0.0 ? sum / weight : float4(0.0);
    }
    // Texel i holds the paint at uv i / (texels - 1), matching how deposit samples it
    float2 uv = (in.uv * p.carryTexels - 0.5) / max(p.carryTexels - 1.0, 1.0);
    return layerUnderDab(uv, p, layer, canvasSampler);
}

// --- Compositing ---

struct CompositeVertexIn {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct CompositeVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex CompositeVertexOut compositeVertex(
    CompositeVertexIn in [[stage_in]],
    constant float4x4 &transform [[buffer(1)]]
) {
    CompositeVertexOut out;
    out.position = transform * float4(in.position, 0.0, 1.0);
    out.texCoord = in.texCoord;
    return out;
}

fragment float4 compositeNormal(
    CompositeVertexOut in [[stage_in]],
    texture2d<float> layer [[texture(0)]],
    sampler s [[sampler(0)]],
    constant float &layerOpacity [[buffer(0)]]
) {
    // Premultiplied source: opacity scales colour and alpha together.
    return layer.sample(s, in.texCoord) * layerOpacity;
}

// Shrinks a texture to a quarter of its size: four bilinear taps, each averaging a 2x2
// block, together a 4x4 box filter. Used to make thumbnails without reading a full layer back.
fragment float4 downsampleFragment(
    CompositeVertexOut in [[stage_in]],
    texture2d<float> source [[texture(0)]],
    sampler s [[sampler(0)]]
) {
    float2 texel = 1.0 / float2(source.get_width(), source.get_height());
    float4 sum = source.sample(s, in.texCoord + texel * float2(-1.0, -1.0))
               + source.sample(s, in.texCoord + texel * float2( 1.0, -1.0))
               + source.sample(s, in.texCoord + texel * float2(-1.0,  1.0))
               + source.sample(s, in.texCoord + texel * float2( 1.0,  1.0));
    return sum * 0.25;
}

// Writes transparent black; drawn under a scissor rect to clear part of a texture.
fragment float4 clearFragment(CompositeVertexOut in [[stage_in]]) {
    return float4(0.0);
}

// --- In-progress stroke ---
//
// While the pen is down the stroke lives in two textures: `committed` holds the part that
// will not change again, `tail` the newest part, which is redrawn every frame. The
// two together are the stroke. It is merged into the active layer's colour *before* that
// layer's opacity and blend mode apply, exactly as it will be once the pen lifts.

// Blend `src` over `dst` — mode: 0=normal, 1=multiply, 2=screen, 3=overlay, 4=darken, 5=lighten.
// Both are premultiplied. For blend modes we un-premultiply the src and dst colours,
// compute the blend, then re-premultiply.
static inline float4 blendOver(float4 src, float4 dst, int mode) {
    float3 srcRGB = src.a > 0.0001 ? src.rgb / src.a : float3(0.0);
    float3 dstRGB = dst.a > 0.0001 ? dst.rgb / dst.a : float3(0.0);

    float3 blended;
    if (mode == 1) {
        // Multiply
        blended = srcRGB * dstRGB;
    } else if (mode == 2) {
        // Screen
        blended = 1.0 - (1.0 - srcRGB) * (1.0 - dstRGB);
    } else if (mode == 3) {
        // Overlay: multiply where dst is dark, screen where dst is light
        float3 mul = 2.0 * srcRGB * dstRGB;
        float3 scr = 1.0 - 2.0 * (1.0 - srcRGB) * (1.0 - dstRGB);
        blended = float3(
            dstRGB.r < 0.5 ? mul.r : scr.r,
            dstRGB.g < 0.5 ? mul.g : scr.g,
            dstRGB.b < 0.5 ? mul.b : scr.b
        );
    } else if (mode == 4) {
        // Darken
        blended = min(srcRGB, dstRGB);
    } else if (mode == 5) {
        // Lighten
        blended = max(srcRGB, dstRGB);
    } else {
        // Normal — fall back to straight source
        blended = srcRGB;
    }

    // The blend only applies where there is a backdrop to blend with; over transparent
    // pixels the source shows through unchanged.
    blended = mix(srcRGB, blended, dst.a);

    // Porter-Duff "source over" with the blended colour, premultiplied result
    float outA = src.a + dst.a * (1.0 - src.a);
    float3 outRGB = blended * src.a + dst.rgb * (1.0 - src.a);
    return float4(outRGB, outA);
}

struct StrokeMergeParams {
    float opacity;      // caps the whole stroke
    int   erase;        // 0 = paint over the layer, 1 = erase from it
    int   accumulates;  // 0 = ribbon (the textures' maximum), 1 = dabs (tail over committed)
    int   mixing;       // how the stroke's colour meets the layer's: 0 light, 1 pigment, 2 glaze
    float wetEdges;     // above 0 the stroke dries as a wash, pigment gathering at its edge
    float granulation;  // above 0 pigment settles into the paper's valleys
    float grainScale;   // paper texels per canvas pixel
    float blendsWhenWet; // above 0 the wash blends into paint still wet instead of glazing it (see wetness())
    float wetNow;       // the layer's wet map is read at this time, seconds since its epoch
    float dryingTime;   // how long paint stays wet at most, seconds
};

// --- Wet and dry ---
//
// A layer's wet map holds, per pixel, the time until which the paint there stays wet, in
// seconds since the layer's wet epoch (CanvasRenderer.clock). Nothing runs to dry it: the
// paint's wetness is read off the clock whenever something asks. Paint is fully wet until
// half of what it was given has gone, then dries off over the rest.
static inline float wetness(texture2d<float> wetMap, sampler s, float2 uv, float now, float dryingTime) {
    float until = wetMap.sample(s, uv).r;
    return saturate((until - now) / max(dryingTime * 0.5, 1e-3));
}

// The wet map's texel under a canvas pixel (origin bottom-left; the map's is top-left).
static inline float2 wetMapCoordinate(float2 canvasPixel, texture2d<float> wetMap) {
    return float2(canvasPixel.x / float(wetMap.get_width()), 1.0 - canvasPixel.y / float(wetMap.get_height()));
}

// A wash drying on paper. `coverage` is the stroke's coverage, 0...1, before its opacity;
// `wet` how wet the paint under it is, which keeps its edge soft and the pigment from
// gathering there.
static inline float4 wetWash(float4 coverage, float2 canvasPixel, float wet, constant StrokeMergeParams &p,
                             texture2d<float> paper, sampler paperSampler) {
    float s = coverage.a;
    if (s <= 0.0) return coverage;
    float height = paper.sample(paperSampler, canvasPixel * p.grainScale / float(paper.get_width())).r;
    float edges = p.wetEdges * (1.0 - wet);
    if (edges > 0.0) {
        // The soft outer falloff becomes a crisp boundary, roughened by the paper, with the
        // pigment that left the middle gathered in a rim just inside it. A pixel's rim is
        // never more than a few times its own coverage, so a faint edge stays faint.
        float boundary = 0.12 + (height - 0.5) * 0.2 * p.granulation;
        float edge = smoothstep(boundary, boundary + 0.08, s);
        float inside = smoothstep(boundary, 1.0, s);
        float rim = smoothstep(boundary, boundary + 0.12, s) * (1.0 - smoothstep(boundary + 0.2, boundary + 0.8, s));
        float middle = inside * (1.0 - 0.4 * edges);
        s = edge * mix(middle, min(1.0, s * 3.0), saturate(1.5 * edges * rim));
    }
    if (p.granulation > 0.0) {
        // More pigment settles in the valleys than stays on the peaks
        s *= 1.0 + p.granulation * (0.5 - height) * 0.8;
    }
    s = saturate(s);
    return float4(straight(coverage) * s, s);
}

// The stroke, at its opacity, onto the layer. A glaze laid into wet paint (`wet` above 0)
// blends with it as pigment instead, by that much.
static inline float4 strokeOnto(float4 stroke, float4 layer, float wet, constant StrokeMergeParams &p) {
    if (p.erase != 0) return layer * (1.0 - stroke.a);
    if (p.mixing == 1) return pigmentOver(stroke, layer);
    if (p.mixing == 2) {
        float4 glazed = blendOver(stroke, layer, 1);   // multiply: a transparent glaze
        return wet > 0.0 ? mix(glazed, pigmentOver(stroke, layer), wet) : glazed;
    }
    return stroke + layer * (1.0 - stroke.a);
}

static inline float4 mergeStroke(float4 coverage, float4 layer, float2 canvasPixel, constant StrokeMergeParams &p,
                                 texture2d<float> paper, sampler paperSampler,
                                 texture2d<float> wetMap, sampler wetSampler) {
    // How wet the paint under the stroke is, for a wash that blends into wet paint
    float wet = p.blendsWhenWet > 0.0
        ? p.blendsWhenWet * wetness(wetMap, wetSampler, wetMapCoordinate(canvasPixel, wetMap), p.wetNow, p.dryingTime) : 0.0;
    if (p.wetEdges > 0.0 || p.granulation > 0.0) coverage = wetWash(coverage, canvasPixel, wet, p, paper, paperSampler);
    return strokeOnto(coverage * p.opacity, layer, wet, p);
}

static inline float4 layerWithStroke(float4 layer, float4 committed, float4 tail, float2 canvasPixel,
                                     constant StrokeMergeParams &params,
                                     texture2d<float> paper, sampler paperSampler,
                                     texture2d<float> wetMap, sampler wetSampler) {
    // A ribbon's two halves are the same coverage drawn twice where they meet, so take the
    // maximum. Dabs in the tail were laid after the committed ones and sit on top of them.
    float4 combined = params.accumulates != 0 ? tail + committed * (1.0 - tail.a) : max(committed, tail);
    return mergeStroke(combined, layer, canvasPixel, params, paper, paperSampler, wetMap, wetSampler);
}

// A finished wet stroke onto its layer's wet map: where the stroke has coverage, the paint
// stays wet until `until`. Drawn with a max blend, so paint already wetter keeps its time.
fragment float4 wetStrokeFragment(
    CompositeVertexOut in [[stage_in]],
    texture2d<float> stroke [[texture(0)]],
    sampler s [[sampler(0)]],
    constant float &until [[buffer(0)]]
) {
    float a = stroke.sample(s, in.texCoord).a;
    return float4(until * saturate(a * 10.0), 0.0, 0.0, 1.0);
}

// The canvas pixel (origin bottom-left, as the stamp shaders see it) under a composite
// fragment, so paper looks the same here as under a stamp brush's grain.
static inline float2 canvasPixel(float2 texCoord, texture2d<float> layer) {
    return float2(texCoord.x * float(layer.get_width()), (1.0 - texCoord.y) * float(layer.get_height()));
}

// Merges a finished stroke into its layer when fixed-function blending will not do (mixing,
// a wash). The result replaces the layer pixel: rendered to a scratch texture and copied
// back, since it reads the layer.
fragment float4 compositeStrokeMerge(
    CompositeVertexOut in [[stage_in]],
    texture2d<float> strokeTex [[texture(0)]],
    texture2d<float> layerTex [[texture(1)]],
    texture2d<float> paper [[texture(4)]],
    texture2d<float> wetMap [[texture(5)]],
    sampler s [[sampler(0)]],
    sampler paperSampler [[sampler(1)]],
    constant StrokeMergeParams &params [[buffer(2)]]
) {
    return mergeStroke(strokeTex.sample(s, in.texCoord), layerTex.sample(s, in.texCoord),
                       canvasPixel(in.texCoord, layerTex), params, paper, paperSampler, wetMap, s);
}

fragment float4 compositeNormalWithStroke(
    CompositeVertexOut in [[stage_in]],
    texture2d<float> layer [[texture(0)]],
    texture2d<float> committed [[texture(2)]],
    texture2d<float> tail [[texture(3)]],
    texture2d<float> paper [[texture(4)]],
    texture2d<float> wetMap [[texture(5)]],
    sampler s [[sampler(0)]],
    sampler paperSampler [[sampler(1)]],
    constant float &layerOpacity [[buffer(0)]],
    constant StrokeMergeParams &stroke [[buffer(2)]]
) {
    float4 merged = layerWithStroke(layer.sample(s, in.texCoord), committed.sample(s, in.texCoord),
                                    tail.sample(s, in.texCoord), canvasPixel(in.texCoord, layer),
                                    stroke, paper, paperSampler, wetMap, s);
    return merged * layerOpacity;
}

fragment float4 compositeBlend(
    CompositeVertexOut in [[stage_in]],
    texture2d<float> srcTex [[texture(0)]],
    texture2d<float> dstTex [[texture(1)]],
    sampler s [[sampler(0)]],
    constant float &layerOpacity [[buffer(0)]],
    constant int &mode [[buffer(1)]]
) {
    float4 src = srcTex.sample(s, in.texCoord) * layerOpacity;
    return blendOver(src, dstTex.sample(s, in.texCoord), mode);
}

fragment float4 compositeBlendWithStroke(
    CompositeVertexOut in [[stage_in]],
    texture2d<float> srcTex [[texture(0)]],
    texture2d<float> dstTex [[texture(1)]],
    texture2d<float> committed [[texture(2)]],
    texture2d<float> tail [[texture(3)]],
    texture2d<float> paper [[texture(4)]],
    texture2d<float> wetMap [[texture(5)]],
    sampler s [[sampler(0)]],
    sampler paperSampler [[sampler(1)]],
    constant float &layerOpacity [[buffer(0)]],
    constant int &mode [[buffer(1)]],
    constant StrokeMergeParams &stroke [[buffer(2)]]
) {
    float4 merged = layerWithStroke(srcTex.sample(s, in.texCoord), committed.sample(s, in.texCoord),
                                    tail.sample(s, in.texCoord), canvasPixel(in.texCoord, srcTex),
                                    stroke, paper, paperSampler, wetMap, s);
    return blendOver(merged * layerOpacity, dstTex.sample(s, in.texCoord), mode);
}

// --- Display ---

fragment float4 displayFragment(
    CompositeVertexOut in [[stage_in]],
    texture2d<float> composite [[texture(0)]],
    sampler s [[sampler(0)]]
) {
    float4 color = composite.sample(s, in.texCoord);
    // Checkerboard for transparency
    float2 checker = floor(in.texCoord * float2(composite.get_width(), composite.get_height()) / 8.0);
    float check = fmod(checker.x + checker.y, 2.0);
    float3 bg = mix(float3(0.8), float3(0.9), check);

    // Alpha composite (premultiplied) over checkerboard
    float3 result = color.rgb + bg * (1.0 - color.a);
    return float4(result, 1.0);
}

// --- Compute Shaders ---

// Masked cut: copies pixels from source where mask > 0.5 into floating texture,
// and clears those pixels from source. All on GPU, no CPU readback.
kernel void maskedCutKernel(
    texture2d<half, access::read_write> source [[texture(0)]],
    texture2d<half, access::write> floating [[texture(1)]],
    texture2d<float, access::read> mask [[texture(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= source.get_width() || gid.y >= source.get_height()) return;

    float maskVal = mask.read(gid).r;
    half4 srcPixel = source.read(gid);

    if (maskVal > 0.5) {
        floating.write(srcPixel, gid);
        source.write(half4(0, 0, 0, 0), gid);
    } else {
        floating.write(half4(0, 0, 0, 0), gid);
    }
}

// Masked clear: sets pixels to transparent where mask > 0.5
/// Write `colour` into `target` wherever `mask` (the size of the region at `origin`) is set:
/// a bucket fill landing, which must leave every other pixel as it is now, not as it was
/// when the fill read the layer.
kernel void maskedFillKernel(
    texture2d<half, access::write> target [[texture(0)]],
    texture2d<float, access::read> mask [[texture(1)]],
    constant float4 &colour [[buffer(0)]],
    constant uint2 &origin [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= mask.get_width() || gid.y >= mask.get_height()) return;
    if (mask.read(gid).r > 0.5) target.write(half4(colour), origin + gid);
}

// Fills a mip level from the level above: each texel the mean of the 2x2 block over it.
// Reads half4, so it serves the composite (rgba16Float) and its height map (r16Float)
// alike. The display pass samples these levels when the canvas is shown smaller than
// 1:1, instead of skipping across level 0 and missing most of it.
kernel void mipKernel(
    texture2d<half, access::read> above [[texture(0)]],
    texture2d<half, access::write> level [[texture(1)]],
    constant uint2 &origin [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint2 at = origin + gid;
    if (at.x >= level.get_width() || at.y >= level.get_height()) return;
    uint2 from = at * 2;
    uint2 last = uint2(above.get_width() - 1, above.get_height() - 1);
    half4 sum = above.read(from)
              + above.read(min(from + uint2(1, 0), last))
              + above.read(min(from + uint2(0, 1), last))
              + above.read(min(from + uint2(1, 1), last));
    level.write(sum * half(0.25), at);
}

kernel void maskedClearKernel(
    texture2d<half, access::read_write> source [[texture(0)]],
    texture2d<float, access::read> mask [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= source.get_width() || gid.y >= source.get_height()) return;

    float maskVal = mask.read(gid).r;
    if (maskVal > 0.5) {
        source.write(half4(0, 0, 0, 0), gid);
    }
}

// Display with solid white background
// Adds a layer's height map into the composite's, at the layer's opacity.
fragment float4 heightAccumulateFragment(
    CompositeVertexOut in [[stage_in]],
    texture2d<float> height [[texture(0)]],
    sampler s [[sampler(0)]],
    constant float &layerOpacity [[buffer(0)]]
) {
    return float4(height.sample(s, in.texCoord).r * layerOpacity, 0.0, 0.0, 1.0);
}

struct ReliefParams {
    float relief;   // how strongly thickness is lit; 0 shows it flat
    float gloss;    // the paint's finish, 0 matte to 1 glossy
    float showWet;  // above 0, the wet map's paint still wet is tinted
    float wetNow;   // seconds since the wet map's epoch
    float dryingTime;
};

fragment float4 displayWhiteFragment(
    CompositeVertexOut in [[stage_in]],
    texture2d<float> composite [[texture(0)]],
    texture2d<float> height [[texture(1)]],
    texture2d<float> wetMap [[texture(2)]],
    sampler s [[sampler(0)]],
    constant ReliefParams &paint [[buffer(0)]]
) {
    float relief = paint.relief;
    float4 color = composite.sample(s, in.texCoord);
    // The composite is premultiplied
    float3 result = color.rgb + float3(1.0) * (1.0 - color.a);
    // How many texels a screen pixel spans (found before the branch: derivatives need
    // every pixel of the quad to take them)
    float2 size = float2(height.get_width(), height.get_height());
    float2 footprint = max(abs(dfdx(in.texCoord)), abs(dfdy(in.texCoord))) * size;

    if (relief > 0.0) {
        // Thick paint catches the light from the top left: a slope facing it is lit, one
        // facing away is shaded, and a ridge gets a glint. Flat paint is left as it is.
        // Thickness adds up without limit as paint is piled on; what is lit saturates
        // softly, so a pile of paint reads as thick rather than as a cliff.
        // The slope is taken across one screen pixel: a texel at 1:1, and with the canvas
        // shown smaller, as many texels as the pixel spans (the sampler is reading a mip
        // level of about that size) — and brought back to a slope per texel, so paint is
        // lit the same however far out the view is, with detail finer than a pixel averaged
        // away rather than picked at random.
        float step = max(1.0, max(footprint.x, footprint.y));
        float2 texel = step / size;
        float hl = 1.0 - exp(-height.sample(s, in.texCoord - float2(texel.x, 0.0)).r);
        float hr = 1.0 - exp(-height.sample(s, in.texCoord + float2(texel.x, 0.0)).r);
        float hu = 1.0 - exp(-height.sample(s, in.texCoord - float2(0.0, texel.y)).r);   // the row above: canvas up
        float hd = 1.0 - exp(-height.sample(s, in.texCoord + float2(0.0, texel.y)).r);
        float h = 1.0 - exp(-height.sample(s, in.texCoord).r);
        float3 n = normalize(float3((hl - hr) * 3.0 * relief / step, (hd - hu) * 3.0 * relief / step, 1.0));
        float3 l = normalize(float3(-0.55, 0.6, 0.6));
        float3 halfway = normalize(l + float3(0.0, 0.0, 1.0));
        // A key light from the top left, and the sky all round, so a slope facing away from
        // the key is shaded, not black
        float diffuse = max(0.0, dot(n, l)) / l.z;    // 1 where the paint is flat
        float sky = 0.5 + 0.5 * n.z;
        // Crevices: paint higher all round leaves less of the sky, so a furrow and the foot
        // of a ridge darken. Looked for close by and a few pixels out, so the paper at the
        // foot of a thick stroke is in its shadow too.
        float2 far = 4.0 * texel;
        float farAround = height.sample(s, in.texCoord + float2(-far.x, 0.0)).r + height.sample(s, in.texCoord + float2(far.x, 0.0)).r
                        + height.sample(s, in.texCoord + float2(0.0, -far.y)).r + height.sample(s, in.texCoord + float2(0.0, far.y)).r;
        float dip = max(0.0, (hl + hr + hu + hd) * 0.25 - h);
        float dipFar = max(0.0, (1.0 - exp(-farAround * 0.25)) - h);
        float occlusion = 1.0 - 0.5 * saturate((dip * 6.0 + dipFar * 1.5) * relief);
        float shade = (0.3 + 0.7 * diffuse) * (0.7 + 0.3 * sky) * occlusion;
        // The finish: a tight bright glint on glossy paint, a broad faint sheen on matte
        float exponent = mix(6.0, 64.0, paint.gloss);
        float glint = pow(max(0.0, dot(n, halfway)), exponent) * mix(0.1, 0.45, paint.gloss) * saturate(h * 4.0) * relief;
        result = result * shade + glint;
    }
    if (paint.showWet > 0.0) {
        // Wet paint shown as a blue sheen that fades as it dries
        float wet = wetness(wetMap, s, in.texCoord, paint.wetNow, paint.dryingTime);
        result = mix(result, float3(0.3, 0.55, 1.0), wet * 0.4);
    }
    return float4(saturate(result), 1.0);
}

// --- Textures compared ---

// Sets the flag if any texel of `a` differs from `b`; for finding layers an undo snapshot
// need not copy again. Reads half4, so it serves rgba16Float and r16Float alike.
kernel void texturesDifferKernel(
    texture2d<half, access::read> a [[texture(0)]],
    texture2d<half, access::read> b [[texture(1)]],
    device atomic_uint *differ [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= a.get_width() || gid.y >= a.get_height()) return;
    if (any(a.read(gid) != b.read(gid))) {
        atomic_store_explicit(differ, 1u, memory_order_relaxed);
    }
}

// --- Pigment mixing on its own ---

// Mixes pairs of Display P3 colours (gamma-encoded, as the canvas holds them) as
// pigments: `pairs[2i]` and `pairs[2i + 1]`, the share of the second in `pairs[2i].w`.
// For tests and tools, not for painting.
kernel void mixPigmentsKernel(
    constant float4 *pairs [[buffer(0)]],
    device float4 *results [[buffer(1)]],
    uint id [[thread_position_in_grid]]
) {
    float4 a = pairs[2 * id], b = pairs[2 * id + 1];
    results[id] = float4(spectral::mixP3(a.rgb, b.rgb, a.w), 1.0);
}

// --- Loaded brush ---
//
// A loaded brush carries paint: a carry texture mapped to the dab, as a smudge's is, holding
// premultiplied colour whose alpha is how much paint that bristle has. Dabs are drawn from
// it (`stampFragment` with `usesCarry`), so a bristle out of paint leaves nothing. Every
// quarter diameter of path the carry is brought up to date for the dab there: what was laid
// has left it, what was crossed has come up into it, and the brush's own colour has seeped
// back. What comes up is read from the layer alone — the paint that was there before this
// stroke — not from the stroke so far, which is the brush's own paint just laid; the
// stroke's colour meets the layer's at the merge, as pigments if the brush mixes them.

struct LoadedBrushParams {
    float2 center;          // the dab, in canvas pixels
    float  size;
    float  angle;
    float  aspect;
    float2 canvasSize;
    float2 carryTexels;     // texels of the carry in use
    float  hardness;
    int    tipIsTexture;
    float  press;           // the dab's opacity: how firmly the bristles touched
    float  depletion;       // shares for this step, 0...1
    float  bleed;
    float  resaturation;
    float4 color;           // the brush's colour, straight, with the load as alpha
    float  variation;       // fill: how unevenly the bristles start
    float  seed;
    int    mixPigments;
    int    usesWet;         // 1: the layer has a wet map, read for how much comes up
    float  wetNow;          // seconds since the layer's wet epoch
    float  dryingTime;
    int    bristleCount;    // above 0, the tip is a bundle: a carry texel touches where its clump is
    uint   strokeSeed;      // the stroke's: the bundle's homes are laid out by it
};

// A tip's coverage without the antialiasing a fragment can do (no derivatives in a kernel).
static inline float tipCoverageFlat(float2 uv, float hardness, int tipIsTexture,
                                    texture2d<float> tip, sampler tipSampler) {
    if (tipIsTexture != 0) return tip.sample(tipSampler, uv).r;
    float dist = distance(uv, float2(0.5)) * 2.0;
    return 1.0 - smoothstep(min(hardness, 0.97), 1.0, dist);
}

// Fills the carry at pen-down: the brush's colour at its load, less along some bristles.
// Bristles run along the dab's x axis, so each row across it is one bristle.
kernel void loadedBrushFillKernel(
    texture2d<float, access::write> carry [[texture(0)]],
    texture2d<float> bristles [[texture(1)]],
    sampler grainSampler [[sampler(0)]],
    constant LoadedBrushParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uint(p.carryTexels.x) || gid.y >= uint(p.carryTexels.y)) return;
    float2 uv = (float2(gid) + 0.5) / p.carryTexels;
    float bristle = bristles.sample(grainSampler, float2(p.seed * 7.0, uv.y * 3.0)).r;
    float load = p.color.a * (1.0 - p.variation * (1.0 - bristle));
    carry.write(premultiplied(p.color.rgb, load), gid);
}

kernel void loadedBrushTransferKernel(
    texture2d<float, access::read_write> carry [[texture(0)]],
    texture2d<float> layer [[texture(1)]],
    texture2d<float> tip [[texture(2)]],
    texture2d<float> wetMap [[texture(3)]],
    sampler canvasSampler [[sampler(0)]],
    sampler tipSampler [[sampler(1)]],
    constant LoadedBrushParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uint(p.carryTexels.x) || gid.y >= uint(p.carryTexels.y)) return;
    float2 uv = (float2(gid) + 0.5) / p.carryTexels;
    // This bristle's touch: the tip's coverage here (the bundle's, at its home layout), by
    // how firmly the dab was pressed
    float k = (p.bristleCount > 0 ? bristleCoverageFlat(uv, 1.0, 0.0, p.bristleCount, 0.0, p.strokeSeed, false)
                                  : tipCoverageFlat(uv, p.hardness, p.tipIsTexture, tip, tipSampler)) * p.press;
    float4 paint = carry.read(gid);

    // What is under the bristle, on the layer
    float2 stretched = (uv - 0.5) * float2(p.size * p.aspect, p.size);
    float c = cos(p.angle), sn = sin(p.angle);
    float2 canvas = p.center + float2(stretched.x * c - stretched.y * sn, stretched.x * sn + stretched.y * c);
    float2 layerUV = float2(canvas.x / p.canvasSize.x, 1.0 - canvas.y / p.canvasSize.y);
    float4 under = layer.sample(canvasSampler, layerUV);

    // 1. What was laid down has left the brush
    paint *= 1.0 - p.depletion * k;
    // 2. What was crossed comes up, if it is still wet: more paint on the bristle, and its
    // colour in the mix. Dry paint stays where it is.
    float wet = p.usesWet != 0 ? wetness(wetMap, canvasSampler, layerUV, p.wetNow, p.dryingTime) : 0.0;
    float pick = p.bleed * k * under.a * wet;
    if (pick > 1e-4) {
        float a = min(1.0, paint.a + pick);
        float share = pick / (paint.a + pick);
        float3 colour = paint.a > 1e-5
            ? (p.mixPigments != 0 ? spectral::mixP3(straight(paint), straight(under), share)
                                  : mix(straight(paint), straight(under), share))
            : straight(under);
        paint = premultiplied(colour, a);
    }
    // 3. The brush's own paint seeps back, towards how it was loaded
    float4 own = premultiplied(p.color.rgb, p.color.a);
    paint = p.mixPigments != 0 ? pigmentLerp(paint, own, p.resaturation) : mix(paint, own, p.resaturation);
    carry.write(paint, gid);
}

// --- Thick paint pushed ---
//
// A dab pressed into paint already there pushes some of it out: to the rim of the dab, and
// more ahead of it than behind, so a stroke drives a wave of paint before it that it leaves
// as a ridge where it stops, and a second stroke ploughs a furrow through the first. Per
// dab, on the layer's height map: inside the tip a share of the height is taken away; in a
// band just outside it, what was taken along the ray from the dab's centre is put down,
// falling off with distance from the tip. The sums are arranged so that what the band gains
// is what the tip lost. The rays are integrated from the height map before the push writes
// it, and the push reads only the pixel it writes, so no copy of the patch is needed.

struct ImpastoPushParams {
    float2 center;         // the dab, in canvas pixels
    float  size;
    float  angle;
    float  aspect;
    float2 canvasSize;
    uint2  patchOrigin;    // the patch of the height map under the dab and its band, in layer pixels (top-left origin)
    uint2  patchSize;
    float  hardness;
    int    tipIsTexture;
    float  press;          // how firmly the dab is pressed: its opacity
    float  squeeze;        // share of the paint under the tip pushed out
    float2 heading;        // unit vector of the stroke's motion, canvas axes
    float  forward;        // how much more goes ahead than behind, 0...1
    float  band;           // the band's width outside the tip, as a fraction of the dab's size
    int    bristleCount;   // above 0, the tip is a bundle of this many clumps
    float  fan;            // the bundle's width and parting at this dab
    float  gap;
    float  along;          // how far along the stroke the dab sits, in diameters
    uint   strokeSeed;
    uint   rayCount;       // directions the rays are integrated along (see impastoRayKernel)
};

// The tip's coverage for the push: the bundle's, where it is at this dab, or the one shape's.
static inline float pushCoverage(float2 uv, constant ImpastoPushParams &p, texture2d<float> tip, sampler tipSampler) {
    return p.bristleCount > 0 ? bristleCoverageFlat(uv, p.fan, p.gap, p.bristleCount, p.along, p.strokeSeed, true)
                              : tipCoverageFlat(uv, p.hardness, p.tipIsTexture, tip, tipSampler);
}

// What the band gains along one ray from the dab's centre: the paint the texels under the
// tip along it lost, each step standing for a ring of texels at its radius. Integrated once
// per direction, `rayCount` directions round the dab, and read by the push kernel for every
// pixel of the band on that ray. It used to be summed again for every band pixel, and
// since a step on a bristle brush costs a dozen clumps' worth of hashing and sines, a big
// dab's push ran to seconds of GPU a frame on a phone; now the sum is a few thousand steps
// per dab whatever its size. In the dab's own space, where the tip is the disc of radius
// a half: direction i is at angle 2π i / rayCount.
kernel void impastoRayKernel(
    device float *rays [[buffer(1)]],
    texture2d<float> height [[texture(0)]],
    texture2d<float> tip [[texture(2)]],
    sampler tipSampler [[sampler(0)]],
    constant ImpastoPushParams &p [[buffer(0)]],
    uint index [[thread_position_in_grid]]
) {
    if (index >= p.rayCount) return;
    float theta = float(index) / float(p.rayCount) * 6.2831853;
    float2 dir = float2(cos(theta), sin(theta));
    float c = cos(p.angle), sn = sin(p.angle);
    float share = p.squeeze * p.press;
    const float edge = 0.5;
    int steps = int(clamp(p.size * 0.5, 4.0, 64.0));
    float sum = 0.0;
    for (int i = 0; i < steps; i++) {
        float s = (float(i) + 0.5) / float(steps) * edge;
        float2 q = dir * s;
        float cover = pushCoverage(q + 0.5, p, tip, tipSampler);
        if (cover <= 0.0) continue;
        float2 stretched = q * float2(p.size * p.aspect, p.size);
        float2 qCanvas = p.center + float2(stretched.x * c - stretched.y * sn, stretched.x * sn + stretched.y * c);
        float2 texel = float2(qCanvas.x, p.canvasSize.y - qCanvas.y);
        float hs = height.read(uint2(clamp(texel, float2(0.0), p.canvasSize - 1.0))).r;
        // A step stands for a ring of texels at radius s; its paint, for the band's ring here
        sum += hs * share * cover * s * (edge / float(steps));
    }
    rays[index] = sum;
}

kernel void impastoPushKernel(
    texture2d<float, access::read_write> height [[texture(0)]],
    texture2d<float> tip [[texture(2)]],
    sampler tipSampler [[sampler(0)]],
    constant ImpastoPushParams &p [[buffer(0)]],
    const device float *rays [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= p.patchSize.x || gid.y >= p.patchSize.y) return;
    uint2 pixel = p.patchOrigin + gid;
    float2 canvas = float2(float(pixel.x) + 0.5, p.canvasSize.y - (float(pixel.y) + 0.5));
    // Into the dab's own space: a unit square, the tip the disc of radius a half within it
    float2 d = canvas - p.center;
    float c = cos(p.angle), sn = sin(p.angle);
    float2 local = float2(d.x * c + d.y * sn, -d.x * sn + d.y * c) / float2(p.size * p.aspect, p.size);
    float2 uv = local + 0.5;
    float h = height.read(pixel).r;
    float inside = (all(uv >= 0.0) && all(uv <= 1.0)) ? pushCoverage(uv, p, tip, tipSampler) : 0.0;
    float share = p.squeeze * p.press;
    float lost = h * share * inside;

    // Gained: along the ray from the centre through here, what the texels under the tip
    // lost (impastoRayKernel), between the two directions integrated either side of it
    float gained = 0.0;
    const float edge = 0.5;
    float rho = length(local);
    if (rho >= edge && rho < edge + p.band) {
        float2 dir = local / max(rho, 1e-4);
        float falloff = 1.0 - saturate((rho - edge) / p.band);
        float2 dirCanvas = normalize(float2(dir.x * c - dir.y * sn, dir.x * sn + dir.y * c));
        float bias = 1.0 + p.forward * dot(dirCanvas, p.heading);
        float turn = atan2(dir.y, dir.x) / 6.2831853;
        float at = (turn - floor(turn)) * float(p.rayCount);
        uint below = uint(at) % p.rayCount, above = (below + 1) % p.rayCount;
        float sum = mix(rays[below], rays[above], at - floor(at));
        // Spread over the band's width, a triangle in profile
        gained = falloff * bias * sum / ((edge + p.band / 3.0) * p.band * 0.5);
    }
    height.write(float4(max(0.0, h - lost + gained), 0.0, 0.0, 1.0), pixel);
}

// --- Water that moves ---
//
// A bounded shallow-water model after Curtis et al. 1997, on a rectangle of the layer that
// has had water laid on it (the wet region), at the canvas's resolution or half of it.
// Per texel: free water and how wet the paper under it is (r and g), pigment suspended in
// the water and pigment settled on the paper since the water came (both premultiplied),
// and, at the layer's own resolution, the dry paint that was there before. Each step water
// moves to where the surface is lower — the surface being the water on top of the paper's
// height, tilted by the canvas tilt — and dry paper beside wet draws water into itself,
// which is what makes a wash bloom outward; suspended pigment goes with the water. Water
// dries off, the paper's share more slowly. Pigment settles out, faster where the free
// water is thin and in the paper's valleys, and free water lifts settled pigment back up,
// so in deep water it stays on the move and only comes to rest as the water goes. So the
// pigment rides out to the advancing edge of a wash, where the paper is drinking the
// water, and darkens it; pools in the grain; and a wet stroke into a wash lifts and shoves
// its pigment outward.

struct WaterParams {
    uint2  size;          // texels of the region
    uint2  origin;        // the region's top-left, in layer pixels
    float  scale;         // layer pixels per texel
    float  layerHeight;   // layer pixels, for the paper's canvas coordinates
    float  paperScale;    // paper texels per layer pixel
    float  flow;          // share of a surface difference that moves between texels per step
    float  paperWeight;   // how much the paper's height tilts the surface
    float2 tilt;          // canvas tilt: surface drop per texel across and down
    float  evaporation;   // water lost per step
    float  settling;      // share of suspended pigment settling per step in deep water
    float  granulation;   // how much more settles in the valleys than on the peaks
    float  wick;          // how much water dry paper draws from a wet neighbour per step
    float  capacity;      // free water that wets the paper through at once
    float  lift;          // share of settled pigment free water lifts back up per step
    float  mobility;      // how freely pigment moves with the water, 0...1: less than freely
};

// The paper is fixed to the canvas, as every brush's grain sees it (origin bottom-left).
static inline float paperHeightAt(texture2d<float> paper, sampler s, float2 layerPx, constant WaterParams &p) {
    float2 canvas = float2(layerPx.x, p.layerHeight - layerPx.y);
    return paper.sample(s, canvas * p.paperScale / float(paper.get_width())).r;
}

static inline float waterSurface(float w, float h, float2 texel, constant WaterParams &p) {
    return w + p.paperWeight * (h - 0.5) + dot(p.tilt, texel);
}

// How far pigment may pass into paper this wet: not at all until it is half wet through.
static inline float waterGate(float soaked) {
    return saturate((soaked - 0.4) / 0.4);
}

// How much water leaves each texel for its four neighbours (left, right, up, down).
kernel void waterFluxKernel(
    texture2d<float> water [[texture(0)]],
    texture2d<float> paper [[texture(1)]],
    texture2d<float, access::write> flux [[texture(2)]],
    sampler paperSampler [[sampler(0)]],
    constant WaterParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= p.size.x || gid.y >= p.size.y) return;
    float w = water.read(gid).r;
    if (w <= 1e-5) { flux.write(float4(0.0), gid); return; }
    float2 layerPx = (float2(gid) + 0.5) * p.scale + float2(p.origin);
    float s = waterSurface(w, paperHeightAt(paper, paperSampler, layerPx, p), float2(gid), p);
    const int2 dirs[4] = { int2(-1, 0), int2(1, 0), int2(0, -1), int2(0, 1) };
    float4 out = float4(0.0);
    for (int k = 0; k < 4; k++) {
        int2 n = int2(gid) + dirs[k];
        // The region's edge is a wall
        if (n.x < 0 || n.y < 0 || n.x >= int(p.size.x) || n.y >= int(p.size.y)) continue;
        float2 wet = water.read(uint2(n)).rg;
        float2 npx = (float2(n) + 0.5) * p.scale + float2(p.origin);
        float sn = waterSurface(wet.r, paperHeightAt(paper, paperSampler, npx, p), float2(n), p);
        // Downhill, and into paper that is not yet wet through, which draws it
        out[k] = p.flow * max(0.0, s - sn) + p.wick * (1.0 - saturate(wet.g)) * min(w, 0.2);
    }
    // Never more than most of what is here, so the step stays stable
    float total = out.x + out.y + out.z + out.w;
    if (total > w * 0.8) out *= w * 0.8 / total;
    flux.write(out, gid);
}

// Move the water and its pigment, dry some off, settle some pigment and lift some.
kernel void waterGatherKernel(
    texture2d<float> water [[texture(0)]],
    texture2d<float> pigment [[texture(1)]],
    texture2d<float> flux [[texture(2)]],
    texture2d<float> paper [[texture(3)]],
    texture2d<float, access::write> waterOut [[texture(4)]],
    texture2d<float, access::write> pigmentOut [[texture(5)]],
    texture2d<float, access::read_write> settled [[texture(6)]],
    sampler paperSampler [[sampler(0)]],
    constant WaterParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= p.size.x || gid.y >= p.size.y) return;
    float2 wet = water.read(gid).rg;
    float w = wet.r, soaked = wet.g;
    float4 g = pigment.read(gid);
    float4 out = flux.read(gid);
    float outTotal = out.x + out.y + out.z + out.w;
    float wNew = w - outTotal;
    // Pigment leaves in the water's proportion, but not as freely: it is hindered by the
    // paper, so it drifts with the flow without smearing as far as the water spreads; and
    // it cannot enter paper that is not yet wet through, which is what pins the hard edge
    // of a wash and piles pigment up there as the water wets the paper ahead of it
    const int2 dirs[4] = { int2(-1, 0), int2(1, 0), int2(0, -1), int2(0, 1) };
    float gOut = 0.0;
    for (int k = 0; k < 4; k++) {
        int2 n = int2(gid) + dirs[k];
        if (out[k] <= 0.0 || n.x < 0 || n.y < 0 || n.x >= int(p.size.x) || n.y >= int(p.size.y)) continue;
        gOut += out[k] * waterGate(water.read(uint2(n)).g);
    }
    float4 gNew = w > 1e-6 ? g * max(0.0, 1.0 - p.mobility * gOut / w) : g;
    float gate = waterGate(soaked);
    // What the neighbours sent this way: the left one's rightward share, and so on
    if (gid.x > 0) {
        uint2 n = uint2(gid.x - 1, gid.y); float f = flux.read(n).y;
        if (f > 0.0) { float wn = water.read(n).r; wNew += f; gNew += pigment.read(n) * (p.mobility * gate * f / wn); }
    }
    if (gid.x + 1 < p.size.x) {
        uint2 n = uint2(gid.x + 1, gid.y); float f = flux.read(n).x;
        if (f > 0.0) { float wn = water.read(n).r; wNew += f; gNew += pigment.read(n) * (p.mobility * gate * f / wn); }
    }
    if (gid.y > 0) {
        uint2 n = uint2(gid.x, gid.y - 1); float f = flux.read(n).w;
        if (f > 0.0) { float wn = water.read(n).r; wNew += f; gNew += pigment.read(n) * (p.mobility * gate * f / wn); }
    }
    if (gid.y + 1 < p.size.y) {
        uint2 n = uint2(gid.x, gid.y + 1); float f = flux.read(n).z;
        if (f > 0.0) { float wn = water.read(n).r; wNew += f; gNew += pigment.read(n) * (p.mobility * gate * f / wn); }
    }
    // The paper under free water wets through, quickly where there is much and slowly
    // where there is little; what it takes up is not lost to the flow (the paper's own
    // water is counted as the wet-area mask, not as a sink), so the thin edge of a wash
    // does not drink the water that would carry it on
    soaked = min(1.0, soaked + min(wNew, p.capacity) / p.capacity * 0.3);
    // Drying off: the free water, much faster where it is thin — the edge of a wash dries
    // first and the water behind flows out to replace it, carrying pigment to the edge —
    // and the paper's wetness over the whole drying time
    wNew = max(0.0, wNew - p.evaporation * (1.0 + 4.0 * (1.0 - saturate(wNew / 0.2))));
    soaked = max(0.0, soaked - p.evaporation * 0.6);
    // Settling: all of it once the free water has gone; otherwise a share per step, more
    // where the water is thin and in the paper's valleys. Free water lifts settled pigment
    // back up, so pigment in deep water stays on the move.
    float4 rest = settled.read(gid);
    float dep, up;
    if (wNew < 1e-4) {
        dep = 1.0;
        up = 0.0;
    } else {
        float2 layerPx = (float2(gid) + 0.5) * p.scale + float2(p.origin);
        float h = paperHeightAt(paper, paperSampler, layerPx, p);
        dep = saturate(p.settling * (1.0 + 12.0 * (1.0 - saturate(wNew / 0.03))) * max(0.1, 1.0 + p.granulation * (0.5 - h) * 1.5));
        up = p.lift * saturate(wNew / 0.1);
    }
    float4 down = gNew * dep, lifted = rest * up;
    waterOut.write(float4(wNew, soaked, 0.0, 1.0), gid);
    pigmentOut.write(gNew - down + lifted, gid);
    settled.write(rest + down - lifted, gid);
}

// A finished stroke onto the region: its pigment into the suspended pigment, mixed in as
// pigment where there is some already, and its coverage as water. Reads the old state and
// writes the new (two targets), since a pass cannot read its own target.
struct WaterInjectParams {
    uint2  size;
    uint2  origin;
    float  scale;
    float2 layerSize;
    float  opacity;      // the stroke's, on its pigment
    float  amount;       // water per unit of coverage
    float  cap;          // most water a texel holds
    int    mixPigments;
};

struct WaterInjectOut {
    float4 water [[color(0)]];
    float4 pigment [[color(1)]];
};

fragment WaterInjectOut waterInjectFragment(
    CompositeVertexOut in [[stage_in]],
    texture2d<float> stroke [[texture(0)]],
    texture2d<float> water [[texture(1)]],
    texture2d<float> pigment [[texture(2)]],
    sampler s [[sampler(0)]],
    constant WaterInjectParams &p [[buffer(0)]]
) {
    float2 layerPx = in.texCoord * float2(p.size) * p.scale + float2(p.origin);
    float4 laid = stroke.sample(s, layerPx / p.layerSize);
    float4 was = pigment.sample(s, in.texCoord);
    float4 fresh = laid * p.opacity;
    float4 mixed;
    if (fresh.a <= 1e-5) mixed = was;
    else if (was.a <= 1e-5) mixed = fresh;
    else mixed = p.mixPigments != 0 ? pigmentOver(fresh, was) : fresh + was * (1.0 - fresh.a);
    WaterInjectOut out;
    float2 wet = water.sample(s, in.texCoord).rg;
    // Water goes down wherever the brush touched, nearly as much at its soft edge as in its
    // middle; it is the pigment that thins towards the edge
    out.water = float4(min(p.cap, wet.r + p.amount * saturate(laid.a * 3.0)), wet.g, 0.0, 1.0);
    out.pigment = mixed;
    return out;
}

// The look of the region for the layer: the pigment, settled and still in the water
// together as the one layer of paint it is, glazed over the dry paint that was there.
// (Drawn as two layers over each other, a wash half settled read lighter than its
// pigment and darkened back as the rest came down.)
struct WaterGlazeParams {
    uint2  size;
    uint2  origin;
    float  scale;
    float2 layerSize;
};

fragment float4 waterGlazeFragment(
    CompositeVertexOut in [[stage_in]],
    texture2d<float> pigment [[texture(0)]],
    texture2d<float> settled [[texture(1)]],
    texture2d<float> dry [[texture(2)]],
    sampler s [[sampler(0)]],
    constant WaterGlazeParams &p [[buffer(0)]]
) {
    float2 layerPx = in.texCoord * p.layerSize;
    float2 uv = (layerPx - float2(p.origin)) / (float2(p.size) * p.scale);
    float4 d = dry.sample(s, uv);   // kept for the region alone, at the layer's resolution
    float4 paint = settled.sample(s, uv) + pigment.sample(s, uv);
    if (paint.a > 1.0) paint /= paint.a;   // piled past full coverage: full, its own colour
    return paint.a > 1e-5 ? blendOver(paint, d, 1) : d;
}
