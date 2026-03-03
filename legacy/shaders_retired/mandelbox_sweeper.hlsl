// Mandelbox Sweeper - Converted from Shadertoy (3lyXDm)
// Original by evvvvil - Live coded on Twitch
// https://www.shadertoy.com/view/3lyXDm

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

// Globals
static float2 z, e = float2(0.000035, -0.000035);
static float t, tt, b, g, g2, bb;
static float3 bp, pp, po, nor, al, ld;

float glmod(float x, float y) { return x - y * floor(x / y); }

float bo(float3 p, float3 r) { p = abs(p) - r; return max(max(p.x, p.y), p.z); }

float2x2 r2(float r) { float c = cos(r), s = sin(r); return float2x2(c, -s, s, c); }

float2 fb(float3 p, float m)
{
    p.y += bb * 0.05;
    float2 h, t = float2(bo(p, float3(5, 1, 3)), 3);
    t.x = max(t.x, -(length(p) - 2.5));
    t.x = max(abs(t.x) - 0.2, (p.y - 0.4));
    h = float2(bo(p, float3(5, 1, 3)), 6);
    h.x = max(h.x, -(length(p) - 2.5));
    h.x = max(abs(h.x) - 0.1, (p.y - 0.5));
    t = t.x < h.x ? t : h;
    h = float2(bo(p + float3(0, 0.4, 0), float3(5.4, 0.4, 3.4)), m);
    h.x = max(h.x, -(length(p) - 2.5));
    t = t.x < h.x ? t : h;
    h = float2(length(p) - 2.0, m);
    t = t.x < h.x ? t : h;
    t.x *= 0.7;
    return t;
}

float2 mp(float3 p)
{
    pp = bp = p;
    p.yz = mul(r2(sin(pp.x * 0.3 - tt * 0.5) * 0.4), p.yz);
    bp.yz = p.yz;
    p.yz = mul(r2(1.57), p.yz);
    b = sin(pp.x * 0.2 + tt);
    bb = cos(pp.x * 0.2 + tt);
    p.x = glmod(p.x - tt * 2.0, 10.0) - 5.0;
    float4 np = float4(p * 0.4, 0.4);
    for (int i = 0; i < 4; i++) {
        np.xyz = abs(np.xyz) - float3(1, 1.2, 0);
        np.xyz = 2.0 * clamp(np.xyz, (float3)0, float3(2, 0, 4.3 + bb)) - np.xyz;
        np = np * (1.3) / clamp(dot(np.xyz, np.xyz), 0.1, 0.92);
    }
    float2 h, t = fb(abs(np.xyz) - float3(2, 0, 0), 5.0);
    t.x /= np.w;
    t.x = max(t.x, bo(p, float3(5, 5, 10)));
    np *= 0.5;
    np.yz = mul(r2(0.785), np.yz);
    np.yz += 2.5;
    h = fb(abs(np.xyz) - float3(0, 4.5, 0), 7.0);
    h.x = max(h.x, -bo(p, float3(20, 5, 5)));
    h.x /= np.w * 1.5;
    t = t.x < h.x ? t : h;
    h = float2(bo(np.xyz, float3(0.0, b * 20.0, 0.0)), 6);
    h.x /= np.w * 1.5;
    g2 += 0.1 / (0.1 * h.x * h.x * (1000.0 - b * 998.0));
    t = t.x < h.x ? t : h;
    h = float2(0.6 * bp.y + sin(p.y * 5.0) * 0.03, 6);
    t = t.x < h.x ? t : h;
    h = float2(length(cos(bp.xyz * 0.6 + float3(tt, tt, 0))) + 0.003, 6);
    g += 0.1 / (0.1 * h.x * h.x * 4000.0);
    t = t.x < h.x ? t : h;
    return t;
}

float2 tr(float3 ro, float3 rd)
{
    float2 h, t = (float2)0.1;
    for (int i = 0; i < 128; i++) {
        h = mp(ro + rd * t.x);
        if (h.x < 0.0001 || t.x > 40.0) break;
        t.x += h.x; t.y = h.y;
    }
    if (t.x > 40.0) t.y = 0.0;
    return t;
}

#define ao(d) clamp(mp(po+nor*d).x/d,0.,1.)
#define ss(d) smoothstep(0.,1.,mp(po+ld*d).x/d)

float4 PSMain(PSInput input) : SV_Target
{
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);
    g = 0; g2 = 0;
    float2 uv = (fragCoord.xy / resolution.xy - 0.5) / float2(resolution.y / resolution.x, 1);
    tt = glmod(time, 62.8318);

    float3 ro = lerp((float3)1, float3(-0.5, 1, -1), ceil(sin(tt * 0.5)))
              * float3(10, 2.8 + 0.75 * smoothstep(-1.5, 1.5, 1.5 * cos(tt + 0.2)), cos(tt * 0.3) * 3.1);
    float3 cw = normalize((float3)0 - ro);
    float3 cu = normalize(cross(cw, normalize(float3(0, 1, 0))));
    float3 cv = normalize(cross(cu, cw));
    float3 rd = mul(normalize(float3(uv, 0.5)), float3x3(cu, cv, cw));
    float3 co, fo;

    ld = normalize(float3(0.2, 0.4, -0.3));
    co = fo = float3(0.1, 0.2, 0.3) - length(uv) * 0.1 - rd.y * 0.2;
    z = tr(ro, rd); t = z.x;

    if (z.y > 0.0) {
        po = ro + rd * t;
        nor = normalize(e.xyy * mp(po + e.xyy).x + e.yyx * mp(po + e.yyx).x
                      + e.yxy * mp(po + e.yxy).x + e.xxx * mp(po + e.xxx).x);
        al = lerp(float3(0.1, 0.2, 0.4), float3(0.1, 0.4, 0.7), 0.5 + 0.5 * sin(bp.y * 7.0));
        if (z.y < 5.0) al = (float3)0;
        if (z.y > 5.0) al = (float3)1;
        if (z.y > 6.0) al = lerp(float3(1, 0.5, 0), float3(0.9, 0.3, 0.1), 0.5 + 0.5 * sin(bp.y * 7.0));
        float dif = max(0.0, dot(nor, ld));
        float fr = pow(1.0 + dot(nor, rd), 4.0);
        float sp = pow(max(dot(reflect(-ld, nor), -rd), 0.0), 40.0);
        co = lerp(sp + lerp((float3)0.8, (float3)1, abs(rd)) * al * (ao(0.1) * ao(0.2) + 0.2) * (dif + ss(2.0)), fo, min(fr, 0.2));
        co = lerp(fo, co, exp(-0.0003 * t * t * t));
    }

    float3 color = pow(co + g * 0.2 + g2 * lerp(float3(1, 0.5, 0), float3(0.9, 0.3, 0.1), 0.5 + 0.5 * sin(bp.y * 3.0)), (float3)0.65);

    // Darken/desaturate post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(color.r, max(color.g, color.b));
    return float4(color * a, a);
}
