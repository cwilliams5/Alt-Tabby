// Triangle Noise
// Converted from: https://www.shadertoy.com/view/ws33Ws

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

float Perlin3D(float3 P)
{
    // https://github.com/BrianSharpe/Wombat/blob/master/Perlin3D.glsl

    // establish our grid cell and unit position
    float3 Pi = floor(P);
    float3 Pf = P - Pi;
    float3 Pf_min1 = Pf - 1.0;

    // clamp the domain
    Pi.xyz = Pi.xyz - floor(Pi.xyz * (1.0 / 69.0)) * 69.0;
    float3 Pi_inc1 = step(Pi, (float3)(69.0 - 1.5)) * (Pi + 1.0);

    // calculate the hash
    float4 Pt = float4(Pi.xy, Pi_inc1.xy) + float2(50.0, 161.0).xyxy;
    Pt *= Pt;
    Pt = Pt.xzxz * Pt.yyww;
    const float3 SOMELARGEFLOATS = float3(635.298681, 682.357502, 668.926525);
    const float3 ZINC = float3(48.500388, 65.294118, 63.934599);
    float3 lowz_mod = 1.0 / (SOMELARGEFLOATS + Pi.zzz * ZINC);
    float3 highz_mod = 1.0 / (SOMELARGEFLOATS + Pi_inc1.zzz * ZINC);
    float4 hashx0 = frac(Pt * lowz_mod.xxxx);
    float4 hashx1 = frac(Pt * highz_mod.xxxx);
    float4 hashy0 = frac(Pt * lowz_mod.yyyy);
    float4 hashy1 = frac(Pt * highz_mod.yyyy);
    float4 hashz0 = frac(Pt * lowz_mod.zzzz);
    float4 hashz1 = frac(Pt * highz_mod.zzzz);

    // calculate the gradients
    float4 grad_x0 = hashx0 - 0.49999;
    float4 grad_y0 = hashy0 - 0.49999;
    float4 grad_z0 = hashz0 - 0.49999;
    float4 grad_x1 = hashx1 - 0.49999;
    float4 grad_y1 = hashy1 - 0.49999;
    float4 grad_z1 = hashz1 - 0.49999;
    float4 grad_results_0 = rsqrt(grad_x0 * grad_x0 + grad_y0 * grad_y0 + grad_z0 * grad_z0) * (float2(Pf.x, Pf_min1.x).xyxy * grad_x0 + float2(Pf.y, Pf_min1.y).xxyy * grad_y0 + Pf.zzzz * grad_z0);
    float4 grad_results_1 = rsqrt(grad_x1 * grad_x1 + grad_y1 * grad_y1 + grad_z1 * grad_z1) * (float2(Pf.x, Pf_min1.x).xyxy * grad_x1 + float2(Pf.y, Pf_min1.y).xxyy * grad_y1 + Pf_min1.zzzz * grad_z1);

    // Classic Perlin Interpolation
    float3 blend = Pf * Pf * Pf * (Pf * (Pf * 6.0 - 15.0) + 10.0);
    float4 res0 = lerp(grad_results_0, grad_results_1, blend.z);
    float4 blend2 = float4(blend.xy, 1.0 - blend.xy);
    float result = dot(res0, blend2.zxzx * blend2.wwyy);
    return (result * 1.1547005383792515290182975610039); // scale to strict -1.0->1.0 range *= 1.0/sqrt(0.75)
}

float2 Rotate(float2 xy, float angle) {
    return float2(xy.x * cos(angle) - xy.y * sin(angle), xy.x * sin(angle) + xy.y * cos(angle));
}

float2 Triangle(float2 uv, float c) {
    float r = 0.5235988;
    float2 o = uv;
    o.x = floor(uv.x * c + 0.5);
    o.y = lerp(floor(Rotate(uv * c + 0.5, r).y), floor(Rotate(uv * c + 0.5, -r).y), 0.5);
    o.y *= 1.154700555;
    return o / c;
}

float2 TriangleUV(float2 uv, float c, float r, float s) {
    uv = Rotate(uv, r);
    uv.y += s;
    uv = Triangle(uv, c);
    uv.y -= s;
    uv = Rotate(uv, -r);
    uv += 0.5;
    return uv;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float Time = time;
    float Scroll = 0.0125;
    float Rotation = -0.7854;
    float NoiseSpeed = 1.0;
    float4 Color1 = float4(0.07451, 0.09022, 0.2471, 1.0); // Background
    float4 Color2 = float4(0.1804, 0.1922, 0.4942, 1.0); // Foreground

    // Fixed resolution UV (screen-independent pattern)
    float2 uv = fragCoord.xy * 0.00025;

    // Create triangular noise pattern
    float n1 = Perlin3D(float3(TriangleUV(uv, 11.0, Rotation, Time * Scroll) * 10.0, Time * NoiseSpeed));
    float n2 = Perlin3D(float3(TriangleUV(uv * 2.0 + float2(10.0, 10.0), 11.0, Rotation, Time * Scroll) * 10.0, Time * NoiseSpeed));
    n1 = clamp((n1 + n2) * 0.5 + 0.5, 0.0, 1.0);

    // Final output
    float3 col = lerp(Color1.rgb, Color2.rgb, n1);

    // Darken/desaturate post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, (float3)lum, desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
