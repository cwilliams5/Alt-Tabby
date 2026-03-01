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

#define iterations 4
#define formuparam2 0.89

#define volsteps 10
#define stepsize 0.190

#define zoom 3.900
#define tile   0.450
#define speed2  0.010

#define brightness 0.2
#define darkmatter 0.400
#define distfading 0.560
#define saturation 0.400

#define transverseSpeed 1.1
#define cloud 0.2

float triangleFn(float x, float a) {
    float output2 = 2.0 * abs(3.0 * ((x / a) - floor((x / a) + 0.5))) - 1.0;
    return output2;
}

float field(in float3 p) {
    float strength = 7.0 + 0.03 * log(1.e-6 + frac(sin(time) * 4373.11));
    float accum = 0.;
    float prev = 0.;
    float tw = 0.;

    for (int i = 0; i < 6; ++i) {
        float mag = dot(p, p);
        p = abs(p) / mag + float3(-.5, -.8 + 0.1 * sin(time * 0.2 + 2.0), -1.1 + 0.3 * cos(time * 0.15));
        float w = exp(-float(i) / 7.);
        accum += w * exp(-strength * pow(abs(mag - prev), 2.3));
        tw += w;
        prev = mag;
    }
    return max(0., 5. * accum / tw - .7);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float2 uv2 = 2. * fragCoord.xy / resolution.xy - 1.;
    float2 uvs = uv2 * resolution.xy / max(resolution.x, resolution.y);

    float time2 = time;

    float speed = speed2;
    speed = 0.005 * cos(time2 * 0.02 + 3.1415926 / 4.0);
    float formuparam = formuparam2;
    float2 uv = uvs;

    float a_xz = 0.9;
    float a_yz = -.6;
    float a_xy = 0.9 + time * 0.04;

    float2x2 rot_xz = float2x2(cos(a_xz), sin(a_xz), -sin(a_xz), cos(a_xz));
    float2x2 rot_yz = float2x2(cos(a_yz), sin(a_yz), -sin(a_yz), cos(a_yz));
    float2x2 rot_xy = float2x2(cos(a_xy), sin(a_xy), -sin(a_xy), cos(a_xy));

    float v2 = 1.0;

    float3 dir = float3(uv * zoom, 1.);
    float3 from = float3(0.0, 0.0, 0.0);

    from.x -= 5.0 * (0.5);
    from.y -= 5.0 * (0.5);

    float3 forward = float3(0., 0., 1.);

    from.x += transverseSpeed * (1.0) * cos(0.01 * time) + 0.001 * time;
    from.y += transverseSpeed * (1.0) * sin(0.01 * time) + 0.001 * time;
    from.z += 0.003 * time;

    dir.xy = mul(dir.xy, rot_xy);
    forward.xy = mul(forward.xy, rot_xy);

    dir.xz = mul(dir.xz, rot_xz);
    forward.xz = mul(forward.xz, rot_xz);

    dir.yz = mul(dir.yz, rot_yz);
    forward.yz = mul(forward.yz, rot_yz);

    from.xy = mul(from.xy, -rot_xy);
    from.xz = mul(from.xz, rot_xz);
    from.yz = mul(from.yz, rot_yz);

    float zooom = (time2 - 3311.) * speed;
    from += forward * zooom;
    float sampleShift = fmod(zooom, stepsize);

    float zoffset = -sampleShift;
    sampleShift /= stepsize;

    float s = 0.24;
    float s3 = s + stepsize / 2.0;
    float3 v = (float3)0.;
    float t3 = 0.0;

    float3 backCol2 = (float3)0.;
    for (int r = 0; r < volsteps; r++) {
        float3 p2 = from + (s + zoffset) * dir;
        float3 p3 = (from + (s3 + zoffset) * dir) * (1.9 / zoom);

        p2 = abs((float3)tile - fmod(p2, (float3)(tile * 2.))); // tiling fold
        p3 = abs((float3)tile - fmod(p3, (float3)(tile * 2.))); // tiling fold

        t3 = field(p3);

        float pa = 0., a = 0.;
        for (int i = 0; i < iterations; i++) {
            p2 = abs(p2) / dot(p2, p2) - formuparam;
            float D = abs(length(p2) - pa);

            if (i > 2) {
                a += i > 7 ? min(12., D) : D;
            }
            pa = length(p2);
        }

        a *= a * a;
        float s1 = s + zoffset;
        float fade = pow(distfading, max(0., float(r) - sampleShift));

        v += fade;

        if (r == 0)
            fade *= (1. - (sampleShift));
        if (r == volsteps - 1)
            fade *= sampleShift;
        v += float3(s1, s1 * s1, s1 * s1 * s1 * s1) * a * brightness * fade;

        backCol2 += lerp(.4, 1., v2) * float3(0.20 * t3 * t3 * t3, 0.4 * t3 * t3, t3 * 0.7) * fade;

        s += stepsize;
        s3 += stepsize;
    }

    v = lerp((float3)length(v), v, saturation);
    float4 forCol2 = float4(v * .01, 1.);

    backCol2 *= cloud;

    float3 color = forCol2.rgb + backCol2;

    // Post-processing: desaturate and darken
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float a_out = max(color.r, max(color.g, color.b));
    return float4(color * a_out, a_out);
}
