// Drifting Waves — based on https://www.shadertoy.com/view/WXjcWK
// Original by panna_pudi
// Water technique by Tater (https://www.shadertoy.com/view/NlKGWK)

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

// --- Constants ---

static const float PI = 3.14159265359;

static const int MAT_WAVE = 2;
static const float MDIST = 60.0;
static const int ITERS_TRACE = 9;
static const int ITERS_NORM = 20;

static const float SCRL_SPEED = 1.5;
static const float2 SCRL_DIR = float2(1.0, 1.2);
static const float HOR_SCALE = 1.1;
static const float FREQ_SCALE = 1.28;
static const float TIME_SCALE = 1.095;
static const float WEIGHT_SCALE = 0.8;
static const float DRAG = 0.9;
static const float HEIGHT_DIV = 2.3;

static const float WAVE_ROT_ANGLE = 6.21;
// Same constructor args as GLSL for mul(v, m) pattern
static const float2x2 WAVE_ROT = float2x2(
    cos(WAVE_ROT_ANGLE), -sin(WAVE_ROT_ANGLE),
    sin(WAVE_ROT_ANGLE), cos(WAVE_ROT_ANGLE));
static const float WAVE_FREQ = 0.6;
static const float OCC_SPEED = 1.4;
static const float DX_DET = 0.65;

static const float2 sunrot_val = float2(-0.3, 0.10);

// --- Utilities (from Common) ---

// Rotation matrix — same constructor args as GLSL for mul(v, m) pattern
float2x2 rot(float a) {
    float c = cos(a), s = sin(a);
    return float2x2(c, -s, s, c);
}

float sd_plane(float3 p, float3 off, float3 n) { return dot(p - off, n); }

float luminance(float3 col) { return dot(col, float3(0.2126729, 0.7151522, 0.0721750)); }
float3 ReinhardExtLuma(float3 col, const float w) {
    float l = luminance(col);
    float n = l * (1.0 + l / (w * w));
    float ln = n / (1.0 + l);
    return col * ln / l;
}

// --- Hit struct ---

struct Hit {
    float t;
    float d;
    int mat;
};

Hit hit_default() { Hit h = { 0.001, 1e9, -1 }; return h; }
Hit hit_init(float dist, int mat) { Hit h = { 0.001, dist, mat }; return h; }
Hit hit_init(float t, float dist, int mat) { Hit h = { t, dist, mat }; return h; }
Hit _min(Hit a, Hit b) {
    if (a.d < b.d) return a;
    return b;
}

// --- Wave functions ---

float2 sd_wave_diff(float2 wave_pos, int iter_num, float t) {
    float2 res = (float2)0;
    float2 wave_dir = float2(1.0, 0.0);
    float wave_weight = 1.0;
    wave_pos += t * SCRL_SPEED * SCRL_DIR;
    wave_pos *= HOR_SCALE;
    float wave_freq = WAVE_FREQ;
    float wave_time = OCC_SPEED * t;
    for (int i = 0; i < iter_num; ++i) {
        wave_dir = mul(wave_dir, WAVE_ROT);
        float x = dot(wave_dir, wave_pos) * wave_freq + wave_time;
        float dx = exp(sin(x) - 1.0) * cos(x) * wave_weight;
        res += dx * wave_dir / pow(wave_weight, DX_DET);

        wave_freq *= FREQ_SCALE;
        wave_time *= TIME_SCALE;
        wave_pos -= wave_dir * dx * DRAG;
        wave_weight *= WEIGHT_SCALE;
    }

    float wave_sum = -(pow(WEIGHT_SCALE, (float)iter_num) - 1.0) * HEIGHT_DIV;
    return res / pow(wave_sum, 1.0 - DX_DET);
}

float3 sd_wave_normal(float3 p, float t) {
    float2 wavedx = -sd_wave_diff(p.xz, ITERS_NORM, t);
    return normalize(float3(wavedx.x, 1.0, wavedx.y));
}

float sd_wave(float2 wave_pos, int iter_num, float t) {
    float res = 0.0;
    float2 wave_dir = float2(1.0, 0.0);
    float wave_weight = 1.0;
    wave_pos += t * SCRL_SPEED * SCRL_DIR;
    wave_pos *= HOR_SCALE;
    float wave_freq = WAVE_FREQ;
    float wave_time = OCC_SPEED * t;
    for (int i = 0; i < iter_num; ++i) {
        wave_dir = mul(wave_dir, WAVE_ROT);
        float x = dot(wave_dir, wave_pos) * wave_freq + wave_time;
        float wave = exp(sin(x) - 1.0) * wave_weight;
        res += wave;

        wave_freq *= FREQ_SCALE;
        wave_time *= TIME_SCALE;
        wave_pos -= wave_dir * wave * DRAG * cos(x);
        wave_weight *= WEIGHT_SCALE;
    }

    float wave_sum = -(pow(WEIGHT_SCALE, (float)iter_num) - 1.0) * HEIGHT_DIV;
    return res / wave_sum;
}

