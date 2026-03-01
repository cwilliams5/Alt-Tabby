// Perhaps a screensaver — converted from Shadertoy (Wfy3zh)
// Original by pirandello (CC0/Public Domain)
// Forked from Trailing the Twinkling Tunnel by BeRo & Paul Karlik

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

float g(float4 p, float s) {
    p *= s;
    return abs(dot(sin(p), cos(p.zxwy)) - 1.0) / s;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float T = time;
    float4 o = (float4)0;
    float4 q = (float4)0;
    float4 p = (float4)0;
    float4 U = float4(2, 1, 0, 3);
    float d = 0.0;
    float z = 0.0;
    float s = 0.0;
    float2 r = resolution;

    for (float i = 0.0; i < 79.0; i += 1.0) {
        z += d + 5e-4;
        q = float4(normalize(float3((fragCoord + fragCoord - r) / r.y, 2.0)) * z, 0.2);
        q.z += T / 30.0;
        s = q.y + 0.1;
        q.y = abs(s);
        p = q;
        p.y -= 0.11;

        // mat2(cos(11. * U.zywz - 2. * p.z))
        float4 angles = 11.0 * U.zywz - 2.0 * p.z;
        float4 cv = cos(angles);
        float2x2 m = float2x2(cv.x, cv.y, cv.z, cv.w);
        p.xy = mul(p.xy, m);

        p.y -= 0.2;
        d = abs(g(p, 8.0) - g(p, 24.0)) / 4.0;

        // Palette color
        p = 1.4 + 1.8 * cos(float4(1.8, 3.1, 4.5, 0.0) + 7.0 * q.z);

        // Glow accumulation
        o += (s > 0.0 ? 1.0 : 0.1) * p.w * p / max(s > 0.0 ? d : d * d * d, 5e-4);
    }

    // Animated, color-shifting, moving tunnelwisp
    float2 wispPos = 1.5 * float2(cos(T * 0.7), sin(T * 0.9));
    float wispDist = length(q.xy - wispPos);
    float3 wispColor = float3(1.0, 0.8 + 0.2 * sin(T), 0.7 + 0.3 * cos(T * 1.3));
    o.xyz += (2.0 + sin(T * 2.0)) * 800.0 * wispColor / (wispDist + 0.4);

    // Tone mapping
    float3 color = tanh(o.xyz / 1e5);

    // Darken/desaturate
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(color.r, max(color.g, color.b));
    return float4(color * a, a);
}
