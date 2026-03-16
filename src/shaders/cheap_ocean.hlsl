// Cheap Ocean - converted from Shadertoy (NdtXDN) by Krischan
// https://www.shadertoy.com/view/NdtXDN
// License: CC BY-NC-SA 3.0

float2x2 rotate2D(float r) {
    float s, c;
    sincos(r, s, c);
    return float2x2(c, s, -s, c);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);

    float e = 0, f = 0, s = 0, g = 0, k = 0.01;
    float o = 1;

    float2x2 rot_neg08 = rotate2D(-0.8);
    for (int i = 0; i < 100; i++) {
        s = 2.0;
        g += min(f, max(0.03, e)) * 0.3;
        float3 p = float3((fragCoord - resolution / s) / resolution.y * g, g - s);
        p.yz = mul(rot_neg08, p.yz);
        p.y *= 2.5;
        p.z += time * 1.3;
        e = p.y;
        f = p.y;
        for (; s < 50.0;) {
            s *= 1.51515151;
            p.xz = mul(rotate2D(s), p.xz);
            float inv_s = 1.0 / s;
            e += abs(dot(sin(p * s) * inv_s, (float3)0.6));
            f += abs(dot(sin(p.xz * s * 0.33 + time * 0.5) * inv_s, (float2)1.0));
        }

        if (f > k * k)
            o += e * o * k;
        else
            o += -exp(-f * f) * o * k;
    }

    float3 color = o * float3(0.33, 0.7, 0.85);

    return AT_PostProcess(color);
}
