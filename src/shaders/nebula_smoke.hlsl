float polygonDistance(float2 p, float radius, float angleOffset, int sideCount) {
    float a = atan2(p.x, p.y) + angleOffset;
    float b = 6.28319 / float(sideCount);
    return cos(floor(0.5 + a / b) * b - a) * length(p) - radius;
}

// from https://www.shadertoy.com/view/4djSRW
#define HASHSCALE1 443.8975
float hash11(float p) {
    float3 p3 = frac((float3)(p) * HASHSCALE1);
    p3 += dot(p3, p3.yzx + 19.19);
    return frac((p3.x + p3.y) * p3.z);
}

#define HASHSCALE3 float3(.1031, .1030, .0973)
float2 hash21(float p) {
    float3 p3 = frac((float3)(p) * HASHSCALE3);
    p3 += dot(p3, p3.yzx + 19.19);
    return frac(float2((p3.x + p3.y) * p3.z, (p3.x + p3.z) * p3.y));
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);

    float2 uv = (float2)0.5 - (fragCoord.xy / resolution.xy);
    uv.x *= resolution.x / resolution.y;

    float accum = 0.0;
    float _rotBase = 0.1 + time * 0.2 + sin(time * 0.1) * 0.9;
    for (int i = 0; i < 83; i++) {
        float fi = float(i);
        float thisYOffset = fmod(hash11(fi * 0.017) * (time + 19.0) * 0.2, 4.0) - 2.0;
        float2 center = (hash21(fi) * 2.0 - 1.0) * float2(1.1, 1.0) - float2(0.0, thisYOffset);
        float radius = 0.5;
        float2 offset = uv - center;
        float twistFactor = (hash11(fi * 0.0347) * 2.0 - 1.0) * 1.9;
        float rotation = _rotBase + (length(offset) / radius) * twistFactor;
        float polyFade = smoothstep(radius, 0.0, polygonDistance(uv - center, 0.1 + hash11(fi * 2.3) * 0.2, rotation, 5) + 0.1);
        accum += polyFade * polyFade * polyFade;
    }

    float3 subColor = float3(0.4, 0.8, 0.2);
    float3 addColor = float3(0.3, 0.2, 0.1);

    float3 color = (float3)1.0 - accum * subColor + addColor;

    return AT_PostProcess(color);
}
