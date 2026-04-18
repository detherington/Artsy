#include <metal_stdlib>
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

fragment float4 strokeFragment(
    StrokeVertexOut in [[stage_in]],
    texture2d<float> brushTip [[texture(0)]],
    sampler s [[sampler(0)]],
    constant float4 &brushColor [[buffer(0)]]
) {
    float tipAlpha = brushTip.sample(s, in.texCoord).a;
    return float4(brushColor.rgb, brushColor.a * tipAlpha * in.opacity);
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
    return float4(brushColor.rgb, brushColor.a * alpha * in.opacity);
}

// Round tip with pencil texture (for caps on pencil strokes).
fragment float4 strokeRadialPencilFragment(
    StrokeVertexOut in [[stage_in]],
    constant float4 &brushColor [[buffer(0)]],
    constant float &hardness [[buffer(1)]]
) {
    float dist = distance(in.texCoord, float2(0.5, 0.5)) * 2.0;
    float shape = 1.0 - smoothstep(hardness, 1.0, dist);

    float2 p = in.position.xy * 0.5;
    float noise = fract(sin(dot(floor(p), float2(12.9898, 78.233))) * 43758.5453);
    float grain = mix(0.4, 1.0, noise);
    float alpha = shape * grain;
    return float4(brushColor.rgb, brushColor.a * alpha * in.opacity);
}

// Round tip for watercolor (cap version of watercolor brush)
fragment float4 strokeRadialWatercolorFragment(
    StrokeVertexOut in [[stage_in]],
    constant float4 &brushColor [[buffer(0)]],
    constant float &hardness [[buffer(1)]]
) {
    float dist = distance(in.texCoord, float2(0.5, 0.5)) * 2.0;
    float shape = 1.0 - smoothstep(0.0, 0.85, dist);
    float wetEdge = smoothstep(0.3, 0.75, dist) * (1.0 - smoothstep(0.75, 0.9, dist));
    float edgeBoost = 1.0 + wetEdge * 0.6;

    float2 p1 = in.position.xy * 0.15;
    float noise1 = fract(sin(dot(floor(p1), float2(12.9898, 78.233))) * 43758.5453);
    float paperTexture = mix(0.7, 1.0, noise1);

    float alpha = shape * edgeBoost * paperTexture * in.opacity;
    float3 color = brushColor.rgb * mix(1.0, 0.75, wetEdge);
    return float4(color, brushColor.a * alpha);
}

// Round tip for acrylic (cap version of acrylic brush)
fragment float4 strokeRadialAcrylicFragment(
    StrokeVertexOut in [[stage_in]],
    constant float4 &brushColor [[buffer(0)]],
    constant float &hardness [[buffer(1)]]
) {
    float dist = distance(in.texCoord, float2(0.5, 0.5)) * 2.0;
    float shape = 1.0 - smoothstep(hardness + 0.1, 0.95, dist);

    float2 p = in.position.xy;
    float canvas = fract(sin(dot(floor(p * 0.2), float2(12.9898, 78.233))) * 43758.5453);
    float canvasTexture = mix(0.92, 1.0, canvas);
    float alpha = shape * canvasTexture * in.opacity;
    return float4(brushColor.rgb, brushColor.a * alpha);
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

    return float4(brushColor.rgb, brushColor.a * alpha * in.opacity);
}

// Procedural pencil: noise-textured, uses cross-stroke distance
fragment float4 strokePencilFragment(
    StrokeVertexOut in [[stage_in]],
    constant float4 &brushColor [[buffer(0)]],
    constant float &hardness [[buffer(1)]]
) {
    float dist = abs(in.texCoord.x - 0.5) * 2.0;
    float shape = 1.0 - smoothstep(hardness, 1.0, dist);

    // Use position for noise so it's consistent regardless of strip topology
    float2 p = in.position.xy * 0.5;
    float noise = fract(sin(dot(floor(p), float2(12.9898, 78.233))) * 43758.5453);
    float grain = mix(0.4, 1.0, noise);

    float alpha = shape * grain;
    return float4(brushColor.rgb, brushColor.a * alpha * in.opacity);
}

