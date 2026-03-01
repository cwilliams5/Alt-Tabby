// 'Dune (Sand Worm)' dean_the_coder (Twitter: @deanthecoder)
// https://www.shadertoy.com/view/7stGRj (YouTube: https://youtu.be/GqkO68U4Hws)
//
// Processed by 'GLSL Shader Shrinker'
// (https://github.com/deanthecoder/GLSLShaderShrinker)
//
// License: Creative Commons Attribution-NonCommercial-ShareAlike 3.0 Unported License

#define R    iResolution
#define NM    normalize
#define Z0    min(iTime, 0.)
#define sat(x)    clamp(x, 0., 1.)
#define S01(a)    smoothstep(0., 1., a)
#define S(a, b, c)    smoothstep(a, b, c)
#define minH(a, b, c) { float h_ = a; if (h_ < h.d) h = Hit(h_, b, c); }

float t;
struct Hit {
    float d;
    int id;
    vec3 uv;
};

float n31(vec3 p) {
    const vec3 s = vec3(7, 157, 113);
    vec3 ip = floor(p);
    p = fract(p);
    p = p * p * (3. - 2. * p);
    vec4 h = vec4(0, s.yz, s.y + s.z) + dot(ip, s);
    h = mix(fract(sin(h) * 43758.545), fract(sin(h + s.x) * 43758.545), p.x);
    h.xy = mix(h.xz, h.yw, p.y);
    return mix(h.x, h.y, p.z);
}

float n21(vec2 p) { return n31(vec3(p, 1)); }

float smin(float a, float b, float k) {
    float h = sat(.5 + .5 * (b - a) / k);
    return mix(b, a, h) - k * h * (1. - h);
}

float box(vec3 p, vec3 b) { return length(max(abs(p) - b, 0.)); }

float cap(vec3 p, vec2 h) {
    p.y -= clamp(p.y, 0., h.x);
    return length(p) - h.y;
}

Hit map(vec3 p) {
    float d, e, g, lp, r, rz,
          f = S(0., 5., t),
          n = n31(p * 4.);
    d = n21(p.xz * .1) * 3. + p.y + 2.5;
    g = smin(d, length(p - vec3(.2, -8.6, 12.6)) - 6. + .01 * (.5 + .5 * sin(p.y * 22.)), 1.);
    p += vec3(.5 + sin(t * .6) * .2 + .6 * sin(p.z * .4 - .66), 1. - cos(p.z * .3 - .3 - f * mix(.8, 1., S01(sin(t * 1.4) * .5 + .5))) * 1.8, S(28., 30., t) * 2.5 - mix(6., 2.8, f));
    r = .8 + smin(p.z * .18, 2., .5) + abs(sin(p.z * 2.) * S01(p.z) * .05);
    r *= S(-5.3 + 2.75 * cos(t * .8) * f, 1.4, p.z);
    lp = length(p.xy);
    f = abs(lp - r - .05) - .03;
    r *= S(2.5, .35 + sin(t) * .1, p.z);
    d = max(abs(lp - r) - .02, .4 - p.z);
    p.xy = vec2(fract(atan(p.y, p.x) * .477) - .5, lp);
    p.y -= r;
    Hit h = Hit(min(d, box(p, vec3(.2 + p.z * .77, .02, .4))), 2, p);
    p.y += .13;
    vec2 v2 = vec2(.1, sat(.07 * p.y));
    p.z -= .4;
    rz = mod(p.z, .3) - .15;
    e = max(min(cap(vec3(mod(p.x, .08333) - .04167, p.y, rz), v2), cap(vec3(mod(p.x + .04167, .08333) - .04167, p.y, rz - .15), v2)), -0.05 - p.z * 0.2);
    d = abs(p.x) - p.z * .5 - .5;
    minH(max(e, d), 4, p);
    f = max(f, d - .05);
    minH(f, 3, p);
    g = smin(g, h.d, .4 + .4 * n * S(1., 0., abs(g - f)));
    minH(g, 1, p);
    return h;
}

