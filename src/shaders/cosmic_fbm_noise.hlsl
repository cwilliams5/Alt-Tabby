// cosmic fbm noise — nayk (Shadertoy 4csyRl)
// CC BY-NC-SA 3.0
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

static const float F3 = 0.3333333;
static const float G3 = 0.1666667;

static const float PI_VAL = 3.141592;
static const float TWOPI = 6.283184;

float3 random3(float3 c) {
    float j = 4096.0 * sin(dot(c, float3(17.0, 59.4, 15.0)));
    float3 r;
    r.z = frac(512.0 * j);
    j *= 0.125;
    r.x = frac(512.0 * j);
    j *= 0.125;
    r.y = frac(512.0 * j);
    return r - 0.5;
}

float simplex3d(float3 p) {
    float3 s = floor(p + dot(p, (float3)F3));
    float3 x = p - s + dot(s, (float3)G3);

    float3 e = step((float3)0.0, x - x.yzx);
    float3 i1 = e * (1.0 - e.zxy);
    float3 i2 = 1.0 - e.zxy * (1.0 - e);

    float3 x1 = x - i1 + G3;
    float3 x2 = x - i2 + 2.0 * G3;
    float3 x3 = x - 1.0 + 3.0 * G3;

    float4 w, d;
    w.x = dot(x, x);
    w.y = dot(x1, x1);
    w.z = dot(x2, x2);
    w.w = dot(x3, x3);

    w = max(0.6 - w, 0.0);

    d.x = dot(random3(s), x);
    d.y = dot(random3(s + i1), x1);
    d.z = dot(random3(s + i2), x2);
    d.w = dot(random3(s + 1.0), x3);

    w *= w;
    w *= w;
    d *= w;

    return dot(d, (float4)52.0);
}

float random_2d(float2 st) {
    return frac(sin(dot(st.xy, float2(12.9898, 78.233))) * 43758.5453123);
}

float noise_2d(float2 st) {
    float2 i = floor(st);
    float2 f = frac(st);

    float a = random_2d(i);
    float b = random_2d(i + float2(1.0, 0.0));
    float c = random_2d(i + float2(0.0, 1.0));
    float d = random_2d(i + float2(1.0, 1.0));

    float2 u = f * f * (3.0 - 2.0 * f);

    return lerp(a, b, u.x) +
           (c - a) * u.y * (1.0 - u.x) +
           (d - b) * u.x * u.y;
}

float fbm(float2 p) {
    float nVal = 0.0;
    float amp = 0.45;
    [unroll]
    for (int i = 0; i < 4; i++) {
        nVal += amp * simplex3d(float3(p, 0.2 * time));
        nVal += amp * noise_2d(p + time);
        p *= 3.0;
        amp *= 0.45;
    }
    return nVal;
}

#define ITERATIONS 12
#define FORMUPARAM 0.53

#define VOLSTEPS 20
#define STEPSIZE 0.1

#define ZOOM 0.800
#define TILE 0.850

#define BRIGHTNESS 0.0015
#define DARKMATTER 0.300
#define DISTFADING 0.730

#define SATURATION 0.850

float happy_star(float2 uv, float anim) {
    uv = abs(uv);
    float2 pos = min(uv.xy / uv.yx, anim);
    float p = (2.0 - pos.x - pos.y);
    return (2.0 + p * (p * p - 1.5)) / (uv.x + uv.y);
}

float2x2 rotMat(float r) {
    float c = cos(r);
    float s = sin(r);
    return float2x2(c, -s, s, c);
}

float abs1d(float x) { return abs(frac(x) - 0.5); }
float2 abs2d(float2 v) { return abs(frac(v) - 0.5); }
float sin1d(float p) { return sin(p * TWOPI) * 0.25 + 0.25; }

static const float D2R = PI_VAL / 180.0;
static const float OC = 15.0;

