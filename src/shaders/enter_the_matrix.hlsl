// Enter The Matrix — kishimisu (Shadertoy cl3XRX)
// CC BY-NC-SA 4.0
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

Texture2D iChannel0 : register(t0);
SamplerState samp0 : register(s0);

struct PSInput {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
};

float4 PSMain(PSInput input) : SV_Target {
    float2 u = input.pos.xy;

    float M = 0.0;
    float A = 0.0;
    float T = time;
    float R = 0.0;

    float4 I = (float4)0;

    for (; R < 66.0; R += 1.0) {
        float4 X = float4(resolution.x, resolution.y, resolution.y, resolution.y);

        // Build rotation matrix from cos(A*sin(T*.1)*.3 + vec4(0,33,11,0))
        float4 angles = A * sin(T * 0.1) * 0.3 + float4(0.0, 33.0, 11.0, 0.0);
        float4 c = cos(angles);
        float2x2 rot = float2x2(c.x, c.y, c.z, c.w);

        float2 centered = u + u - X.xy;
        float2 rotated = mul(centered, rot);

        float4 p = A * normalize(float4(rotated, X.y, 0.0));
        p.z += T;
        p.y = abs(abs(p.y) - 1.0);

        // Random noise via ceil + sin + fract
        X = ceil(p * 4.0);
        X = frac(dot(X, sin(X)) + X);
        X.g += 4.0;

        // Texture lookup for character mask
        float2 texUV = (p.xz + ceil(T + X.x)) / 4.0;
        float texA = iChannel0.Sample(samp0, texUV).a;
        M = 4.0 * pow(smoothstep(1.0, 0.5, texA), 8.0) - 5.0;

        A += p.y * 0.6 - (M + A + A + 3.0) / 67.0;

        I += (X.a + 0.5) * (X + A) * (1.4 - p.y) / 2e2 / M / M / exp(A * 0.1);
    }

    float3 col = I.rgb;

    // Darken/desaturate post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, (float3)lum, desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
