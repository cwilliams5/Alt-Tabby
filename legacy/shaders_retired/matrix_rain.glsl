// Matrix Rain — Shadertoy-style digital rain
// Original: https://www.shadertoy.com/view/ldccW4
// Author: Reinder
// License: CC BY-NC-SA 3.0
//
// Simplified version — no iChannel textures, procedural glyphs.

// Hash function for pseudo-random
float hash(vec2 p) {
    float h = dot(p, vec2(127.1, 311.7));
    return fract(sin(h) * 43758.5453);
}

// Character-like pattern (simplified glyph)
float charPattern(vec2 uv, float id) {
    vec2 g = fract(uv * vec2(3.0, 4.0) + hash(vec2(id, id * 0.7)) * 10.0);
    float d = step(0.3, g.x) * step(0.3, g.y);
    float pattern2 = step(0.5, fract(sin(id * 91.7) * 437.5));
    float bar = step(0.4, g.x) * step(g.y, 0.8);
    return mix(d, bar, pattern2);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;

    // Grid parameters
    float colWidth = 14.0;
    float rowHeight = 16.0;

    float col = floor(fragCoord.x / colWidth);
    float row = floor(fragCoord.y / rowHeight);

    // Per-column properties
    float colHash = hash(vec2(col, 0.0));
    float speed = 2.0 + colHash * 4.0;
    float offset = colHash * 100.0;
    float trailLen = 8.0 + colHash * 16.0;

    // Current position in the rain stream
    float rainPos = iTime * speed + offset;
    float headRow = fract(rainPos / 40.0) * (iResolution.y / rowHeight + trailLen);

    // Distance from head of trail
    float dist = headRow - row;

    if (dist < 0.0 || dist > trailLen) {
        fragColor = vec4(0, 0, 0, 0);
        return;
    }

    // Brightness: bright at head, fading tail
    float brightness = 1.0 - (dist / trailLen);
    brightness = brightness * brightness;

    // Head glow
    float headGlow = clamp(1.0 - dist * 0.5, 0.0, 1.0);

    // Character cell UV
    vec2 cellUV = vec2(fract(fragCoord.x / colWidth), fract(fragCoord.y / rowHeight));

    // Character ID changes over time
    float charId = hash(vec2(col, floor(row + iTime * speed * 0.3)));

    // Character shape
    float ch = charPattern(cellUV, charId + floor(iTime * 2.0));

    // Color
    vec3 green = vec3(0.1, 0.9, 0.3);
    vec3 white = vec3(0.8, 1.0, 0.85);
    vec3 color = mix(green, white, headGlow * 0.7);

    // Final alpha
    float alpha = ch * brightness * 0.9;
    alpha *= 0.6 + 0.4 * hash(vec2(col * 7.3, 1.0));

    // Premultiplied alpha
    fragColor = vec4(color * alpha, alpha);
}
