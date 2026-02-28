// Dune (Sand Worm) — dean_the_coder
// https://www.shadertoy.com/view/7stGRj
// License: CC BY-NC-SA 3.0

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

#define R float3(resolution, 1.0)
#define NM normalize
#define Z0 min(time, 0.0)
#define sat(x) saturate(x)
#define S01(a) smoothstep(0.0, 1.0, a)
#define S(a, b, c) smoothstep(a, b, c)

float glsl_mod(float x, float y) { return x - y * floor(x / y); }

static float t;

struct Hit {
    float d;
    int id;
    float3 uv;
};

Hit makeHit(float d, int id, float3 uv) {
    Hit result; result.d = d; result.id = id; result.uv = uv;
    return result;
}

#define minH(a, b, c) { float h_ = a; if (h_ < h.d) h = makeHit(h_, b, c); }

float n31(float3 p) {
    const float3 s = float3(7, 157, 113);
    float3 ip = floor(p);
    p = frac(p);
    p = p * p * (3.0 - 2.0 * p);
    float4 h = float4(0, s.yz, s.y + s.z) + dot(ip, s);
    h = lerp(frac(sin(h) * 43758.545), frac(sin(h + s.x) * 43758.545), p.x);
    h.xy = lerp(h.xz, h.yw, p.y);
    return lerp(h.x, h.y, p.z);
}

float n21(float2 p) { return n31(float3(p, 1)); }

float smin(float a, float b, float k) {
    float h = sat(0.5 + 0.5 * (b - a) / k);
    return lerp(b, a, h) - k * h * (1.0 - h);
}

float box(float3 p, float3 b) { return length(max(abs(p) - b, (float3)0)); }

float cap(float3 p, float2 h) {
    p.y -= clamp(p.y, 0.0, h.x);
    return length(p) - h.y;
}

Hit map(float3 p) {
    float d, e, g, lp, r, rz,
          f = S(0.0, 5.0, t),
          n = n31(p * 4.0);
    d = n21(p.xz * 0.1) * 3.0 + p.y + 2.5;
    g = smin(d, length(p - float3(0.2, -8.6, 12.6)) - 6.0 + 0.01 * (0.5 + 0.5 * sin(p.y * 22.0)), 1.0);
    p += float3(0.5 + sin(t * 0.6) * 0.2 + 0.6 * sin(p.z * 0.4 - 0.66),
                1.0 - cos(p.z * 0.3 - 0.3 - f * lerp(0.8, 1.0, S01(sin(t * 1.4) * 0.5 + 0.5))) * 1.8,
                S(28.0, 30.0, t) * 2.5 - lerp(6.0, 2.8, f));
    r = 0.8 + smin(p.z * 0.18, 2.0, 0.5) + abs(sin(p.z * 2.0) * S01(p.z) * 0.05);
    r *= S(-5.3 + 2.75 * cos(t * 0.8) * f, 1.4, p.z);
    lp = length(p.xy);
    f = abs(lp - r - 0.05) - 0.03;
    r *= S(2.5, 0.35 + sin(t) * 0.1, p.z);
    d = max(abs(lp - r) - 0.02, 0.4 - p.z);
    p.xy = float2(frac(atan2(p.y, p.x) * 0.477) - 0.5, lp);
    p.y -= r;
    Hit h = makeHit(min(d, box(p, float3(0.2 + p.z * 0.77, 0.02, 0.4))), 2, p);
    p.y += 0.13;
    float2 v2 = float2(0.1, sat(0.07 * p.y));
    p.z -= 0.4;
    rz = glsl_mod(p.z, 0.3) - 0.15;
    e = max(min(cap(float3(glsl_mod(p.x, 0.08333) - 0.04167, p.y, rz), v2),
                cap(float3(glsl_mod(p.x + 0.04167, 0.08333) - 0.04167, p.y, rz - 0.15), v2)),
            -0.05 - p.z * 0.2);
    d = abs(p.x) - p.z * 0.5 - 0.5;
    minH(max(e, d), 4, p);
    f = max(f, d - 0.05);
    minH(f, 3, p);
    g = smin(g, h.d, 0.4 + 0.4 * n * S(1.0, 0.0, abs(g - f)));
    minH(g, 1, p);
    return h;
}

