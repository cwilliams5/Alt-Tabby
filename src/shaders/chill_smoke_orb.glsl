#define T (iTime)

float orb(vec3 p) {
    // orb time
    float t = T * 4.;
    return length(p - vec3(
            sin(sin(t*.2)+t*.4) * 6.,
            1.+sin(sin(t*.5)+t*.2) *4.,
            12.+T+cos(t*.3)*8.));
}

void mainImage(out vec4 o, vec2 u) {
    float d,a,e,i,s,t = T ;
    vec3  p = iResolution;

    // scale coords
    u = (u+u-p.xy)/p.y;

    // camera movement
    u += vec2(cos(t*.1)*.3, cos(t*.3)*.1);

    for(o*=i; i++<128.;

        // accumulate distance
        d += s = min(.03+.2*abs(s),e=max(.5*e, .01)),

        // grayscale color and orb light
        o += 1./(s+e*3.))

        // noise loop start, march
        for (p = vec3(u*d,d+t), // p = ro + rd *d, p.z + t;

            // entity (orb)
            e = orb(p)-.1,

            // spin by t, twist by p.z
            p.xy *= mat2(cos(.1*t+p.z/8.+vec4(0,33,11,0))),

            // mirrored planes 4 units apart
            s = 4. - abs(p.y),

            // noise starts at .8 up to 32., grow by a+=a
            a = .8; a < 32.; a += a)

            // apply turbulence
            p += cos(.7*t+p.yzx)*.2,

            // apply noise
            s -= abs(dot(sin(.1*t+p * a ), .6+p-p)) / a;

    // tanh tonemap, brightness, light off-screen
    o = tanh(o/1e1);
}
