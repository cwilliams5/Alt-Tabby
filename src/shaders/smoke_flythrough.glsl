// A simple cloud shader to test my volumetric renderer, the noise is very bad and cheap.

#define LOOK 0
#define NUM_STEPS 256 // marching steps, higher -> better quality

// aces tonemapping
vec3 ACES(vec3 x) {
    float a = 2.51;
    float b =  .03;
    float c = 2.43;
    float d =  .59;
    float e =  .14;
    return (x*(a*x+b))/(x*(c*x+d)+e);
}

// camera path
vec2 camPath(float t) {
    return vec2(.4*sin(t),.4*cos(t*.5));
}

// generate a number between 0 and 1
float hash(float n) {return fract(sin(n)*43758.5453123);}

// 3d noise function
float noise(vec3 x) {
    vec3 p = floor(x+.5);
    vec3 f = fract(x+.5);
    f = f*f*(3.-2.*f);

    x = p + f - .5;
    return textureLod(iChannel0, x/iChannelResolution[0], 0.).r;
}

// smooth minimum
// thanks to iq: https://iquilezles.org/articles/smin/
float smin(float a, float b, float k) {
	float h = clamp(.5+.5*(b-a)/k, 0., 1.);
	return mix(b, a, h) - k*h*(1.-h);
}

// volume density
float map(vec3 p) {
    float f = 0.;

    // smoke fbm
    vec3 q = p;
    p *= 3.;
    f += .5*noise(p);
    f += .25*noise(2.*p);
    f += .0625*noise(7.*p);
    f += .03125*noise(16.*p);
    f -= .35;

    // tunnel
    q.xy -= camPath(q.z);
    f = smin(f, .1-length(q.xy), -.4);

    return -256.*f;
}

#if LOOK==0
// light intensity function
float getLight(float h, float k, vec3 ce, vec3 p) {
    vec3 lig = ce-p;
    float llig = length(lig);
    lig = normalize(lig);
    float sha = clamp((h - map(p + lig*k))/128.,0.,1.);
    float att = 1./(llig*llig);
    return sha*att;
}
#endif

// volumetric rendering
vec3 render(vec3 ro, vec3 rd) {
    float tmax = 6.; // maximum distance
    float s = tmax / float(NUM_STEPS); // step size
    float t = 0.; // distance travelled
    // dithering
    t += s*hash(gl_FragCoord.x*8315.9213/iResolution.x+gl_FragCoord.y*2942.5192/iResolution.y);
    vec4 sum = vec4(0,0,0,1); // final result

    for (int i=0; i<NUM_STEPS; i++) { // marching loop
        vec3 p = ro + rd*t; // current point
        float h = map(p); // density

        if (h>0.) { // inside the volume
            // lighting
            float occ = exp(-h*.1); // occlusion

            #if LOOK==0
            float k = .08;
            vec3 col = 3.*vec3(.3,.6,1)*getLight(h, k, ro+vec3(1,0,2), p)*occ
                     + 3.*vec3(1,.2,.1)*getLight(h, k, ro+vec3(-1,0,2.5), p)*occ;
            #else
            vec3 col = .1*vec3(.6,.8,1)*occ;
            #endif

            sum.rgb += h*s*sum.a*col; // add the color to the final result
            sum.a *= exp(-h*s); // beer's law
        }

        if (sum.a<.01) break; // optimization
        t += s; // march
    }

    // output
    return sum.rgb;
}

// camera function
mat3 setCamera(vec3 ro, vec3 ta) {
    vec3 w = normalize(ta - ro); // forward vector
    vec3 u = normalize(cross(w, vec3(0,1,0))); // side vector
    vec3 v = cross(u, w); // cross vector
    return mat3(u, v, w);
}

void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
    // pixel coordinates centered at the origin
    vec2 p = (fragCoord - .5*iResolution.xy) / iResolution.y;

    vec3 ro = vec3(0,0,iTime); // ray origin
    vec3 ta = ro + vec3(0,0,1); // target

    ro.xy += camPath(ro.z);
    ta.xy += camPath(ta.z);

    mat3 ca = setCamera(ro, ta); // camera matrix
    vec3 rd = ca * normalize(vec3(p,1.5)); // ray direction

    vec3 col = render(ro, rd); // render

    col = ACES(col); // tonemapping
    col = pow(col, vec3(.4545)); // gamma correction

    // vignette and black bars
    vec2 q = fragCoord/iResolution.xy;
    col *= pow(16. * q.x*q.y*(1.-q.x)*(1.-q.y), .1);
    col *= step(abs(q.y-.5),.4);

    // output
    fragColor = vec4(col,1.0);
}