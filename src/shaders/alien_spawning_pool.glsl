// 'Alien Spawning Pool' by @christinacoffin
// License Creative Commons Attribution-NonCommercial-ShareAlike 3.0 Unported License.
//
// hacked up version of https://www.shadertoy.com/view/4s23zz#
// See https://iquilezles.org/articles/warp for details
//
//
#define iGlobalTime iTime
float noise( in vec2 x )
{
    x.x +=0.3*cos(x.y+(iTime*0.3));//crawling under myyyy skinnn!
    x.y +=0.3*sin(x.x);
    vec2 p = floor(x);
    vec2 f = fract(x);
    f = f*f*(3.0-2.0*f);

    //edit: using texture instead of textureLod so this compiles+runs on mobile
    vec4 a_vec = texture(iChannel0,(p+vec2(0.5,0.5))/256.0,-32.0);
	vec4 b_vec = texture(iChannel0,(p+vec2(1.5,0.5))/256.0,-32.0);
	vec4 c_vec = texture(iChannel0,(p+vec2(0.5,1.5))/256.0,-32.0);
	vec4 d_vec = texture(iChannel0,(p+vec2(1.5,1.5))/256.0,-32.0);

    float a = a_vec.x;
    float b = b_vec.x;
    float c = c_vec.x;
    float d = d_vec.x;

    return mix(mix( a, b,f.x), mix( c, d,f.x),f.y);
}

const mat2 mtx = mat2( 0.480,  0.60, -0.60,  0.480 );

float fbm4( vec2 p )
{
    float f = 0.0;

    f += 0.15000*(-1.0+2.0*noise( p )); p = mtx*p*2.02;
    f += 0.2500*(-1.0+2.0*noise( p )); p = mtx*p*2.03;
    f += 0.1250*(-1.0+2.0*noise( p )); p = mtx*p*2.01;
    f += 0.0625*(-1.0+2.0*noise( p ));

    return f/0.9375;
}

float fbm6( vec2 p )
{
    float f = 0.0;

    f += 0.500000*noise( p ); p = mtx*p*2.02;
    f += 0.250000*noise( p ); p = mtx*p*2.03;
    f += 0.63125000*noise( p ); p = mtx*p*2.01;
    f += 0.062500*noise( p ); p = mtx*p*2.04;
    f += 0.031250*noise( p ); p = mtx*p*2.01;
    f += 0.015625*noise( p );

    return f/0.996875;
}

float func( vec2 q, out vec2 o, out vec2 n )
{
    float ql = length( q );
    q.x += 0.015*sin(0.11*iGlobalTime+ql*14.0);
    q.y += 0.035*sin(0.13*iGlobalTime+ql*14.0);
    q *= 0.7 + 0.2*cos(0.05*iGlobalTime);

    q = (q+1.0)*0.5;

    o.x = 0.5 + 0.5*fbm4( vec2(2.0*q*vec2(1.0,1.0)          )  );
    o.y = 0.5 + 0.5*fbm4( vec2(2.0*q*vec2(1.0,1.0)+vec2(5.2))  );

    float ol = length( o*o );
    o.x += 0.003*sin(0.911*iGlobalTime*ol)/ol;
    o.y += 0.002*sin(0.913*iGlobalTime*ol)/ol;


    n.x = fbm6( vec2(4.0*o*vec2(1.0,1.0)+vec2(9.2))  );
    n.y = fbm6( vec2(4.0*o*vec2(1.0,1.0)+vec2(5.7))  );

    vec2 p = 11.0*q + 3.0*n;

    float f = 0.5 + 0.85*fbm4( p );

    f = mix( f, f*f*f*-3.5, -f*abs(n.x) );

    float g = 0.5+0.5*sin(1.0*p.x)*sin(1.0*p.y);
    f *= 1.0-0.5*pow( g, 7.0 );

    return f;
}

float funcs( in vec2 q )
{
    vec2 t1, t2;
    return func(q,t1,t2);
}


void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
	vec2 p = fragCoord.xy / iResolution.xy;
	vec2 q = (-iResolution.xy + 2.0*fragCoord.xy) /iResolution.y;
    vec2 o, n;
    float f = func(q, o, n);
    vec3 col = vec3(-0.91620);
	col = mix( vec3(0.2,0.1,0.4), col, f );
    col = mix( vec3(0.2,0.1,0.4), col * vec3(0.13,0.05,0.05), f );
    col = mix( col, vec3(0.19,0.9,0.9), dot(n,n)*n.x*1.357 );
    col = mix( col, vec3(0.5,0.2,0.2), 0.5*o.y*o.y );
	col += 0.05*mix( col, vec3(0.9,0.9,0.9), dot(n,n) );
    col = mix( col, vec3(0.0,0.2,0.4), 0.5*smoothstep(1.02,1.3,abs(n.y)+abs(n.x*n.x)) );
    col *= f*(5.92+(1.1*cos(iTime)));//animate glowy translucent underbits

	col = mix( col, vec3(-1.0,0.2,0.4), 0.5*smoothstep(1.02,1.3,abs(n.y)+abs(n.x*n.x)) );
	col = mix( col, vec3(0.40,0.92,0.4), 0.5*smoothstep(0.602,1.93,abs(n.y)+abs(n.x*n.x)) );

    vec2 ex = -1.* vec2( 2.0 / iResolution.x, 0.0 );
    vec2 ey = -1.*vec2( 0.0, 2.0 / iResolution.y );
	vec3 nor = normalize( vec3( funcs(q+ex) - f, ex.x, funcs(q+ey) - f ) );
    vec3 lig = normalize( vec3( 0.19, -0.2, -0.4 ) );
    float dif = clamp( 0.03+0.7*dot( nor, lig ), 0.0, 1.0 );

    vec3 bdrf;
    bdrf  = vec3(0.85,0.90,0.95)*(nor.y*0.5+0.5);
    bdrf += vec3(0.15,0.10,0.05)*dif;
    col *= bdrf/f;
    col = vec3(0.8)-col;
    col = col*col;
    col *= vec3(0.8,1.15,1.2);
	col *= 0.45 + 0.5 * sqrt(16.0*p.x*p.y*p.y*(2.0-p.x)*(1.0-p.y)) * vec3(1.,0.3,0.);

    col = clamp(col,0.0,1.0);
	fragColor = vec4( col, 1.0 );
}