// Inspired by https://www.shadertoy.com/view/MtX3Ws

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

float4 PSMain(PSInput input) : SV_Target
{
    float2 fragCoord = input.pos.xy;
    float2 r = resolution.xy;
    float mr = 1. / min(r.x, r.y);
    float x = 0, y = 0, i, j, c, f, t = time;
    float3 n, k = (float3)0, p;
    float3 l = float3(sin(t * .035), sin(t * .089) * cos(t * .073), cos(t * .1)) * .3 + (float3).3;

    // 2x2 AA loop
    for (x = 0; x++ < 2.; y = 0.) { for (y = 0; y++ < 2.;) {
        n = float3((fragCoord * 2. - r + float2(x, y)) * mr * 4., 1.);
        float3 g = (float3)0;
        float u = .2, d = 0.;
        for (i = 0.; i++ < 3.;) {
            d += u; p = n * d - l; c = 0.;
            for (j = 0.; j++ < 7.;) {
                p = (sin(t * .05) * .1 + .9) * abs(p) / dot(p, p) - (cos(t * .09) * .02 + .8);
                p.xy = float2(p.x * p.x - p.y * p.y, (smoothstep(0., 4., time) * 3. + .8 * cos(t * .07)) * p.x * p.y);
                p = p.yxz;
                c += exp(-9. * abs(dot(p, p.zxy)));
            }
            u *= exp(-c * .6);
            f = c * c * .09;
            g = g * 1.5 + .5 * float3(c * f * .3, f, f);
        }
        g *= g;
        k += g * .4;
    }}

    float3 col = k / (1. + k);

    // Post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
