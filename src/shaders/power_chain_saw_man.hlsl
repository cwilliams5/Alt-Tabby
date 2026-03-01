// Power Chain Saw Man — after Pudi (CC BY-NC-SA 3.0)
// Converted from Shadertoy GLSL to HLSL

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

// ============= Constants =============

static const float3 BLOOD_COLOR = float3(179, 236, 15) / 255.0;
static const float3 BACKGROUND_COLOR = float3(179, 236, 15) / 255.0;
static const float3 BRIGHT_RED = float3(254, 81, 51) / 255.0;
static const float3 TEETH_COLOR = float3(224, 195, 226) / 255.0 * 1.2;
static const float3 BORDER_COLOR = (float3)0.01;
static const float3 SKIN_COLOR = float3(158, 0, 24) / 255.0;
static const float3 HIGHLIGHT_COLOR = float3(240, 48, 18) / 255.0 * 1.2;
static const float3 HAIR_COLOR = float3(68, 0, 50) / 255.0;
static const float3 HAIR_SHADOW_COLOR = float3(28, 0, 62) / 255.0;

static const float PI = acos(-1.0);

#define sat(x) saturate(x)

// ============= Utility Functions =============

// GLSL mat2(c,-s,s,c) is column-major; HLSL float2x2 is row-major.
// For equivalent mul(M,v): transpose the constructor args.
float2x2 rot(float a) {
    float c = cos(a), s = sin(a);
    return float2x2(c, s, -s, c);
}

// GLSL mat2(0.707,-0.707,0.707,0.707) → transposed for HLSL row-major
static const float2x2 rot45_val = float2x2(0.707, 0.707, -0.707, 0.707);

float pow2(float x) {
    return x * x;
}

float dot2(float2 v) {
    return dot(v, v);
}

float cross2(float2 a, float2 b) {
    return a.x * b.y - a.y * b.x;
}

float smooth_hill(float x, float off, float width, float gap) {
    x -= off;
    float start = width, end_val = width + max(0.0, gap);
    return smoothstep(-end_val, -start, x) - smoothstep(start, end_val, x);
}

float remap(float val, float start1, float stop1, float start2, float stop2) {
    return start2 + (val - start1) / (stop1 - start1) * (stop2 - start2);
}

float remap01(float val, float start, float stop) {
    return start + val * (stop - start);
}

float3 erot(float3 p, float3 ax, float ro) {
    return lerp(dot(ax, p) * ax, p, cos(ro)) + sin(ro) * cross(ax, p);
}

