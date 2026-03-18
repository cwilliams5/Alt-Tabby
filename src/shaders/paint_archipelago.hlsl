float hash(float2 p) { return frac(1e4 * sin(17.0 * p.x + p.y * 0.1) * (0.1 + abs(sin(p.y * 13.0 + p.x)))); }

float noise(float2 x) {
    float2 i = floor(x);
    float2 f = frac(x);
    float a = hash(i);
    float b = hash(i + float2(1.0, 0.0));
    float c = hash(i + float2(0.0, 1.0));
    float d = hash(i + float2(1.0, 1.0));
    float2 u = f * f * (3.0 - 2.0 * f);
    return lerp(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

#define octaves 14

float fbm(in float2 p) {
    float value = 0.0;
    float freq = 1.0;
    float amp = 0.5;

    for (int i = 0; i < octaves; i++) {
        value += amp * (noise((p - (float2)1.0) * freq));
        freq *= 1.9;
        amp *= 0.6;
    }
    return value;
}

float pattern(in float2 p) {
    float sinT01 = sin(time * 0.01);
    float2 aPos = float2(sin(time * 0.005), sinT01) * 6.0;
    float2 aScale = (float2)3.0;
    float a = fbm(p * aScale + aPos);

    float2 bPos = float2(sinT01, sinT01);
    float2 bScale = (float2)0.6;
    float b = fbm((p + a) * bScale + bPos);

    float2 cPos = float2(-0.6, -0.5) + float2(sin(-time * 0.001), sinT01) * 2.0;
    float2 cScale = (float2)2.6;
    float c = fbm((p + b) * cScale + cPos);
    return c;
}

float3 palette(in float t) {
    float3 a = float3(0.5, 0.5, 0.5);
    float3 b = float3(0.45, 0.25, 0.14);
    float3 c = float3(1.0, 1.0, 1.0);
    float3 d = float3(0.0, 0.1, 0.2);
    return a + b * cos(6.28318 * (c * t + d));
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 p = fragCoord.xy / resolution.xy;
    p.x *= resolution.x / resolution.y;
    float patVal = pattern(p);
    float value = patVal * patVal;
    float3 color = palette(value);

    return AT_PostProcess(color);
}