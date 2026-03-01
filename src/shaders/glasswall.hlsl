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

// GLSL mod: always returns positive remainder for positive divisor
float glsl_mod(float x, float y) { return x - y * floor(x / y); }

float random(in float2 _st) {
    return frac(sin(dot(_st.xy, float2(0.89, -0.90))) * 757.153);
}

// Based on Morgan McGuire @morgan3d
// https://www.shadertoy.com/view/4dS3Wd
float noise(in float2 _st) {
    float2 i = floor(_st);
    float2 f = frac(_st);

    // Four corners in 2D of a tile
    float a = random(i);
    float b = random(i + float2(1.0, 0.0));
    float c = random(i + float2(0.0, 1.0));
    float d = random(i + float2(1.0, 1.0));

    float2 u = f * f * (3.0 - 2.0 * f);

    return lerp(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

float fbm(in float2 _st) {
    float v = sin(time * 0.2) * 0.15;
    float a = 0.8;
    float2 shift = (float2)100.0;
    // Rotate to reduce axial bias
    // GLSL mat2 is column-major; HLSL float2x2 is row-major — transpose constructor args
    float2x2 rot = float2x2(cos(0.5), -sin(0.5),
                             sin(1.0),  acos(0.5));
    for (int i = 0; i < 5; ++i) {
        v += a * noise(_st);
        _st = mul(rot, _st) * 2.0 + shift;
        a *= 0.01;
    }
    return v;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float2 st = (2.0 * fragCoord - resolution) / min(resolution.x, resolution.y) * 1.7;

    float2 co = st;
    float len;
    for (int i = 0; i < 3; i++) {
        len = length(co);
        co.x += sin(co.y + time * 0.620) * 0.1;
        co.y += cos(co.x + time * 0.164) * 0.1;
    }
    len -= 3.0;

    float3 col = (float3)0.0;

    float2 q = (float2)0.0;
    q.x = fbm(st + 1.0);
    q.y = fbm(st + float2(-0.45, 0.65));

    float2 r = (float2)0.0;
    r.x = fbm(st + q + float2(0.57, 0.52) + 0.5 * time);
    r.y = fbm(st + q + float2(0.34, -0.57) + 0.4 * time);

    for (float j = 0.0; j < 3.0; j++) {
        r += 1.0 / abs(glsl_mod(st.y, 1.2 * j) * 500.0) * 1.0;       // Vertical line
        r += 1.0 / abs(glsl_mod(st.x, 0.3 * j) * 500.0) * 1.0;       // Horizontal line
        r += 1.0 / abs(glsl_mod(st.y + st.x, 0.6 * j) * 500.0) * 1.0; // Diagonal line
        r += 1.0 / abs(glsl_mod(st.y - st.x, 0.6 * j) * 500.0) * 1.0; // Diagonal line
    }
    float f = fbm(st + r);

    col = lerp(col, cos(len + float3(0.2, 0.0, -0.5)), 1.0);
    col = lerp(float3(0.730, 0.386, 0.372), float3(0.397, 0.576, 0.667), col);

    float3 color = 2.0 * (f * f * f + 0.6 * f * f + 0.5 * f) * col;

    // Post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness — premultiplied
    float a = max(color.r, max(color.g, color.b));
    return float4(color * a, a);
}