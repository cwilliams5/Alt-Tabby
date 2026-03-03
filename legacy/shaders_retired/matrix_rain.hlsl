// Matrix Rain — Shadertoy-style digital rain converted to HLSL.
// Original: https://www.shadertoy.com/view/ldccW4
// Author: Reinder
// License: CC BY-NC-SA 3.0

cbuffer Constants : register(b0) {
    float time;
    float2 resolution;
    float timeDelta;
    uint frame;
    float darken;
    float desaturate;
    float _pad;
};

// Hash function for pseudo-random
float hash(float2 p) {
    float h = dot(p, float2(127.1, 311.7));
    return frac(sin(h) * 43758.5453);
}

// Character-like pattern (simplified glyph)
float charPattern(float2 uv, float id) {
    // Grid of dots/bars simulating matrix glyphs
    float2 g = frac(uv * float2(3.0, 4.0) + hash(float2(id, id * 0.7)) * 10.0);
    float d = step(0.3, g.x) * step(0.3, g.y);
    // Mix patterns based on ID
    float pattern2 = step(0.5, frac(sin(id * 91.7) * 437.5));
    float bar = step(0.4, g.x) * step(g.y, 0.8);
    return lerp(d, bar, pattern2);
}

struct PSInput {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
};

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 uv = fragCoord / resolution;

    // Grid parameters
    float colWidth = 14.0;  // pixels per column
    float rowHeight = 16.0; // pixels per row

    float col = floor(fragCoord.x / colWidth);
    float row = floor(fragCoord.y / rowHeight);

    // Per-column properties
    float colHash = hash(float2(col, 0.0));
    float speed = 2.0 + colHash * 4.0;        // Fall speed varies per column
    float offset = colHash * 100.0;             // Start offset
    float trailLen = 8.0 + colHash * 16.0;      // Trail length varies

    // Current position in the rain stream
    float rainPos = time * speed + offset;
    float headRow = frac(rainPos / 40.0) * (resolution.y / rowHeight + trailLen);

    // Distance from head of trail
    float dist = headRow - row;

    // Only draw if within trail
    if (dist < 0.0 || dist > trailLen) {
        return float4(0, 0, 0, 0);
    }

    // Brightness: bright at head, fading tail
    float brightness = 1.0 - (dist / trailLen);
    brightness = brightness * brightness; // Quadratic falloff

    // Head glow (first 2 chars are brighter/whiter)
    float headGlow = saturate(1.0 - dist * 0.5);

    // Character cell UV
    float2 cellUV = float2(frac(fragCoord.x / colWidth), frac(fragCoord.y / rowHeight));

    // Character ID changes over time (scrolling effect)
    float charId = hash(float2(col, floor(row + time * speed * 0.3)));

    // Character shape
    float ch = charPattern(cellUV, charId + floor(time * 2.0));

    // Color: green with white head
    float3 green = float3(0.1, 0.9, 0.3);
    float3 white = float3(0.8, 1.0, 0.85);
    float3 color = lerp(green, white, headGlow * 0.7);

    // Apply darken/desaturate post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Final alpha from character shape and trail brightness
    float alpha = ch * brightness * 0.9;

    // Slight column brightness variation
    alpha *= 0.6 + 0.4 * hash(float2(col * 7.3, 1.0));

    // Premultiplied alpha output for D2D compositing
    return float4(color * alpha, alpha);
}
