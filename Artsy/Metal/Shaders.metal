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
};

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
    return out;
}

/// A dab's coverage at this fragment: the tip's shape, the second tip's mask, and grain.
static inline float stampCoverage(
    StampVertexOut in, constant StampParams &params,
    texture2d<float> tip, texture2d<float> grain, texture2d<float> secondTip,
    sampler tipSampler, sampler grainSampler
) {
    float coverage;
    if (params.tipIsTexture != 0) {
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
        float height = grain.sample(grainSampler, where * params.grainScale / float(grain.get_width())).r;
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
    return alpha;
}

fragment float4 stampFragment(
    StampVertexOut in [[stage_in]],
    texture2d<float> tip [[texture(0)]],
    texture2d<float> grain [[texture(1)]],
    texture2d<float> secondTip [[texture(2)]],
    sampler tipSampler [[sampler(0)]],
    sampler grainSampler [[sampler(1)]],
    constant StampParams &params [[buffer(0)]]
) {
    float alpha = stampCoverage(in, params, tip, grain, secondTip, tipSampler, grainSampler);
    return premultiplied(params.color.rgb, params.color.a * alpha);
}

// The same dab as paint thickness, added to the layer's height map (impasto). Grain
// shapes it as it shapes the colour, so bristle streaks stand up as ridges.
fragment float4 stampHeightFragment(
    StampVertexOut in [[stage_in]],
    texture2d<float> tip [[texture(0)]],
    texture2d<float> grain [[texture(1)]],
    texture2d<float> secondTip [[texture(2)]],
    sampler tipSampler [[sampler(0)]],
    sampler grainSampler [[sampler(1)]],
    constant StampParams &params [[buffer(0)]]
) {
    float alpha = stampCoverage(in, params, tip, grain, secondTip, tipSampler, grainSampler);
    return float4(alpha * params.thickness, 0.0, 0.0, 1.0);
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
};

// A wash drying on paper. `coverage` is the stroke's coverage, 0...1, before its opacity.
static inline float4 wetWash(float4 coverage, float2 canvasPixel, constant StrokeMergeParams &p,
                             texture2d<float> paper, sampler paperSampler) {
    float s = coverage.a;
    if (s <= 0.0) return coverage;
    float height = paper.sample(paperSampler, canvasPixel * p.grainScale / float(paper.get_width())).r;
    if (p.wetEdges > 0.0) {
        // The soft outer falloff becomes a crisp boundary, roughened by the paper, with the
        // pigment that left the middle gathered in a rim just inside it. A pixel's rim is
        // never more than a few times its own coverage, so a faint edge stays faint.
        float boundary = 0.12 + (height - 0.5) * 0.2 * p.granulation;
        float edge = smoothstep(boundary, boundary + 0.08, s);
        float inside = smoothstep(boundary, 1.0, s);
        float rim = smoothstep(boundary, boundary + 0.12, s) * (1.0 - smoothstep(boundary + 0.2, boundary + 0.8, s));
        float middle = inside * (1.0 - 0.4 * p.wetEdges);
        s = edge * mix(middle, min(1.0, s * 3.0), saturate(1.5 * p.wetEdges * rim));
    }
    if (p.granulation > 0.0) {
        // More pigment settles in the valleys than stays on the peaks
        s *= 1.0 + p.granulation * (0.5 - height) * 0.8;
    }
    s = saturate(s);
    return float4(straight(coverage) * s, s);
}

// The stroke, at its opacity, onto the layer.
static inline float4 strokeOnto(float4 stroke, float4 layer, constant StrokeMergeParams &p) {
    if (p.erase != 0) return layer * (1.0 - stroke.a);
    if (p.mixing == 1) return pigmentOver(stroke, layer);
    if (p.mixing == 2) return blendOver(stroke, layer, 1);   // multiply: a transparent glaze
    return stroke + layer * (1.0 - stroke.a);
}

static inline float4 mergeStroke(float4 coverage, float4 layer, float2 canvasPixel, constant StrokeMergeParams &p,
                                 texture2d<float> paper, sampler paperSampler) {
    if (p.wetEdges > 0.0 || p.granulation > 0.0) coverage = wetWash(coverage, canvasPixel, p, paper, paperSampler);
    return strokeOnto(coverage * p.opacity, layer, p);
}

static inline float4 layerWithStroke(float4 layer, float4 committed, float4 tail, float2 canvasPixel,
                                     constant StrokeMergeParams &params,
                                     texture2d<float> paper, sampler paperSampler) {
    // A ribbon's two halves are the same coverage drawn twice where they meet, so take the
    // maximum. Dabs in the tail were laid after the committed ones and sit on top of them.
    float4 combined = params.accumulates != 0 ? tail + committed * (1.0 - tail.a) : max(committed, tail);
    return mergeStroke(combined, layer, canvasPixel, params, paper, paperSampler);
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
    sampler s [[sampler(0)]],
    sampler paperSampler [[sampler(1)]],
    constant StrokeMergeParams &params [[buffer(2)]]
) {
    return mergeStroke(strokeTex.sample(s, in.texCoord), layerTex.sample(s, in.texCoord),
                       canvasPixel(in.texCoord, layerTex), params, paper, paperSampler);
}

fragment float4 compositeNormalWithStroke(
    CompositeVertexOut in [[stage_in]],
    texture2d<float> layer [[texture(0)]],
    texture2d<float> committed [[texture(2)]],
    texture2d<float> tail [[texture(3)]],
    texture2d<float> paper [[texture(4)]],
    sampler s [[sampler(0)]],
    sampler paperSampler [[sampler(1)]],
    constant float &layerOpacity [[buffer(0)]],
    constant StrokeMergeParams &stroke [[buffer(2)]]
) {
    float4 merged = layerWithStroke(layer.sample(s, in.texCoord), committed.sample(s, in.texCoord),
                                    tail.sample(s, in.texCoord), canvasPixel(in.texCoord, layer),
                                    stroke, paper, paperSampler);
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
    sampler s [[sampler(0)]],
    sampler paperSampler [[sampler(1)]],
    constant float &layerOpacity [[buffer(0)]],
    constant int &mode [[buffer(1)]],
    constant StrokeMergeParams &stroke [[buffer(2)]]
) {
    float4 merged = layerWithStroke(srcTex.sample(s, in.texCoord), committed.sample(s, in.texCoord),
                                    tail.sample(s, in.texCoord), canvasPixel(in.texCoord, srcTex),
                                    stroke, paper, paperSampler);
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

fragment float4 displayWhiteFragment(
    CompositeVertexOut in [[stage_in]],
    texture2d<float> composite [[texture(0)]],
    texture2d<float> height [[texture(1)]],
    sampler s [[sampler(0)]],
    constant float &relief [[buffer(0)]]
) {
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
        float diffuse = max(0.0, dot(n, l)) / l.z;    // 1 where the paint is flat
        float glint = pow(max(0.0, dot(n, halfway)), 32.0) * 0.35 * saturate(h * 4.0) * relief;
        result = result * (0.3 + 0.7 * diffuse) + glint;
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
