// SPDX-License-Identifier: CC-BY-NC-SA-4.0
// Copyright (c) 2026 @Frostbyte
//[LICENSE] https://creativecommons.org/licenses/by-nc-sa/4.0/

#define R(a) mat2(cos(a+vec4(0,33,11,0)))
void mainImage(out vec4 o, in vec2 u)
{

    float i, s, t = iTime;
    vec3 p,
    d = normalize(vec3(2. * u - iResolution.xy, iResolution.y));
    p.z = t;
    for (o *= i; i < 10.; i++)
    {
        p.xy *= R(-p.z * .01 - iTime * .05);
        s = 0.;
        s = max(s, 15. * (-length(p.xy) + 3.));
        s += abs(p.y * .004 + sin(t - p.x * .5) * .9 + 1.);
        p += d * s;
        o += (1. + sin(i * .9 + length(p.xy * .1) + vec4(9, 1.5, 1, 1))) / s;
    }
    o /= 1e2;

}
