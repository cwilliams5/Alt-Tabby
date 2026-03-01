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

#define sepsize 1.2
#define seplight 1.9
#define sepanim 0.1
#define caustic_strength 0.008
#define caustic_roughness 1.3
#define caustic_chormatic_aberation 0.001

float4 mod289(float4 x)
{
    return x - floor(x / 289.0) * 289.0;
}

float4 permute(float4 x)
{
    return mod289((x * 34.0 + 1.0) * x);
}

float4 snoise(float3 v)
{
    const float2 C = float2(1.0 / 6.0, 1.0 / 3.0);

    // First corner
    float3 i  = floor(v + dot(v, (float3)C.y));
    float3 x0 = v   - i + dot(i, (float3)C.x);

    // Other corners
    float3 g = step(x0.yzx, x0.xyz);
    float3 l = 1.0 - g;
    float3 i1 = min(g.xyz, l.zxy);
    float3 i2 = max(g.xyz, l.zxy);

    float3 x1 = x0 - i1 + C.x;
    float3 x2 = x0 - i2 + C.y;
    float3 x3 = x0 - 0.5;

    // Permutations
    float4 p =
      permute(permute(permute(i.z + float4(0.0, i1.z, i2.z, 1.0))
                            + i.y + float4(0.0, i1.y, i2.y, 1.0))
                            + i.x + float4(0.0, i1.x, i2.x, 1.0));

    // Gradients: 7x7 points over a square, mapped onto an octahedron.
    float4 j = p - 49.0 * floor(p / 49.0);

    float4 x_ = floor(j / 7.0);
    float4 y_ = floor(j - 7.0 * x_);

    float4 x = (x_ * 2.0 + 0.5) / 7.0 - 1.0;
    float4 y = (y_ * 2.0 + 0.5) / 7.0 - 1.0;

    float4 h = 1.0 - abs(x) - abs(y);

    float4 b0 = float4(x.xy, y.xy);
    float4 b1 = float4(x.zw, y.zw);

    float4 s0 = floor(b0) * 2.0 + 1.0;
    float4 s1 = floor(b1) * 2.0 + 1.0;
    float4 sh = -step(h, (float4)0.0);

    float4 a0 = b0.xzyw + s0.xzyw * sh.xxyy;
    float4 a1 = b1.xzyw + s1.xzyw * sh.zzww;

    float3 g0 = float3(a0.xy, h.x);
    float3 g1 = float3(a0.zw, h.y);
    float3 g2 = float3(a1.xy, h.z);
    float3 g3 = float3(a1.zw, h.w);

    // Compute noise and gradient at P
    float4 m = max(0.6 - float4(dot(x0, x0), dot(x1, x1), dot(x2, x2), dot(x3, x3)), 0.0);
    float4 m2 = m * m;
    float4 m3 = m2 * m;
    float4 m4 = m2 * m2;
    float3 grad =
      -6.0 * m3.x * x0 * dot(x0, g0) + m4.x * g0 +
      -6.0 * m3.y * x1 * dot(x1, g1) + m4.y * g1 +
      -6.0 * m3.z * x2 * dot(x2, g2) + m4.z * g2 +
      -6.0 * m3.w * x3 * dot(x3, g3) + m4.w * g3;
    float4 px = float4(dot(x0, g0), dot(x1, g1), dot(x2, g2), dot(x3, g3));
    return 42.0 * float4(grad, dot(m4, px));
}

float4 cloud(float3 v, int oct)
{
    float4 outp = (float4)0.0;
    for (int i = 1; i < 64; i++)
    {
        if(i >= oct+1) { break; }
        outp += snoise(float3(-143*i,842*i,0)+v*float3(1.,1.,pow((float)i,sepanim))*pow((float)i,sepsize))*(1.0/pow((float)i,seplight));
    }
    return outp;
}

float caustic(float2 uv, int octaves, float st)
{
    float4 val = (float4)0.0;
    for(int i = 0; i < 10; i++)
    {
        val = cloud(float3(uv.xy, time), octaves);
        uv -= val.xy * st;
    }
    return exp(cloud(float3(uv.xy, time), octaves).w * caustic_roughness - caustic_roughness / 2.0);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 uv = (3.0 * fragCoord.xy - resolution.xy) / resolution.y;

    float3 color = float3(
        caustic(uv, 24, caustic_strength + caustic_chormatic_aberation),
        caustic(uv, 24, caustic_strength),
        caustic(uv, 24, caustic_strength - caustic_chormatic_aberation));

    // Darken/desaturate post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(color.r, max(color.g, color.b));
    return float4(color * a, a);
}