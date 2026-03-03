// --- Common ---
#define OCTAVES 5

#define TYPE 0
// effect :
// 0 : art effect
// 1 : sparkle effect

// --- Image ---
/*
*
*
*	Inspired by : https://iquilezles.org/articles/warp
*				& https://thebookofshaders.com/
*
*
*/

float rand(vec2 st)
{
    return fract(sin(dot(st,
                         vec2(12.9898,78.233)))*
        43758.5453123);
}

float noise (in vec2 st) {
    vec2 i = floor(st);
    vec2 f = fract(st);

    // Four corners in 2D of a tile
    float a = rand(i);
    float b = rand(i + vec2(1.0,0.0));
    float c = rand(i + vec2(0.0, 1.0));
    float d = rand(i + vec2(1.0, 1.0));

    vec2 u = smoothstep(0.0,1.0, f);

    return mix(a, b, u.x) +
            (c - a)* u.y * (1.0 - u.x) +
            (d - b) * u.x * u.y;
}


float fbm (in vec2 st) {
    // Initial values
    float value = 0.0;
    float amplitude = .5;
    float frequency = 0.;
    //
    // Loop of octaves
    for (int i = 0; i < OCTAVES; i++) {
        value += amplitude * noise(st);
        st *= 2.;
        amplitude *= .5;
    }
    return value;
}

float pattern( in vec2 p, out vec2 q, out vec2 r , in float time)
{
    q.x = fbm( p + vec2(0.0,0.0) );
    q.y = fbm( p + vec2(5.2,1.3) );

    q += vec2(sin(iTime*0.25), sin(iTime*0.3538));

    r.x = fbm( p + 4.0*q + vec2(1.7,9.2) );
    r.y = fbm( p + 4.0*q + vec2(8.3,2.8) );

    r += vec2(sin(iTime*0.125), sin(iTime*0.43538));

    return fbm( p + 4.0*r );

}

void mainImage( out vec4 fragColor, in vec2 fragCoord )
{

    vec2 uv = 10.0* fragCoord/iResolution.x;


    vec2 q, r;
    float val = pattern(uv, q, r, iTime);
    vec3 col = vec3(0.0);

#if TYPE == 0
    col = mix(vec3(q*0.1,0.0), vec3(r, 0.5*sin(iTime) + 0.5),val);
#elif TYPE == 1
    col = mix(vec3(q*r,0.0), vec3(0.0),step(val, 0.8));
#endif

    // Output to screen
    fragColor = vec4(col,1.0);
}
