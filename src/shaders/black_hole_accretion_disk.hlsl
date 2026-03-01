cbuffer Constants : register(b0) {
    float time;
    float2 resolution;
    float timeDelta;
    uint frame;
    float darken;
    float desaturate;
    float _pad;
};

Texture2D iChannel0 : register(t0);
SamplerState samp0 : register(s0);

#define AA 1

#define _Speed 3.0
#define _Steps 12.0
#define _Size 0.3

float hash1(float x) { return frac(sin(x) * 152754.742); }
float hash2(float2 x) { return hash1(x.x + hash1(x.y)); }

float value(float2 p, float f)
{
    float bl = hash2(floor(p * f + float2(0.0, 0.0)));
    float br = hash2(floor(p * f + float2(1.0, 0.0)));
    float tl = hash2(floor(p * f + float2(0.0, 1.0)));
    float tr = hash2(floor(p * f + float2(1.0, 1.0)));

    float2 fr = frac(p * f);
    fr = (3.0 - 2.0 * fr) * fr * fr;
    float b = lerp(bl, br, fr.x);
    float t = lerp(tl, tr, fr.x);
    return lerp(b, t, fr.y);
}

float4 background(float3 ray)
{
    float2 uv = ray.xy;

    if (abs(ray.x) > 0.5)
        uv.x = ray.z;
    else if (abs(ray.y) > 0.5)
        uv.y = ray.z;

    float brightness = value(uv * 3.0, 100.0);
    float color = value(uv * 2.0, 20.0);
    brightness = pow(brightness, 256.0);

    brightness = brightness * 100.0;
    brightness = clamp(brightness, 0.0, 1.0);

    float3 stars = brightness * lerp(float3(1.0, 0.6, 0.2), float3(0.2, 0.6, 1.0), color);

    float4 nebulae = iChannel0.Sample(samp0, uv * 1.5);
    nebulae.xyz += nebulae.xxx + nebulae.yyy + nebulae.zzz;
    nebulae.xyz *= 0.25;

    nebulae *= nebulae;
    nebulae *= nebulae;
    nebulae *= nebulae;
    nebulae *= nebulae;

    nebulae.xyz += stars;
    return nebulae;
}

float4 raymarchDisk(float3 ray, float3 zeroPos)
{
    float3 position = zeroPos;
    float lengthPos = length(position.xz);
    float dist = min(1.0, lengthPos * (1.0 / _Size) * 0.5) * _Size * 0.4 * (1.0 / _Steps) / abs(ray.y);

    position += dist * _Steps * ray * 0.5;

    float2 deltaPos;
    deltaPos.x = -zeroPos.z * 0.01 + zeroPos.x;
    deltaPos.y = zeroPos.x * 0.01 + zeroPos.z;
    deltaPos = normalize(deltaPos - zeroPos.xz);

    float parallel = dot(ray.xz, deltaPos);
    parallel /= sqrt(lengthPos);
    parallel *= 0.5;
    float redShift = parallel + 0.3;
    redShift *= redShift;

    redShift = clamp(redShift, 0.0, 1.0);

    float disMix = clamp((lengthPos - _Size * 2.0) * (1.0 / _Size) * 0.24, 0.0, 1.0);
    float3 insideCol = lerp(float3(1.0, 0.8, 0.0), float3(0.5, 0.13, 0.02) * 0.2, disMix);

    insideCol *= lerp(float3(0.4, 0.2, 0.1), float3(1.6, 2.4, 4.0), redShift);
    insideCol *= 1.25;
    redShift += 0.12;
    redShift *= redShift;

    float4 o = (float4)0;

    for (float i = 0.0; i < _Steps; i++)
    {
        position -= dist * ray;

        float intensity = clamp(1.0 - abs((i - 0.8) * (1.0 / _Steps) * 2.0), 0.0, 1.0);
        float lp = length(position.xz);
        float distMult = 1.0;

        distMult *= clamp((lp - _Size * 0.75) * (1.0 / _Size) * 1.5, 0.0, 1.0);
        distMult *= clamp((_Size * 10.0 - lp) * (1.0 / _Size) * 0.20, 0.0, 1.0);
        distMult *= distMult;

        float u = lp + time * _Size * 0.3 + intensity * _Size * 0.2;

        float2 xy;
        float rot = fmod(time * _Speed, 8192.0);
        xy.x = -position.z * sin(rot) + position.x * cos(rot);
        xy.y = position.x * sin(rot) + position.z * cos(rot);

        float x = abs(xy.x / xy.y);
        float angle = 0.02 * atan(x);

        static const float f = 70.0;
        float noise = value(float2(angle, u * (1.0 / _Size) * 0.05), f);
        noise = noise * 0.66 + 0.33 * value(float2(angle, u * (1.0 / _Size) * 0.05), f * 2.0);

        float extraWidth = noise * 1.0 * (1.0 - clamp(i * (1.0 / _Steps) * 2.0 - 1.0, 0.0, 1.0));

        float alpha = clamp(noise * (intensity + extraWidth) * ((1.0 / _Size) * 10.0 + 0.01) * dist * distMult, 0.0, 1.0);

        float3 col = 2.0 * lerp(float3(0.3, 0.2, 0.15) * insideCol, insideCol, min(1.0, intensity * 2.0));
        o = clamp(float4(col * alpha + o.rgb * (1.0 - alpha), o.a * (1.0 - alpha) + alpha), (float4)0, (float4)1);

        lp *= (1.0 / _Size);

        o.rgb += redShift * (intensity * 1.0 + 0.5) * (1.0 / _Steps) * 100.0 * distMult / (lp * lp);
    }

    o.rgb = clamp(o.rgb - 0.005, 0.0, 1.0);
    return o;
}

