// Deterioration - converted from Shadertoy (3dBSW3)
// Author: Blokatt - License: CC BY-NC-SA 3.0

float2x2 rot(float a) {
    float s, c;
    sincos(a, s, c);
    return float2x2(c, -s, s, c);
}

float rand(float2 uv) {
    return frac(sin(dot(float2(12.9898, 78.233), uv)) * 43758.5453123);
}

float valueNoise(float2 uv) {
    float2 i = frac(uv);
    float2 f = floor(uv);
    float a = rand(f);
    float b = rand(f + float2(1.0, 0.0));
    float c = rand(f + float2(0.0, 1.0));
    float d = rand(f + float2(1.0, 1.0));
    return lerp(lerp(a, b, i.x), lerp(c, d, i.x), i.y);
}

float fbm(float2 uv, float sinTime02) {
    float v = 0.0;
    float amp = 0.75;
    float z = (20.0 * sinTime02) + 30.0;
    float t01 = time * 0.1;

    for (int i = 0; i < 10; ++i) {
        v += valueNoise(uv + (z * uv * 0.05) + t01) * amp;
        uv *= 3.25;
        amp *= 0.5;
    }

    return v;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float2 uv = fragCoord / resolution.xy - 0.5;
    float2 oldUV = uv;
    uv.x *= resolution.x / resolution.y;
    float2x2 r = rot(time * 0.02);
    uv = mul(uv, r);
    float sinTime02 = sin(time * 0.2);
    float2x2 angle = rot(fbm(uv, sinTime02));

    float3 col = float3(
        fbm(mul(angle, float2(5.456, -2.8112)) + uv, sinTime02),
        fbm(mul(angle, float2(5.476, -2.8122)) + uv, sinTime02),
        fbm(mul(angle, float2(5.486, -2.8132)) + uv, sinTime02));
    col -= smoothstep(0.1, 1.0, length(oldUV));

    return AT_PostProcess(col);
}
