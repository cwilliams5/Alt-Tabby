// Enter The Matrix — kishimisu (Shadertoy cl3XRX)
// CC BY-NC-SA 4.0
// Converted from GLSL to HLSL for Alt-Tabby

Texture2D iChannel0 : register(t0);
SamplerState samp0 : register(s0);

float4 PSMain(PSInput input) : SV_Target {
    float2 u = input.pos.xy;

    float M = 0.0;
    float A = 0.0;
    float T = time;
    float R = 0.0;

    float4 I = (float4)0;

    float _sinT01 = sin(T * 0.1) * 0.3; // Hoist loop-invariant sin(T*0.1)
    for (; R < 66.0; R += 1.0) {
        float4 X = float4(resolution.x, resolution.y, resolution.y, resolution.y);

        // Build rotation matrix from cos(A*sin(T*.1)*.3 + vec4(0,33,11,0))
        float4 angles = A * _sinT01 + float4(0.0, 33.0, 11.0, 0.0);
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
        float ss = smoothstep(1.0, 0.5, texA); float ss2 = ss*ss; float ss4 = ss2*ss2;
        M = 4.0 * (ss4 * ss4) - 5.0; // pow(x,8)

        A += p.y * 0.6 - (M + A + A + 3.0) / 67.0;

        I += (X.a + 0.5) * (X + A) * (1.4 - p.y) / (2e2 * M * M) / exp(A * 0.1);
    }

    float3 col = I.rgb;

    return AT_PostProcess(col);
}
