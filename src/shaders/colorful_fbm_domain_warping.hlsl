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

// GLSL-compatible mod (always positive)
float glsl_mod(float x, float y) { return x - y * floor(x / y); }
float3 glsl_mod3(float3 x, float y) { return x - y * floor(x / y); }

float random(in float2 st) {
    return frac(sin(dot(st.xy,
                        float2(12.9898, 78.233))) *
                43758.5453123);
}

float noise(in float2 st) {
    float2 i = floor(st);
    float2 f = frac(st);

    float a = random(i);
    float b = random(i + float2(1.0, 0.0));
    float c = random(i + float2(0.0, 1.0));
    float d = random(i + float2(1.0, 1.0));

    float2 u = f * f * (3.0 - 2.0 * f);

    return lerp(a, b, u.x) +
        (c - a) * u.y * (1.0 - u.x) +
        (d - b) * u.x * u.y;
}

#define OCTAVES 16

float fbm(in float2 st) {
    float value = 0.0;
    float amplitude = 1.0;
    float frequency = 2.0;

    for (int i = 0; i < OCTAVES; i++) {
        value += amplitude * noise(st);
        st *= 3.0;
        amplitude *= 0.5;
    }
    return value;
}

float fbmWarp2(in float2 st, out float2 q, out float2 r) {
    q.x = fbm(st + float2(0.0, 0.0));
    q.y = fbm(st + float2(5.2, 1.3));

    r.x = fbm(st + 4.0 * q + float2(1.7, 9.2) + 0.7 * time);
    r.y = fbm(st + 4.0 * q + float2(8.3, 2.8) + 0.7 * time);

    return fbm(st + 4.0 * r);
}

float3 hsb2rgb(in float3 c) {
    float3 rgb = clamp(abs(glsl_mod3(c.x * 6.0 + float3(0.0, 4.0, 2.0),
                                     6.0) - 3.0) - 1.0,
                       0.0,
                       1.0);
    rgb = rgb * rgb * (3.0 - 2.0 * rgb);
    return c.z * lerp((float3)1.0, rgb, c.y);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 st = fragCoord.xy / resolution.xy;
    st.x *= resolution.x / resolution.y;

    float3 color = (float3)0.0;
    float2 q = (float2)0.0;
    float2 r = (float2)0.0;
    float height = fbmWarp2(st * 10.0, q, r);

    color += hsb2rgb(float3(0.3, 1.0 - (0.5 * sin(time) + 0.5), height));
    color = lerp(color, hsb2rgb(float3(0.0, q.x, 0.2 + (0.2 * sin(0.7 * time) + 0.2))), length(q));
    color = lerp(color, hsb2rgb(float3(0.58, r.x, 0.0 + (0.25 * sin(0.3 * time) + 0.25))), r.y);

    // Darken/desaturate post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float a = max(color.r, max(color.g, color.b));
    return float4(color * a, a);
}