// fBM Noise - jorgemoag (Shadertoy WslcR2)
// Inspired by https://iquilezles.org/articles/warp
// Converted from GLSL to HLSL for Alt-Tabby

float random(float2 p) {
    float x = dot(p, float2(4371.321, -9137.327));
    return 2.0 * frac(sin(x) * 17381.94472) - 1.0;
}

float noise(in float2 p) {
    float2 id = floor(p);
    float2 f = frac(p);

    float2 u = f * f * (3.0 - 2.0 * f);

    return lerp(lerp(random(id + float2(0.0, 0.0)),
                     random(id + float2(1.0, 0.0)), u.x),
                lerp(random(id + float2(0.0, 1.0)),
                     random(id + float2(1.0, 1.0)), u.x),
                u.y);
}

float fbm(float2 p) {
    float f = 0.0;
    float gat = 0.0;
    float la = 1.0;
    float ga = 0.5;

    for (int octave = 0; octave < 5; ++octave) {
        f += ga * noise(la * p);
        gat += ga;
        la *= 2.0;
        ga *= 0.5;
    }

    f = f / gat;

    return f;
}

float noise_fbm(float2 p) {
    float h = fbm(0.09 * time + p + fbm(0.065 * time + 2.0 * p - 5.0 * fbm(4.0 * p)));
    return h;
}

float outline(float2 p, float eps, float center) {
    float ft = noise_fbm(p - float2(0.0, eps));
    float fl = noise_fbm(p - float2(eps, 0.0));
    float fb = noise_fbm(p + float2(0.0, eps));
    float fr = noise_fbm(p + float2(eps, 0.0));

    return saturate(abs(4.0 * center - ft - fr - fl - fb));
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 p = (2.0 * fragCoord - resolution.xy) / resolution.y;

    float f = noise_fbm(p);

    float a2 = smoothstep(-0.5, 0.5, f);
    float a1 = smoothstep(-1.0, 1.0, fbm(p));

    float3 cc = lerp(lerp(float3(0.50, 0.00, 0.10),
                          float3(0.50, 0.75, 0.35), a1),
                          float3(0.00, 0.00, 0.02), a2);

    cc += float3(0.0, 0.2, 1.0) * outline(p, 0.0005, f);
    cc += float3(1.0, 1.0, 1.0) * outline(p, 0.0025, f);

    cc += 0.5 * float3(0.1, 0.0, 0.2) * f;
    cc += 0.25 * float3(0.3, 0.4, 0.6) * noise_fbm(2.0 * p);

    return AT_PostProcess(cc);
}
