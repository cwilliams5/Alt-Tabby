// Disco Inferno by orblivius
// Ported from https://www.shadertoy.com/view/MXdSzl
// Fork of star shine by nayk (https://shadertoy.com/view/MXdSzX)
// Cubemap iChannel0 replaced with procedural environment map

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

#define TAU 6.283185
#define PI 3.14159265359

#define iterations 17
#define formuparam 0.53

#define volsteps 20
#define stepsize 0.1

#define zoom 0.800
#define tile 0.850

#define brightness 0.0015
#define darkmatter_val 0.300
#define distfading 0.730
#define saturation_val 0.850

#define SIZE 2.8
#define RADIUS 0.5
#define INNER_FADE 0.04
#define OUTER_FADE 0.01
#define SPEED_VAL 0.21
#define BORDER 0.21

float2x2 rot2(float a) {
    float4 c = cos(a + float4(0, 11, 33, 0));
    return float2x2(c.x, c.y, c.z, c.w);
}

float3 glsl_mod(float3 x, float3 y) {
    return x - y * floor(x / y);
}

// Procedural environment map replacing cubemap iChannel0
float4 envMap(float3 dir) {
    float3 col = float3(0.2, 0.1, 0.3);
    col += 0.3 * float3(
        0.5 + 0.5 * sin(dir.x * 3.0 + time),
        0.5 + 0.5 * sin(dir.y * 3.0 + time * 1.3),
        0.5 + 0.5 * sin(dir.z * 3.0 + time * 0.7));
    return float4(col, 1.0);
}

float aafi(float2 p) {
    float fi = atan2(p.y, p.x);
    fi += step(p.y, 0.0) * TAU;
    return fi;
}

float2 lonlat(float3 p) {
    float lon = aafi(p.xy) / TAU;
    float lat = aafi(float2(p.z, length(p.xy))) / PI;
    return float2(lon, lat);
}

float3 pointOnSphere(float2 ll, float r) {
    float f1 = ll.x * TAU;
    float f2 = ll.y * PI;
    float z = r * cos(f2);
    float d = abs(r * sin(f2));
    float x = d * cos(f1);
    float y = d * sin(f1);
    return float3(x, y, z);
}

float sdDiscoBall(float3 pos, float r) {
    float2 ll = lonlat(pos);
    float n = 15.0;
    float n2 = 30.0;
    ll.x = floor(ll.x * n2);
    ll.y = floor(ll.y * n);
    float3 a = pointOnSphere(float2(ll.x / n2, ll.y / n), r);
    float3 b = pointOnSphere(float2(ll.x / n2, (ll.y + 1.0) / n), r);
    float3 c = pointOnSphere(float2((ll.x + 1.0) / n2, (ll.y + 1.0) / n), r);
    float d = dot(normalize(cross(b - a, c - a)), pos - a);
    return abs(d * 0.9);
}

float sdf(float3 pos) {
    return sdDiscoBall(pos * 0.2, 0.05);
}

float random_val(float2 p) {
    float3 p3 = frac(float3(p.x, p.y, p.x) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.x + p3.y) * p3.z);
}

float noise_val(float2 st) {
    float2 i = floor(st);
    float2 f = frac(st);
    float a = random_val(i);
    float b = random_val(i + float2(1.0, 0.0));
    float c = random_val(i + float2(0.0, 1.0));
    float d = random_val(i + float2(1.0, 1.0));
    float2 u = f * f * (3.0 - 2.0 * f);
    return lerp(a, b, u.x) +
           (c - a) * u.y * (1.0 - u.x) +
           (d - b) * u.x * u.y;
}

float light_val(float2 pos, float size, float radius, float inner_fade, float outer_fade) {
    float len = length(pos / size);
    return pow(clamp(1.0 - pow(clamp(len - radius, 0.0, 1.0), 1.0 / inner_fade), 0.0, 1.0), 1.0 / outer_fade);
}

float flare(float angle, float alpha, float t) {
    float n = noise_val(float2(t + 0.5 + abs(angle) + pow(alpha, 0.6),
                               t - abs(angle) + pow(alpha + 0.1, 0.6)) * 7.0);
    float sp = 15.0 + sin(t * 2.0 + n * 4.0 + angle * 20.0 + alpha * n) * (0.8 + alpha * 0.6 * n);
    float ro = sin(angle * 20.0 + sin(angle * 15.0 + alpha * 4.0 + t * 30.0 + n * 5.0 + alpha * 4.0))
             * (0.5 + alpha * 1.5);
    float g = pow((2.0 + sin(sp + n * 1.5 * alpha + ro) * 1.4) * n * 4.0, n * (1.5 - 0.8 * alpha));
    g *= alpha * alpha * alpha * 0.5;
    g += alpha * 0.7 + g * g * g;
    return g;
}