// --- Scene ---

Hit map(float3 p) {
    float t = time * 0.8 + 50.0;
    Hit hit = hit_default();

    float wave = sd_wave(p.xz, ITERS_TRACE, t);
    float plane = sd_plane(p, (float3)0, float3(0.0, 1.0, 0.0));
    hit = _min(hit, hit_init(plane - wave, 2));

    return hit;
}

float3 get_norm(float3 p, Hit hit, float t) {
    if (hit.mat == MAT_WAVE) {
        return sd_wave_normal(p, t);
    } else {
        static const float3 e = float3(0.0001, 0, 0);
        float3 grad = float3(
            map(p - e.xyz).d,
            map(p - e.yxz).d,
            map(p - e.yzx).d);
        return normalize(hit.d - grad);
    }
}

Hit trace(float3 ro, float3 rd) {
    float t = 0.0;
    for (int i = 0; i < 60; ++i) {
        float3 pos = ro + rd * t;
        Hit hit = map(pos);
        float d = hit.d;
        if (d < 0.001) {
            return hit_init(t, d, hit.mat);
        }
        t += d;
        if (t > MDIST) {
            break;
        }
    }
    return hit_init(t, 1e9, -1);
}

float3x3 get_cam(float3 eye, float3 target) {
    float3 frw = normalize(target - eye);
    float3 up = normalize(cross(frw, float3(0.0, 1.0, 0.0)));
    float3 side = cross(frw, up);
    // GLSL mat3(col0, col1, col2) is column-major;
    // HLSL float3x3(row0, row1, row2) is row-major — transpose for mul(m, v)
    return transpose(float3x3(up, frw, side));
}

// --- Palette / Sky ---

float3 pal(float pt, float3 a, float3 b, float3 c, float3 d) {
    return a + b * cos(2.0 * PI * (c * pt + d));
}
float3 spc(float n, float bright) {
    return pal(n, (float3)bright, (float3)0.5, (float3)1.0, float3(0.0, 0.33, 0.67));
}

float3 sky(float3 rd) {
    float rad = 0.075;
    float3 col = (float3)0;

    float sky_palette = 0.08;
    rd.yz = mul(rd.yz, rot(sunrot_val.y));
    rd.xz = mul(rd.xz, rot(sunrot_val.x));
    float px = min(fwidth(rd).x, fwidth(rd).y);
    float sFade = px * 2.0;
    float zFade = rd.z * 0.5 + 0.5;

    float3 sc = spc(sky_palette - 0.1, 0.6) * 0.85;
    float a = length(rd.xy);
    float3 sun = smoothstep(a - px - sFade, a + px + sFade, rad) * sc * zFade * 3.0;
    col += sun;
    col += rad / (rad + pow(a, 1.7)) * sc * zFade;
    col = col + lerp(col, spc(sky_palette + 0.1, 0.8), saturate(1.0 - length(col))) * 0.03;

    col *= 2.0;

    return col;
}

// --- Render ---

float3 render(float2 fragCoord) {
    float2 uv = (fragCoord / resolution - 0.5) *
                float2(resolution.x / resolution.y, 1.0);

    float t = time * 0.8 + 50.0;

    float3 ro = float3(4.84, 6.94, 2.64);
    float3x3 cam = get_cam(ro, ro + float3(-0.97, 3.7, 1.2));
    float3 rd = normalize(mul(cam, float3(uv, 1.0)));

    float3 col = float3(0.96, 0.95, 0.9) * 0.2;

    float3 sky_col = sky(rd);
    Hit hit = trace(ro, rd);
    if (hit.mat > 0) {
        float3 pos = ro + rd * hit.t;
        float3 normal = get_norm(pos, hit, t);

        float3 rfl = reflect(rd, normal);
        rfl.y = abs(rfl.y);
        float fres = clamp(pow(1.0 - max(0.0, dot(-normal, rd)), 5.0), 0.0, 1.0);
        col += sky(rfl) * fres * 0.9;

        float3 water_col = saturate(saturate(spc(0.46, 0.4)) * 0.05 * pow(min(pos.y + 0.5, 1.8), 4.0) *
                            length(sky_col) * (rd.z * 0.3 + 0.7));
        col += water_col * 0.35;

        col = lerp(col, sky_col, saturate(1.0 - exp(-hit.t / MDIST * 2.5)));
    } else {
        col = sky_col;
    }

    col = ReinhardExtLuma(col, 1.5);
    col = pow(col, (float3)1.1);
    return col;
}

// --- Entry point (no AA for performance) ---

float4 PSMain(PSInput input) : SV_Target {
    // Y-flip: ocean/sky scene has up/down orientation
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);

    float3 color = render(fragCoord);

    // Post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, (float3)lum, desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float outA = max(color.r, max(color.g, color.b));
    return float4(color * outA, outA);
}
