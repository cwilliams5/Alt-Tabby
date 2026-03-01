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

#define NUM_OCTAVES 4
#define pi 3.14159265

static float focus = 0.0;
static float focus2 = 0.0;

float random(float2 p) {
    return frac(sin(dot(p, float2(12.0, 90.0))) * 5e5);
}

float2x2 rot2(float an) {
    float cc = cos(an), ss = sin(an);
    return float2x2(cc, ss, -ss, cc);
}

float noise(float3 p) {
    float2 i = floor(p.yz);
    float2 f = frac(p.yz);
    float a = random(i + float2(0.0, 0.0));
    float b = random(i + float2(1.0, 0.0));
    float c = random(i + float2(0.0, 1.0));
    float d = random(i + float2(1.0, 1.0));
    float2 u = f * f * (3.0 - 2.0 * f);

    return lerp(lerp(a, b, u.x), lerp(c, d, u.x), u.y);
}

float fbm3d(float3 p) {
    float v = 0.0;
    float a = 0.35;

    for (int i = 0; i < NUM_OCTAVES; i++) {
        v += a * noise(p);
        a *= 0.25 * (1.2 + focus + focus2);
    }
    return v;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 uv = (2.0 * fragCoord - resolution.xy) / resolution.y * 2.5;

    float aspectRatio = resolution.x / resolution.y;

    float3 rd = normalize(float3(uv, -1.2));
    float3 ro = (float3)0;

    float delta = time / 1.5;

    rd.yz = mul(rot2(-delta / 2.0), rd.yz);
    rd.xz = mul(rot2(delta * 3.0), rd.xz);
    float3 p = ro + rd;

    float bass = 1.5 + 0.5 * max(0.0, 2.0 * sin(time * 3.0));

    float2 nudge = float2(aspectRatio * cos(time * 1.5), sin(time * 1.5));

    focus = length(uv + nudge);
    focus = 2.0 / (1.0 + focus) * bass;

    focus2 = length(uv - nudge);
    focus2 = 4.0 / (1.0 + focus2 * focus2) / bass;

    float3 q = float3(fbm3d(p), fbm3d(p.yzx), fbm3d(p.zxy));

    float f = fbm3d(p + q);

    float3 col = q;
    col *= 20.0 * f;

    col.r += 5.0 * focus; col.g += 3.5 * focus;
    col.b += 7.0 * focus2; col.r -= 3.5 * focus2;
    col /= 25.0;

    // Apply darken/desaturate
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
