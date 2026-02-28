// Cloud 3D — based on https://www.shadertoy.com/view/4sXGRM

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

static const float3 skytop = float3(0.05, 0.2, 0.5);
static const float3 light = normalize(float3(0.1, 0.25, 0.9));
static const float2 cloudrange = float2(0.0, 10000.0);

// GLSL mat3 is column-major; HLSL float3x3 is row-major — constructor args transposed
static const float3x3 m = float3x3(
     0.00, -1.60, -1.20,
     1.60,  0.72, -0.96,
     1.20, -0.96,  1.28);

float hash(float n) {
    return frac(cos(n) * 114514.1919);
}

float noise(float3 x) {
    float3 p = floor(x);
    float3 f = smoothstep(0.0, 1.0, frac(x));
    float n = p.x + p.y * 10.0 + p.z * 100.0;
    return lerp(
        lerp(lerp(hash(n + 0.0), hash(n + 1.0), f.x),
             lerp(hash(n + 10.0), hash(n + 11.0), f.x), f.y),
        lerp(lerp(hash(n + 100.0), hash(n + 101.0), f.x),
             lerp(hash(n + 110.0), hash(n + 111.0), f.x), f.y), f.z);
}

float fbm(float3 p) {
    float f = 0.5000 * noise(p);
    p = mul(m, p);
    f += 0.2500 * noise(p);
    p = mul(m, p);
    f += 0.1666 * noise(p);
    p = mul(m, p);
    f += 0.0834 * noise(p);
    return f;
}

float3 get_camera(float t) {
    return float3(5000.0 * sin(1.0 * t), 5000.0 + 1500.0 * sin(0.5 * t), 6000.0 * t);
}

float4 PSMain(PSInput input) : SV_Target {
    // Y-flip: clouds have gravity/up direction
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);
    float2 uv = 2.0 * fragCoord.xy / resolution.xy - 1.0;
    uv.x *= resolution.x / resolution.y;

    float camTime = time + 57.5;
    float3 campos = get_camera(camTime);
    float3 camtar = get_camera(camTime + 0.4);

    float3 front = normalize(camtar - campos);
    float3 right = normalize(cross(front, float3(0.0, 1.0, 0.0)));
    float3 up = normalize(cross(right, front));
    float3 fragAt = normalize(uv.x * right + uv.y * up + front);

    // clouds
    float4 sum = (float4)0;
    for (float depth = 0.0; depth < 100000.0; depth += 200.0) {
        float3 ray = campos + fragAt * depth;
        if (cloudrange.x < ray.y && ray.y < cloudrange.y) {
            float a = smoothstep(0.5, 1.0, fbm(ray * 0.00025));
            float3 localcolor = lerp(float3(1.1, 1.05, 1.0), float3(0.3, 0.3, 0.2), a);
            a = (1.0 - sum.a) * a;
            sum += float4(localcolor * a, a);
        }
    }

    float alpha = smoothstep(0.7, 1.0, sum.a);
    sum.rgb /= sum.a + 0.0001;

    float sundot = clamp(dot(fragAt, light), 0.0, 1.0);
    float3 col = 0.8 * skytop;
    col += 0.47 * float3(1.6, 1.4, 1.0) * pow(sundot, 350.0);
    col += 0.4 * float3(0.8, 0.9, 1.0) * pow(sundot, 2.0);

    sum.rgb -= 0.6 * float3(0.8, 0.75, 0.7) * pow(sundot, 13.0) * alpha;
    sum.rgb += 0.2 * float3(1.3, 1.2, 1.0) * pow(sundot, 5.0) * (1.0 - alpha);

    col = lerp(col, sum.rgb, sum.a);

    float3 color = col;

    // Post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float outA = max(color.r, max(color.g, color.b));
    return float4(color * outA, outA);
}
