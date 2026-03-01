// License CC0: Alien skin
//  Converted from Shadertoy: https://www.shadertoy.com/view/wtBcRW
//  Author: mrange
//  More playing around with warped FBMs
//  https://iquilezles.org/articles/warp

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

float hash(float2 co) {
    return frac(sin(dot(co.xy, float2(12.9898, 58.233))) * 13758.5453);
}

float psin(float a) {
    return 0.5 + 0.5*sin(a);
}

float onoise(float2 x) {
    x *= 0.5;
    float a = sin(x.x);
    float b = sin(x.y);
    float c = lerp(a, b, psin(TAU*tanh(a*b+a+b)));
    return c;
}

float vnoise(float2 x) {
    float2 i = floor(x);
    float2 w = frac(x);

    // quintic interpolation
    float2 u = w*w*w*(w*(w*6.0-15.0)+10.0);

    float a = hash(i+float2(0.0, 0.0));
    float b = hash(i+float2(1.0, 0.0));
    float c = hash(i+float2(0.0, 1.0));
    float d = hash(i+float2(1.0, 1.0));

    float k0 =   a;
    float k1 =   b - a;
    float k2 =   c - a;
    float k3 =   d - c + a - b;

    float aa = lerp(a, b, u.x);
    float bb = lerp(c, d, u.x);
    float cc = lerp(aa, bb, u.y);

    return k0 + k1*u.x + k2*u.y + k3*u.x*u.y;
}

float fbm(float2 p, int mx) {
    float2 op = p;
    const float aa = 0.45;
    const float pp = 2.03;
    const float2 oo = -float2(1.23, 1.5);
    const float rr = 1.2;

    float h = 0.0;
    float d = 0.0;
    float a = 1.0;

    for (int i = 0; i < mx; ++i) {
        h += a*onoise(p);
        d += a;
        a *= aa;
        p += oo;
        p *= pp;
        rot(p, rr);
    }

    return lerp((h/d), -0.5*(h/d), pow(vnoise(0.9*op), 0.25));
}

float warp(float2 p) {
    const int mx1 = 8;
    const int mx2 = 3;
    const int mx3 = 3;
    float2 v = float2(fbm(p, mx1), fbm(p+0.7*float2(1.0, 1.0), mx1));

    rot(v, 1.0+time*0.1);

    float2 vv = float2(fbm(p + 3.7*v, mx2), fbm(p + -2.7*v.yx+0.7*float2(1.0, 1.0), mx2));

    rot(vv, -1.0+time*0.2315);

    return fbm(p + 1.4*vv, mx3);
}

float height(float2 p) {
    float a = 0.005*time;
    p += 5.0*float2(cos(a), sin(sqrt(0.5)*a));
    p *= 2.0;
    p += 13.0;
    float h = warp(p);
    float rs = 3.0;
    return 0.4*tanh(rs*h)/rs;
}

float3 normal(float2 p) {
    float2 eps = -float2(2.0/resolution.y, 0.0);

    float3 n;
    n.x = height(p + eps.xy) - height(p - eps.xy);
    n.y = 2.0*eps.x;
    n.z = height(p + eps.yx) - height(p - eps.yx);

    return normalize(n);
}

float3 postProcess(float3 col, float2 q) {
    col = pow(saturate(col), (float3)0.75);
    col = col*0.6+0.4*col*col*(3.0-2.0*col);  // contrast
    col = lerp(col, (float3)dot(col, (float3)0.33), -0.4);  // saturation
    col *= 0.5+0.5*pow(19.0*q.x*q.y*(1.0-q.x)*(1.0-q.y), 0.7);  // vignetting
    return col;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 q = fragCoord/resolution.xy;
    float2 p = -1.0 + 2.0 * q;
    p.x *= resolution.x/resolution.y;

    const float3 lp1 = float3(0.8, -0.75, 0.8);
    const float3 lp2 = float3(0.0, -1.5, -1.0);

    float h = height(p);
    float3 pp = float3(p.x, h, p.y);
    float3 ld1 = normalize(lp1 - pp);
    float3 ld2 = normalize(lp2 - pp);

    float3 n = normal(p);
    float diff1 = max(dot(ld1, n), 0.0);
    float diff2 = max(dot(ld2, n), 0.0);

    const float3 baseCol1 = float3(0.6, 0.8, 1.0);
    const float3 baseCol2 = sqrt(baseCol1.zyx);

    float3 col = (float3)0.0;
    col += baseCol1*pow(diff1, 16.0);
    col += 0.1*baseCol1*pow(diff1, 4.0);
    col += 0.15*baseCol2*pow(diff2, 8.0);
    col += 0.015*baseCol2*pow(diff2, 2.0);

    col = saturate(col);
    col = lerp(0.05*baseCol1, col, 1.0 - (1.0 - 0.5*diff1)*exp(-2.0*smoothstep(-0.1, 0.05, h)));

    col = postProcess(col, q);

    // Darken/desaturate
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, (float3)lum, desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
