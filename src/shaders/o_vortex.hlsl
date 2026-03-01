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

static const int cell_amount = 2;

float2 modulo(float2 divident, float2 divisor) {
    float2 positiveDivident = fmod(divident, divisor) + divisor;
    return fmod(positiveDivident, divisor);
}

float2 random2(float2 value) {
    value = float2(dot(value, float2(127.1, 311.7)),
                   dot(value, float2(269.5, 183.3)));
    return -1.0 + 2.0 * frac(sin(value) * 43758.5453123);
}

float noise(float2 uv) {
    float2 _period = (float2)3.0;
    uv = uv * float(cell_amount);
    float2 cMin = floor(uv);
    float2 cMax = ceil(uv);
    float2 uvFract = frac(uv);

    cMin = modulo(cMin, _period);
    cMax = modulo(cMax, _period);

    float2 blur = smoothstep(0.0, 1.0, uvFract);

    float2 ll = random2(float2(cMin.x, cMin.y));
    float2 lr = random2(float2(cMax.x, cMin.y));
    float2 ul = random2(float2(cMin.x, cMax.y));
    float2 ur = random2(float2(cMax.x, cMax.y));

    float2 fraction = frac(uv);

    return lerp(lerp(dot(ll, fraction - float2(0, 0)),
                     dot(lr, fraction - float2(1, 0)), blur.x),
                lerp(dot(ul, fraction - float2(0, 1)),
                     dot(ur, fraction - float2(1, 1)), blur.x), blur.y) * 0.8 + 0.5;
}

float fbm(float2 uv) {
    float amplitude = 0.5;
    float frequency = 3.0;
    float value = 0.0;

    for (int i = 0; i < 6; i++) {
        value += amplitude * noise(frequency * uv);
        amplitude *= 0.5;
        frequency *= 2.0;
    }
    return value;
}

float2 polar(float2 uv, float2 center, float zoom, float repeat) {
    float2 dir = uv - center;
    float radius = length(dir) * 2.0;
    float angle = atan2(dir.y, dir.x) * 1.0 / (3.1416 * 2.0);
    return float2(radius * zoom, angle * repeat);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float2 uv = floor((2.0 * fragCoord - resolution) / resolution.y * 1000.0) / 500.0;
    float2 puv = polar(uv, (float2)0.0, 0.5, 1.0);
    float3 c = (float3)0.0;

    float3 milkBlack = float3(0.050980392156862744, 0.050980392156862744, 0.0784313725490196);
    float3 milkGrey = float3(0.3215686274509804, 0.14901960784313725, 0.24313725490196078);
    float3 milkWhite = float3(0.6745098039215687, 0.19607843137254902, 0.19607843137254902);

    float n = fbm(puv * float2(1.0, 1.0) + float2(time * 0.2, 5.0 / (puv.x) * -0.1) * 0.5);
    n = n * n / sqrt(puv.x) * 0.8;

    c = milkBlack;
    if (n > 0.2) {
        c = milkGrey;
    }
    if (n > 0.25) {
        c = milkWhite;
    }
    if (puv.x < 0.4) {
        c = milkBlack;
    }

    // Post-processing: darken/desaturate
    float lum = dot(c, float3(0.299, 0.587, 0.114));
    c = lerp(c, float3(lum, lum, lum), desaturate);
    c = c * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float a = max(c.r, max(c.g, c.b));
    return float4(c * a, a);
}
