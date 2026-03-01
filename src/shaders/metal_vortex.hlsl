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

#define SURF_DIST 0.001
#define MAX_STEPS 256
#define MAX_STEPS_REF 32
#define MAX_STEPS_SHAD 16

static int mat_id;
static float3 ref_vec = float3(0.0, 0.0, 0.0);

float2 rotate2d(float2 a, float d) {
    float s = sin(d);
    float c = cos(d);
    return float2(
        a.x * c - a.y * s,
        a.x * s + a.y * c);
}

float noise(float3 p) {
    return frac(sin(dot(p, float3(41932.238945, 12398.5387294, 18924.178293))) * 123890.12893);
}

float sdVerticalCapsule(float3 p, float h, float r) {
    p.y -= clamp(p.y, 0.0, h);
    return length(p) - r;
}

float smin(float d1, float d2, float k) {
    float h = clamp(0.5 + 0.5 * (d2 - d1) / k, 0.0, 1.0);
    return lerp(d2, d1, h) - k * h * (1.0 - h);
}

float sdSphere(float3 p, float r) {
    return length(p) - r;
}

float sdBox(float3 p, float3 b) {
    float3 d = abs(p) - b;
    return max(max(d.x, d.y), d.z);
}

float sdTriPrism(float3 p, float2 h) {
    float3 q = abs(p);
    return max(q.z - h.y, max(q.x * 0.866025 + p.y * 0.5, -p.y) - h.x * 0.5);
}

float sdOctahedron(float3 p, float s) {
    p = abs(p);
    return (p.x + p.y + p.z - s) * 0.57735027;
}

float3 opTwist(float3 p, float k) {
    float c = cos(k * p.y);
    float s = sin(k * p.y);
    float2x2 m = float2x2(c, -s, s, c);
    float2 twisted = mul(m, p.xz);
    return float3(twisted, p.y);
}

float sdHexPrism(float3 p, float2 h) {
    static const float3 k = float3(-0.8660254, 0.5, 0.57735);
    p = abs(p);
    p.xy -= 2.0 * min(dot(k.xy, p.xy), 0.0) * k.xy;
    float2 d = float2(
        length(p.xy - float2(clamp(p.x, -k.z * h.x, k.z * h.x), h.x)) * sign(p.y - h.x),
        p.z - h.y);
    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0));
}

float sdHexScrew(float3 p, float2 h, float t) {
    static const float3 k = float3(-0.8660254, 0.5, 0.57735);
    p = abs(opTwist(p, t));
    p.xy -= 2.0 * min(dot(k.xy, p.xy), 0.0) * k.xy;
    float2 d = float2(
        length(p.xy - float2(clamp(p.x, -k.z * h.x, k.z * h.x), h.x)) * sign(p.y - h.x),
        p.z - h.y);
    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0));
}

float cog(float3 p, float3 tp) {
    float d = 1e10;

    float3 bp = p;
    bp.xy = rotate2d(bp.xy, sin(-time - tp.z * 0.05 - p.x * 0.01) * 10.0);

    float base_d = sdHexPrism(bp, float2(2.0, 0.2));
    d = min(d, base_d);

    bp.zy = rotate2d(bp.zy, 1.5);
    float base2 = sdHexScrew(bp, float2(0.95, 1.0), 2.0);
    d = max(d, -base2);

    return d;
}

float map(float3 p) {
    float3 tp = p;
    p.xy = rotate2d(p.xy, p.z * 0.02);
    float3 cell = float3(5.0, 40.5, 21.5);
    p = fmod(p, cell) - cell * 0.5;

    float3 cp = p;

    float s = sin(time + tp.z * 0.05) * 10.0;
    cp.z += s;

    float d = 1e10;

    float cog_d = cog(cp, tp);
    d = min(d, cog_d);

    p.zy = rotate2d(p.zy, 1.57);
    float screw = sdHexScrew(p, float2(0.85, 11.0), 2.0);
    d = min(d, screw);

    if (d == cog_d) {
        mat_id = 1;
    } else if (d == screw) {
        mat_id = 3;
    }
    return d;
}

float3 calcNormal(float3 p) {
    float2 e = float2(0.01, 0.0);
    return normalize(float3(
        map(p + e.xyy) - map(p - e.xyy),
        map(p + e.yxy) - map(p - e.yxy),
        map(p + e.yyx) - map(p - e.yyx)));
}

