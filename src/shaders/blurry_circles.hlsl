// Blurry Circles - converted from Shadertoy (wlBGDG)
// Author: LJ (@LJ_1102) - License: CC BY-NC-SA 3.0

// GLSL mod: always returns positive (a - b*floor(a/b))
float2 glsl_mod(float2 a, float b) {
    return a - b * floor(a / b);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float2 w = resolution.xy;
    float2 p = fragCoord.xy / w.xy * 2.0 - 1.0;
    float2 o = p;
    p.x *= w.x / w.y;
    float3 d = (float3)0.0;
    float t = time * 0.1;
    float e = length(o);
    float k = o.y + o.x;

    for (int i = 0; i < 40; i++) {
        float a = (float)i;
        float r = frac(sin(a * 9.7)) * 0.8;
        p = glsl_mod(p + float2(sin(a + a - t), cos(t + a) + t * 0.1), 2.0) - 1.0;
        float l = length(p);
        float3 baseCol = lerp(
            float3(0.6, 0.46, 0.4),
            float3(0.25, 0.15, 0.3) + float3(0.0, k, k) * 0.25,
            a / 40.0);
        float3 colPow = baseCol * baseCol * baseCol;
        float _rp = max(1.0 - abs(l - r + e * 0.2), 0.0);
        float _rp2 = _rp*_rp; float _rp4 = _rp2*_rp2; float _rp8 = _rp4*_rp4;
        float _rp16 = _rp8*_rp8;
        float ring = (_rp16 * _rp8 * _rp) * 0.2; // pow(x,25)
        float fill = smoothstep(r, r - e * 0.2, l);
        d += colPow * (ring + fill);
    }

    float3 color = sqrt(d) * 1.4;

    return AT_PostProcess(color);
}
