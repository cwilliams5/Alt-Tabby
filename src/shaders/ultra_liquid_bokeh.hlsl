// Ultra Liquid Bokeh — converted from Shadertoy (MtdXzr)
// Created by inigo quilez - iq/2013 : https://www.shadertoy.com/view/4dl3zn
// License Creative Commons Attribution-NonCommercial-ShareAlike 3.0 Unported License.
// Messed up by Weyland

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
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);

    float2 uv = -1.0 + 2.0 * fragCoord.xy / resolution.xy;
    uv.x *= resolution.x / resolution.y;
    float3 color = (float3)0.0;
    for (int i = 0; i < 128; i++)
    {
        float pha =      sin(float(i) * 546.13 + 1.0) * 0.5 + 0.5;
        float siz = pow( sin(float(i) * 651.74 + 5.0) * 0.5 + 0.5, 4.0 );
        float pox =      sin(float(i) * 321.55 + 4.1) * resolution.x / resolution.y;
        float rad = 0.1 + 0.5 * siz + sin(pha + siz) / 4.0;
        float2 pos = float2( pox + sin(time / 15. + pha + siz), -1.0 - rad + (2.0 + 2.0 * rad) * fmod(pha + 0.3 * (time / 7.) * (0.2 + 0.8 * siz), 1.0));
        float dis = length( uv - pos );
        float3 col = lerp( float3(0.194 * sin(time / 6.0) + 0.3, 0.2, 0.3 * pha), float3(1.1 * sin(time / 9.0) + 0.3, 0.2 * pha, 0.4), 0.5 + 0.5 * sin(float(i)));
        float f = length(uv - pos) / rad;
        f = sqrt(clamp(1.0 + (sin(time * siz) * 0.5) * f, 0.0, 1.0));
        color += col.zyx * (1.0 - smoothstep( rad * 0.15, rad, dis ));
    }
    color *= sqrt(1.5 - 0.5 * length(uv));

    // Darken/desaturate post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float a = max(color.r, max(color.g, color.b));
    return float4(color * a, a);
}
