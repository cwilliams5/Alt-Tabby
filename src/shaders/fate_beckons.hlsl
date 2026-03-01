// Fate Beckons — Fork by vivavolt
// Shadertoy: https://shadertoy.com/view/Dlj3Dm

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

#define TIME (time * 3.0)

static const float hf = 0.01;

#define hsv(h,s,v) (v) * (1.0 + (s) * clamp(abs(frac((h) + float3(3,2,1) / 3.0) * 6.0 - 3.0) - 2.0, -1.0, 0.0))

float3 aces_approx(float3 v) {
    v = max(v, (float3)0) * 0.6;
    return min((v * (2.51 * v + 0.03)) / (v * (2.43 * v + 0.59) + 0.14), (float3)1);
}

float pmin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return lerp(b, a, h) - k * h * (1.0 - h);
}

#define pabs(a,k) (-pmin(a, -(a), k))

float height(float2 p) {
    p *= 0.4;
    float tm = TIME,
          xm = 0.5 * 0.005123,
          ym = lerp(0.125, 0.25, 0.5 - 0.5 * sin(cos(6.28 * TIME / 6e2))),
           d = length(p),
           c = 1E6,
           x = pow(d, 0.1) * ym,
           y = (atan2(p.x, p.y) + 0.05 * tm - 3.0 * d) / 6.28;

    float v;
    for (float i = 0.0; i < 4.0; i += 1.0) {
        v = length(frac(float2(x - tm * i * xm,
                               frac(y + i * ym) / 8.0)
                        * 16.0 * (1.0 + abs(sin(0.01 * TIME + 10.0))))
                   * 2.0 - 1.0);
        c = pmin(c, v, 0.0125);
    }

    return hf * (pabs(tanh(5.5 * d - 40.0 * c * c * d * d * (0.55 - d)) - 0.25 * d, 0.25) - 1.0);
}

float3 get_normal(float2 p) {
    float2 e = float2(4.0 / resolution.y, 0.0);
    return normalize(float3(
        height(p + e.xy) - height(p - e.xy),
        -2.0 * e.x,
        height(p + e.yx) - height(p - e.yx)));
}

float3 get_color(float2 p) {
    float ss = 1.0, hh = 1.95, spe = 3.0;

    float3 lp1 = -float3(1, hh, -1) * float3(ss, 1, ss),
           lp2 = -float3(-1, hh, -1) * float3(ss, 1, ss),
         lcol1 = hsv(0.1, 0.75, abs(sin(TIME * 0.1)) * 2.0),
         lcol2 = hsv(0.57, sin(TIME * 0.1) * 0.7, 1.0),
          matc = hsv(0.55, 0.83, 0.55),
             n = get_normal(p),
            ro = float3(0, 8, 0),
            pp = float3(p.x, 0, p.y),
            po = pp,
            rd = normalize(ro - po),
           ld1 = normalize(lp1 - po),
           ld2 = normalize(lp2 - po),
           ref = reflect(rd, n);

    float diff1 = max(dot(n, ld1), 0.0),
          diff2 = max(dot(n, ld2), 0.0),
           ref1 = max(dot(ref, ld1), 0.0),
           ref2 = max(dot(ref, ld2), 0.0),
             rm = tanh(abs(height(p)) * 120.0);

    float3 lpow1 = rm * rm * matc * lcol1,
           lpow2 = rm * rm * matc * lcol2;

    return diff1 * diff1 * lpow1
         + diff2 * diff2 * lpow2
         + rm * pow(ref1, spe) * lcol1
         + rm * pow(ref2, spe) * lcol2;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 R = resolution;
    float2 p = (2.0 * fragCoord - R) / R.y;

    float3 col = get_color(p);
    col = aces_approx(col);
    float3 color = sqrt(max(col, (float3)0));

    // Post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float alpha = max(color.r, max(color.g, color.b));
    return float4(color * alpha, alpha);
}
