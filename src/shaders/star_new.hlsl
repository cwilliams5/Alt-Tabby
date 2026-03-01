// Star New by nayk
// Ported from https://www.shadertoy.com/view/lcjyDR
// Volumetric starfield with animated ellipse trails and star overlay

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

#define iterations 17
#define formuparam 0.53
#define volsteps 20
#define stepsize 0.1
#define zoom 0.800
#define tile 0.850
#define brightness_val 0.0015
#define darkmatter 0.300
#define distfading 0.730
#define saturation_val 0.850

// GLSL mod: x - y * floor(x/y)
float3 glsl_mod3(float3 x, float3 y) { return x - y * floor(x / y); }

float3 pal(in float t, in float3 a, in float3 b, in float3 c, in float3 d) {
    return a + b*cos(6.28318*(c*t + d));
}

float h21(float2 a) {
    return frac(sin(dot(a, float2(1., 10.233))) * 40000.5453123);
}

float sdEllipse(in float2 p, in float2 ab) {
    p = abs(p); if (p.x > p.y) { p = p.yx; ab = ab.yx; }
    float l = ab.y*ab.y - ab.x*ab.x;
    float m = ab.x*p.x/l;      float m2 = m*m;
    float n = ab.y*p.y/l;      float n2 = n*n;
    float c = (m2 + n2 - 1.0)/3.0; float c3 = c*c*c;
    float q = c3 + m2*n2*2.0;
    float d = c3 + m2*n2;
    float g = m + m*n2;
    float co;
    if (d < 0.0) {
        float h = acos(q/c3)/3.0;
        float s = cos(h);
        float tv = sin(h)*sqrt(3.0);
        float rx = sqrt(-c*(s + tv + 2.0) + m2);
        float ry = sqrt(-c*(s - tv + 2.0) + m2);
        co = (ry + sign(l)*rx + abs(g)/(rx*ry) - m)/2.0;
    } else {
        float h = 2.0*m*n*sqrt(d);
        float s = sign(q + h)*pow(abs(q + h), 1.0/3.0);
        float u = sign(q - h)*pow(abs(q - h), 1.0/3.0);
        float rx = -s - u - c*4.0 + 2.0*m2;
        float ry = (s - u)*sqrt(3.0);
        float rm = sqrt(rx*rx + ry*ry);
        co = (ry/sqrt(rm - rx) + 2.0*g/rm - m)/2.0;
    }
    float2 r = ab * float2(co, sqrt(1.0 - co*co));
    return length(r - p) * sign(p.y - r.y);
}

// Ellipse trail between two points
float ellipse_shape(float2 uv_in, float2 p, float2 q) {
    float quadTest = 0.5 * (sign(q.x - p.x) * sign(q.y - p.y) + 1.);
    float i = 1. - quadTest;
    float2 c = (i == 1.) ? float2(p.x, q.y) : float2(q.x, p.y);
    float x = abs(q.x - p.x), y = abs(q.y - p.y);
    float d = sdEllipse(uv_in - c, float2(x, y));
    return exp(-100. * abs(d));
}

// Volumetric starfield rendering
float4 starfield(float3 from, float3 dir) {
    float s = 0.1, fade = 1.;
    float3 v = (float3)0;
    float c_rot = cos(time*0.02), s_rot = sin(time*0.02);
    [loop]
    for (int r = 0; r < volsteps; r++) {
        float3 p = from + s*dir*.5;
        p = abs((float3)tile - glsl_mod3(p, (float3)(tile*2.)));
        float pa = 0., a = 0.;
        [loop]
        for (int i = 0; i < iterations; i++) {
            p = abs(p)/dot(p, p) - (float3)formuparam;
            p.xy = mul(float2x2(c_rot, s_rot, -s_rot, c_rot), p.xy);
            a += abs(length(p) - pa);
            pa = length(p);
        }
        float dm = max(0., darkmatter - a*a*.001);
        a *= a*a;
        if (r > 6) fade *= 1. - dm;
        v += (float3)fade;
        v += float3(s, s*s, s*s*s*s)*a*brightness_val*fade;
        fade *= distfading;
        s += stepsize;
    }
    v = lerp((float3)length(v), v, saturation_val);
    return float4(v*.01, 1.);
}

float happy_star(float2 uv_in, float anim) {
    uv_in = abs(uv_in);
    float2 pos = min(uv_in.xy/uv_in.yx, (float2)anim);
    float p = (2.0 - pos.x - pos.y);
    return (2.0 + p*(p*p - 1.5)) / (uv_in.x + uv_in.y);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float2 uv = fragCoord.xy/resolution.xy - .5;
    uv.y *= resolution.y/resolution.x;
    float3 dir = float3(uv*zoom, 1.);

    uv *= 1.1 + 0.15 * cos(uv.y - 0.6 * time);
    uv.y += 0.02 * cos(time);

    float t_anim = 10. * time + 8. * h21(uv) + 15. * exp(-0.01 * length(uv)) * (650. + time);
    int f = int(floor(t_anim));

    float s_acc = 0.;
    float2 pp = (float2)0;

    float3 e = (float3)1;
    float3 col = (float3)0;

    float n = 20.;
    [loop]
    for (float i = 0.; i <= n; i++) {
        float f2 = 0.0001 * float(f);
        float f3 = 0.0001 * float(f + 1);

        float2 qp = pp;

        pp = float2(h21((float2)f2), h21((float2)(0.01 + f2)));
        pp = pow(4. * pp * (1. - pp), (float2)4);

        float2 pp2 = float2(h21((float2)f3), h21((float2)(0.01 + f3)));
        float fr = frac(t_anim);
        fr = smoothstep(0., 1., fr);
        pp = lerp(pp, pp2, fr);
        pp = 0.3 * (pp - 0.5);
        f++;

        float s2 = 0.;
        if (i > 0.) s2 = ellipse_shape(uv, pp, qp);
        s_acc = clamp(s_acc + s2, 0., 1.);
        float3 col2 = pal(i/n, e, e, e, (i/n) * float3(0, 1, 2)/3.);
        col = lerp(col, col2, s2);
    }

    col += 0.03;
    col += 0.35 * exp(-3. * length(uv));

    float3 from = float3(1., .5, 0.5);
    float4 fragColor = starfield(from, dir);
    fragColor *= float4(col*3., 1.);

    uv *= 2.0 * (cos(time * 2.0) - 2.5);
    float anim = sin(time * 12.0) * 0.1 + 1.0;
    fragColor += float4(happy_star(uv, anim) * float3(0.35, 0.2, 0.55)*0.1, 1.0);

    float3 color = fragColor.rgb;

    // Post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, (float3)lum, desaturate);
    color *= 1.0 - darken;

    // Alpha from brightness, premultiply
    float alpha = max(color.r, max(color.g, color.b));
    return float4(color * alpha, alpha);
}
