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

#define PI 3.14159265359
#define TWO_PI 6.28318530718
#define FBM_ITER 5

float2 viewport(float2 uv, float2 r) {
    return (uv * 2.0 - r) / min(r.x, r.y);
}

float rand1(float x, int s) {
    return frac(sin(x + (float)s) * 43758.5453123);
}

float rand2(float2 uv, int seed) {
    return frac(sin(dot(uv.xy, float2(12.9898, 78.233)) + (float)seed) * 43758.5453123);
}

float noise1(float x, int s) {
    float xi = floor(x);
    float xf = frac(x);
    return lerp(rand1(xi, s), rand1(xi + 1.0, s), smoothstep(0.0, 1.0, xf));
}

float noise2(float2 p, int s) {
    float2 pi = floor(p);
    float2 pf = frac(p);

    float2 o = float2(0, 1);

    float bl = rand2(pi, s);
    float br = rand2(pi + o.yx, s);
    float tl = rand2(pi + o.xy, s);
    float tr = rand2(pi + o.yy, s);

    float2 w = smoothstep(0.0, 1.0, pf);

    float t = lerp(tl, tr, w.x);
    float b = lerp(bl, br, w.x);

    return lerp(b, t, w.y);
}

float fbm(float2 p, int seed) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < FBM_ITER; i++) {
        v += a * noise2(p, seed);
        p *= 2.0;
        a *= 0.5;
    }
    return v;
}

float3 gradient(float t, float3 a, float3 b, float3 c, float3 d) {
    return a + b * cos(TWO_PI * (c * t + d));
}

float cosine_interp(float x, float s) {
    float y = cos(frac(x) * PI);
    return floor(x) + 0.5 - (0.5 * pow(abs(y), 1.0 / s) * sign(y));
}

float noise0(float x) {
    return noise1(x, 0);
}

float2x2 rot2(float a) {
    float c = cos(a);
    float s = sin(a);
    return float2x2(c, -s, s, c);
}

float map(float3 p) {
    float t = time * 0.5;
    p.z += t;
    t *= 0.125;
    float n = fbm(p.xz, 0);
    n = pow(n, 3.0 + sin(t));
    float g = p.y + 2.0;
    g -= n;
    g = min(g, 3.3 - g);
    return g;
}

static const float3 c3 = float3(0.05, 0.05, 0.05);
static const float3 c4 = float3(0.52, 0.57, 0.59);

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);
    float2 uv = viewport(fragCoord.xy, resolution.xy);
    float t = time * 0.1;

    float3 ro = float3(0, 0, -3);
    float3 rd = normalize(float3(uv, 1));
    rd.xz = mul(rd.xz, rot2(sin(t)));
    float3 p = (float3)0;

    float d = 0.0;
    float dt = 0.0;

    float j = 0.0;

    float m = 0.1;
    float an = cos(t * 0.05) * m;

    for (int i = 0; i < 30; i++) {
        p = ro + rd * d;
        p.xy = mul(p.xy, rot2(d * an));
        dt = map(p);
        d += dt;
        j = (float)i;
        if (dt < 0.001 || d > 100.0) {
            break;
        }
    }

    float glow = sin(noise0(t * 5.0)) * 0.005 + 0.02;
    d += j * (0.33 + glow * 5.0);
    float a = smoothstep(0.0, 30.0, d);
    float phase = cosine_interp(length(p.zy * 0.1), 2.0);

    float g = sin(time * 0.125) * 0.25 + 0.35;
    float3 c12 = float3(g, g, g);
    float3 col1 = gradient(phase, c12, c12, c3, c4) * d * 0.2;

    float3 col2 = lerp(float3(0.9, 0.9, 0.56), float3(0.95, 0.65, 0.38), sin(noise0(t * 5.0 + uv.x * 0.3)) * 0.5 + 0.5) * d * glow;
    float3 col = lerp(col1, col2, a);

    // Darken / desaturate
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiply
    float alpha = max(col.r, max(col.g, col.b));
    return float4(col * alpha, alpha);
}