float3 N(float3 p, float nt) {
    float h = nt * 0.4;
    float3 n = (float3)0;
    for (int i = 0; i < 4; i++) {
        float3 e = 0.005773 * (2.0 * float3(((i + 3) >> 1) & 1, (i >> 1) & 1, i & 1) - 1.0);
        n += e * map(p + e * h).d;
    }
    return NM(n);
}

float shadow(float3 p, float3 lp) {
    float d, s = 1.0, st = 0.1, mxt = length(p - lp);
    float3 ld = NM(lp - p);
    for (float i = Z0; i < 40.0; i++) {
        d = map(st * ld + p).d;
        s = min(s, 15.0 * d / st);
        st += max(0.1, d);
        if (mxt - st < 0.5 || s < 0.001) break;
    }
    return S01(s);
}

float ao(float3 p, float3 n, float h) { return map(h * n + p).d / h; }

float fog(float3 v) { return exp(dot(v, v) * -0.001); }

float3 lights(float3 p, float3 rd, float d, Hit h) {
    float3 ld = NM(float3(6, 3, -10) - p);
    float3 n = N(p, d);
    float3 c;
    float spe = 1.0;
    if (h.id == 3) {
        c = float3(0.4, 0.35, 0.3);
        n.y += n31(h.uv * 10.0);
        n = NM(n);
    }
    else if (h.id == 2) c = lerp(float3(0.16, 0.08, 0.07), (float3)0.6, pow(n31(h.uv * 10.0), 3.0));
    else if (h.id == 4) c = float3(0.6, 1, 4);
    else {
        spe = 0.1;
        c = (float3)0.6;
        n.x += sin((p.x + p.z * n.z) * 8.0) * 0.1;
        n = NM(n);
    }
    float ao_val = lerp(ao(p, n, 0.2), ao(p, n, 2.0), 0.7);
    float diff = sat(0.1 + 0.9 * dot(ld, n));
    float shad = 0.1 + 0.9 * shadow(p, float3(6, 3, -10));
    float ao_fac = 0.3 + 0.7 * ao_val;
    float rim = sat(0.1 + 0.9 * dot(ld * float3(-1, 0, -1), n)) * 0.3;
    float spec = pow(sat(dot(rd, reflect(ld, n))), 10.0) * spe;
    float3 lightCol = float3(1.85, 0.5, 0.08);
    float3 lit = (diff * shad * ao_fac + (rim + spec) * ao_val) * c * lightCol;
    return lerp(lit, lightCol, S(0.7, 1.0, 1.0 + dot(rd, n)) * 0.1);
}

float4 march(inout float3 p, float3 rd, float s, float mx) {
    float i, d = 0.01;
    Hit h;
    for (i = Z0; i < s; i++) {
        h = map(p);
        if (abs(h.d) < 0.0015) break;
        d += h.d;
        if (d > mx) return (float4)0;
        p += h.d * rd;
    }
    return float4(lights(p, rd, d, h), h.id);
}

float3 scene(float3 rd) {
    t = glsl_mod(time, 30.0);
    float3 c;
    float3 p = (float3)0;
    float4 col = march(p, rd, 180.0, 64.0);
    float f = 1.0, x = n31(rd + float3(-t * 2.0, -t * 0.4, t));
    if (col.w == 0.0) c = lerp(float3(0.5145, 0.147, 0.0315), float3(0.22, 0.06, 0.01), sat(rd.y * 3.0));
    else {
        c = col.rgb;
        f = fog(p * (0.7 + 0.3 * x));
    }
    f *= 1.0 - x * x * x * 0.4;
    return lerp(float3(0.49, 0.14, 0.03), c, sat(f));
}

float4 PSMain(PSInput input) : SV_Target {
    // Y-flip: scene has sky above, desert below
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);
    float2 fc = fragCoord;
    float2 uv = (fc - 0.5 * R.xy) / R.y;
    float2 q = fc.xy / R.xy;
    float3 r = NM(cross(float3(0, 1, 0), float3(0, 0, 1)));
    float3 col = scene(NM(float3(0, 0, 1) + r * uv.x + cross(float3(0, 0, 1), r) * uv.y));
    col *= 0.5 + 0.5 * pow(16.0 * q.x * q.y * (1.0 - q.x) * (1.0 - q.y), 0.4);

    // Gamma + fade-in/out (from rgba macro)
    float3 color = pow(max((float3)0, col), (float3)0.45) * sat(t) * sat(30.0 - t);

    // Post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float alpha = max(color.r, max(color.g, color.b));
    return float4(color * alpha, alpha);
}
