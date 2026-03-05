// Satinlike (Simple FBM Warp) by CaliCoastReplay
// Ported from https://www.shadertoy.com/view/ll3GD7
// FBM domain warping inspired by IQ's warp tutorial

// Color space helpers

float3 rgb2hsv(float3 c) {
    float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    float4 p = lerp(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
    float4 q = lerp(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

float3 hsv2rgb(float3 c) {
    float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(frac(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * lerp(K.xxx, saturate(p - K.xxx), c.y);
}

// FBM (Fractal Brownian Motion)

float rand_val(float2 n) {
    return frac(cos(dot(n, float2(12.9898, 4.1414))) * 3758.5453);
}

float noise_val(float2 n) {
    float2 d = float2(0.0, 1.0);
    float2 b = floor(n);
    float2 f = smoothstep((float2)0, (float2)1, frac(n));
    return lerp(lerp(rand_val(b), rand_val(b + d.yx), f.x),
                lerp(rand_val(b + d.xy), rand_val(b + d.yy), f.x), f.y);
}

float fbm(float2 n) {
    float total = 0.0;
    float amplitude = 1.0;
    [loop]
    for (int i = 0; i < 10; i++) {
        total += noise_val(n) * amplitude;
        amplitude *= 0.4;
    }
    return total;
}

float pattern(float2 p) {
    float _st, _ct;
    sincos(time, _st, _ct);

    float2 q = float2(
        fbm(p),
        fbm(p + float2(5.2 + _st / 10.0, 1.3 - _ct / 10.0)));

    float2 r = float2(
        fbm(p + 4.0 * q + float2(1.7 + _st / 10.0, 9.2)),
        fbm(p + 4.0 * q + float2(8.3, 2.8 - _ct / 10.0)));

    float2 ac = p + 4.0 * r;
    ac.x += _st;
    ac.y += _ct;
    return 1.0 / fbm(ac + time
               + fbm(ac - time
                    + fbm(ac + _st)));
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 uv = fragCoord / resolution;
    float intensity = pattern(uv);
    float3 color = float3(uv, 0.5 + 0.5 * sin(time));
    float3 hsv = rgb2hsv(color);
    hsv.z = cos(hsv.y) - 0.1;
    color = hsv2rgb(hsv);
    color *= intensity;

    return AT_PostProcess(color);
}
