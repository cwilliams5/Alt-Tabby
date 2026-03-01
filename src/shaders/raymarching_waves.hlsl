// Is it still raymarching? — converted from Shadertoy 7sdyWX
// By VPas, inspired by https://www.shadertoy.com/view/MtX3Ws
// License: CC BY-NC-SA 3.0

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
    float2 r = resolution.xy;
    float mr = 1.0 / min(r.x, r.y);
    float c, f, t = time;
    float3 k = (float3)0;
    float3 n, p;
    float3 l = float3(sin(t * .035), sin(t * .089) * cos(t * .073), cos(t * .1)) * .3 + (float3).3;

    // 2x2 AA loop
    [unroll] for (int ax = 1; ax <= 2; ax++) {
        [unroll] for (int ay = 1; ay <= 2; ay++) {
            n = float3((fragCoord * 2.0 - r + float2(ax, ay)) * mr * 4.0, 1.0);
            float3 g = (float3)0;
            float u = .2, d = 0.0;

            [loop] for (int ii = 0; ii < 3; ii++) {
                d += u;
                p = n * d - l;
                c = 0.0;

                [loop] for (int jj = 0; jj < 7; jj++) {
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
        }
    }

    float3 col = k / (1.0 + k);

    // Darken/desaturate post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
