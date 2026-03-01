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

#define NUM_LAYERS 10.

float2x2 Rot(float a) {
    float c = cos(a), s = sin(a);
    return float2x2(c, -s, s, c);
}

float Star(float2 uv, float flare) {
    float d = length(uv);
    float m = 0.02 / d;

    float rays = max(0.0, 1.0 - abs(uv.x * uv.y * 1000.0));
    m += rays * flare;
    uv = mul(uv, Rot(3.1415 / 4.0));
    rays = max(0.0, 1.0 - abs(uv.x * uv.y * 1000.0));
    m += rays * 0.3 * flare;

    m *= smoothstep(1.0, 0.2, d);

    return m;
}

float Hash21(float2 p) {
    p = frac(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return frac(p.x * p.y);
}

float3 StarLayer(float2 uv) {
    float3 col = (float3)0;

    float2 gv = frac(uv) - 0.5;
    float2 id = floor(uv);

    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float2 offs = float2(x, y);

            float n = Hash21(id + offs);
            float size = frac(n * 345.32);

            float2 p = float2(n, frac(n * 34.0));

            float star = Star(gv - offs - p + 0.5, smoothstep(0.8, 1.0, size) * 0.6);

            // Replace audio-reactive hue shift with time-based variation
            float2 audioReplace = float2(sin(time * 0.3) * 0.5 + 0.5, cos(time * 0.2) * 0.5 + 0.5);
            float3 hueShift = frac(n * 2345.2 + dot(uv / 420.0, audioReplace)) * float3(0.2, 0.3, 0.9) * 123.2;

            float3 color = sin(hueShift) * 0.5 + 0.5;
            color = color * float3(1.0, 0.25, 1.0 + size);

            star *= sin(time * 3.0 + n * 6.2831) * 0.4 + 1.0;
            col += star * size * color;
        }
    }

    return col;
}

float2 N(float angle) {
    return float2(sin(angle), cos(angle));
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float2 uv = (fragCoord - 0.5 * resolution.xy) / resolution.y;
    float t = time * 0.01;

    uv.x = abs(uv.x);
    uv.y += tan((5.0 / 6.0) * 3.1415) * 0.5;

    float2 n = N((5.0 / 6.0) * 3.1415);
    float d = dot(uv - float2(0.5, 0.0), n);
    uv -= n * max(0.0, d) * 2.0;

    n = N((2.0 / 3.0) * 3.1415);
    uv.x += 1.5 / 1.25;
    for (int i = 0; i < 5; i++) {
        uv *= 1.25;
        uv.x -= 1.5;

        uv.x = abs(uv.x);
        uv.x -= 0.5;
        uv -= n * min(0.0, dot(uv, n)) * 2.0;
    }

    uv = mul(uv, Rot(t));
    float3 col = (float3)0;

    for (float li = 0.0; li < 1.0; li += 1.0 / NUM_LAYERS) {
        float depth = frac(li + t);
        float sc = lerp(20.0, 0.5, depth);
        float fade = depth * smoothstep(1.0, 0.9, depth);
        col += StarLayer(uv * sc + li * 453.2) * fade;
    }

    // Post-processing: darken/desaturate
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
