// Noise animation - Electric
// by nimitz (stormoid.com) (twitter: @stormoid)
// License Creative Commons Attribution-NonCommercial-ShareAlike 3.0 Unported License
// Converted from Shadertoy (ldlXRS) to Alt-Tabby HLSL

cbuffer Constants : register(b0) {
    float time;
    float2 resolution;
    float timeDelta;
    uint frame;
    float darken;
    float desaturate;
    float _pad;
};

Texture2D iChannel0 : register(t0);
SamplerState samp0 : register(s0);

struct PSInput {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
};

#define t time*0.15
#define tau 6.2831853

float2x2 makem2(in float theta) {
    float c = cos(theta);
    float s = sin(theta);
    return float2x2(c, -s, s, c);
}

float noise(in float2 x) {
    return iChannel0.Sample(samp0, x * 0.01).x;
}

float fbm(in float2 p) {
    float z = 2.0;
    float rz = 0.0;
    float2 bp = p;
    for (float i = 1.0; i < 6.0; i++) {
        rz += abs((noise(p) - 0.5) * 2.0) / z;
        z = z * 2.0;
        p = p * 2.0;
    }
    return rz;
}

float dualfbm(in float2 p) {
    // get two rotated fbm calls and displace the domain
    float2 p2 = p * 0.7;
    float2 basis = float2(fbm(p2 - t * 1.6), fbm(p2 + t * 1.7));
    basis = (basis - 0.5) * 0.2;
    p += basis;

    // coloring
    return fbm(mul(p, makem2(t * 0.2)));
}

float circ(float2 p) {
    float r = length(p);
    r = log(sqrt(r));
    return abs(fmod(r * 4.0, tau) - 3.14) * 3.0 + 0.2;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    // setup system
    float2 p = fragCoord.xy / resolution.xy - 0.5;
    p.x *= resolution.x / resolution.y;
    p *= 4.0;

    float rz = dualfbm(p);

    // rings
    p /= exp(fmod(t * 10.0, 3.14159));
    rz *= pow(abs(0.1 - circ(p)), 0.9);

    // final color
    float3 col = float3(0.2, 0.1, 0.4) / rz;
    col = pow(abs(col), (float3)0.99);

    // darken/desaturate
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // alpha from brightness, premultiply
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}