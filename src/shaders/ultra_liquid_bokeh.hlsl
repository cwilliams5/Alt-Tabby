// Ultra Liquid Bokeh — converted from Shadertoy (MtdXzr)
// Created by inigo quilez - iq/2013 : https://www.shadertoy.com/view/4dl3zn
// License Creative Commons Attribution-NonCommercial-ShareAlike 3.0 Unported License.
// Messed up by Weyland

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);

    float aspect = resolution.x / resolution.y;
    float2 uv = -1.0 + 2.0 * fragCoord.xy / resolution.xy;
    uv.x *= aspect;
    float3 color = (float3)0.0;
    float t_div15 = time / 15.0;
    float t_div7_03 = 0.3 * (time / 7.0);
    float col_r = 0.194 * sin(time / 6.0) + 0.3;
    float col_g = 1.1 * sin(time / 9.0) + 0.3;
    for (int i = 0; i < 128; i++)
    {
        float pha =      sin(float(i) * 546.13 + 1.0) * 0.5 + 0.5;
        float _sizT = sin(float(i) * 651.74 + 5.0) * 0.5 + 0.5; float _sizT2 = _sizT * _sizT;
        float siz = _sizT2 * _sizT2;
        float pox =      sin(float(i) * 321.55 + 4.1) * aspect;
        float rad = 0.1 + 0.5 * siz + sin(pha + siz) / 4.0;
        float2 pos = float2( pox + sin(t_div15 + pha + siz), -1.0 - rad + (2.0 + 2.0 * rad) * frac(pha + t_div7_03 * (0.2 + 0.8 * siz)));
        float dis = length( uv - pos );
        float3 col = lerp( float3(col_r, 0.2, 0.3 * pha), float3(col_g, 0.2 * pha, 0.4), 0.5 + 0.5 * sin(float(i)));
        float f = dis / rad;
        f = sqrt(saturate(1.0 + (sin(time * siz) * 0.5) * f));
        color += col.zyx * smoothstep( rad, rad * 0.15, dis );
    }
    color *= sqrt(1.5 - 0.5 * length(uv));

    return AT_PostProcess(color);
}
