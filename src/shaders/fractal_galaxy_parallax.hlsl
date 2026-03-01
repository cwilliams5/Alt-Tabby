// Fractal Galaxy Parallax — converted from Shadertoy Dl2XWD
// Original by Birdmachine (CC BY-NC-SA 3.0)
// Parallax scrolling fractal galaxy with stars

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

// Synthetic beat replacement for audio channels
float getFreq(float band) {
    return 0.4 + 0.15 * sin(time * (0.8 + band * 0.3))
               + 0.1 * sin(time * (1.3 + band * 0.7));
}

float field(float3 p, float s) {
    float strength = 7.0 + 0.03 * log(1.e-6 + frac(sin(time) * 4373.11));
    float accum = s / 4.0;
    float prev = 0.0;
    float tw = 0.0;
    for (int i = 0; i < 26; ++i) {
        float mag = dot(p, p);
        p = abs(p) / mag + float3(-0.5, -0.4, -1.5);
        float w = exp(-(float)i / 7.0);
        accum += w * exp(-strength * pow(abs(mag - prev), 2.2));
        tw += w;
        prev = mag;
    }
    return max(0.0, 5.0 * accum / tw - 0.7);
}

// Less iterations for second layer
float field2(float3 p, float s) {
    float strength = 7.0 + 0.03 * log(1.e-6 + frac(sin(time) * 4373.11));
    float accum = s / 4.0;
    float prev = 0.0;
    float tw = 0.0;
    for (int i = 0; i < 18; ++i) {
        float mag = dot(p, p);
        p = abs(p) / mag + float3(-0.5, -0.4, -1.5);
        float w = exp(-(float)i / 7.0);
        accum += w * exp(-strength * pow(abs(mag - prev), 2.2));
        tw += w;
        prev = mag;
    }
    return max(0.0, 5.0 * accum / tw - 0.7);
}

float3 nrand3(float2 co) {
    float3 a = frac(cos(co.x * 8.3e-3 + co.y) * float3(1.3e5, 4.7e5, 2.9e5));
    float3 b = frac(sin(co.x * 0.3e-3 + co.y) * float3(8.1e5, 1.0e5, 0.1e5));
    float3 c = lerp(a, b, 0.5);
    return c;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 uv = 2.0 * fragCoord.xy / resolution.xy - 1.0;
    float2 uvs = uv * resolution.xy / max(resolution.x, resolution.y);
    float3 p = float3(uvs / 4.0, 0.0) + float3(1.0, -1.3, 0.0);
    p += 0.2 * float3(sin(time / 16.0), sin(time / 12.0), sin(time / 128.0));

    // Synthetic frequency bands (replaces audio input)
    float freqs0 = getFreq(0.0);
    float freqs1 = getFreq(1.0);
    float freqs2 = getFreq(2.0);
    float freqs3 = getFreq(3.0);

    float t = field(p, freqs2);
    float v = (1.0 - exp((abs(uv.x) - 1.0) * 6.0)) * (1.0 - exp((abs(uv.y) - 1.0) * 6.0));

    // Second Layer
    float3 p2 = float3(uvs / (4.0 + sin(time * 0.11) * 0.2 + 0.2 + sin(time * 0.15) * 0.3 + 0.4), 1.5) + float3(2.0, -1.3, -1.0);
    p2 += 0.25 * float3(sin(time / 16.0), sin(time / 12.0), sin(time / 128.0));
    float t2 = field2(p2, freqs3);
    float4 c2 = lerp(0.4, 1.0, v) * float4(1.3 * t2 * t2 * t2, 1.8 * t2 * t2, t2 * freqs0, t2);

    // Stars
    float2 seed = p.xy * 2.0;
    seed = floor(seed * resolution.x);
    float3 rnd = nrand3(seed);
    float4 starcolor = (float4)pow(rnd.y, 40.0);

    // Second layer stars
    float2 seed2 = p2.xy * 2.0;
    seed2 = floor(seed2 * resolution.x);
    float3 rnd2 = nrand3(seed2);
    starcolor += (float4)pow(rnd2.y, 40.0);

    float4 col = lerp(freqs3 - 0.3, 1.0, v) * float4(1.5 * freqs2 * t * t * t, 1.2 * freqs1 * t * t, freqs3 * t, 1.0) + c2 + starcolor;

    float3 color = col.rgb;

    // Post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(color.r, max(color.g, color.b));
    return float4(color * a, a);
}
