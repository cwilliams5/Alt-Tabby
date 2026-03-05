float length2(float2 p) {
    return dot(p, p);
}

float noise(float2 p) {
    return frac(sin(frac(sin(p.x) * 43.13311) + p.y) * 31.0011);
}

float worley(float2 p) {
    float d = 1e30;
    for (int xo = -1; xo <= 1; ++xo) {
        for (int yo = -1; yo <= 1; ++yo) {
            float2 tp = floor(p) + float2(xo, yo);
            d = min(d, length2(p - tp - noise(tp)));
        }
    }
    return 3.0 * exp(-4.0 * abs(2.5 * d - 1.0));
}

float fworley(float2 p) {
    return sqrt(sqrt(sqrt(
        worley(p * 5.0 + 0.05 * time) *
        sqrt(worley(p * 50.0 + 0.12 + -0.1 * time)) *
        sqrt(sqrt(worley(p * -10.0 + 0.03 * time))))));
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 uv = fragCoord.xy / resolution.xy;
    float t = fworley(uv * resolution.xy / 1500.0);
    t *= exp(-length2(abs(0.7 * uv - 1.0)));
    float3 color = t * float3(0.1, 1.1 * t, pow(t, 0.5 - t));

    return AT_PostProcess(color);
}
