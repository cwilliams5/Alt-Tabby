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

// divisions of grid
static const float repeats = 30.0;

// number of layers
static const float layers = 21.0;

// star colours
static const float3 blue_c = float3(51.0, 64.0, 195.0) / 255.0;
static const float3 cyan_c = float3(117.0, 250.0, 254.0) / 255.0;
static const float3 white_c = float3(255.0, 255.0, 255.0) / 255.0;
static const float3 yellow_c = float3(251.0, 245.0, 44.0) / 255.0;
static const float3 red_c = float3(247.0, 2.0, 20.0) / 255.0;

// spectrum function
float3 spectrum(float2 pos) {
    pos.x *= 4.0;
    float3 outCol = (float3)0;
    if (pos.x > 0.0) {
        outCol = lerp(blue_c, cyan_c, frac(pos.x));
    }
    if (pos.x > 1.0) {
        outCol = lerp(cyan_c, white_c, frac(pos.x));
    }
    if (pos.x > 2.0) {
        outCol = lerp(white_c, yellow_c, frac(pos.x));
    }
    if (pos.x > 3.0) {
        outCol = lerp(yellow_c, red_c, frac(pos.x));
    }

    return 1.0 - (pos.y * (1.0 - outCol));
}

float N21(float2 p) {
    p = frac(p * float2(233.34, 851.73));
    p += dot(p, p + 23.45);
    return frac(p.x * p.y);
}

float2 N22(float2 p) {
    float n = N21(p);
    return float2(n, N21(p + n));
}

float2x2 scale2(float2 _scale) {
    return float2x2(_scale.x, 0.0,
                    0.0, _scale.y);
}

// 2D Noise based on Morgan McGuire @morgan3d
float noise(float2 st) {
    float2 i = floor(st);
    float2 f = frac(st);

    // Four corners in 2D of a tile
    float a = N21(i);
    float b = N21(i + float2(1.0, 0.0));
    float c = N21(i + float2(0.0, 1.0));
    float d = N21(i + float2(1.0, 1.0));

    // Cubic Hermite Curve
    float2 u = f * f * (3.0 - 2.0 * f);

    // Mix 4 corners percentages
    return lerp(a, b, u.x) +
            (c - a) * u.y * (1.0 - u.x) +
            (d - b) * u.x * u.y;
}

float perlin2(float2 uv, int octaves, float pscale) {
    float col = 1.0;
    float initScale = 4.0;
    for (int l = 0; l < octaves; l++) {
        float val = noise(uv * initScale);
        if (col <= 0.01) {
            col = 0.0;
            break;
        }
        val -= 0.01;
        val *= 0.5;
        col *= val;
        initScale *= pscale;
    }
    return col;
}

float3 stars(float2 uv, float offset) {

    float timeScale = -(time + offset) / layers;

    float trans = frac(timeScale);

    float newRnd = floor(timeScale);

    float3 col = (float3)0;

    // translate uv then scale for center
    uv -= float2(0.5, 0.5);
    uv = mul(scale2(float2(trans, trans)), uv);
    uv += float2(0.5, 0.5);

    // create square aspect ratio
    uv.x *= resolution.x / resolution.y;

    // add nebula colours
    float colR = N21(float2(offset + newRnd, offset + newRnd));
    float colB = N21(float2(offset + newRnd * 123.0, offset + newRnd * 123.0));

    // generate perlin noise nebula on every third layer
    if (fmod(offset, 3.0) == 0.0) {
        float perl = perlin2(uv + offset + newRnd, 3, 2.0);
        col += float3(perl * colR, perl * 0.1, perl * colB);
    }

    // create boxes
    uv *= repeats;

    // get position
    float2 ipos = floor(uv);

    // return uv as 0 to 1
    uv = frac(uv);

    // calculate random xy and size
    float2 rndXY = N22(newRnd + ipos * (offset + 1.0)) * 0.9 + 0.05;
    float rndSize = N21(ipos) * 100.0 + 200.0;

    float2 j = (rndXY - uv) * rndSize;
    float sparkle = 1.0 / dot(j, j);

    col += spectrum(frac(rndXY * newRnd * ipos)) * float3(sparkle, sparkle, sparkle);

    col *= smoothstep(1.0, 0.8, trans);
    col *= smoothstep(0.0, 0.1, trans);
    return col;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    // Normalized pixel coordinates (from 0 to 1)
    float2 uv = fragCoord / resolution;

    float3 color = (float3)0;

    for (float i = 0.0; i < layers; i++) {
        color += stars(uv, i);
    }

    // Darken/desaturate post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(color.r, max(color.g, color.b));
    return float4(color * a, a);
}