float happy_star(float2 uv, float anim) {
    uv = abs(uv);
    float2 pos = min(uv.xy / uv.yx, anim);
    float p = 2.0 - pos.x - pos.y;
    return (2.0 + p * (p * p - 1.5)) / (uv.x + uv.y);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 uv = (fragCoord - resolution * 0.5) / resolution.y;
    float f = 0.0;
    float f2 = 0.0;

    float3 dir = float3(uv * zoom, 1.0);
    float3 from_pt = float3(1.0, 0.5, 0.5);

    // Volumetric star field rendering
    float s2 = 0.1;
    float fade = 1.0;
    float3 v = (float3)0;
    [loop]
    for (int r = 0; r < volsteps; r++) {
        float3 p = from_pt + s2 * dir * 0.5;
        p = abs((float3)tile - glsl_mod(p, (float3)(tile * 2.0)));
        float pa = 0.0;
        float a = 0.0;
        [loop]
        for (int i = 0; i < iterations; i++) {
            p = abs(p) / dot(p, p) - formuparam;
            float ct = cos(time * 0.05);
            float st2 = sin(time * 0.05);
            p.xy = mul(float2x2(ct, st2, -st2, ct), p.xy);
            a += abs(length(p) - pa);
            pa = length(p);
        }
        float dm = max(0.0, darkmatter_val - a * a * 0.001);
        a *= a * a;
        if (r > 6) fade *= 1.0 - dm;
        v += fade;
        v += float3(s2, s2 * s2, s2 * s2 * s2 * s2) * a * brightness * fade;
        fade *= distfading;
        s2 += stepsize;
    }
    v = lerp((float3)length(v), v, saturation_val);
    uv *= 0.5;

    // Flare effects
    float t = time * SPEED_VAL;
    float alpha = light_val(uv, SIZE, RADIUS, INNER_FADE, OUTER_FADE);
    float angle = atan2(uv.x, uv.y);
    float l = length(uv * v.xy * 0.01);
    if (l < BORDER) {
        t *= 0.8;
        alpha = 1.0 - pow((BORDER - l) / BORDER, 0.22) * 0.7;
        alpha = clamp(alpha - light_val(uv, 0.02, 0.0, 0.3, 0.7) * 0.55, 0.0, 1.0);
        f = flare(angle, alpha, -t * 0.5 + alpha);
        f2 = flare(angle, alpha * 1.2, -t + alpha * 0.5 + 0.38134);
    }

    // Disco ball raymarching
    float3 R = float3(resolution, 1.0);
    float3 e = float3(1e-3, 0, 0);
    float3 N, D, p, q;
    D = normalize(float3(fragCoord, -18.0 * R.y) - R);
    p = float3(1.5, 0.85, 30.5);
    // Demo mode camera (no mouse)
    float3 C = 3.0 * cos(0.3 * time + float3(0, 11, 0));
    p.yz = mul(rot2(-C.y), p.yz);
    p.xz = mul(rot2(-C.x - 1.57), p.xz);
    D.yz = mul(rot2(-C.y), D.yz);
    D.xz = mul(rot2(-C.x - 1.57), D.xz);

    float4 O = (float4)1;
    q = p;
    [loop]
    while (O.x > 0.0 && t > 0.01) {
        q = p;
        t = min(t, sdf(q));
        p += 0.5 * t * D;
        O -= 0.01;
    }

    N = float3(sdf(q + e), sdf(q + e.yxy), sdf(q + e.yyx)) - t;
    if (O.x < 0.0) {
        O = 0.5 * envMap(D);
    } else {
        O += envMap(reflect(D, N / length(N)));
    }

    f = flare(angle, alpha, t) * 1.3;

    O += float4(
        f * (1.0 + sin(angle - t * 4.0) * 0.3) + f2 * f2 * f2,
        f * alpha + f2 * f2 * 2.0,
        f * alpha * 0.5 + f2 * (1.0 + sin(angle + t * 4.0) * 0.3),
        1.0);

    // Star overlay
    uv *= 2.0 * (cos(time * 2.0) - 2.5);
    float anim = sin(time * 12.0) * 0.1 + 1.0;
    O *= 0.5 * float4(happy_star(uv, anim) * float3(0.55, 0.5, 1.15), 1.0);
    O += 0.5 * float4(happy_star(uv, anim) * float3(0.55, 0.5, 1.15) * 0.01, 1.0);

    float3 color = O.rgb;

    // Post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, (float3)lum, desaturate);
    color *= 1.0 - darken;

    // Alpha from brightness, premultiply
    float a = max(color.r, max(color.g, color.b));
    return float4(color * a, a);
}
