// Kaleidoscope Tunnel
// Combines TheGrid by dila and The Drive Home by BigWings

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

#define PI 3.141592654

// GLSL mod: always returns positive remainder (unlike HLSL fmod)
float glsl_mod(float x, float y) { return x - y * floor(x / y); }
float2 glsl_mod(float2 x, float y) { return x - y * floor(x / y); }

float2x2 rot(float x) {
    float c = cos(x), s = sin(x);
    return float2x2(c, s, -s, c);
}

float2 foldRotate(float2 p, float s) {
    float a = PI / s - atan2(p.x, p.y);
    float n = PI * 2.0 / s;
    a = floor(a / n) * n;
    p = mul(rot(a), p);
    return p;
}

float sdRect(float2 p, float2 b) {
    float2 d = abs(p) - b;
    return min(max(d.x, d.y), 0.0) + length(max(d, (float2)0));
}

float tex(float2 p, float z) {
    p = foldRotate(p, 8.0);
    float2 q = (frac(p / 10.0) - 0.5) * 10.0;
    for (int i = 0; i < 3; ++i) {
        for (int j = 0; j < 2; j++) {
            q = abs(q) - 0.25;
            q = mul(rot(PI * 0.25), q);
        }
        q = abs(q) - float2(1.0, 1.5);
        q = mul(rot(PI * 0.25 * z), q);
        q = foldRotate(q, 3.0);
    }
    float d = sdRect(q, float2(1.0, 1.0));
    float f = 1.0 / (1.0 + abs(d));
    return smoothstep(0.9, 1.0, f);
}

float Bokeh(float2 p, float2 sp, float size, float mi, float blur) {
    float d = length(p - sp);
    float c = smoothstep(size, size * (1.0 - blur), d);
    c *= lerp(mi, 1.0, smoothstep(size * 0.8, size, d));
    return c;
}

float2 hash(float2 p) {
    p = float2(dot(p, float2(127.1, 311.7)), dot(p, float2(269.5, 183.3)));
    return frac(sin(p) * 43758.5453) * 2.0 - 1.0;
}

float dirt(float2 uv, float n) {
    float2 p = frac(uv * n);
    float2 st = (floor(uv * n) + 0.5) / n;
    float2 rnd = hash(st);
    return Bokeh(p, float2(0.5, 0.5) + (float2)0.2 * rnd, 0.05, abs(rnd.y * 0.4) + 0.3, 0.25 + rnd.x * rnd.y * 0.2);
}

float sm(float start, float end, float t, float smo) {
    return smoothstep(start, start + smo, t) - smoothstep(end - smo, end, t);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 uv = fragCoord.xy / resolution.xy;
    uv = uv * 2.0 - 1.0;
    uv.x *= resolution.x / resolution.y;
    uv *= 2.0;

    float3 col = (float3)0;
    #define N 6
    #define NN float(N)
    #define INTERVAL 3.0
    #define INTENSITY (float3)((NN * INTERVAL - t) / (NN * INTERVAL))

    for (int i = 0; i < N; i++) {
        float t;
        float ii = float(N - i);
        t = ii * INTERVAL - glsl_mod(time - INTERVAL * 0.75, INTERVAL);
        col = lerp(col, INTENSITY, dirt(glsl_mod(uv * max(0.0, t) * 0.1 + float2(0.2, -0.2) * time, 1.2), 3.5));

        t = ii * INTERVAL - glsl_mod(time + INTERVAL * 0.5, INTERVAL);
        col = lerp(col, INTENSITY * float3(0.7, 0.8, 1.0) * 1.3, tex(uv * max(0.0, t), 4.45));

        t = ii * INTERVAL - glsl_mod(time - INTERVAL * 0.25, INTERVAL);
        col = lerp(col, INTENSITY, dirt(glsl_mod(uv * max(0.0, t) * 0.1 + float2(-0.2, -0.2) * time, 1.2), 3.5));

        t = ii * INTERVAL - glsl_mod(time, INTERVAL);
        float r = length(uv * 2.0 * max(0.0, t));
        float rr = sm(-24.0, 0.0, r - glsl_mod(time * 30.0, 90.0), 10.0);
        col = lerp(col, lerp(INTENSITY, INTENSITY * float3(0.7, 0.5, 1.0) * 3.0, rr), tex(uv * 2.0 * max(0.0, t), 0.27 + 2.0 * rr));
    }

    float3 color = col;

    // Post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float alpha = max(color.r, max(color.g, color.b));
    return float4(color * alpha, alpha);
}
