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

#define SIZE 3.8
#define RADIUS 0.15
#define INNER_FADE 0.08
#define OUTER_FADE 0.02
#define SPEED 0.21
#define BORDER 0.21

#define iterations 17
#define formuparam 0.53

#define volsteps 20
#define stepsize 0.1

#define zoom_val 0.800
#define tile_val 0.850
#define speed_val 0.010

#define brightness 0.0015
#define darkmatter 0.300
#define distfading 0.730
#define saturation_val 0.850

// GLSL mod: x - y * floor(x/y) (always positive for positive y)
float glsl_mod(float x, float y) { return x - y * floor(x / y); }
float2 glsl_mod2(float2 x, float2 y) { return x - y * floor(x / y); }
float3 glsl_mod3(float3 x, float3 y) { return x - y * floor(x / y); }

float random_val(in float2 p) {
    float3 p3 = frac(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.x + p3.y) * p3.z);
}

float noise_val(in float2 _st) {
    float2 i = floor(_st);
    float2 f = frac(_st);

    float a = random_val(i);
    float b = random_val(i + float2(1.0, 0.0));
    float c = random_val(i + float2(0.0, 1.0));
    float d = random_val(i + float2(1.0, 1.0));

    float2 u = f * f * (3.0 - 2.0 * f);

    return lerp(a, b, u.x) +
            (c - a) * u.y * (1.0 - u.x) +
            (d - b) * u.x * u.y;
}

float light_val(in float2 pos, in float size, in float radius, in float inner_fade, in float outer_fade) {
    float len = length(pos / size);
    return pow(clamp((1.0 - pow(clamp(len - radius, 0.0, 1.0), 1.0 / inner_fade)), 0.0, 1.0), 1.0 / outer_fade);
}

float flare(in float angle, in float alpha, in float t_val) {
    float t = t_val;
    float n = noise_val(float2(t + 0.5 + abs(angle) + pow(alpha, 0.6), t - abs(angle) + pow(alpha + 0.1, 0.6)) * 7.0);

    float split_val = (15.0 + sin(t * 2.0 + n * 4.0 + angle * 20.0 + alpha * 1.0 * n) * (0.3 + 0.5 + alpha * 0.6 * n));

    float rotate = sin(angle * 20.0 + sin(angle * 15.0 + alpha * 4.0 + t * 30.0 + n * 5.0 + alpha * 4.0)) * (0.5 + alpha * 1.5);

    float g = pow((2.0 + sin(split_val + n * 1.5 * alpha + rotate) * 1.4) * n * 4.0, n * (1.5 - 0.8 * alpha));

    g *= alpha * alpha * alpha * 0.5;
    g += alpha * 0.7 + g * g * g;
    return g;
}

float2 project_val(float2 position, float2 a, float2 b) {
    float2 q = b - a;
    float u = dot(position - a, q) / dot(q, q);
    u = clamp(u, 0.0, 1.0);
    return lerp(a, b, u);
}

float segment_val(float2 position, float2 a, float2 b) {
    return distance(position, project_val(position, a, b));
}

float contour(float x) {
    return 1.0 - clamp(x * 2048.0, 0.0, 1.0);
}

float line_val(float2 p, float2 a, float2 b) {
    return contour(segment_val(p, a, b));
}

float2 neighbor_offset(float i) {
    float c = abs(i - 2.0);
    float s = abs(i - 4.0);
    return float2(c > 1.0 ? (c > 2.0 ? 1.0 : 0.0) : -1.0, s > 1.0 ? (s > 2.0 ? -1.0 : 0.0) : 1.0);
}

