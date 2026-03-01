// In Space - by morimea (Danil)
// https://www.shadertoy.com/view/sldGDf
// License: CC0
// Converted from GLSL to HLSL for Alt-Tabby

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

#define SS(x, y, z) smoothstep(x, y, z)
#define MD(a) float2x2(cos(a), sin(a), -sin(a), cos(a))

static const float divx = 35.0;
#define polar_line_scale (2.0/divx)
static const float zoom_nise = 9.0;

// Rotation matrices
float3x3 rotx(float a) {
    float s = sin(a); float c = cos(a);
    return float3x3(1, 0, 0,  0, c, -s,  0, s, c);
}

float3x3 roty(float a) {
    float s = sin(a); float c = cos(a);
    return float3x3(c, 0, -s,  0, 1, 0,  s, 0, c);
}

float3x3 rotz(float a) {
    float s = sin(a); float c = cos(a);
    return float3x3(c, -s, 0,  s, c, 0,  0, 0, 1);
}

float linearstep(float begin, float end, float t) {
    return clamp((t - begin) / (end - begin), 0.0, 1.0);
}

float hash(float2 p) {
    float3 p3 = frac(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return -1.0 + 2.0 * frac((p3.x + p3.y) * p3.z);
}

float noise(float2 p) {
    float2 i = floor(p);
    float2 f = frac(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return lerp(lerp(hash(i + float2(0.0, 0.0)),
                     hash(i + float2(1.0, 0.0)), u.x),
                lerp(hash(i + float2(0.0, 1.0)),
                     hash(i + float2(1.0, 1.0)), u.x), u.y);
}

float fbm(float2 p) {
    p *= 0.25;
    float s = 0.5;
    float f = 0.0;
    for (int i = 0; i < 4; i++) {
        f += s * noise(p);
        s *= 0.8;
        p = 2.01 * mul(float2x2(0.8, -0.6, 0.6, 0.8), p);
    }
    return 0.5 + 0.5 * f;
}

float2 ToPolar(float2 v) {
    return float2(atan2(v.y, v.x) / 3.1415926, length(v));
}

float3 fcos(float3 x) {
    float3 w = fwidth(x);
    return cos(x) * smoothstep(3.14 * 2.0, 0.0, w);
}

float3 getColor(float t) {
    float3 col = float3(0.3, 0.4, 0.5);
    col += 0.12 * fcos(6.28318 * t *   1.0 + float3(0.0, 0.8, 1.1));
    col += 0.11 * fcos(6.28318 * t *   3.1 + float3(0.3, 0.4, 0.1));
    col += 0.10 * fcos(6.28318 * t *   5.1 + float3(0.1, 0.7, 1.1));
    col += 0.10 * fcos(6.28318 * t *  17.1 + float3(0.2, 0.6, 0.7));
    col += 0.10 * fcos(6.28318 * t *  31.1 + float3(0.1, 0.6, 0.7));
    col += 0.10 * fcos(6.28318 * t *  65.1 + float3(0.0, 0.5, 0.8));
    col += 0.10 * fcos(6.28318 * t * 115.1 + float3(0.1, 0.4, 0.7));
    col += 0.10 * fcos(6.28318 * t * 265.1 + float3(1.1, 1.4, 2.7));
    return col;
}

float3 pal(float t, float3 a, float3 b, float3 c, float3 d) {
    return a + b * cos(6.28318 * (c * t + d));
}

float3 get_noise(float2 p, float timer) {
    float2 res = resolution / resolution.y;
    float2 shiftx = res * 0.5 * 1.25 + 0.5 * (0.5 + 0.5 * float2(sin(timer * 0.0851), cos(timer * 0.0851)));
    float2 shiftx2 = res * 0.5 * 2.0 + 0.5 * (0.5 + 0.5 * float2(sin(timer * 0.0851), cos(timer * 0.0851)));
    float2 tp = p + shiftx;
    float atx = (atan2(tp.x + 0.0001 * (1.0 - abs(sign(tp.x))), tp.y) / 3.141592653) * 0.5 + frac(timer * 0.025);
    float2 puv = ToPolar(tp);
    puv.y += atx;
    puv.x *= 0.5;
    float2 tuv = puv * divx;
    float idx = fmod(floor(tuv.y), divx) + 200.0;
    puv.y = frac(puv.y);
    puv.x = abs(frac(puv.x / divx) - 0.5) * divx;
    puv.x += -0.5 * timer * (0.075 - 0.0025 * max((min(idx, 16.0) + 2.0 * sin(idx / 5.0)), 0.0));
    float2 idxVec = (float2)(4.0 + 2.0 * idx);
    return float3(
        SS(0.43, 0.73, fbm(mul((p * 0.5 + shiftx2), MD(-timer * 0.013951 * 10.0 / zoom_nise)) * zoom_nise * 2.0 + idxVec)),
        SS(0.543, 0.73, fbm(mul((p * 0.5 + shiftx2), MD(timer * 0.02751 * 10.0 / zoom_nise)) * zoom_nise * 1.4 + idxVec)),
        fbm(idxVec * puv * zoom_nise / 100.0));
}

float4 get_lines_color(float2 p, float3 n, float timer) {
    float2 res = resolution / resolution.y;

    float3 col = (float3)0;
    float a = 1.0;

    float2 shiftx = res * 0.5 * 1.25 + 0.5 * (0.5 + 0.5 * float2(sin(timer * 0.0851), cos(timer * 0.0851)));
    float2 tp = p + shiftx;
    float atx = (atan2(tp.x + 0.0001 * (1.0 - abs(sign(tp.x))), tp.y) / 3.141592653) * 0.5 + frac(timer * 0.025);
    float2 puv = ToPolar(tp);
    puv.y += atx;
    puv.x *= 0.5;
    float2 tuv = puv * divx;
    float idx = fmod(floor(tuv.y), divx) + 1.0;

    // thin lines
    float d = length(tp);
    d += atx;
    float v = sin(3.141592653 * 2.0 * divx * 0.5 * d + 0.5 * 3.141592653);
    float fv = fwidth(v);
    fv += 0.0001 * (1.0 - abs(sign(fv)));
    d = 1.0 - SS(-1.0, 1.0, 0.3 * abs(v) / fv);

    float d2 = 1.0 - SS(0.0, 0.473, abs(frac(tuv.y) - 0.5));
    tuv.x += 3.5 * timer * (0.01 + divx / 200.0) - 0.435 * idx;

    // lines
    tuv.x = abs(frac(tuv.x / divx) - 0.5) * divx;
    float ld = SS(0.1, 0.9, (frac(polar_line_scale * tuv.x * max(idx, 1.0) / 10.0 + idx / 3.0))) *
               (1.0 - SS(0.98, 1.0, (frac(polar_line_scale * tuv.x * max(idx, 1.0) / 10.0 + idx / 3.0))));

    tuv.x += 1.0 * timer * (0.01 + divx / 200.0) - 1.135 * idx;
    ld *= 1.0 - SS(0.1, 0.9, (frac(polar_line_scale * tuv.x * max(idx, 1.0) / 10.0 + idx / 6.5))) *
                (1.0 - SS(0.98, 1.0, (frac(polar_line_scale * tuv.x * max(idx, 1.0) / 10.0 + idx / 6.5))));

    float ld2 = 0.1 / (max(abs(frac(tuv.y) - 0.5) * 1.46, 0.0001) + ld);
    ld = 0.1 / ((max(abs(frac(tuv.y) - 0.5) * 1.46, 0.0001) + ld) * (2.5 - (n.y + 1.0 * max(n.y, n.z))));

    ld = min(ld, 13.0);
    ld *= SS(0.0, 0.15, 0.5 - abs(frac(tuv.y) - 0.5));

    // noise
    d *= n.z * n.z * 2.0;
    float d3 = (d * n.x * n.y + d * n.y * n.y + (d2 * ld2 + d2 * ld * n.z * n.z));
    d = (d * n.x * n.y + d * n.y * n.y + (d2 * ld + d2 * ld * n.z * n.z));

    a = clamp(d, 0.0, 1.0);

    puv.y = lerp(frac(puv.y), frac(puv.y + 0.5), SS(0.0, 0.1, abs(frac(puv.y) - 0.5)));
    col = getColor(0.54 * length(puv.y));

    col = 3.5 * a * col * col + 2.0 * (lerp(col.bgr, col.grb, 0.5 + 0.5 * sin(timer * 0.1)) - col * 0.5) * col;

    d3 = min(d3, 4.0);
    d3 *= (d3 * n.y - (n.y * n.x * n.z));
    d3 *= n.y / max(n.z + n.x, 0.001);
    d3 = max(d3, 0.0);
    float3 col2 = 0.5 * d3 * float3(0.3, 0.7, 0.98);
    col2 = clamp(col2, 0.0, 2.0);

    col = col2 * 0.5 * (0.5 - 0.5 * cos((timer * 0.48 * 2.0))) + lerp(col, col2, 0.45 + 0.45 * cos((timer * 0.48 * 2.0)));

    col = clamp(col, 0.0, 1.0);

    return float4(col, a);
}

float4 planet(float3 ro, float3 rd, float timer) {
    float3 lgt = float3(-0.523, 0.41, -0.747);
    float sd = clamp(dot(lgt, rd) * 0.5 + 0.5, 0.0, 1.0);
    float far_dist = 400.0;
    float dtp = 13.0 - (ro + rd * far_dist).y * 3.5;
    float hori = (linearstep(-1900.0, 0.0, dtp) - linearstep(11.0, 700.0, dtp)) * 1.0;
    hori *= pow(abs(sd), 0.04);
    hori = abs(hori);

    float3 col = (float3)0;
    col += pow(hori, 200.0) * float3(0.3, 0.7, 1.0) * 3.0;
    col += pow(hori, 25.0) * float3(0.5, 0.5, 1.0) * 0.5;
    col += pow(hori, 7.0) * pal(timer * 0.48 * 0.1, float3(0.8, 0.5, 0.04), float3(0.3, 0.04, 0.82), float3(2.0, 1.0, 1.0), float3(0.0, 0.25, 0.25)) * 1.0;
    col = clamp(col, 0.0, 1.0);

    float t = fmod(timer, 15.0);
    float t2 = fmod(timer + 7.5, 15.0);
    float td = 0.071 * dtp / far_dist + 5.1;
    float td2 = 0.1051 * dtp / far_dist + t * 0.00715 + 0.025;
    float td3 = 0.1051 * dtp / far_dist + t2 * 0.00715 + 0.025;
    float3 c1 = getColor(td);
    float3 c2 = getColor(td2);
    float3 c3 = getColor(td3);
    c2 = lerp(c2, c3.bbr, abs(t - 7.5) / 7.5);

    c2 = clamp(c2, 0.0001, 1.0);

    col += sd * hori * clamp((c1 / (2.0 * c2)), 0.0, 3.0) * SS(0.0, 50.0, dtp);
    col = clamp(col, 0.0, 1.0);

    float a = 1.0;
    a = (0.15 + 0.95 * (1.0 - sd)) * hori * (1.0 - SS(0.0, 25.0, dtp));
    a = clamp(a, 0.0, 1.0);

    return float4(col, a);
}

float3 cam(float2 uv, float timer) {
    timer *= 0.48;
    float2 im = float2(cos(fmod(timer, 3.1415926)), -0.02 + 0.06 * cos(timer * 0.17));
    im *= 3.14159263;
    im.y = -im.y;

    float fov = 90.0;
    float aspect = 1.0;
    float screenSize = (1.0 / (tan(((180.0 - fov) * (3.14159263 / 180.0)) / 2.0)));
    float3 rd = normalize(float3(uv * screenSize, 1.0 / aspect));
    rd = mul(mul(mul(roty(-im.x), rotx(im.y)), rotz(0.32 * sin(timer * 0.07))), rd);
    return rd;
}

static const float3x3 ACESInputMat = float3x3(
    0.59719, 0.07600, 0.02840,
    0.35458, 0.90834, 0.13383,
    0.04823, 0.01566, 0.83777);

static const float3x3 ACESOutputMat = float3x3(
     1.60475, -0.10208, -0.00327,
    -0.53108,  1.10813, -0.07276,
    -0.07367, -0.00605,  1.07602);

float3 RRTAndODTFit(float3 v) {
    float3 a = v * (v + 0.0245786) - 0.000090537;
    float3 b = v * (0.983729 * v + 0.4329510) + 0.238081;
    return a / b;
}

float3 ACESFitted(float3 color) {
    color = mul(color, ACESInputMat);
    color = RRTAndODTFit(color);
    color = mul(color, ACESOutputMat);
    color = clamp(color, 0.0, 1.0);
    return color;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);

    float timer = 0.65 * time + 220.0;
    float2 res = resolution / resolution.y;
    float2 uv = fragCoord.xy / resolution.y - 0.5 * res;

    float3 noisev = get_noise(uv, timer);
    float4 lcol = get_lines_color(uv, noisev, timer);

    float3 ro = float3(1.0, 40.0, 1.0);
    float3 rd = cam(uv, timer);
    float4 planetc = planet(ro, rd, timer);

    float3 col = lcol.rgb * planetc.a * 0.75 + 0.5 * lcol.rgb * min(12.0 * planetc.a, 1.0) + planetc.rgb;
    col = clamp(col, 0.0, 1.0);

    col = col * 0.85 + 0.15 * col * col;

    // Extra color correction
    col = col * 0.15 + col * col * 0.65 + (col * 0.7 + 0.3) * ACESFitted(col);

    // Darken/desaturate for Alt-Tabby compositing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Brightness-based alpha with premultiply
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
