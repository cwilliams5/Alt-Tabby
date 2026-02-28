// Nox by diatribes
// https://www.shadertoy.com/view/WfKGRD
// Cloud tunnel with moon - noise, turbulence, and translucency

void mainImage(out vec4 o, vec2 u) {
    float i, d, s, n, t=iTime*.05;
    vec3 p = iResolution;
    u = (u-p.xy/2.)/p.y;
    for(o*=i; i++<1e2; ) {
        p = vec3(u * d, d + t*4.);
        p += cos(p.z+t+p.yzx*.5)*.5;
        s = 5.-length(p.xy);
        for (n = .06; n < 2.;
            p.xy *= mat2(cos(t*.1+vec4(0,33,11,0))),
            s -= abs(dot(sin(p.z+t+p * n * 20.), vec3( .05))) / n,
            n += n);
        d += s = .02 + abs(s)*.1;
        o += 1. / s;
    }
    o = tanh(o / d / 9e2 / length(u));
}