float happy_star(float2 uv, float anim) {
    uv = abs(uv);
    float2 pos = min(uv.xy / uv.yx, (float2)anim);
    float p = (2.0 - pos.x - pos.y);
    return (2.0 + p * (p * p - 1.5)) / (uv.x + uv.y);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 uv = (fragCoord.xy - resolution.xy * 0.5) / resolution.y;
    float f = 0.0;
    float f2 = 0.0;

    float3 dir = float3(uv * zoom_val, 1.0);

    float3 from_val = float3(1.0, 0.5, 0.5);

    // Volumetric rendering
    float s2 = 0.1, fade = 1.0;
    float3 v = (float3)0.0;
    for (int r = 0; r < volsteps; r++) {
        float3 p = from_val + s2 * dir * 0.5;
        p = abs((float3)tile_val - glsl_mod3(p, (float3)(tile_val * 2.0)));
        float pa, a;
        pa = 0.0;
        a = 0.0;
        float cos_t = cos(time * 0.05);
        float sin_t = sin(time * 0.05);
        for (int i = 0; i < iterations; i++) {
            p = abs(p) / dot(p, p) - formuparam;
            // mat2 rotation expanded
            float2 rotated = float2(
                p.x * cos_t + p.y * sin_t,
                p.x * (-sin_t) + p.y * cos_t);
            p.x = rotated.x;
            p.y = rotated.y;
            a += abs(length(p) - pa);
            pa = length(p);
        }
        float dm = max(0.0, darkmatter - a * a * 0.001);
        a *= a * a;
        if (r > 6) fade *= 1.0 - dm;

        v += fade;
        v += float3(s2, s2 * s2, s2 * s2 * s2 * s2) * a * brightness * fade;
        fade *= distfading;
        s2 += stepsize;
    }
    v = lerp((float3)length(v), v, saturation_val);
    uv *= 0.5;

    float4 result = float4(0.0, 0.0, 0.0, 1.0);

    float t2 = abs(sin(time * 0.1));
    float c = cos(t2);
    float s = sin(t2);
    // mat2 rm = (c, s, -s, c)
    float2 position = float2(0.0, 0.0);
    for (float i = 0.0; i < 256.0; i++) {
        float2 rm_pos = float2(
            position.x * c + position.y * s,
            position.x * (-s) + position.y * c);
        float2 sample2 = neighbor_offset(glsl_mod(i, 8.0)) / resolution.y + rm_pos;
        result += line_val(uv, position, sample2);
        position = sample2;
    }

    float t = time * SPEED;
    float alpha = light_val(uv, SIZE, RADIUS, INNER_FADE, OUTER_FADE);
    float angle = atan2(uv.x, uv.y);
    float n = noise_val(float2(uv.x * 10.0 + time, uv.y * 20.0 + time));

    float l = length(uv * v.xy * 0.01);
    if (l < BORDER) {
        t *= 0.8;
        alpha = (1.0 - pow(((BORDER - l) / BORDER), 0.22) * 0.7);
        alpha = clamp(alpha - light_val(uv, 0.02, 0.0, 0.3, 0.7) * 0.55, 0.0, 1.0);
        f = flare(angle * 1.0, alpha, -t * 0.5 + alpha);
        f2 = flare(angle * 1.0, alpha * 1.2, ((-t + alpha * 0.5 + 0.38134)));
    }
    f = flare(angle, alpha, t) * 1.3;

    float4 fragColor = float4(float3(f * (1.0 + sin(angle - t * 4.0) * 0.3) + f2 * f2 * f2, f * alpha + f2 * f2 * 2.0, f * alpha * 0.5 + f2 * (1.0 + sin(angle + t * 4.0) * 0.3)), 1.0);

    uv *= 2.0 * (cos(time * 2.0) - 2.5);
    float anim = sin(time * 12.0) * 0.1 + 1.0;
    fragColor *= float4(happy_star(uv, anim) * float3(0.55, 0.5, 1.15), 1.0);
    fragColor += float4(happy_star(uv, anim) * float3(0.55, 0.5, 1.15) * 0.01, 1.0);

    // Alpha from brightness + premultiply
    float3 color = fragColor.rgb;
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);
    float a_val = max(color.r, max(color.g, color.b));
    return float4(color * a_val, a_val);
}
