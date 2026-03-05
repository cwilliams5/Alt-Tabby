// Starship by @XorDev — https://www.shadertoy.com/view/l3cfW4
// Inspired by the debris from SpaceX's 7th Starship test.

Texture2D iChannel0 : register(t0);
SamplerState samp0 : register(s0);

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);

    float2 r = resolution;
    // Center, rotate and scale
    float2 v = (fragCoord + fragCoord - r) / r.y;
    float2 p = mul(v, float2x2(3, 4, 4, -3)) / 1e2;

    // Sum of colors, RGB color shift and wave
    float4 S = (float4)0;
    float4 C = float4(1, 2, 3, 0);
    float4 W;

    float t = time;
    float T = 0.1 * t + p.y;

    // Iterate through 50 particles
    for (float i = 1.0; i <= 50.0; i += 1.0) {
        // Body: shift position for each particle
        p += 0.02 * cos(i * (C.xz + 8.0 + i) + T + T);

        // Increment: accumulate color
        W = sin(i) * C;
        float noiseVal = iChannel0.Sample(samp0, p / exp(W.x) + float2(i, t) / 8.0).r;
        S += (cos(W) + 1.0)
            * exp(sin(i + i * T))
            / length(max(p, p / float2(2.0, noiseVal * 40.0)))
            / 1e4;
    }

    // Sky background and tanh tonemap
    C -= 1.0;
    float4 O = tanh(p.x * C + S * S);

    float3 color = O.rgb;

    return AT_PostProcess(color);
}