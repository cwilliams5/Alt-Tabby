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

float hexDist(float2 p)
{
    p = abs(p);
    float d = dot(p, normalize(float2(1.0, 1.73)));
    return max(p.x, d);
}

float4 hexCoords(float2 uv)
{
    float2 r = float2(1.0, 1.73);
    float2 h = 0.5 * r;
    float2 a = fmod(uv, r) - h;
    float2 b = fmod(uv - h, r) - h;

    float2 gv = length(a) < length(b) ? a : b;

    float x = atan2(gv.x, gv.y);
    float y = 0.5 - hexDist(gv);
    float2 id = uv - gv;

    return float4(x, y, id);
}

float4 PSMain(PSInput input) : SV_Target
{
    float2 fragCoord = input.pos.xy;
    float2 uv = (fragCoord.xy - 0.5 * resolution.xy) / resolution.y;

    uv *= 10.0;

    float3 col = (float3)0;
    float4 hc = hexCoords(uv);

    float t = time * 0.5;
    float wavy = pow(sin(length(hc.zw) - t), 4.0) + 0.1;

    float c = smoothstep(0., 15./resolution.y, hc.y);

    col = (float3)(c * wavy);

    // Post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
