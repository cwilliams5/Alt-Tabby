// Paint 1 - JuliaPoo (Shadertoy MlVcDt)
// Converted from GLSL to HLSL for Alt-Tabby

float2x2 rot(float a) {
    float s, c;
    sincos(a, s, c);
    return float2x2(s, c, -c, s);
}

float noise(in float2 x) { return smoothstep(0., 1., sin(1.5 * x.x) * sin(1.5 * x.y)); }

// rot(.4): sin(.4)=0.38942, cos(.4)=0.92106 → float2x2(sin, cos, -cos, sin)
static const float2x2 _rot04 = float2x2(0.38942, 0.92106, -0.92106, 0.38942);

float fbm(float2 p) {
    float2x2 m = _rot04;
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

    return AT_PostProcess(c);
}
