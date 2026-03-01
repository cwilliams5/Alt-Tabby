// Trailing the Twinkling Tunnelwisp (CC0)

// Volumetric tunnel shader (distance field raymarching).
// Gyroid-based, twisting tunnel with animated "wisp" lighting.
// Supports customizable color palettes and water-like reflections.

// Based on the original by BeRo & Paul Karlik.
// Palette, wisp animation, and customization extensions by ChatGPT (2024).

//Modified with ChatGPT (2025).
// CC0/Public Domain.

float g(vec4 p, float s) {
    return abs(dot(sin(p *= s), cos(p.zxwy)) - 1.) / s;
}

void mainImage(out vec4 O, vec2 C) {
    float i, d, z, s, T = iTime;
    vec4 o = vec4(0), q, p, U = vec4(2, 1, 0, 3);

    for (
        vec2 r = iResolution.xy;
        ++i < 79.;
        z += d + 5E-4,
        q = vec4(normalize(vec3((C + C - r) / r.y, 2)) * z, .2),
        q.z += T / 3E1,
        s = q.y + .1,
        q.y = abs(s),
        p = q,
        p.y -= .11,
        p.xy *= mat2(cos(11. * U.zywz - 2. * p.z)),
        p.y -= .2,
        d = abs(g(p, 8.) - g(p, 24.)) / 4.,
        //Palette Color
        //p = 1.3 + 1.2 * cos(vec4(2.1, 4.5, 1.7, 0.0) + 5.5 * q.z)
        //p = 1.0 + 1.2 * cos(vec4(2.6, 5.0, 3.2, 0.0) + 5.1 * q.z)
        p = 1.4 + 1.8 * cos(vec4(1.8, 3.1, 4.5, 0.0) + 7.0 * q.z)
        //p = 1.2 + 0.8 * cos(vec4(0.7, 2.8, 4.7, 0.0) + 3.4 * q.z)
        //p = 1.18 + cos(vec4(3.1, 5.2, 4.4, 0.0) + 3.6 * q.z)
        //p = 1.25 + cos(vec4(1.4, 2.1, 0.5, 0.0) + 3.2 * q.z)
    )
        // Glow accumulation (unchanged)
        o += (s > 0. ? 1. : .1) * p.w * p / max(s > 0. ? d : d * d * d, 5E-4);

    // --- Animated, color-shifting, moving tunnelwisp ---
    vec2 wispPos = 1.5 * vec2(cos(T * 0.7), sin(T * 0.9));
    float wispDist = length(q.xy - wispPos);
    vec3 wispColor = vec3(1.0, 0.8 + 0.2 * sin(T), 0.7 + 0.3 * cos(T * 1.3));
    o.xyz += (2.0 + sin(T * 2.0)) * 800.0 * wispColor / (wispDist + 0.4);

    // Tone mapping
    O = tanh(o / 1E5);
}
