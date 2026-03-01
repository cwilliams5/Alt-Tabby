// Grey Liquid - Converted from Shadertoy (fsdyzf)
// Licence CC0: Liquid Metal
// Some experimenting with warped FBM and very very fake lighting
// Author: fractalfantasy — Forked from Warped Liquid two (7tyXDw)

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

#define PI  3.141592654
#define TAU (2.0*PI)

void rot(inout float2 p, float a) {
    float c = cos(a);
    float s = sin(a);
    p = float2(c*p.x + s*p.y, -s*p.x + c*p.y);
}

float hash(in float2 co) {
    return frac(sin(dot(co.xy, float2(12.9898, 58.233))) * 13758.5453);
}

float psin(float a) {
    return 0.5 + 0.5*sin(a);
}

float tanh_approx(float x) {
    float x2 = x*x;
    return clamp(x*(27.0 + x2)/(27.0 + 9.0*x2), -1.0, 1.0);
}

float onoise(float2 x) {
    x *= 0.5;
    float a = sin(x.x);
    float b = sin(x.y);
    float c = lerp(a, b, psin(TAU*tanh_approx(a*b + a + b)));
    return c;
}

float vnoise(float2 x) {
    float2 i = floor(x);
    float2 w = frac(x);

    // quintic interpolation
    float2 u = w*w*w*(w*(w*6.0 - 15.0) + 10.0);

    float a = hash(i + float2(0.0, 0.0));
    float b = hash(i + float2(1.0, 0.0));
    float c = hash(i + float2(0.0, 1.0));
    float d = hash(i + float2(1.0, 1.0));

    float k0 = a;
    float k1 = b - a;
    float k2 = c - a;
    float k3 = d - c + a - b;

    return k0 + k1*u.x + k2*u.y + k3*u.x*u.y;
}

float fbm1(float2 p) {
    float2 op = p;
    const float aa = 0.45;
    const float pp = 2.03;
    const float2 oo = -float2(1.23, 1.5);
    const float rr = 1.2;

    float h = 0.0;
    float d = 0.0;
    float a = 1.0;

    [loop]
    for (int i = 0; i < 5; ++i) {
        h += a*onoise(p);
        d += a;
        a *= aa;
        p += oo;
        p *= pp;
        rot(p, rr);
    }

    return lerp(h/d, -0.5*(h/d), pow(vnoise(0.9*op), 0.25));
}

float fbm2(float2 p) {
    float2 op = p;
    const float aa = 0.45;
    const float pp = 2.03;
    const float2 oo = -float2(1.23, 1.5);
    const float rr = 1.2;

    float h = 0.0;
    float d = 0.0;
    float a = 1.0;

    [loop]
    for (int i = 0; i < 7; ++i) {
        h += a*onoise(p);
        d += a;
        a *= aa;
        p += oo;
        p *= pp;
        rot(p, rr);
    }

    return lerp(h/d, -0.5*(h/d), pow(vnoise(0.9*op), 0.25));
}

float fbm3(float2 p) {
    float2 op = p;
    const float aa = 0.45;
    const float pp = 2.03;
    const float2 oo = -float2(1.23, 1.5);
    const float rr = 1.2;

    float h = 0.0;
    float d = 0.0;
    float a = 1.0;

    [loop]
    for (int i = 0; i < 3; ++i) {
        h += a*onoise(p);
        d += a;
        a *= aa;
        p += oo;
        p *= pp;
        rot(p, rr);
    }

    return lerp(h/d, -0.5*(h/d), pow(vnoise(0.9*op), 0.25));
}

float warp(float2 p) {
    float2 v = float2(fbm1(p), fbm1(p + 0.7*float2(1.0, 1.0)));

    rot(v, 1.0 + time*1.8);

    float2 vv = float2(fbm2(p + 3.7*v), fbm2(p + -2.7*v.yx + 0.7*float2(1.0, 1.0)));

    rot(vv, -1.0 + time*0.8);

    return fbm3(p + 9.0*vv);
}

float height(float2 p) {
    float a = 0.045*time;
    p += 9.0*float2(cos(a), sin(a));
    p *= 2.0;
    p += 13.0;
    float h = warp(p);
    float rs = 3.0;
    return 0.35*tanh_approx(rs*h)/rs;
}

float3 computeNormal(float2 p) {
    float2 eps = -float2(2.0/resolution.y, 0.0);

    float3 n;
    n.x = height(p + eps.xy) - height(p - eps.xy);
    n.y = 2.0*eps.x;
    n.z = height(p + eps.yx) - height(p - eps.yx);

    return normalize(n);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float2 q = fragCoord / resolution.xy;
    float2 p = -1. + 2. * q;
    p.x *= resolution.x / resolution.y;

    // lights positions
    const float3 lp1 = float3(2.1, -0.5, -0.1);
    const float3 lp2 = float3(-2.1, -0.5, -0.1);

    float h = height(p);
    float3 pp = float3(p.x, h, p.y);
    float ll1 = length(lp1.xz - pp.xz);
    float3 ld1 = normalize(lp1 - pp);
    float3 ld2 = normalize(lp2 - pp);

    float3 n = computeNormal(p);
    float diff1 = max(dot(ld1, n), 0.0);
    float diff2 = max(dot(ld2, n), 0.0);

    // lights colors
    float3 baseCol1 = float3(0.5, 0.4, 0.4);
    float3 baseCol2 = float3(0.1, 0.1, 0.1);

    float oh = height(p + ll1*0.05*normalize(ld1.xz));
    const float level0 = 0.0;
    const float level1 = 0.125;

    // VERY VERY fake shadows + hilight
    float3 scol1 = baseCol1*(smoothstep(level0, level1, h) - smoothstep(level0, level1, oh));
    float3 scol2 = baseCol2*(smoothstep(level0, level1, h) - smoothstep(level0, level1, oh));

    // specular and diffuse
    float3 color = float3(0.0, 0.0, 0.0);
    color += 0.55*baseCol1.zyx*pow(diff1, 1.0);
    color += 0.55*baseCol1.zyx*pow(diff1, 1.0);
    color += 0.55*baseCol2.zyx*pow(diff2, 1.0);
    color += 0.55*baseCol2.zyx*pow(diff2, 1.0);
    color += scol1*0.5;
    color += scol2*0.5;

    // Darken/desaturate post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiply
    float alpha = max(color.r, max(color.g, color.b));
    return float4(color * alpha, alpha);
}
