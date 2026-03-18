// Fractal Galaxy Parallax — converted from Shadertoy Dl2XWD
// Original by Birdmachine (CC BY-NC-SA 3.0)
// Parallax scrolling fractal galaxy with stars

// Synthetic beat replacement for audio channels
float getFreq(float band) {
    return 0.4 + 0.15 * sin(time * (0.8 + band * 0.3))
               + 0.1 * sin(time * (1.3 + band * 0.7));
}

static const float inv7 = 1.0 / 7.0;

float field(float3 p, float s, float strength) {
    float accum = s / 4.0;
    float prev = 0.0;
    float tw = 0.0;
    for (int i = 0; i < 26; ++i) {
        float mag = dot(p, p);
        p = abs(p) / mag + float3(-0.5, -0.4, -1.5);
        float w = exp(-(float)i * inv7);
        accum += w * exp(-strength * pow(abs(mag - prev), 2.2));
        tw += w;
        prev = mag;
    }
    return max(0.0, 5.0 * accum / tw - 0.7);
}

// Less iterations for second layer
float field2(float3 p, float s, float strength) {
    float accum = s / 4.0;
    float prev = 0.0;
    float tw = 0.0;
    for (int i = 0; i < 18; ++i) {
        float mag = dot(p, p);
        p = abs(p) / mag + float3(-0.5, -0.4, -1.5);
        float w = exp(-(float)i * inv7);
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
    float3 timeOsc = float3(sin(time * 0.0625), sin(time * 0.083333), sin(time * 0.0078125));
    float3 p = float3(uvs / 4.0, 0.0) + float3(1.0, -1.3, 0.0);
    p += 0.2 * timeOsc;

    // Synthetic frequency bands (replaces audio input)
    float freqs0 = getFreq(0.0);
    float freqs1 = getFreq(1.0);
    float freqs2 = getFreq(2.0);
    float freqs3 = getFreq(3.0);

    float strength = 7.0 + 0.03 * log(1.e-6 + frac(sin(time) * 4373.11));
    float t = field(p, freqs2, strength);
    float v = (1.0 - exp((abs(uv.x) - 1.0) * 6.0)) * (1.0 - exp((abs(uv.y) - 1.0) * 6.0));

    // Second Layer
    float3 p2 = float3(uvs / (4.0 + sin(time * 0.11) * 0.2 + 0.2 + sin(time * 0.15) * 0.3 + 0.4), 1.5) + float3(2.0, -1.3, -1.0);
    p2 += 0.25 * timeOsc;
    float t2 = field2(p2, freqs3, strength);
    float4 c2 = lerp(0.4, 1.0, v) * float4(1.3 * t2 * t2 * t2, 1.8 * t2 * t2, t2 * freqs0, t2);

    // Stars
    float2 seed = p.xy * 2.0;
    seed = floor(seed * resolution.x);
    float3 rnd = nrand3(seed);
    float _y2 = rnd.y*rnd.y; float _y4 = _y2*_y2; float _y8 = _y4*_y4;
    float _y16 = _y8*_y8; float _y32 = _y16*_y16; float _y40 = _y32*_y8;
    float4 starcolor = (float4)_y40;

    // Second layer stars
    float2 seed2 = p2.xy * 2.0;
    seed2 = floor(seed2 * resolution.x);
    float3 rnd2 = nrand3(seed2);
    float _r2 = rnd2.y*rnd2.y; float _r4 = _r2*_r2; float _r8 = _r4*_r4;
    float _r16 = _r8*_r8; float _r32 = _r16*_r16; float _r40 = _r32*_r8;
    starcolor += (float4)_r40;

    float4 col = lerp(freqs3 - 0.3, 1.0, v) * float4(1.5 * freqs2 * t * t * t, 1.2 * freqs1 * t * t, freqs3 * t, 1.0) + c2 + starcolor;

    float3 color = col.rgb;

    return AT_PostProcess(color);
}
