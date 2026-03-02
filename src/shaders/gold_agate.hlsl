// Gold Agate - JuliaPoo (Shadertoy XtcfRn)
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

float2x2 rot(float a) { float sa, ca; sincos(a, sa, ca); return float2x2(sa, ca, -ca, sa); }

float noise(in float2 x) { return smoothstep(0., 1., sin(1.5 * x.x) * sin(1.5 * x.y)); }

float fbm(float2 p) {

    float2x2 m = rot(.4);
    float f = 0.0;
    f += 0.500000 * (0.5 + 0.5 * noise(p)); p = mul(p, m) * 2.02;
    f += 0.250000 * (0.5 + 0.5 * noise(p)); p = mul(p, m) * 2.03;
    f += 0.125000 * (0.5 + 0.5 * noise(p)); p = mul(p, m) * 2.01;
    f += 0.015625 * (0.5 + 0.5 * noise(p));
    return f / 0.96875;
}

float pattern(in float2 p, out float2 q, out float2 r, float t) {

    q.x = fbm(2.0 * p + float2(0.0, 0.0) + 2. * t);
    q.y = fbm(1.5 * p + float2(5.2, 1.3) + 1. * t);

    r.x = fbm(p + 4. * q + float2(1.7, 9.2) + sin(t) + .9 * sin(30. * length(q)));
    r.y = fbm(p + 8. * q + float2(8.3, 2.8) + cos(t) + .9 * sin(20. * length(q)));

    return fbm(p + mul(rot(t), 7. * r));
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    // iMouse zeroed — shader looks great without mouse interaction
    float2 uv = fragCoord.xy / resolution.xy * 2.;
    uv.x *= resolution.x / resolution.y;

    float2 q, r;
    float3 col1 = float3(.9, .7, .5);
    float3 col2 = float3(.3, .5, .4);
    float3 c;

    float f = pattern(uv, q, r, 0.1 * time);

    // mix colours
    float _ss1 = smoothstep(.0, .9, f);
    c = lerp(col1, (float3)0, _ss1 * _ss1);
    float _ss2 = smoothstep(0., .8, dot(q, r) * .6);
    c += col2 * (_ss2 * _ss2 * _ss2) * 1.5;
    // add contrast
    float _dqr = dot(q, r) + .3;
    c *= _dqr * _dqr * _dqr;
    // soften the bright parts
    c *= f * 1.5;

    // Darken/desaturate post-processing
    float lum = dot(c, float3(0.299, 0.587, 0.114));
    c = lerp(c, (float3)lum, desaturate);
    c = c * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float a = max(c.r, max(c.g, c.b));
    return float4(c * a, a);
}
