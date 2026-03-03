// Path to the colorful infinity by benoitM
// Ported from https://www.shadertoy.com/view/WtjyzR
// 2D fractal space-folding with layered depth

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

#define NUM_LAYERS 16.
#define ITER 23

float4 tex_fractal(float3 p) {
    float t = time + 78.;
    float4 o = float4(p.xyz, 3.*sin(t*.1));
    float4 dec = float4(1., .9, .1, .15) + float4(.06*cos(t*.1), 0, 0, .14*cos(t*.23));
    [loop]
    for (int i = 0; i++ < ITER;) o.xzyw = abs(o / dot(o, o) - dec);
    return o;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float2 uv = (fragCoord - resolution.xy*.5) / resolution.y;
    float3 col = (float3)0;
    float t = time * .3;

    [loop]
    for (float i = 0.; i <= 1.; i += 1./NUM_LAYERS) {
        float d = frac(i + t);
        float s = lerp(5., .5, d);
        float f = d * smoothstep(1., .9, d);
        col += tex_fractal(float3(uv*s, i*4.)).xyz * f;
    }

    col /= NUM_LAYERS;
    col *= float3(2, 1., 2.);
    col = pow(col, (float3).5);

    // Post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, (float3)lum, desaturate);
    col *= 1.0 - darken;

    // Alpha from brightness, premultiply
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
