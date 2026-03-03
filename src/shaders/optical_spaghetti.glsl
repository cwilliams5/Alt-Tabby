// Optical Spaghetti — Shadertoy GLSL (original)
void mainImage(out vec4 fragColor, in vec2 fragCoord)
{
    vec2 u = fragCoord.xy;

    float i = 0.0;
    float a = 0.0;
    float d = 0.0;
    float s = 0.0;
    float t = iTime+10.;
    float r = 0.0;

    vec3 p = iResolution;
    u = (u + u - p.xy) / p.y;

    vec4 o = vec4(0.0);

    for (i = 0.0; i++ <175.0; ) {
        s = 0.004+ abs(s) * 0.1;
        d += s;

        o += s * d;
        o.r += (d*1.5-5. / s) * 0.25;
        o.b += sin(d * 0.09 + p.z * 0.3) *2.0 / s;
        o.g += sin(d * 0.2) * 1. / s;

        p = vec3(u * d, d + t*5.);
        s = min(p.z, 1.9+sin(p.z)*.15);

        for (a = 1.0; a < 2.; a += a) {

             p += cos(t*.1 - p.yzx * 0.5)*.5;

            r = p.z * 0.1 + sin(t * 0.2);

            mat2 rot = mat2(cos(r), -sin(r),sin(r),  cos(r));
            p.xy *= rot;
            s += abs(sin(p.x * a)) * (2.2+sin(t*.1)*.25 )*-abs(sin(abs(p.y) * a) / a);
        }
    }

    o = pow(tanh(o*o / 1.5e8 * length(u)),vec4(1./2.2));
    o*=o;

    fragColor = o;
}
