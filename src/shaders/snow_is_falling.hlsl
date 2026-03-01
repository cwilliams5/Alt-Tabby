// Snow is Falling - tholzer (Shadertoy 4lfcz4)
// Converted from GLSL to HLSL for Alt-Tabby
// Background: https://www.shadertoy.com/view/4dl3R4
// Snow: https://www.shadertoy.com/view/ldsGDn

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

// GLSL-compatible mod (always positive for positive divisor)
float glsl_mod(float x, float y) { return x - y * floor(x / y); }
float2 glsl_mod(float2 x, float y) { return x - y * floor(x / y); }
float3 glsl_mod(float3 x, float y) { return x - y * floor(x / y); }
float2 glsl_mod2(float2 x, float2 y) { return x - y * floor(x / y); }

#define mod289(x) glsl_mod((x), 289.0)

float3 permute(float3 x) { return mod289(((x * 34.0) + 1.0) * x); }

//-----------------------------------------------------
float snoise(float2 v)
{
    const float4 C = float4(0.211324865405187, 0.366025403784439, -0.577350269189626, 0.024390243902439);
    float2 i = floor(v + dot(v, C.yy));
    float2 x0 = v - i + dot(i, C.xx);

    float2 i1;
    i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;

    i = mod289(i); // Avoid truncation effects in permutation
    float3 p = permute(permute(i.y + float3(0.0, i1.y, 1.0))
                + i.x + float3(0.0, i1.x, 1.0));

    float3 m = max(0.5 - float3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), 0.0);
    m = m * m;
    m = m * m;

    float3 x = 2.0 * frac(p * C.www) - 1.0;
    float3 h = abs(x) - 0.5;
    float3 ox = floor(x + 0.5);
    float3 a0 = x - ox;

    m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);

    float3 g;
    g.x = a0.x * x0.x + h.x * x0.y;
    g.yz = a0.yz * x12.xz + h.yz * x12.yw;

    return 130.0 * dot(m, g);
}

//-----------------------------------------------------
float fbm(float2 p)
{
    float f = 0.0;
    float w = 0.5;
    for (int i = 0; i < 5; i++)
    {
        f += w * snoise(p);
        p *= 2.;
        w *= 0.5;
    }
    return f;
}

//-----------------------------------------------------
float background(float2 uv)
{
    // iMouse zeroed (only active on click in Shadertoy)
    uv.x += -1.0;

    float2 sunCenter = float2(0.3, 0.9);
    float suns = clamp(1.2 - distance(uv, sunCenter), 0.0, 1.0);
    float sunsh = smoothstep(0.85, 0.95, suns);

    float slope = 1.0 - smoothstep(0.55, 0.0, 0.8 + uv.x - 2.3 * uv.y);

    float n = abs(fbm(uv * 1.5));
    slope = (n * 0.2) + (slope - ((1.0 - n) * slope * 0.1)) * 0.6;
    slope = clamp(slope, 0.0, 1.0);

    return 0.35 + (slope * (suns + 0.3)) + (sunsh * 0.6);
}

//-----------------------------------------------------

#define LAYERS 66

#define DEPTH1 .3
#define WIDTH1 .4
#define SPEED1 .6

#define DEPTH2 .1
#define WIDTH2 .3
#define SPEED2 .1

float snowing(in float2 uv, in float2 fragCoord)
{
    const float3x3 p = float3x3(13.323122, 23.5112, 21.71123, 21.1212, 28.7312, 11.9312, 21.8112, 14.7212, 61.3934);
    // iMouse zeroed — default snow parameters
    float depth = smoothstep(DEPTH1, DEPTH2, 0.0);
    float width = smoothstep(WIDTH1, WIDTH2, 0.0);
    float speed = smoothstep(SPEED1, SPEED2, 0.0);
    float acc = 0.0;
    float dof = 5.0 * sin(time * 0.1);
    for (int i = 0; i < LAYERS; i++)
    {
        float fi = float(i);
        float2 q = uv * (1.0 + fi * depth);
        float w = width * glsl_mod(fi * 7.238917, 1.0) - width * 0.1 * sin(time * 2. + fi);
        q += float2(q.y * w, speed * time / (1.0 + fi * depth * 0.03));
        float3 n = float3(floor(q), 31.189 + fi);
        float3 m = floor(n) * 0.00001 + frac(n);
        float3 mp = (31415.9 + m) / frac(mul(m, p));
        float3 r = frac(mp);
        float2 s = abs(glsl_mod2(q, (float2)1.0) - 0.5 + 0.9 * r.xy - 0.45);
        s += 0.01 * abs(2.0 * frac(10. * q.yx) - 1.);
        float d = 0.6 * max(s.x - s.y, s.x + s.y) + max(s.x, s.y) - .01;
        float edge = 0.05 + 0.05 * min(.5 * abs(fi - 5. - dof), 1.);
        acc += smoothstep(edge, -edge, d) * (r.x / (1. + .02 * fi * depth));
    }
    return acc;
}

//-----------------------------------------------------
float4 PSMain(PSInput input) : SV_Target {
    // Y-flip: snow falls downward, background has ground orientation
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);
    float2 uv = fragCoord.xy / resolution.y;

    float bg = background(uv);
    float3 col = float3(bg * 0.9, bg, bg * 1.1);

    float snowOut = snowing(uv, fragCoord);
    col += (float3)snowOut;

    // Darken/desaturate post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
