// Glassy with odd rotation by etrujillo — https://www.shadertoy.com/view/3XdXWX
// A shiny reflective variation of a raymarched fractal accident (CC0)

// tanh not available in SM 5.0
float3 tanhSafe(float3 x) {
    float3 e2x = exp(2.0 * clamp(x, -10.0, 10.0));
    return (e2x - 1.0) / (e2x + 1.0);
}

float sdfMap(float3 p) {
    // Domain repetition
    p = abs(frac(p) - 0.5);
    // Cylinder + planes SDF
    return abs(min(length(p.xy) - 0.175, min(p.x, p.y) + 1e-3)) + 1e-3;
}

float3 estimateNormal(float3 p) {
    float eps = 0.001;
    return normalize(float3(
        sdfMap(p + float3(eps, 0.0, 0.0)) - sdfMap(p - float3(eps, 0.0, 0.0)),
        sdfMap(p + float3(0.0, eps, 0.0)) - sdfMap(p - float3(0.0, eps, 0.0)),
        sdfMap(p + float3(0.0, 0.0, eps)) - sdfMap(p - float3(0.0, 0.0, eps))));
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 r = resolution;
    float2 uv = (fragCoord - 0.5 * r) / r.y;

    float t = time;
    float z = frac(dot(fragCoord, sin(fragCoord))) - 0.5;
    float3 col = (float3)0;
    float4 p;

    [loop]
    for (float i = 0.0; i < 77.0; i++) {
        // Ray direction
        p = float4(z * normalize(float3(fragCoord - 0.7 * r, r.y)), 0.1 * t);
        p.z += t;

        float4 q = p;

        // Apply rotation matrices for glitchy fractal distortion
        float s1, c1;
        sincos(2.0 + q.z, s1, c1);
        p.xy = mul(float2x2(c1, s1, -s1, c1), p.xy);
        // q is float4: each component uses a different angle, not a true rotation
        float4 cosVal2 = cos(q + float4(0, 11, 33, 0));
        p.xy = mul(float2x2(cosVal2.x, cosVal2.y, cosVal2.z, cosVal2.w), p.xy);

        // Distance estimation
        float d = sdfMap(p.xyz);

        // Estimate lighting
        float3 pos = p.xyz;
        float3 lightDir = normalize(float3(0.3, 0.5, 1.0));
        float3 viewDir = normalize(float3(uv, 1.0));
        float3 n = estimateNormal(pos);
        float3 reflectDir = reflect(viewDir, n);

        // Fake environment reflection
        float3 envColor = lerp(float3(0.8, 0.4, 0.8), (float3)1.0, 0.5 + 0.5 * reflectDir.y);

        // Specular highlight
        float _sp0 = max(dot(reflectDir, lightDir), 0.0); float _sp2 = _sp0*_sp0; float _sp4 = _sp2*_sp2;
        float _sp8 = _sp4*_sp4; float _sp16 = _sp8*_sp8; float spec = _sp16*_sp16;

        // Funky palette color
        float4 baseColor = (1.0 + sin(0.5 * q.z + length(p.xyz - q.xyz) + float4(0, 4, 3, 6)))
                         / (0.5 + 2.0 * dot(q.xy, q.xy));

        // Combine base color + environment reflection + specular
        float3 finalColor = baseColor.rgb * 0.1 + envColor * 0.9 + (float3)spec * 1.2;

        // Brightness weighted accumulation
        col += finalColor / d;

        z += 0.6 * d;
    }

    // Compress brightness range
    float3 color = tanhSafe(col / 2e4);

    return AT_PostProcess(color);
}
