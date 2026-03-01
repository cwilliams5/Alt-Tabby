// Volumetric Fire — gyroid fBm volumetric ray marcher
// https://www.shadertoy.com/view/NttBWj
// Author: myth0genesis | License: CC BY-NC-SA 3.0
// Based on nimitz's Protean clouds

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

static const float3x3 m3 = float3x3(0.3338, 0.56034, -0.71817,
                                     -0.87887, 0.32651, -0.15323,
                                     0.15162, 0.69596, 0.61339) * 1.93;

float LinStep(float mn, float mx, float x) {
    return clamp((x - mn) / (mx - mn), 0.0, 1.0);
}

float2x2 rotate(float a) {
    float c = cos(a);
    float s = sin(a);
    return float2x2(c, s, -s, c);
}

// nimitz's genius fast gyroid fBm
float gyroidFBM3D(float3 p, float cl) {
    float d = 0.0;
    p *= 0.185;
    p.z -= time;
    float z = 1.0;
    float trk = 1.0;
    float dspAmp = 0.1;
    for (int i = 0; i < 5; i++) {
        p += sin(p.yzx * 1.5 * trk) * dspAmp;
        d -= abs(dot(cos(p), sin(p.zxy)) * z);
        z *= 0.7;
        trk *= 1.4;
        p = mul(p, m3);
        p -= time * 2.0;
    }
    return (cl + d * 6.5) * 0.5;
}

// nimitz's volumetric ray marcher
float3 transRender(float3 ro, float3 rd) {
    float4 rez = float4(0.0, 0.0, 0.0, 0.0);
    float t = 20.0;
    for (int i = 0; i < 100; i++) {
        if (rez.w > 0.99) break;
        float3 pos = ro + t * rd;
        float mpv = gyroidFBM3D(pos, -pos.z);
        float den = clamp(mpv - 0.2, 0.0, 1.0) * 0.71;
        float dn = clamp(mpv * 2.0, 0.0, 3.0);
        float4 col = float4(0.0, 0.0, 0.0, 0.0);
        if (mpv > 0.6) {
            col = float4(11.0, 1.0, 0.0, 0.08);
            col *= den;
            col.xyz *= LinStep(3.0, -1.0, mpv) * 3.0;
            float dif = clamp((den - mpv + 1.5) * 0.125, 0.08, 1.0);
            col.xyz *= den * (1.5 * float3(0.005, 0.045, 0.075) + 1.5 * float3(0.033, 0.05, 0.030) * dif);
        }
        rez += col * (1.0 - rez.w);
        t += clamp(0.25 - dn * dn * 0.05, 0.15, 1.4);
    }
    return clamp(rez.xyz, 0.0, 1.0);
}

float4 PSMain(PSInput input) : SV_Target
{
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);
    float2 uv = (fragCoord - 0.5 * resolution) / resolution.y;
    float3 ro = float3(0.0, 0.0, -3.0);

    float3 rd = normalize(float3(uv.x, 1.0, uv.y));

    // Gentle time-based camera rotation (replaces mouse drag)
    rd.xy = mul(rd.xy, rotate(sin(time * 0.15) * 0.3));

    float3 col = transRender(ro, rd);

    // darken/desaturate post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // alpha from brightness, premultiply
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}