void DoRotate(inout float3 v, float2 a)
{
    v.yz = cos(a.y) * v.yz + sin(a.y) * float2(-1, 1) * v.zy;
    v.xz = cos(a.x) * v.xz + sin(a.x) * float2(-1, 1) * v.zx;
}

struct PSInput {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
};

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float4 colOut = (float4)0;

    float2 fragCoordRot;
    fragCoordRot.x = fragCoord.x * 0.985 + fragCoord.y * 0.174;
    fragCoordRot.y = fragCoord.y * 0.985 - fragCoord.x * 0.174;
    fragCoordRot += float2(-0.06, 0.12) * resolution.xy;

    // Gentle time-based camera motion replacing iMouse
    float fakeMx = (sin(time * 0.05) * 0.3 + 0.5) * resolution.y;
    float fakeMy = (cos(time * 0.03) * 0.15 + 0.4) * resolution.y;

    for (int j = 0; j < AA; j++)
    for (int i = 0; i < AA; i++)
    {
        float3 ray = normalize(float3((fragCoordRot - resolution.xy * 0.5 + float2(i, j) / (float)AA) / resolution.x, 1.0));
        float zDist = 20.0 * fakeMx / resolution.y - 10.0;
        float3 pos = float3(0.0, 0.05, -zDist * zDist * 0.05);
        float2 angle = float2(time * 0.1, 0.2);
        angle.y = (2.0 * fakeMy / resolution.y) * 3.14 + 0.1 + 3.14;
        float dist = length(pos);
        DoRotate(pos, angle);
        angle.xy -= min(0.3 / dist, 3.14) * float2(1.0, 0.5);
        DoRotate(ray, angle);

        float4 col = (float4)0;
        float4 glow = (float4)0;
        float4 outCol = (float4)100.0;

        for (int disks = 0; disks < 20; disks++)
        {
            for (int h = 0; h < 6; h++)
            {
                float dotpos = dot(pos, pos);
                float invDist = rsqrt(dotpos);
                float centDist = dotpos * invDist;
                float stepDist = 0.92 * abs(pos.y / ray.y);
                float farLimit = centDist * 0.5;
                float closeLimit = centDist * 0.1 + 0.05 * centDist * centDist * (1.0 / _Size);
                stepDist = min(stepDist, min(farLimit, closeLimit));

                float invDistSqr = invDist * invDist;
                float bendForce = stepDist * invDistSqr * _Size * 0.625;
                ray = normalize(ray - (bendForce * invDist) * pos);
                pos += stepDist * ray;

                glow += float4(1.2, 1.1, 1.0, 1.0) * (0.01 * stepDist * invDistSqr * invDistSqr * clamp(centDist * 2.0 - 1.2, 0.0, 1.0));
            }

            float dist2 = length(pos);

            if (dist2 < _Size * 0.1)
            {
                outCol = float4(col.rgb * col.a + glow.rgb * (1.0 - col.a), 1.0);
                break;
            }
            else if (dist2 > _Size * 1000.0)
            {
                float4 bg = background(ray);
                outCol = float4(col.rgb * col.a + bg.rgb * (1.0 - col.a) + glow.rgb * (1.0 - col.a), 1.0);
                break;
            }
            else if (abs(pos.y) <= _Size * 0.002)
            {
                float4 diskCol = raymarchDisk(ray, pos);
                pos.y = 0.0;
                pos += abs(_Size * 0.001 / ray.y) * ray;
                col = float4(diskCol.rgb * (1.0 - col.a) + col.rgb, col.a + diskCol.a * (1.0 - col.a));
            }
        }

        if (outCol.r == 100.0)
            outCol = float4(col.rgb + glow.rgb * (col.a + glow.a), 1.0);

        col = outCol;
        col.rgb = pow(col.rgb, (float3)0.6);

        colOut += col / (float)(AA * AA);
    }

    float3 color = colOut.rgb;

    // Darken/desaturate post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(color.r, max(color.g, color.b));
    return float4(color * a, a);
}
