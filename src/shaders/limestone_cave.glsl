#define R iResolution
#define T iTime
#define M mat2(cos(p.z * 1.1 + vec4(0, 11, 33, 0)))
float n(vec2 p) {
    return sin(p.x * 3. + sin(p.y * 2.7)) * cos(p.y * 1.1 + cos(p.x * 2.3));
}
float f(vec3 p) {
    float v = 0., a = 1.;
    for(int i = 0; i++ < 7; p *= 2., a /= 2.)
        v += n(p.xy + p.z / 2.) * a;
    return v;
}
float m(vec3 p) {
    p.xy *= M;
    return (1. - length(p.xy) - f(p + T / 10.) * .3) / 5.;
}

vec3 N(vec3 p, float t) {
    vec2 e = vec2(1e-3 + t / 1e3, 0);
    return normalize(vec3(
    m(p + e.xyy) - m(p - e.xyy),
    m(p + e.yxy) - m(p - e.yxy),
    m(p + e.yyx) - m(p - e.yyx)));
}

float A(vec3 p, vec3 n) {
    float o = 0., s = 1., h;
    for(int i = 0; i++ < 5; s *= .9) {
        h = .01 + .03 * float(i);
        o += (h - m(p + h * n)) * s;
        if(o > .33) break;
    }
    return max(1. - 3. * o, 0.);
}

void mainImage(out vec4 O, vec2 u) {
    vec3 d = normalize(vec3(u - .5 * R.xy, R.y)),
         o = vec3(0, 0, T), p, n, l, h, c = vec3(0);
    float t = 0., w;
    for(int i = 0; i++ < 99;) {
        p = o + d * t;
        w = m(p);
        if(abs(w) < t / 1e3 || t > 20.) break;
        t += w;
    }

    if(t <= 20.) {
        n = N(p, t);
        vec3 q = p;
        q.xy *= M;
        c = mix(vec3(.1, .3, .7), vec3(.8, .4, .2),
        clamp(f(q + T / 10.) + .5, 0., 1.));
        l = normalize(o + vec3(0, 0, 4) - p);
        h = normalize(l + normalize(o - p));
        w = length(o + vec3(0, 0, 4) - p);

        c = c * .02 +
            (c * max(dot(n, l), 0.) +
            vec3(.8) * pow(abs(max(dot(n, h), 0.)), 16.) *
            smoothstep(15., 5., t))
            / (1. + w * w / 5.);

        c *= A(p, n);
    }

    c = mix(vec3(.02, 0, .05), c, 1. / exp(.15 * t));
    c = c * (2.51 * c + .03) / (c * (2.43 * c + .59) + .14);

    O = vec4(pow(abs(c), vec3(1. / 2.2)), 1);
}
