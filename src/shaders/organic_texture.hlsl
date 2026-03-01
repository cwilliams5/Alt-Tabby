// Organic Texture - converted from Shadertoy (tt2XDV)
// Author: Eseris - License: CC BY-NC-SA 3.0
// Gradient noise by iq: https://www.shadertoy.com/view/XdXGW8

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

#define safepow(x,n) pow(abs(x),n)

float2 hash(in float2 x) {
    const float2 k = float2(0.3183099, 0.3678794);
    x = x * k + k.yx;
    return -1.0 + 2.0 * frac(16.0 * k * frac(x.x * x.y * (x.x + x.y)));
}

float noise(in float2 p) {
    float2 i = floor(p);
    float2 f = frac(p);

    float2 u = f * f * (3.0 - 2.0 * f);

    return lerp(lerp(dot(hash(i + float2(0.0, 0.0)), f - float2(0.0, 0.0)),
                     dot(hash(i + float2(1.0, 0.0)), f - float2(1.0, 0.0)), u.x),
                lerp(dot(hash(i + float2(0.0, 1.0)), f - float2(0.0, 1.0)),
                     dot(hash(i + float2(1.0, 1.0)), f - float2(1.0, 1.0)), u.x), u.y);
}

float heightmap(float2 p) {
    float h = 0.0;
    float2 q = 4.0 * p + noise(-4.0 * p + time * float2(-0.07, 0.03));
    float2 r = 7.0 * p + float2(37.0, 59.0) + noise(5.0 * p + time * float2(0.08, 0.03));
    float2 s = 3.0 * p + noise(5.0 * p + time * float2(0.1, 0.05) + float2(13.0, 37.0));
    float smoothAbs = 0.2;
    h += 1.0 * noise(s);
    h += 0.9 * safepow(noise(q), 1.0 + smoothAbs);
    h += 0.7 * safepow(noise(r), 1.0 + smoothAbs);

    h = 0.65 * h + 0.33;
    return h;
}

float3 calcNormal(float2 p) {
    float2 e = float2(1e-3, 0.0);
    return normalize(float3(
        heightmap(p - e.xy) - heightmap(p + e.xy),
        heightmap(p - e.yx) - heightmap(p + e.yx),
        -2.0 * e.x));
}

float3 getColor(float x) {
    float3 a = float3(0.1, 0.0, 0.03);
    float3 b = float3(1.0, 0.05, 0.07);
    float3 c = float3(0.9, 0.2, 0.3);
    return lerp(a, lerp(b, c, smoothstep(0.4, 0.9, x)), smoothstep(0.0, 0.9, x));
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float2 uv = fragCoord / resolution.y;
    float h = heightmap(uv);
    float3 v = (float3)h;
    v.yz *= 3.0;
    float3 nor = calcNormal(uv);
    nor.xy *= 0.4;
    nor = normalize(nor);

    float3 mtl = getColor(h);
    mtl = clamp(mtl, 0.0, 1.0);
    float3 ld = normalize(float3(1.0, -1.0, 1.0));
    float3 ha = normalize(ld - float3(0.0, 0.0, -1.0));

    float3 col = (float3)0.0;
    col += mtl * 0.8;
    col += 0.2 * mtl * safepow(max(dot(normalize(nor), -ld), 0.0), 3.0);
    col += 0.3 * h * safepow(dot(normalize(nor), ha), 20.0);

    // Darken / desaturate post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