vec3 N(vec3 p, float t) {
    float h = t * .4;
    vec3 n = vec3(0);
    for (int i = min(iFrame, 0); i < 4; i++) {
        vec3 e = .005773 * (2. * vec3(((i + 3) >> 1) & 1, (i >> 1) & 1, i & 1) - 1.);
        n += e * map(p + e * h).d;
    }
    return NM(n);
}

float shadow(vec3 p, vec3 lp) {
    float d, s = 1., t = .1, mxt = length(p - lp);
    vec3 ld = NM(lp - p);
    for (float i = Z0; i < 40.; i++) {
        d = map(t * ld + p).d;
        s = min(s, 15. * d / t);
        t += max(.1, d);
        if (mxt - t < .5 || s < .001) break;
    }
    return S01(s);
}

float ao(vec3 p, vec3 n, float h) { return map(h * n + p).d / h; }

float fog(vec3 v) { return exp(dot(v, v) * -.001); }

vec3 lights(vec3 p, vec3 rd, float d, Hit h) {
    vec3 c, ld = NM(vec3(6, 3, -10) - p), n = N(p, d);
    float spe = 1.;
    if (h.id == 3) { c = vec3(.4, .35, .3); n.y += n31(h.uv * 10.); n = NM(n); }
    else if (h.id == 2) c = mix(vec3(.16, .08, .07), vec3(.6), pow(n31(h.uv * 10.), 3.));
    else if (h.id == 4) c = vec3(.6, 1, 4);
    else { spe = .1; c = vec3(.6); n.x += sin((p.x + p.z * n.z) * 8.) * .1; n = NM(n); }
    float ao = mix(ao(p, n, .2), ao(p, n, 2.), .7);
    return mix((sat(.1 + .9 * dot(ld, n)) * (.1 + .9 * shadow(p, vec3(6, 3, -10))) * (.3 + .7 * ao) + (sat(.1 + .9 * dot(ld * vec3(-1, 0, -1), n)) * .3 + pow(sat(dot(rd, reflect(ld, n))), 10.) * spe) * ao) * c * vec3(1.85, .5, .08), vec3(1.85, .5, .08), S(.7, 1., 1. + dot(rd, n)) * .1);
}

vec4 march(inout vec3 p, vec3 rd, float s, float mx) {
    float i, d = .01;
    Hit h;
    for (i = Z0; i < s; i++) {
        h = map(p);
        if (abs(h.d) < .0015) break;
        d += h.d;
        if (d > mx) return vec4(0);
        p += h.d * rd;
    }
    return vec4(lights(p, rd, d, h), h.id);
}

vec3 scene(vec3 rd) {
    t = mod(iTime, 30.);
    vec3 c, p = vec3(0);
    vec4 col = march(p, rd, 180., 64.);
    float f = 1., x = n31(rd + vec3(-t * 2., -t * .4, t));
    if (col.w == 0.) c = mix(vec3(.5145, .147, .0315), vec3(.22, .06, .01), sat(rd.y * 3.));
    else { c = col.rgb; f = fog(p * (.7 + .3 * x)); }
    f *= 1. - x * x * x * .4;
    return mix(vec3(.49, .14, .03), c, sat(f));
}

#define rgba(col) vec4(pow(max(vec3(0), col), vec3(.45)) * sat(t), 0)

void mainImage(out vec4 fragColor, vec2 fc) {
    vec2 uv = (fc - .5 * R.xy) / R.y, q = fc.xy / R.xy;
    vec3 r = NM(cross(vec3(0, 1, 0), vec3(0, 0, 1))),
         col = scene(NM(vec3(0, 0, 1) + r * uv.x + cross(vec3(0, 0, 1), r) * uv.y));
    col *= .5 + .5 * pow(16. * q.x * q.y * (1. - q.x) * (1. - q.y), .4);
    fragColor = rgba(col) * sat(30. - t);
}
