#define H(a) (cos(radians(vec3(90, 30, -30))-((a)*6.2832))*.5+.5)  // hue pallete
#define RT(a) mat2(cos(m.a*1.571+vec4(0,-1.571,1.571,0)))          // rotate
float cubes(vec3 p) { p = abs(p-round(p)); return max(p.x, max(p.y, p.z)); }
void mainImage( out vec4 C, in vec2 U )
{
    float aa = 2., // anti-aliasing (1 = off)
          d, s;
    vec2 R = iResolution.xy,
         m = (iMouse.xy/R*4.)-2.,
         o;
    vec3 c = vec3(0), // black background
         cam = vec3(vec2(.5), iTime/4.),
         u, v;
    if (iMouse.z < 1.) m = vec2(cos(iTime/8.)*.5+.5); // rotate with time
    mat2 pitch = RT(y),
         yaw   = RT(x);
    for (int k = 0; k < int(aa*aa); k++) // aa loop
    {
        o = vec2(k%2, k/2)/aa; // aa offset
        u = normalize(vec3((U-.5*R+o)/R.y, .7));
        u.yz *= pitch;
        u.xz *= yaw;
        d = 0.; // step dist for raymarch
        for (int i = 0; i < 50; i++) // raymarch loop
        {
            s = smoothstep(.2, .25, cubes(cam+u*d)-.05);
            if (s < 0.01) break;
            d += s;
        }
        v = d*.01*H(length(u.xy)); // objects & color
        c += v + max(v, .5-H(d));  // add to bg
    }
    c /= aa*aa;
    C = vec4(exp(log(c)/2.2), 1);
}
