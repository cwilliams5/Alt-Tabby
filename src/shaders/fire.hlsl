// Fire Shader — after @febucci

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

float rand(float2 co) {
    return frac(sin(dot(co.xy, float2(12.9898, 78.233))) * 43758.5453);
}

float hermite(float t) {
    return t * t * (3.0 - 2.0 * t);
}

float noise(float2 co, float frequency) {
    float2 v = float2(co.x * frequency, co.y * frequency);
    float ix1 = floor(v.x);
    float iy1 = floor(v.y);
    float ix2 = floor(v.x + 1.0);
    float iy2 = floor(v.y + 1.0);
    float fx = hermite(frac(v.x));
    float fy = hermite(frac(v.y));
    float fade1 = lerp(rand(float2(ix1, iy1)), rand(float2(ix2, iy1)), fx);
    float fade2 = lerp(rand(float2(ix1, iy2)), rand(float2(ix2, iy2)), fx);
    return lerp(fade1, fade2, fy);
}

float pnoise(float2 co, float freq, int steps, float persistence) {
    float value = 0.0;
    float ampl = 1.0;
    float sum = 0.0;
    for (int i = 0; i < steps; i++) {
        sum += ampl;
        value += noise(co, freq) * ampl;
        freq *= 2.0;
        ampl *= persistence;
    }
    return value / sum;
}

float4 PSMain(PSInput input) : SV_Target {
    // Y-flip: fire rises upward
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);
    float2 uv = fragCoord.xy / resolution.xy;
    float gradient = 1.0 - uv.y;
    float gradientStep = 0.2;

    float2 pos = fragCoord.xy / resolution.x;
    pos.y -= time * 0.3125;

    float4 brighterColor = float4(1.0, 0.65, 0.1, 0.25);
    float4 darkerColor = float4(1.0, 0.0, 0.15, 0.0625);
    float4 middleColor = lerp(brighterColor, darkerColor, 0.5);

    float noiseTexel = pnoise(pos, 10.0, 5, 0.5);

    float firstStep = smoothstep(0.0, noiseTexel, gradient);
    float darkerColorStep = smoothstep(0.0, noiseTexel, gradient - gradientStep);
    float darkerColorPath = firstStep - darkerColorStep;
    float4 col = lerp(brighterColor, darkerColor, darkerColorPath);

    float middleColorStep = smoothstep(0.0, noiseTexel, gradient - 0.4);

    col = lerp(col, middleColor, darkerColorStep - middleColorStep);
    col = lerp((float4)0, col, firstStep);

    float3 color = col.rgb;

    // Post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float alpha = max(color.r, max(color.g, color.b));
    return float4(color * alpha, alpha);
}
