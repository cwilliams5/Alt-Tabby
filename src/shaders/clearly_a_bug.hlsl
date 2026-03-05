// CC0: Clearly a bug - mrange
// https://www.shadertoy.com/view/33cGDj

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float i = 0.0;
    float d = 0.0;
    float z = frac(dot(fragCoord, sin(fragCoord))) - 0.5;
    float4 o = (float4)0;
    float4 p = (float4)0;
    float4 O = (float4)0;

    float2 r = resolution;
    [loop] for (; ++i < 77.0; z += 0.6 * d) {
        p = float4(z * normalize(float3(fragCoord - 0.5 * r, r.y)), 0.1 * time);
        p.z += time;
        O = p;

        // Rotation matrix 1 — fractal pattern transform
        float s1, c1;
        sincos(2.0 + O.z, s1, c1);
        p.xy = mul(float2x2(c1, -s1, s1, c1), p.xy);

        // Rotation matrix 2 — the happy accident bug
        // O is float4: each component uses a different angle, not a true rotation
        float4 cv2 = cos(O + float4(0, 11, 33, 0));
        p.xy = mul(float2x2(cv2.x, cv2.z, cv2.y, cv2.w), p.xy);

        // Color palette from position + space distortion
        O = (1.0 + sin(0.5 * O.z + length(p - O) + float4(0, 4, 3, 6)))
            / (0.5 + 2.0 * dot(O.xy, O.xy));

        // Domain repetition
        p = abs(frac(p) - 0.5);

        // Distance to nearest surface (cylinder + 2 planes)
        d = abs(min(length(p.xy) - 0.125, min(p.x, p.y) + 1e-3)) + 1e-3;

        // Accumulate lighting
        o += O.w / d * O;
    }

    // HDR tone mapping
    float3 color = tanh(o.rgb / 2e4);

    return AT_PostProcess(color);
}
