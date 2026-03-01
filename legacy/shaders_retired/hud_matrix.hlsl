// HUD Matrix
// https://www.shadertoy.com/view/Nff3Rn
// by proas61

cbuffer Constants : register(b0) {
    float time;
    float2 resolution;
    float timeDelta;
    uint frame;
    float darken;
    float desaturate;
    float _pad;
};

struct PSInput {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
};

#define PI 3.14159265359

float hash(float n) { return frac(sin(n) * 43758.5453123); }
float hash21(float2 p) { return frac(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }

float bandMaskHard(float y, float y0, float thick) {
    return step(abs(y - y0), thick);
}

float glyph(float2 uv, float id) {
    uv *= float2(5.0, 7.0);
    float2 gv = floor(uv);
    float2 lv = frac(uv);

    float h = hash21(gv + id * 13.1);
    float on = step(0.55, h);

    float edge = smoothstep(0.1, 0.0, min(min(lv.x, 1.0 - lv.x), min(lv.y, 1.0 - lv.y)));
    return on * edge;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);

    float2 uv0 = fragCoord.xy / resolution.xy;
    float2 uv = uv0 * 0.64;

    uv.x *= resolution.x / resolution.y;

    // ---------------- SCROLL ----------------
    float scrollSpeed = 0.128;
    uv.y += time * scrollSpeed;

    float row = floor(uv.y * 20.0);
    float col = floor(uv.x * 30.0);

    float2 cell = float2(col, row);
    float id = hash21(cell);

    float2 localUV = frac(float2(uv.x * 30.0, uv.y * 20.0));

    // ---------------- GLITCH ----------------
    float t = floor(time * 14.0);

    float glitchCount = 3.0;
    float glitchThickness = 0.02;
    float glitchOffset = 0.25;

    float globalGate = step(3.45, hash(t * 2.1));

    float2 uvGlitch = uv;

    for (float i = 0.0; i < glitchCount; i++) {
        float gid = i + t * 17.13;

        float y0 = hash(gid) * 2.0 - 1.0;
        float dir = (hash(gid * 3.7) < 0.5) ? -1.0 : 1.0;
        float power = lerp(0.3, 1.0, hash(gid * 9.1));

        float m = bandMaskHard(uv.y * 2.0 - 1.0, y0, glitchThickness);

        uvGlitch.x += globalGate * m * dir * glitchOffset * power;
    }

    float2 localGlitch = frac(float2(uvGlitch.x * 36.0, uvGlitch.y * 24.0));

    float gR = glyph(localGlitch + float2(0.01, 0.0), id);
    float gG = glyph(localGlitch, id);
    float gB = glyph(localGlitch - float2(0.01, 0.0), id);

    // depth fade
    float fade = exp(-uv.x * 0.8);

    // flicker
    float flick = 0.85 + 0.25 * sin(time * 8.0 + row);

    float3 colOut = float3(gR * 0.3, gG * 0.8, gB * 0.7) * fade * flick;

    // random flash burst
    colOut *= 1.0 + 0.5 * step(0.94, hash(t * 5.7));

    // Darken/desaturate post-processing
    float lum = dot(colOut, float3(0.299, 0.587, 0.114));
    colOut = lerp(colOut, float3(lum, lum, lum), desaturate);
    colOut = colOut * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(colOut.r, max(colOut.g, colOut.b));
    return float4(colOut * a, a);
}