float4 trace(float3 ro, float3 rd) {
    float t = 0.0;
    float3 col = float3(0.9, 0.9, 0.9);
    float k = 0.0;

    for (int i = 0; i < MAX_STEPS; ++i) {
        k = map(ro + rd * t);
        t += k * 0.5;
        if (abs(k) < SURF_DIST) {
            if (mat_id == 1)
                col = float3(0.5, 0.5, 0.5);
            else if (mat_id == 3)
                col = float3(0.8, 0.8, 0.8);
            else if (mat_id == 2)
                col = float3(1.0, 1.0, 1.0);
            break;
        }
    }

    return float4(t, col);
}

float4 traceRef(float3 ro, float3 rd, float start_d, float end_d) {
    float t = 0.0;
    float3 col = float3(0.9, 0.9, 0.9);
    float k = 0.0;

    for (int i = 0; i < MAX_STEPS_REF; ++i) {
        k = map(ro + rd * t);
        t += k * 0.25;
        if (k < SURF_DIST) {
            float light = dot(calcNormal(ro + rd * t), normalize(float3(1.0, 3.0, -5.0))) * 2.0;
            if (mat_id == 1)
                col = float3(0.5, 0.5, 0.5);
            else if (mat_id == 3)
                col = float3(0.9, 0.9, 0.9);
            break;
        }
    }
    return float4(t, col);
}

float calculateAO(float3 p, float3 n) {
    float r = 0.0;
    float w = 1.0;
    for (float i = 1.0; i <= 5.0; i++) {
        float d0 = i * 0.2;
        r += w * (d0 - map(p + n * d0));
        w *= 0.5;
    }
    return 1.0 - clamp(r, 0.0, 1.0);
}

float softShadow(float3 ro, float3 rd, float start_d, float end_d, float k) {
    float shade = 1.0;
    float d = start_d;

    for (int i = 0; i < MAX_STEPS_SHAD; i++) {
        float h = map(ro + rd * d);
        shade = min(shade, k * h / d);
        d += min(h, d / 2.0);
        if (h < SURF_DIST || d > end_d) break;
    }

    return min(max(shade, 0.0) + 0.3, 1.0);
}

float3 lighting(float3 sp, float3 camPos, int reflectionPass) {
    float3 col = float3(0.0, 0.0, 0.0);
    float3 n = calcNormal(sp);
    float3 objCol = float3(0.5, 0.5, 0.5);

    float3 lp = float3(sin(time) * 50.0, cos(time) * 50.0, time * 10.0);
    float3 ld = lp - sp;
    float3 lcolor = float3(sin(time * 0.2), cos(time * 0.2), 1.0) / 3.0 + float3(1.0, 1.0, 1.0);

    float len = length(ld);
    ld /= len;
    float lightAtten = clamp(0.5 * len * len, 0.0, 1.0);

    ref_vec = reflect(-ld, n);

    float shadowcol = 1.0;
    if (reflectionPass == 0)
        shadowcol = softShadow(sp, ld, 0.005 * 2.0, len, 32.0);

    float ao = 0.5 + 0.5 * calculateAO(sp, n);
    float ambient = 0.05;
    float specPow = 8.0;
    float diff = max(0.0, dot(n, ld));
    float spec = max(0.0, dot(ref_vec, normalize(camPos - sp)));
    spec = pow(spec, specPow);

    col += (objCol * (diff + ambient) + spec * 0.5) * lcolor * lightAtten * shadowcol * ao;

    return col;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float depth = 0.0;
    float3 tot = float3(0.0, 0.0, 0.0);

    float2 uv = (fragCoord - 0.5 * resolution) / resolution.y;

    float t = time * 10.0;

    float3 cam = float3(0.0, 0.0, -10.0 + t);
    float3 dir = normalize(float3(uv, 1.0));

    float4 d = trace(cam, dir);
    float3 p = cam + dir * d.x;
    float3 n = calcNormal(p);

    float4 r = traceRef(p, reflect(dir, n), 0.05, 32.0);
    float3 l = lighting(p, cam, 0);

    depth = r.x;
    float3 rsp = p + ref_vec * r.x;

    float3 col = (lighting(rsp, p, 1) * 0.05 + l) / clamp(d.x * 0.015, 1.0, 10.0);
    // vignette
    col *= 1.0 - dot(uv, uv) * 0.75;

    tot = col;

    // Post-processing
    float lum = dot(tot, float3(0.299, 0.587, 0.114));
    tot = lerp(tot, float3(lum, lum, lum), desaturate);
    tot = tot * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float a = max(tot.r, max(tot.g, tot.b));
    return float4(tot * a, a);
}
