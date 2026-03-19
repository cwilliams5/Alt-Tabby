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

// Precomputed pow(i, const) for i=1..24 — eliminates 3 SFU ops per loop iteration.
// fxc folds these to compile-time constants since both arguments are literals.
static const float _powAnim[24] = {
    pow(1.0,sepanim),  pow(2.0,sepanim),  pow(3.0,sepanim),  pow(4.0,sepanim),
    pow(5.0,sepanim),  pow(6.0,sepanim),  pow(7.0,sepanim),  pow(8.0,sepanim),
    pow(9.0,sepanim),  pow(10.0,sepanim), pow(11.0,sepanim), pow(12.0,sepanim),
    pow(13.0,sepanim), pow(14.0,sepanim), pow(15.0,sepanim), pow(16.0,sepanim),
    pow(17.0,sepanim), pow(18.0,sepanim), pow(19.0,sepanim), pow(20.0,sepanim),
    pow(21.0,sepanim), pow(22.0,sepanim), pow(23.0,sepanim), pow(24.0,sepanim)
};
static const float _powSize[24] = {
    pow(1.0,sepsize),  pow(2.0,sepsize),  pow(3.0,sepsize),  pow(4.0,sepsize),
    pow(5.0,sepsize),  pow(6.0,sepsize),  pow(7.0,sepsize),  pow(8.0,sepsize),
    pow(9.0,sepsize),  pow(10.0,sepsize), pow(11.0,sepsize), pow(12.0,sepsize),
    pow(13.0,sepsize), pow(14.0,sepsize), pow(15.0,sepsize), pow(16.0,sepsize),
    pow(17.0,sepsize), pow(18.0,sepsize), pow(19.0,sepsize), pow(20.0,sepsize),
    pow(21.0,sepsize), pow(22.0,sepsize), pow(23.0,sepsize), pow(24.0,sepsize)
};
static const float _powLight[24] = {
    pow(1.0,-seplight),  pow(2.0,-seplight),  pow(3.0,-seplight),  pow(4.0,-seplight),
    pow(5.0,-seplight),  pow(6.0,-seplight),  pow(7.0,-seplight),  pow(8.0,-seplight),
    pow(9.0,-seplight),  pow(10.0,-seplight), pow(11.0,-seplight), pow(12.0,-seplight),
    pow(13.0,-seplight), pow(14.0,-seplight), pow(15.0,-seplight), pow(16.0,-seplight),
    pow(17.0,-seplight), pow(18.0,-seplight), pow(19.0,-seplight), pow(20.0,-seplight),
    pow(21.0,-seplight), pow(22.0,-seplight), pow(23.0,-seplight), pow(24.0,-seplight)
};

float4 cloud(float3 v, int oct)
{
    float4 outp = (float4)0.0;
    for (int i = 1; i < 64; i++)
    {
        if(i >= oct+1) { break; }
        outp += snoise(float3(-143*i,842*i,0)+v*float3(1.,1.,_powAnim[i-1])*_powSize[i-1])*_powLight[i-1];
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
    return exp(cloud(float3(uv.xy, time), octaves).w * caustic_roughness - caustic_roughness * 0.5);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 uv = (3.0 * fragCoord.xy - resolution.xy) / resolution.y;

    float3 color = float3(
        caustic(uv, 24, caustic_strength + caustic_chormatic_aberation),
        caustic(uv, 24, caustic_strength),
        caustic(uv, 24, caustic_strength - caustic_chormatic_aberation));

    return AT_PostProcess(color);
}