float hash11(float p) {
    p = frac(p * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return frac(p);
}

float hash21(float2 p) {
    float3 p3 = frac(p.xyx * 0.1031);
    p3 += dot(p3, p3.yzx + 3.33);
    return frac((p3.x + p3.y) * p3.z);
}

float noise(float2 x) {
    float2 p = floor(x);
    float2 f = frac(x);
    f = f * f * (3.0 - 2.0 * f);

    float a = hash21(p + float2(0, 0));
    float b = hash21(p + float2(1, 0));
    float c = hash21(p + float2(0, 1));
    float d = hash21(p + float2(1, 1));
    return lerp(lerp(a, b, f.x), lerp(c, d, f.x), f.y);
}

float voronoi(float2 uv) {
    float d = 1e9;
    float2 id = floor(uv);
    uv = frac(uv);

    for (float i = -1.0; i <= 1.0; i++) {
        for (float j = -1.0; j <= 1.0; j++) {
            float2 nbor = float2(i, j);
            d = min(d, length(uv - noise(id + nbor) - nbor));
        }
    }
    return d;
}

float2 clog(float2 z) {
    float r = length(z);
    return float2(log(r), atan2(z.y, z.x));
}

float smin(float a, float b, float k) {
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * (1.0 / 4.0);
}

float smax(float a, float b, float k) {
    float h = max(k - abs(a - b), 0.0);
    return max(a, b) + h * h * k * (1.0 / 4.0);
}

// ============= SDF Primitives =============

float sd_circle(float2 p, float r) {
    return length(p) - r;
}

float sd_box(float2 p, float2 h) {
    p = abs(p) - h;
    return length(max(p, 0.0)) + min(0.0, max(p.x, p.y));
}

float sd_hook(float2 p, float r, float a, float s) {
    float base_d = max(sd_circle(p, r), -p.x * sign(s));
    p.x -= r;
    p = mul(rot(a), p);
    p.x += r;
    float crop = sd_circle(p, r);
    return max(base_d, -crop);
}

float sd_line(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float k = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return distance(p, lerp(a, b, k));
}

float sd_line_y(float2 p, float h, float r) {
    p.y -= clamp(p.y, 0.0, h);
    return length(p) - r;
}

float op_rem_lim(float p, float s, float l) {
    return p - s * clamp(round(p / s), -l, l);
}

float sd_trig_isosceles(float2 p, float2 q) {
    p.x = abs(p.x);
    float2 a = p - q * clamp(dot(p, q) / dot(q, q), 0.0, 1.0);
    float2 b = p - q * float2(clamp(p.x / q.x, 0.0, 1.0), 1.0);
    float s = -sign(q.y);
    float2 d = min(float2(dot(a, a), s * (p.x * q.y - p.y * q.x)),
                   float2(dot(b, b), s * (p.y - q.y)));
    return -sqrt(d.x) * sign(d.y);
}

float sd_uneven_capsule(float2 p, float2 pa, float2 pb, float ra, float rb) {
    p -= pa;
    pb -= pa;
    float h = dot(pb, pb);
    float2 q = float2(dot(p, float2(pb.y, -pb.x)), dot(p, pb)) / h;

    q.x = abs(q.x);
    float b = ra - rb;
    float2 c = float2(sqrt(h - b * b), b);

    float k = cross2(c, q);
    float m = dot(c, q), n = dot(q, q);

    if (k < 0.0) {
        return sqrt(h * n) - ra;
    } else if (k > c.x) {
        return sqrt(h * (n + 1.0 - 2.0 * q.y)) - rb;
    }
    return m - ra;
}

float sd_egg(float2 p, float ra, float rb) {
    const float k = sqrt(3.0);
    p.x = abs(p.x);
    float r = ra - rb;
    return ((p.y < 0.0)             ? length(float2(p.x, p.y)) - r
            : (k * (p.x + r) < p.y) ? length(float2(p.x, p.y - k * r))
                                     : length(float2(p.x + r, p.y)) - 2.0 * r) -
           rb;
}

// ============= Bezier Functions =============

float3 sd_bezier_base(float2 pos, float2 A, float2 B, float2 C) {
    float2 a = B - A;
    float2 b = A - 2.0 * B + C;
    float2 c = a * 2.0;
    float2 d = A - pos;

    float kk = 1.0 / dot(b, b);
    float kx = kk * dot(a, b);
    float ky = kk * (2.0 * dot(a, a) + dot(d, b)) / 3.0;
    float kz = kk * dot(d, a);
    float t = 0.0;

    float res = 0.0;
    float sgn = 1.0;

    float p = ky - kx * kx;
    float p3 = p * p * p;
    float q = kx * (2.0 * kx * kx - 3.0 * ky) + kz;
    float h = q * q + 4.0 * p3;

    if (h >= 0.0) {
        h = sqrt(h);
        float2 x = (float2(h, -h) - q) / 2.0;
        float2 uv_bz = sign(x) * pow(abs(x), (float2)(1.0 / 3.0));
        t = clamp(uv_bz.x + uv_bz.y - kx, 0.0, 1.0);
        float2 qq = d + (c + b * t) * t;
        res = dot2(qq);
        sgn = cross2(c + 2.0 * b * t, qq);
    } else {
        float z = sqrt(-p);
        float v = acos(q / (p * z * 2.0)) / 3.0;
        float m = cos(v);
        float n = sin(v) * 1.732050808;
        float2 tt = clamp(float2(m + m, -n - m) * z - kx, 0.0, 1.0);
        float2 qx = d + (c + b * tt.x) * tt.x;
        float dx = dot2(qx), sx = cross2(c + 2.0 * b * tt.x, qx);
        float2 qy = d + (c + b * tt.y) * tt.y;
        float dy = dot2(qy), sy = cross2(c + 2.0 * b * tt.y, qy);
        if (dx < dy) {
            res = dx;
            sgn = sx;
        } else {
            res = dy;
            sgn = sy;
        }
        t = res;
    }

    return float3(res, sgn, t);
}

float2 sd_bezier(float2 pos, float2 A, float2 B, float2 C) {
    float3 bz = sd_bezier_base(pos, A, B, C);
    return float2(sqrt(bz.x) * sign(bz.y), bz.z);
}

float sd_bezier_convex(float2 pos, float2 A, float2 B, float2 C) {
    if (cross2(C - A, B - A) < 0.0) {
        float2 tmp = A;
        A = C;
        C = tmp;
    }
    float sa = cross2(A, pos);
    float sc = cross2(C - A, pos - A);
    float s0 = cross2(-C, pos - C);
    float o = cross2(C - A, -A);

    float ts = (sa < 0.0 && sc < 0.0 && s0 < 0.0) ? -1.0 : 1.0;
    float ts2 = (sa > 0.0 && sc > 0.0 && s0 > 0.0) ? -1.0 : 1.0;
    ts = o > 0.0 ? ts2 : ts;

    float3 bz = sd_bezier_base(pos, A, B, C);
    return sqrt(bz.x) * sign(sc < 0.0 ? 1.0 : -bz.y) * ts;
}

// GLSL mat2(normal, tangent) + pos*mm = (dot(pos,normal), dot(pos,tangent))
float4 sd_bezier_rep(float2 pos, float2 A, float2 B, float2 C) {
    float2 bz = sd_bezier(pos, A, B, C);
    float t = bz.y;
    float2 tangent = normalize((2.0 - 2.0 * t) * (B - A) + 2.0 * t * (C - B));
    float2 normal = float2(tangent.y, -tangent.x);
    pos = lerp(lerp(A, B, t), lerp(B, C, t), t) - pos;
    return float4(bz.x, dot(pos, normal), dot(pos, tangent), t);
}

// ============= Alpha Blending & Rendering =============

float4 alpha_blending(float4 d, float4 s) {
    float4 res = (float4)0;
    res.a = lerp(1.0, d.a, s.a);
    if (res.a == 0.0) {
        res.rgb = (float3)0;
    } else {
        res.rgb = lerp(d.rgb * d.a, s.rgb, s.a) / res.a;
    }
    return res;
}

void alpha_blend_inplace(inout float4 d, float4 s) {
    d = alpha_blending(d, s);
}

float AAstep2(float thre, float val) {
    return smoothstep(-0.5, 0.5, (val - thre) / min(0.03, fwidth(val - thre)));
}

float AAstep(float val) {
    return AAstep2(val, 0.0);
}

float4 render_f4(float d, float4 color) {
    return float4(color.rgb, color.a * AAstep(d));
}

float4 render_f3(float d, float3 color) {
    return render_f4(d, float4(color, 1.0));
}

float4 render_stroked_masked(float d,
                             float4 color,
                             float stroke,
                             float stroke_mask) {
    float4 stroke_layer = float4((float3)0.01, AAstep(d));
    float4 color_layer = float4(color.rgb, AAstep(d + stroke));
    return float4(lerp(lerp(stroke_layer.rgb, color_layer.rgb, AAstep(stroke_mask)),
                       color_layer.rgb, color_layer.a),
                  stroke_layer.a * color.a);
}

float4 render_stroked_f4(float d, float4 color, float stroke) {
    return render_stroked_masked(d, color, stroke, 1.0);
}

float4 render_stroked_f3(float d, float3 color, float stroke) {
    return render_stroked_f4(d, float4(color, 1.0), stroke);
}

// Macros — rely on 'final_color' being in scope as inout parameter.
// HLSL doesn't support function overloading in macros, so we dispatch
// to typed helpers via _Generic-style suffixed names. We use a trick:
// float4 has .a, float3 does not — but preprocessor can't check types.
// Instead we provide explicit typed macros.
#define LayerFlat4(d, color) alpha_blend_inplace(final_color, render_f4(d, color))
#define LayerFlat3(d, color) alpha_blend_inplace(final_color, render_f3(d, color))
#define LayerStroked4(d, color, stroke) \
    alpha_blend_inplace(final_color, render_stroked_f4(d, color, stroke))
#define LayerStroked3(d, color, stroke) \
    alpha_blend_inplace(final_color, render_stroked_f3(d, color, stroke))
#define LayerStrokedMask(d, color, stroke, mask) \
    alpha_blend_inplace(final_color, render_stroked_masked(d, color, stroke, mask))

void draw_highlight(inout float4 final_color, float highlight) {
    LayerFlat3(highlight, HIGHLIGHT_COLOR);
    float s = 0.15;
    alpha_blend_inplace(final_color, float4(HIGHLIGHT_COLOR,
                                            0.07 * smoothstep(s, 0.0, highlight)));
}

// ============= Params Struct =============

struct ShaderParams {
    float stroke;
    float displacement;
    float stime;
    float shift;
};

// ============= Character Functions =============

float fbm(float2 st, float n) {
    st *= 3.0;

    float s = 0.5;
    float ret = 0.0;
    for (float i = min(0.0, (float)frame); i < n; i++) {
        ret += noise(st) * s;
        st *= 2.5;
        s /= 2.0;
        st = mul(rot45_val, st);
        st.y += time * 0.05;
    }
    return ret;
}

float3 background(float2 uv) {
    uv = mul(rot(-PI / 2.0), uv);
    uv = clog(uv);
    uv.x -= time * 0.1;
    uv /= PI;
    float fa1 = fbm(mul(rot(sin(uv.x) * 0.001), uv), 5.0);
    float fb1 = fbm(uv, 5.0);

    float fa2 = fbm(uv + sin(uv.x * 15.0) + fa1 * 5.0, 4.0);
    float fb2 = fbm(uv + fb1, 5.0);

    float3 col = (float3)0;
    col = lerp(col, BACKGROUND_COLOR, pow(sat(fb2 * 2.4), 1.5));
    col = lerp(col, float3(0.4, 0.3, 0.7), pow(sat(fb2 * 0.7), 1.9));
    col = lerp(col, float3(0.3, 0.6, 0.6), pow(sat(fa2 * 1.5), 20.0) * 0.7);
    col = lerp(col, (float3)0, voronoi(uv * 10.0 + fa1 * 4.0) * 0.8);

    col.yz = mul(rot(-0.16), col.yz);

    return col;
}

float sd_teeth(float2 coords,
               float t,
               float width,
               float spacing,
               float2 sz,
               float2 fang_range,
               float fang_length,
               float x) {
    coords.y -= (t - 0.5) * width;
    coords.y = op_rem_lim(coords.y, spacing, width + spacing / 1.3);
    coords = mul(rot(-1.57), coords);
    fang_range *= spacing / width * 2.0;
    float off =
        fang_length * smoothstep(fang_range.x, fang_range.y, abs(t * 2.0 - 1.0));
    sz += float2(x * off, off);
    coords.y += sz.y;
    float tooth = sd_trig_isosceles(coords, sz);
    return tooth;
}

float make_mouth(inout float4 final_color, float2 uv, ShaderParams p) {
    uv *= 1.15;
    uv.y -= -0.02;
    uv = mul(rot(0.03), uv);
    float poff = remap01(p.shift, -0.05, 0.05);
    float lip_off = remap01(p.shift, 0.0, 0.2);

    float2 a = float2(-0.5, 0.0 + poff);
    float2 b = float2(0.0, -0.70);
    float2 c = float2(0.5, 0.0 + poff);

    float width = 3.8;
    float spacing = 0.26;
    float2 sz = float2(0.25, 0.07);
    float4 curve_lower = sd_bezier_rep(uv, a, b, c);
    float teeth_lower = sd_teeth(curve_lower.yz, curve_lower.w, width, spacing,
                                 sz, float2(2.4, 5.3), 0.031, -8.0);

    float2 la = c - float2(0.04, 0.02);
    float2 lb = float2(0.0, 0.1 + lip_off);
    float2 lc = a - float2(-0.04, 0.02);

    width = 3.7;
    spacing = 0.31;
    sz = float2(0.24, 0.09);
    float4 curve_upper = sd_bezier_rep(uv, la, lb, lc);
    float teeth_upper = sd_teeth(curve_upper.yz, curve_upper.w, width, spacing,
                                 sz, float2(3.0, 4.0), 0.06, -1.0);

    float mouth = max(curve_lower.x, curve_upper.x);
    LayerFlat3(mouth, SKIN_COLOR * 0.35);
    float2 tuv = uv - float2(0.0, -0.48 + poff);
    tuv.x = abs(tuv.x);
    float tongue = sd_line(tuv, float2(0.1, 0.20), float2(-0.3, 0.0)) - 0.19 +
                   p.displacement * 0.002;
    tongue = max(tongue, mouth);
    LayerFlat3(tongue, BRIGHT_RED);
    LayerStroked3(teeth_upper, TEETH_COLOR, p.stroke * 1.3);
    LayerStroked3(teeth_lower, TEETH_COLOR, p.stroke * 1.3);
    float border = smin(abs(curve_lower.x), abs(curve_upper.x), 0.1);
    LayerFlat3(border - 0.004, BORDER_COLOR);

    float2 huv = uv - float2(0.06, -0.38 + poff * 0.4);
    huv = mul(rot(-0.15), huv);
    huv *= float2(0.3, 1.0);
    huv.y -= sqrt(pow2(huv.x) + 0.0001) * 0.5;
    float highlight =
        sd_circle(huv, max(0.015, smoothstep(-0.8, 1.0, p.shift) * 0.02));
    draw_highlight(final_color, highlight);

    return curve_lower.x - p.stroke * 0.5;
}

float2 head_tranform(float2 uv, ShaderParams p, float amp) {
    float2 head_uv = uv;
    head_uv.y -= 0.85;
    head_uv -= float2(0.04, 0.1) * p.shift * amp;
    head_uv = mul(rot(remap01(p.shift, 0.0, 0.05)), head_uv);
    return head_uv;
}

float2 head_tranform_point(float2 pt, ShaderParams par, float amp) {
    float2 head_p = pt;
    head_p += float2(0.04, 0.1) * par.shift * amp;
    head_p = mul(rot(-remap01(par.shift, 0.0, 0.05)), head_p);
    return head_p;
}

float make_head(inout float4 final_color, float2 uv, ShaderParams p) {
    uv -= float2(0.00, 0.8);
    float egg = sd_egg(float2(uv.x, -uv.y), 0.95, 0.3);

    float2 euv = uv - float2(0.84, -0.71);
    float b = dot(euv - 0.35, float2(-4.88, 0.2));
    float ear =
        sd_uneven_capsule(euv, float2(0.04, -0.04), float2(0.17, 0.33), 0.07, 0.20);
    ear = smax(ear, -b, 0.4);
    float head = smin(egg, ear, 0.13);
    LayerStroked3(head, SKIN_COLOR, p.stroke);

    float snail =
        sd_uneven_capsule(euv, float2(0.04, 0.05), float2(0.17, 0.35), 0.10, 0.13);
    snail = smax(snail, -b, 0.87);
    snail = smax(snail, -egg, 0.4);
    snail = smax(snail, -sd_circle(euv - float2(0.01, 0.15), 0.05), 0.54);
    LayerStroked3(snail, float3(0.5, 0.1, 0.1) * 0.4, p.stroke * 0.7);
    float snail_inner = sd_uneven_capsule(
        euv - pow2(uv.x) * 0.00, float2(0.08, 0.15), float2(0.09, 0.3), 0.03, 0.07);
    snail_inner = max(snail_inner, snail);
    LayerStroked3(snail_inner, float3(0.5, 0.1, 0.1) * 0.25, p.stroke * 0.9);

    float highlight = 1e9;
    float base_d = abs(egg - 0.015) - 0.01;
    float right = base_d + smooth_hill(uv.x, -0.62, -0.26, 0.505);
    highlight = min(highlight, right);
    float left = base_d + smooth_hill(uv.x, 0.56, -0.39, 0.58) * 0.1;
    left = max(left, dot(uv, float2(2.14, -0.13)) - 1.82);
    highlight = min(highlight, left);
    highlight = max(highlight, egg);
    float on_ear = abs(ear - 0.015) - 0.01;
    on_ear += smooth_hill(uv.x, 1.0, -0.61, 0.98) * 0.1;
    on_ear = max(on_ear, dot(uv, float2(-0.54, 0.54)) + 0.88);
    on_ear = max(on_ear, ear);
    highlight = min(highlight, on_ear);

    draw_highlight(final_color, highlight);

    return head;
}

void make_nose(inout float4 final_color, float2 uv, ShaderParams p) {
    uv.y -= -0.02;
    float2 nuv = float2(abs(uv.x), uv.y);
    uv -= float2(0.08, 0.14 + remap01(p.shift, 0.0, 0.15));
    nuv -= float2(0.08, 0.14 + remap01(p.shift, 0.0, 0.15));
    float2 def = float2(-1.06, 0.21);
    nuv.x -= max(0.0, dot(nuv, def));
    float shadow = sd_line(uv, float2(-0.02, 0.03), float2(0.05, 0.04)) - 0.02;
    float ds =
        sd_line(uv, float2(0.05, 0.06), float2(0.06, 0.08 + p.shift * 0.06)) - 0.01;
    shadow = smin(shadow, ds, 0.10);
    float nostrils = sd_circle(nuv, 0.04);
    shadow = max(shadow, -nostrils + 0.008);
    nostrils = abs(nostrils) - 0.004;
    nostrils = max(nostrils, dot(nuv - float2(0.0, 0.025), float2(-0.06, -0.21)));
    LayerFlat3(nostrils, BORDER_COLOR);
    draw_highlight(final_color, shadow);
}

float2 translate_rotate(float2 p, float2 off, float a) {
    p = p - off;
    p = mul(rot(a), p);
    return p;
}

float intersection_sd(float d1, float d2) {
    float dmin = min(abs(d1), abs(d2));
    return dmin * sign(d1) * sign(d2);
}

float make_body(inout float4 final_color, float2 uv, ShaderParams p) {
    float2 left_shoulder = float2(0.98, -0.33), left_top = float2(0.51, 1.06);
    float2 a = left_shoulder, b = float2(-0.001, -0.29), c = left_top;
    float base_d = sd_bezier_convex(uv, a, b, c);
    float body = base_d;

    float2 right_shoulder = float2(-1.16, -0.22), right_top = float2(-0.37, 1.06);

    right_top += head_tranform_point((float2)1.0, p, 50.0) * 0.05;

    a = right_top; b = float2(-0.16, -0.30); c = right_shoulder;
    base_d = sd_bezier_convex(uv, a, b, c);
    body = intersection_sd(body, base_d);

    a = left_top; c = right_top; b = (a + c) / 2.0 - float2(0.0, 0.1);
    base_d = sd_bezier_convex(uv, a, b, c);
    body = intersection_sd(body, base_d);

    float2 right_side = float2(-2.14, -1.71);
    float2 left_side = float2(2.07, -2.17);

    a = right_side; c = left_side; b = (a + c) / 2.0 + float2(0.0, -0.1);
    base_d = sd_bezier_convex(uv, a, b, c);
    body = intersection_sd(body, base_d);

    a = right_shoulder; b = float2(-2.3, -0.02); c = right_side;
    float rbase = sd_bezier_convex(uv, a, b, c);
    body = intersection_sd(body, rbase);

    a = left_side; b = float2(2.79, -0.24); c = left_shoulder;
    float lbase = sd_bezier_convex(uv, a, b, c);
    body = intersection_sd(body, lbase);

    float arm = sd_line(uv, float2(1.6, -1.03), float2(2.76, -1.73)) - 0.5;
    body = smin(body, arm, 0.1);

    float2 huv = head_tranform(uv, p, 0.5) - float2(0.0, -0.15);
    float head_shadow = sd_egg(float2(huv.x, -huv.y), 0.5, 0.07);
    head_shadow = max(head_shadow, body);

    // collar bones
    float areas = 1e9, strokes = 1e9;
    a = float2(-0.28, 0.09); b = float2(-0.07, -0.53); c = float2(-0.64, -0.56);
    base_d = sd_bezier_convex(uv, a, b, c);
    areas = intersection_sd(areas, base_d);
    b = float2(-0.09, -0.63);
    base_d = sd_bezier_convex(uv, a, b, c);
    areas = intersection_sd(areas, base_d);

    a = float2(-1.27, -0.28); c = float2(-0.26, -0.60); b = float2(-1.06, -0.52);
    float bone_base = sd_bezier(uv, a, b, c).x;
    strokes = min(strokes, abs(bone_base) - 0.005);
    areas = max(areas, bone_base);
    float2 tuv = uv + float2(1.11, 0.345);
    tuv = mul(rot(-2.72), tuv);
    float edge = sd_trig_isosceles(tuv, float2(0.3, 0.2)) - 0.1;
    edge = max(edge, bone_base);
    areas = min(areas, edge);
    c = float2(1.23, -0.43); a = float2(0.22, -0.60); b = float2(1.18, -0.60);
    bone_base = sd_bezier(uv, a, b, c).x;
    strokes = min(strokes, abs(bone_base) - 0.005);
    tuv = uv + float2(-1.09, 0.47);
    tuv = mul(rot(-3.3), tuv);
    edge = sd_trig_isosceles(tuv, float2(0.3, 0.2)) - 0.1;
    edge = max(edge, bone_base);
    areas = min(areas, edge);
    a = float2(-0.24, -0.61); c = float2(0.20, -0.6); b = float2(-0.01, -0.84);
    strokes = smin(strokes, abs(sd_bezier(uv, a, b, c).x) - 0.005, 0.02);

    a = float2(0.28, 0.08); b = float2(0.14, -0.51); c = float2(0.51, -0.60);
    base_d = sd_bezier_convex(uv, a, b, c);
    areas = intersection_sd(areas, base_d);
    b = float2(0.069, -0.62);
    base_d = sd_bezier_convex(uv, a, b, c);
    areas = intersection_sd(areas, base_d);

    // arms
    a = float2(1.70, -1.17); b = float2(1.52, -1.81); c = float2(5.63, -4.82);
    float2 bz = sd_bezier(uv, a, b, c);
    areas = min(areas, abs(bz.x) - 0.6 * smoothstep(-0.04, 0.91, bz.y));
    a = float2(-1.31, -1.09); b = float2(-1.20, -1.48); c = float2(-1.63, -2.13);
    bz = sd_bezier(uv, a, b, c);
    areas = min(areas, abs(bz.x) - 0.05 * smoothstep(-0.11, 0.39, bz.y));

    // chest
    a = float2(-0.26, -0.98); b = float2(0.07, -1.12); c = float2(0.23, -2.24);
    bz = sd_bezier(uv, a, b, c);
    float cleavage = abs(bz.x) - 0.1 * smoothstep(-0.07, 0.9, bz.y) -
                     0.025 * pow2(sin(bz.y * 6.32 + 12.76));
    areas = min(areas, cleavage);

    float w = 0.003;
    float on_neck = sd_line_y(uv - float2(0.17, -0.08), 0.3, w * 2.0);
    on_neck =
        smin(on_neck, sd_line_y(uv - float2(0.16, 0.02), 0.2, w * 2.0), 0.02);
    float2 luv = translate_rotate(uv, float2(0.21, 0.0), 0.1);
    on_neck = min(on_neck, sd_line_y(luv, 0.2, w * 1.5));

    float weirmo = sin(uv.x * 10.0 + p.displacement * 24.0 + 3.1) * 0.003;
    LayerStroked3(body, SKIN_COLOR, p.stroke);
    LayerFlat3(on_neck, BLOOD_COLOR);
    LayerFlat4(head_shadow, float4(SKIN_COLOR * 0.01, 0.5));
    LayerStrokedMask(areas, float4(float3(0.3, 0.1, 0.1) * 0.25, 0.9), p.stroke,
                     weirmo);
    LayerFlat3(strokes + weirmo, BORDER_COLOR);

    float hbase = abs(body - 0.015) - 0.01;
    float highlight = hbase + smooth_hill(uv.x, 1.94, -1.05, 0.55) * 0.05;
    highlight =
        min(highlight, hbase + smooth_hill(uv.x, -1.63, -0.49, 0.28) * 0.05);
    highlight = max(highlight, body);
    draw_highlight(final_color, highlight);

    return body;
}

float make_hair_back(inout float4 final_color, float2 uv, ShaderParams p) {
    // right side
    float2 c = float2(1.16, 1.69), b = float2(1.49, 0.69), a = float2(3.36, -0.04);
    c = head_tranform_point(c, p, 0.75);
    float2 base_bz = sd_bezier(uv, a, b, c);
    float hair = max(base_bz.x, -uv.x);
    float2 cuv = translate_rotate(uv - float2(1.0, 1.0) * p.shift * 0.01,
                                  float2(-0.19, -3.03), -1.11);
    float cuts = sd_hook(cuv, 4.22, 0.25, 1.0);
    cuv = translate_rotate(uv - float2(1.0, 1.0) * p.shift * 0.02,
                           float2(-1.48, -2.51), 5.8);
    cuts = min(cuts, sd_hook(cuv, 4.22, 0.1, 1.0));
    cuv = translate_rotate(uv, float2(-2.65, -1.53), 5.8);
    cuts = min(cuts, sd_hook(cuv, 4.22, 0.25, 1.0));
    cuv = translate_rotate(uv, float2(-3.71, -0.12), 6.24);
    cuts = min(cuts, sd_hook(cuv, 4.22, 0.25, 1.0));

    float highlight = abs(base_bz.x + 0.020) - 0.008;
    highlight = max(highlight, base_bz.x);

    // left side
    a = float2(-1.53, 2.5); c = float2(-1.66, 0.64); b = float2(-0.76, 0.90);
    a = head_tranform_point(a, p, 1.0);
    float left_base = sd_bezier_convex(uv, a, b, c);
    a = float2(-1.56, 0.66); b = float2(-2.98, 0.47); c = float2(-3.15, -0.42);
    c = head_tranform_point(c, p, 1.0);
    left_base = min(left_base, sd_bezier_convex(uv, a, b, c));
    left_base = min(left_base, uv.y);
    hair = min(hair, max(left_base, uv.x));
    cuv = translate_rotate(uv, float2(-1.01, -1.51), 0.73);
    cuts = min(cuts,
               sd_hook(cuv - float2(-1.0, 1.0) * p.shift * 0.02, 2.22, 0.25, -1.0));
    cuv = translate_rotate(uv, float2(1.55, -2.34), 0.3);
    cuts = min(cuts,
               sd_hook(cuv - float2(-1.0, 0.0) * p.shift * 0.02, 4.22, 0.05, -1.0));
    cuv = translate_rotate(uv, float2(2.0, -2.33), 0.33);
    cuts = min(cuts, sd_hook(cuv, 4.22, 0.3, -1.0));
    hair = max(hair, -cuts);

    float left_highlight = abs(left_base + 0.025) - 0.011;
    left_highlight = max(left_highlight, left_base);
    left_highlight = max(left_highlight, uv.x + 0.8);
    left_highlight = max(left_highlight, -uv.y + 0.3);
    highlight = min(highlight, left_highlight);
    float2 luv = translate_rotate(uv - float2(-1.0, 1.0) * p.shift * 0.02,
                                  float2(-0.95, -1.49), 0.72);
    float clight = sd_hook(luv, 2.22, 0.25, -1.0);
    luv = translate_rotate(uv - float2(1.0, 1.0) * p.shift * 0.01,
                           float2(-0.33, -3.00), -1.06);
    clight = min(clight, sd_hook(luv, 4.22, 0.25, 1.0));
    clight = max(hair + p.stroke * 0.9, clight);
    highlight = min(highlight, clight);

    float2 huv = (uv + float2(0.02, 1.02)) * float2(2.0, 1.0);
    huv = head_tranform(huv, p, 1.0);
    float3 hair_color =
        lerp(HAIR_COLOR, HAIR_SHADOW_COLOR, AAstep2(sd_circle(huv, 1.6), 0.0));
    LayerStroked3(hair, hair_color, p.stroke * 1.2);

    draw_highlight(final_color, highlight);

    return hair;
}

void make_hair_front(inout float4 final_color,
                     float2 uv,
                     ShaderParams p,
                     float dhead,
                     float dbody,
                     float dbhair) {
    float2 head_uv = head_tranform(uv, p, 1.0);
    float2 cuv = head_uv - float2(5.14, -0.81);
    float right_hair = sd_circle(cuv, 5.99);
    right_hair = abs(right_hair) - 0.2;
    right_hair = max(right_hair, cuv.x);
    right_hair = max(right_hair, -dbody);

    float hbase = abs(right_hair - 0.015) - 0.01;
    float highlight = hbase + smooth_hill(uv.y, 0.42, -0.67, 1.09) * 0.1;
    highlight = max(highlight, right_hair);
    highlight = max(highlight, uv.x + 0.7);

    float2 suv = uv - float2(2.26, 0.13);
    suv = mul(rot(0.13), suv);
    float right_hair_shadow = sd_hook(suv, 3.1, 0.19, -1.0);
    right_hair_shadow = max(right_hair_shadow, -dbody);

    float skin_shadow = -sd_circle(head_uv - float2(0.91, -0.32), 1.51);
    skin_shadow = max(skin_shadow, dhead);
    skin_shadow = max(skin_shadow, -right_hair);
    skin_shadow = max(skin_shadow, head_uv.x);

    float2 a = float2(-0.22, 1.53), c = float2(-2.9, -1.52), b = float2(-1.11, -1.04);
    a = head_tranform_point(a, p, 0.3);
    float2 vuv = uv;
    float2 base_bz = sd_bezier(vuv, a, b, c);
    float right_curl = base_bz.x;
    right_curl = abs(right_curl) -
                 remap(sin(base_bz.y * 4.93 + 1.93), -1.0, 1.0, 0.01, 0.14) +
                 smoothstep(0.43, 1.94, base_bz.y) * 0.1;
    float2 huv = uv - float2(-3.21, 2.74);
    huv -= 0.1 * p.shift;
    huv = mul(rot(0.64), huv);
    skin_shadow = min(skin_shadow, sd_hook(huv, 3.43, -0.1, 1.0));

    hbase = abs(right_curl - 0.015) - 0.01;
    float clight = hbase + smooth_hill(base_bz.y, 0.31, -0.15, 0.24) * 0.1;
    clight = max(clight, right_curl);
    clight = max(clight, dot(uv, float2(0.28, -0.19)) + 0.26);
    highlight = min(highlight, clight);

    a = float2(1.26, 1.02); c = float2(1.00, -0.24); b = float2(1.55, 0.43);
    a = head_tranform_point(a, p, 0.3);
    base_bz = sd_bezier(uv, a, b, c);
    float left_curl = base_bz.x, t = base_bz.y, tt = base_bz.y;
    a = c; c = float2(1.28, -1.75); b = float2(0.32, -1.07);
    left_curl =
        abs(left_curl) - remap(sin(t * -2.05 + 3.6), -1.0, 1.0, 0.01, 0.20);
    base_bz = sd_bezier(uv, a, b, c);
    float sec = base_bz.x;
    t = 1.0 - base_bz.y;
    sec = abs(sec) - remap(sin(t * -2.05 + 3.6), -1.0, 1.0, 0.01, 0.20);
    left_curl = min(left_curl, sec);
    huv = translate_rotate(uv, float2(1.99, -1.3), 0.47);
    float lcurl_shadow = sd_hook(huv, 1.5, 0.2, -1.0);
    lcurl_shadow = max(lcurl_shadow, left_curl + p.stroke);
    huv = translate_rotate(uv, float2(-0.19, 0.95), 0.05);
    float sh = sd_hook(huv, 1.5, 0.2, 1.0);
    sh = max(sh, -left_curl);
    sh = max(sh, -dbody);
    sh = max(sh, dbhair + p.stroke * 1.2);
    lcurl_shadow = min(lcurl_shadow, sh);

    hbase = abs(left_curl - 0.015) - 0.01;
    clight = hbase + smooth_hill(tt, 0.54, -0.46, 0.7) * 0.1;
    clight = max(clight, left_curl);
    clight = max(clight, dot(uv, float2(-0.47, 0.07)) + 0.62);
    highlight = min(highlight, clight);

    LayerFlat4(skin_shadow, float4(final_color.rgb * 0.2, 0.5));
    float mask = dot(head_uv, float2(5.13, 1.31)) + 3.81;
    LayerStrokedMask(right_hair, float4(HAIR_COLOR, 1.0), p.stroke, mask);
    mask = dot(suv, float2(-3.86, -0.54)) + -12.0;
    LayerStrokedMask(right_hair_shadow, float4(HAIR_SHADOW_COLOR, 1.0),
                     p.stroke * 1.4, mask);

    LayerStroked3(right_curl, HAIR_COLOR, p.stroke * 1.1);
    mask = dot(uv, float2(0.6, -0.48)) + -0.33;
    LayerStrokedMask(left_curl, float4(HAIR_COLOR, 1.0), p.stroke * 1.4, mask);
    LayerFlat4(lcurl_shadow, float4(HAIR_SHADOW_COLOR, 1.0));

    draw_highlight(final_color, highlight);
}

void make_blood(inout float4 final_color,
                float2 uv,
                ShaderParams p,
                float dmouth,
                float dhead) {
    float2 head_uv = head_tranform(uv, p, 1.0);
    float blood = 1e9;

    float w = 0.003;
    float2 luv = translate_rotate(head_uv, float2(0.64, 0.04), -0.53);
    float lines = sd_line_y(luv, 0.15, w);
    luv = translate_rotate(head_uv, float2(0.66, 0.07), -0.53);
    lines = min(lines, sd_line_y(luv, 0.11, w));
    luv = translate_rotate(head_uv, float2(0.68, 0.09), -0.63);
    lines = min(lines, sd_line_y(luv, 0.09, w * 1.5));
    blood = min(blood, lines);

    luv = translate_rotate(head_uv, float2(0.55, -0.18), -0.1);
    float on_chin = sd_line_y(luv, 0.15, 0.015);
    on_chin =
        smin(on_chin, sd_circle(head_uv - float2(0.57, -0.24), 0.015), 0.09);
    float cut_plane = dot(head_uv, float2(0.71, 0.52)) - 0.36;
    on_chin = max(on_chin, cut_plane);
    blood = min(blood, on_chin);

    float on_mouth = sd_circle(head_uv - float2(0.24, -0.53), 0.016);
    on_mouth = smin(
        on_mouth, sd_line_y(head_uv - float2(0.235, -0.53), 0.34, w * 2.5), 0.05);
    on_mouth =
        max(on_mouth, -sd_line_y(head_uv - float2(0.22, -0.535), 0.19, w * 3.5));
    float poff = remap01(p.shift, -0.05, 0.05);
    luv =
        translate_rotate(uv, float2(0.19 + poff * 0.3, 0.64 + poff * 1.40), 0.9);
    float s = 0.12;
    on_mouth = smin(
        on_mouth,
        sd_line_y(luv / s, 1.4, 0.0025) * s - fbm(head_uv * 2.73 + 0.1, 4.0) * s,
        0.06);
    on_mouth = smin(on_mouth, dmouth + 0.004, 0.07);
    on_mouth = max(on_mouth, -dmouth + 0.002);
    blood = min(blood, on_mouth);

    LayerFlat3(blood, BLOOD_COLOR);
}

// ============= Entry Point =============

float4 PSMain(PSInput input) : SV_Target {
    // Y-flip: character faces upward in Shadertoy convention
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);
    float2 uv = (2.0 * fragCoord - resolution.xy) / resolution.y;

    uv *= 1.5;
    uv.y -= 0.1;

    float t = time + 0.1;
    uv += (float2(fbm(float2(t, 0.0), 3.0), fbm(float2(t, 1.0), 3.0)) * 2.0 - 1.0) * 0.025 *
          (1.0 - length(uv * 0.05));
    ShaderParams p;
    p.stime = time;
    p.shift = cos(p.stime) * 0.5 + 0.5;
    p.displacement = fbm(uv * 2.91, 2.0) * 0.42;
    p.stroke = fwidth(uv.y) * 0.5 + p.displacement * 0.05;

    uv = mul(rot(0.05), uv);

    float4 final_color = float4((float3)0.051, 1.0);
    final_color.rgb = background(uv);

    float dbhair = make_hair_back(final_color, uv, p);
    float dbody = make_body(final_color, uv, p);
    float2 head_uv = head_tranform(uv, p, 1.0);
    float dhead = 1e9, dmouth = 1e9;
    if (uv.y > -0.1) {
        dhead = make_head(final_color, head_uv, p);
        dmouth = make_mouth(final_color, head_uv, p);
        make_nose(final_color, head_uv, p);
        make_blood(final_color, uv, p, dmouth, dhead);
    }
    make_hair_front(final_color, uv, p, dhead, dbody, dbhair);

    final_color.rgb =
        lerp(final_color.rgb, (float3)0, smoothstep(1.50, -2.84, uv.y));

    float3 col = final_color.rgb;

    col = sat(col);
    col = pow(col, (float3)(1.0 / 1.9));
    col = smoothstep(0.0, 1.0, col);
    col = pow(col, float3(1.74, 1.71, 1.48));

    float2 in_uv = fragCoord / resolution.xy;
    col *= sat(pow(500.0 * in_uv.x * in_uv.y * (1.0 - in_uv.x) * (1.0 - in_uv.y), 0.256));

    col += noise(uv * 500.0) * 0.015 * smoothstep(-1.47, 0.58, uv.y);

    // Post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float alpha = max(col.r, max(col.g, col.b));
    return float4(col * alpha, alpha);
}