// Watercolor: very soft edges with wet-edge darkening effect
// The edges of a watercolor stroke are slightly darker where pigment pools
fragment float4 strokeWatercolorFragment(
    StrokeVertexOut in [[stage_in]],
    constant float4 &brushColor [[buffer(0)]],
    constant float &hardness [[buffer(1)]]
) {
    float dist = abs(in.texCoord.x - 0.5) * 2.0;

    // Soft base shape
    float shape = 1.0 - smoothstep(0.0, 0.85, dist);

    // Wet edge: slight darkening/concentration at the stroke edges
    float wetEdge = smoothstep(0.3, 0.75, dist) * (1.0 - smoothstep(0.75, 0.9, dist));
    float edgeBoost = 1.0 + wetEdge * 0.6;

    // Subtle paper texture variation using position
    float2 p1 = in.position.xy * 0.15;
    float noise1 = fract(sin(dot(floor(p1), float2(12.9898, 78.233))) * 43758.5453);
    float2 p2 = in.position.xy * 0.05;
    float noise2 = fract(sin(dot(floor(p2), float2(63.7264, 10.873))) * 43758.5453);
    float paperTexture = mix(0.7, 1.0, noise1 * 0.6 + noise2 * 0.4);

    float alpha = shape * edgeBoost * paperTexture * in.opacity;

    // Slightly shift color toward darker at edges for pigment pooling
    float3 color = brushColor.rgb * mix(1.0, 0.75, wetEdge);

    return float4(color, brushColor.a * alpha);
}

// Acrylic: thick, opaque paint with subtle canvas/bristle texture
fragment float4 strokeAcrylicFragment(
    StrokeVertexOut in [[stage_in]],
    constant float4 &brushColor [[buffer(0)]],
    constant float &hardness [[buffer(1)]]
) {
    float dist = abs(in.texCoord.x - 0.5) * 2.0;

    // Firm edge with slight softness
    float shape = 1.0 - smoothstep(hardness + 0.1, 0.95, dist);

    // Bristle texture: streaks along the stroke direction
    float2 p = in.position.xy;
    // Cross-stroke bristle lines
    float bristle = fract(sin(floor(in.texCoord.x * 30.0) * 45.17) * 43758.5453);
    float bristleAlpha = mix(0.85, 1.0, bristle);

    // Slight canvas grain
    float2 cp = p * 0.2;
    float grain = fract(sin(dot(floor(cp), float2(12.9898, 78.233))) * 43758.5453);
    float canvasTexture = mix(0.92, 1.0, grain);

    float alpha = shape * bristleAlpha * canvasTexture * in.opacity;

    // Subtle color variation for paint thickness
    float thickness = mix(0.95, 1.05, bristle * 0.5 + grain * 0.5);
    float3 color = clamp(brushColor.rgb * thickness, 0.0, 1.0);

    return float4(color, brushColor.a * alpha);
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
    float4 src = layer.sample(s, in.texCoord);
    src.a *= layerOpacity;
    return src;
}

// Generic blend shader — mode: 0=normal, 1=multiply, 2=screen, 3=overlay, 4=darken, 5=lighten
// Source is already premultiplied (from stroke rendering). For blend modes we un-premultiply
// the src color, compute the blend with dst (also un-premultiplied), then re-premultiply.
fragment float4 compositeBlend(
    CompositeVertexOut in [[stage_in]],
    texture2d<float> srcTex [[texture(0)]],
    texture2d<float> dstTex [[texture(1)]],
    sampler s [[sampler(0)]],
    constant float &layerOpacity [[buffer(0)]],
    constant int &mode [[buffer(1)]]
) {
    float4 src = srcTex.sample(s, in.texCoord);
    float4 dst = dstTex.sample(s, in.texCoord);
    src.a *= layerOpacity;

    // Un-premultiply source for blend math (assume src came in premultiplied)
    float3 srcRGB = src.a > 0.001 ? src.rgb / src.a : src.rgb;
    float3 dstRGB = dst.a > 0.001 ? dst.rgb / dst.a : dst.rgb;

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

    // Standard Porter-Duff "source over" compositing using the blended color
    float outA = src.a + dst.a * (1.0 - src.a);
    float3 outRGB = (blended * src.a + dstRGB * dst.a * (1.0 - src.a));
    return float4(outRGB, outA);
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

    // Alpha composite over checkerboard
    float3 result = color.rgb * color.a + bg * (1.0 - color.a);
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
fragment float4 displayWhiteFragment(
    CompositeVertexOut in [[stage_in]],
    texture2d<float> composite [[texture(0)]],
    sampler s [[sampler(0)]]
) {
    float4 color = composite.sample(s, in.texCoord);
    float3 result = color.rgb * color.a + float3(1.0) * (1.0 - color.a);
    return float4(result, 1.0);
}
