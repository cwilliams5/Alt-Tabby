// Singularity by @XorDev — https://www.shadertoy.com/view/3csSWB
// A whirling blackhole.

cbuffer Constants : register(b0) {
    float time;
    float2 resolution;
    float timeDelta;
    uint frame;
    float darken;
    float desaturate;
    float _pad;
};

struct PSInput {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
};

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    // Iterator and attenuation (distance-squared)
    float i = .2, a;
    // Resolution for scaling and centering
    float2 r = resolution;
    // Centered ratio-corrected coordinates
    float2 p = (fragCoord + fragCoord - r) / r.y / .7;
    // Diagonal vector for skewing
    float2 d = float2(-1, 1);
    // Blackhole center
    float2 b = p - i * d;
    // Rotate and apply perspective
    float2 dExpr = d / (.1 + i / dot(b, b));
    // GLSL: p * mat2(1, 1, dExpr.x, dExpr.y) → HLSL: mul(float2x2(same args), p)
    float2 c = mul(float2x2(1, 1, dExpr.x, dExpr.y), p);
    // Rotate into spiraling coordinates
    a = dot(c, c);
    float4 cosVal = cos(.5 * log(a) + time * i + float4(0, 33, 11, 0));
    float2 v = mul(float2x2(cosVal.x, cosVal.y, cosVal.z, cosVal.w), c) / i;
    // Waves cumulative total for coloring
    float2 w = (float2)0;

    // Loop through waves
    [unroll]
    for (; i++ < 9.; w += 1. + sin(v))
        // Distort coordinates
        v += .7 * sin(v.yx * i + time) / i + .5;
    // Acretion disk radius
    i = length(sin(v / .3) * .4 + c * (3. + d));
    // Red/blue gradient
    float4 color = 1. - exp(-exp(c.x * float4(.6, -.4, -1, 0))
                          // Wave coloring
                          / w.xyyx
                          // Acretion disk brightness
                          / (2. + i * i / 4. - i)
                          // Center darkness
                          / (.5 + 1. / a)
                          // Rim highlight
                          / (.03 + abs(length(p) - .7)));

    // Apply darken/desaturate
    float3 col = color.rgb;
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float alpha = max(col.r, max(col.g, col.b));
    return float4(col * alpha, alpha);
}