float3 Oilnoise(float2 pos, float3 RGB) {
    float2 q = (float2)1.0;
    float result = 0.0;
    float t = time * 0.1 + ((0.25 + 0.05 * sin(time * 0.1)) / (length(pos.xy) + 0.07)) * 2.2;
    float si = sin(t);
    float co = cos(t);
    float2x2 ma = float2x2(co, si, -si, co);
    float s = 14.2;

    float gain = 0.44;
    float2 aPos = abs2d(pos) * 0.0;

    for (float i = 0.0; i < OC; i++) {
        pos = mul(pos, rotMat(D2R * 30.0));

        float tm = (sin(time) * 0.5 + 0.5) * 0.2 + time * 0.8;
        q = pos * s + tm;
        q = pos * s + aPos + tm;
        q = cos(q);
        q = mul(q, ma);
        result += sin1d(dot(q, float2(0.3, 0.3))) * gain;

        s *= 1.07;
        aPos += cos(smoothstep(0.0, 0.15, q));
        aPos = mul(aPos, rotMat(D2R * 1.0));
        aPos *= 1.232;
    }

    result = pow(result, 4.504);
    return clamp(RGB / abs1d(dot(q, float2(-0.240, 0.000))) * 0.5 / result, (float3)0.0, (float3)1.0);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float2 uv = (fragCoord - 0.5 * resolution.xy) / resolution.y;
    float2 uv2 = (fragCoord - 0.5 * resolution.xy) / resolution.y;
    float2 uv3 = (fragCoord - 0.5 * resolution.xy) / resolution.y;
    uv3.x += 0.5;
    uv3.y += 0.2;
    float3 col = (float3)0.0;

    uv2.x += 0.1 * cos(time);
    uv2.y += 0.1 * sin(time);
    uv.y *= resolution.y / resolution.x;
    float3 dir = float3(uv * ZOOM, 1.0);
    float2 uPos = (fragCoord.xy / resolution.y);
    uPos -= float2((resolution.x / resolution.y) / 2.0, 0.5);

    float multiplier = 0.0005;
    static const float step2 = 0.006;
    static const float loop_count = 80.0;
    static const float timeSCale = 0.5;

    float3 blueGodColor = (float3)0.0;
    for (float i = 1.0; i < loop_count; i++) {
        float t = time * timeSCale - step2 * i * i;
        float2 pt = float2(0.75 * sin(t), 0.5 * sin(t));
        pt += float2(0.75 * cos(t * 4.0), 0.5 * sin(t * 3.0));
        pt /= 11.0 * sin(i);
        float componentColor = multiplier / ((uPos.x - pt.x) * (uPos.x - pt.x) + (uPos.y - pt.y) * (uPos.y - pt.y)) / i;
        blueGodColor += float3(componentColor / 3.0, componentColor / 3.0, componentColor);
    }

    float3 color = (float3)0.0;
    color += pow(blueGodColor, float3(0.1, 0.3, 0.8));

    float3 from = float3(1.0, 0.5, 0.5);
    float2 uv0 = uv;
    float3 col2 = (float3)0.0;
    float2 st = (fragCoord / resolution.xy);
    st.x = ((st.x - 0.5) * (resolution.x / resolution.y)) + 0.5;

    float t2 = time * 0.1 + ((0.25 + 0.05 * sin(time * 0.1)) / (length(uv3.xy) + 0.57)) * 25.2;
    float si = sin(t2);
    float co = cos(t2);
    float2x2 ma = float2x2(co, si, -si, co);

    st *= 3.0;

    float3 rgb = float3(0.30, 0.8, 1.200);

    float2 pix = 1.0 / resolution.xy;
    float2 aaST = st + pix * float2(1.5, 0.5);
    col2 += Oilnoise(aaST, rgb);

    float scale = 5.0;
    uv *= scale;
    uv2 *= 2.0 * (cos(time * 2.0) - 2.5);
    float anim = sin(time * 12.0) * 0.1 + 1.0;

    // Idea from IQ — nested fbm
    float fbm1 = fbm(uv);
    float fbm2 = fbm(uv + fbm1);
    float fbm3 = fbm(uv + fbm2);
    col += 3.0 * (fbm3 - 0.4) * (1.5 - length(uv0));

    col *= float3(0.9, 0.9, 1.0);
    float s = 0.1, fade = 1.0;
    float3 v = (float3)0.0;
    for (int r = 0; r < VOLSTEPS; r++) {
        float3 p = from + s * dir + 0.5;

        p = abs((float3)TILE - fmod(p, (float3)(TILE * 2.0)));
        float pa, a;
        pa = 0.0;
        a = 0.0;
        for (int i = 0; i < ITERATIONS; i++) {
            p = abs(p) / dot(p, p) - FORMUPARAM;
            float cosT = cos(time * 0.05);
            float sinT = sin(time * 0.05);
            p.xy = mul(p.xy, float2x2(cosT, sinT, -sinT, cosT));
            a += abs(length(p) - pa);
            pa = length(p);
        }
        float dm = max(0.0, DARKMATTER - a * a * 0.001);
        a *= a * a;
        if (r > 6) fade *= 1.2 - dm;
        v += fade;
        v += float3(s, s * s, s * s * s * s) * a * BRIGHTNESS * fade;
        fade *= DISTFADING;
        s += STEPSIZE;
    }
    v = lerp((float3)length(v), v, SATURATION);

    float3 finalColor = v * 0.03 + col + col2 + color * 2.0;
    finalColor += happy_star(mul(uv3, ma), anim) * float3(0.15 + 0.1 * cos(time), 0.2, 0.15 + 0.1 * sin(time)) * 0.3;
    finalColor += happy_star(uv2, anim) * float3(0.25 + 0.1 * cos(time), 0.2 + 0.1 * sin(time), 0.15) * 0.5;
    finalColor *= happy_star(uv2, anim) * float3(0.25 + 0.1 * cos(time), 0.2 + 0.1 * sin(time), 0.15) * 2.0;

    // Darken/desaturate post-processing
    float lum = dot(finalColor, float3(0.299, 0.587, 0.114));
    finalColor = lerp(finalColor, (float3)lum, desaturate);
    finalColor = finalColor * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a_out = max(finalColor.r, max(finalColor.g, finalColor.b));
    return float4(finalColor * a_out, a_out);
}
