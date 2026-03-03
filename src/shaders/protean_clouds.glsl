// Fork of "Protean clouds" by nimitz. https://shadertoy.com/view/3l23Rh
// 2025-09-27 13:24:14

// 2921

#define rot(a)         mat2(cos( a +vec4(0,11,33,0)))
#define linstep(m,M,x) clamp((x - m)/(M - m), 0., 1.)
#define disp(t)        2.* vec2( sin((t)*.22), cos((t)*.175) )

float prm1; // parameter for gaz animation
vec2  bsMo; // mouse

vec2 map(vec3 p)
{
    vec2 q = p.xy - disp(p.z);
    p.xy *= rot(  sin(p.z+iTime)
                * (.1 + prm1*.05) + iTime*.09 );
    float d, z = 1., trk = z,
        dspAmp = .1 + prm1*.2;

    p *= .61;
    for(int i; i < 5; i++, z *= .57, trk *= 1.4 )
        p += dspAmp * sin( trk*(p.zxy*.75 + iTime*.8) ),
        d -= z * abs( dot(cos(p), sin(p.yzx)) ),
        p *= 1.93 * mat3(.33338, .56034, -.71817, -.87887, .32651, -.15323, .15162, .69596, .61339);

    d = abs(d + prm1*3. )+ prm1*.3 - 2.5 + bsMo.y;
    return vec2(d +.25,0) + dot(q,q)*vec2(.2,1);
}

vec4 render( vec3 ro, vec3 rd, float time )
{
    vec4 rez;
    float ldst = 8., t = 1.5, T = time + ldst, fogT;
    vec3 lpos = vec3( disp(T)*.5, T );
    for(int i; rez.a < .99 && i<130; i++ ) {
        vec3  pos = ro + t*rd;
        vec2  mpv = map(pos);
        float den = clamp(mpv.x - .3, 0.,1.)*1.12,
               dn = clamp(mpv.x + 2., 0.,3.);

        vec4 C;
        if (mpv.x > .6)
        {
            C = vec4( sin(vec3(5.,.4,.2) + mpv.y*.1 +sin(pos.z*.4)*.5 + 1.8)*.5 + .5, .08 );
            C *= den*den*den;
            C.rgb *= linstep(4.,-2.5, mpv.x) *2.3;
            float dif =  clamp((den - map(pos+.8 ).x)/9. , .001, 1. )
                       + clamp((den - map(pos+.35).x)/2.5, .001, 1. );
            C.xyz *= den*( vec3(.005,.045,.075) + 1.5*dif*vec3(.033,.07,.03));
        }

        float fogC = exp(t*.2 - 2.2);  // fog
        C += vec4(.06,.11,.11, .1) *clamp(fogC-fogT, 0., 1.);
        fogT = fogC;

        rez += C *(1. - rez.a);
        t += clamp(.5 - dn*dn*.05, .09, .3);
    }
    return rez;
}

#define getsat(c)  1. -  min(min(c.x, c.y), c.z)  \
                       / max(max(c.x, c.y), c.z)

//from my "Will it blend" shader (https://www.shadertoy.com/view/lsdGzN)
vec3 iLerp(vec3 a, vec3 b, float x)
{
    vec3   ic = mix(a, b, x);
    float lgt = dot(vec3(1), ic),
           sd = abs( getsat(ic) - mix(getsat(a), getsat(b), x) );
    vec3  dir = normalize( ic*3. - lgt );
    ic += 1.5*dir*sd*lgt * dot(dir, normalize(ic));
    return ic; // clamp(ic,0.,1.);
}

void mainImage( out vec4 O, vec2 u )
{
    vec2 R = iResolution.xy,
         q = u/R,                       // for vignetting
         p = (u - .5*R ) / R.y;         // normalized coordinates
    bsMo = (iMouse.xy - .5*R ) / R.y;   // mouse
    prm1 = smoothstep(-.4, .4, sin(iTime*.3) );

    float time = iTime*3.,
        tgtDst = 3.5,
        dspAmp = .85;
    vec3 P = vec3(sin(iTime)*.5,0,time);
    P.xy += disp(P.z)*dspAmp;

    vec3 target = normalize(P - vec3(disp(time + tgtDst)*dspAmp, time + tgtDst)),
       rightdir = normalize(cross(target, vec3(0,1,0))),
          updir = normalize(cross(rightdir, target)),
      rightdir2 = cross(updir, target),
              D = normalize( p.x*rightdir2 + p.y*updir - target);
    D.xy *= rot( bsMo.x - disp(time + 3.5).x*.2 );
    P.x -= bsMo.x*2.;

    vec3 C = render(P, D, time).rgb;

    C = iLerp(C, C.bgr, min(prm1,.95));
    C = pow( C, vec3(.55,.65,.6) ) *vec3(1,.97,.9);
    C *= pow( 16.*q.x*q.y*(1.-q.x)*(1.-q.y), .12)*.7+.3; //vignetting
    O.rgb = C;
}
