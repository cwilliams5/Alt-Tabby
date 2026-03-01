// Paint 1 - JuliaPoo (Shadertoy MlVcDt)
// Converted from GLSL to HLSL for Alt-Tabby

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

float2x2 rot(float a) {
    float s = sin(a);
    float c = cos(a);
    return float2x2(s, c, -c, s);
}

float noise(in float2 x) { return smoothstep(0., 1., sin(1.5 * x.x) * sin(1.5 * x.y)); }

float fbm(float2 p) {
    float2x2 m = rot(.4);
    float f = 0.0;
    f += 0.500000 * (0.5 + 0.5 * noise(p)); p = mul(p, m) * 2.02;
    f += 0.250000 * (0.5 + 0.5 * noise(p)); p = mul(p, m) * 2.03;
    f += 0.125000 * (0.5 + 0.5 * noise(p)); p = mul(p, m) * 2.01;
    f += 0.062500 * (0.5 + 0.5 * noise(p)); p = mul(p, m) * 2.04;
    f += 0.031250 * (0.5 + 0.5 * noise(p)); p = mul(p, m) * 2.01;
    f += 0.015625 * (0.5 + 0.5 * noise(p));
    return f / 0.96875;
}

float pattern(in float2 p, out float2 q, out float2 r, float t) {

    q.x = fbm(p + float2(0.0, 0.0) + .7 * t);
    q.y = fbm(p + float2(5.2, 1.3) + 1. * t);

    r.x = fbm(p + 10.0 * q + float2(1.7, 9.2) + sin(t));
    r.y = fbm(p + 12.0 * q + float2(8.3, 2.8) + cos(t));

    return fbm(p + 3.0 * r);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    // iMouse zeroed — shader looks great without mouse interaction
    float2 uv = fragCoord.xy / resolution.xy * 2.;
    uv.x *= resolution.x / resolution.y;

    float2 q, r;
    float3 col1 = float3(0., .9, .8);
    float3 col2 = float3(1., .6, .5);

    float f = pattern(uv, q, r, 0.1 * time);

    float3 c = lerp(col1, (float3)0, smoothstep(.0, .95, f));
    float3 a = col2 * smoothstep(0., .8, dot(q, r) * 0.6);
    c = sqrt(c * c + a * a);

    // Darken/desaturate post-processing
    float lum = dot(c, float3(0.299, 0.587, 0.114));
    c = lerp(c, float3(lum, lum, lum), desaturate);
    c = c * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float alpha = max(c.r, max(c.g, c.b));
    return float4(c * alpha, alpha);
}
