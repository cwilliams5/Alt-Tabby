// Hazel Quantock 2014
// License Creative Commons Attribution-NonCommercial-ShareAlike 3.0 Unported License.


const float tau = 6.28318530717958647692;

#if ( 1 ) // is hash noise or texture noise faster?

// texture noise
vec2 Noise( in vec3 x )
{
    vec3 p = floor(x), f = fract(x);
	f = f*f*(3.0-2.0*f);
	vec2 uv = (p.xy+vec2(37.0,17.0)*p.z) + f.xy;
	vec4 rg = textureLod( iChannel0, (uv+0.5)/256.0, 0.0 );
	return mix( rg.yw, rg.xz, f.z );
}

#else

// hash noise adapted from IQ
float hash( vec3 p )
{
	float h = dot(p,vec3(127.1,311.7,201.3));

    return fract(sin(h)*43758.5453123);
}

float noise( in vec3 p )
{
    vec3 i = floor( p );
    vec3 f = fract( p );

	vec3 u = f*f*(3.0-2.0*f);

    return mix(mix( mix( hash( i + vec3(0,0,0) ),
                         hash( i + vec3(1,0,0) ), u.x),
                    mix( hash( i + vec3(0,1,0) ),
                         hash( i + vec3(1,1,0) ), u.x), u.y),
               mix( mix( hash( i + vec3(0,0,1) ),
                         hash( i + vec3(1,0,1) ), u.x),
                    mix( hash( i + vec3(0,1,1) ),
                         hash( i + vec3(1,1,1) ), u.x), u.y), u.z );
}

vec2 Noise( in vec3 x )
{
    return vec2( noise(x), noise(x.zxy) );
}

#endif


vec4 Density( vec3 pos )
{
    pos /= 30.0;
    vec2 s = vec2(0);
	s += Noise(pos.xyz/1.0)/1.0;
	s += Noise(pos.zxy*2.0)/2.0;
	s += Noise(pos.yzx*4.0)/4.0;
	s += Noise(pos.xzy*8.0)/8.0;

    s /= 2.0-1.0/8.0;

    s.y = pow(s.y,5.0)*1.0;

    //s.y *= smoothstep( 2.5, .0, length(pos) );

    return vec4(pow(sin(vec3(1,2,5)+tau*s.x)*.5+.5,vec3(1.0))*16.0,s.y);
}


vec3 Path( float time )
{
    // sort of like a spirograph pattern, but more random
    time *= .2;
    vec2 a = vec2(1,.3)*time;
    float r = sin(time*1.2)*.2+.8;

    return 100.0*r*vec3(cos(a.x),1,sin(a.x))*vec2(cos(a.y),sin(a.y)).xyx;
}


void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
    float T = iTime;

    // create a camera without constant "up", so we get more spacey feel and more variety

    // fly a "plane", with a free camera inside it
    // i.e. "up" stays in the plane of the curve


    vec3 pos = Path(T);

    float d = .5;
    vec3 a=Path(T+d), b=Path(T-d);
    vec3 sky = (a+b)/2.0-pos;

    // alternate between looking forward and looking toward centre of nebula, for parallax
    vec3 forward = normalize( mix( normalize(a-b), normalize(vec3(0)-pos), smoothstep( -.2, .2, sin(T*.2) ) ) );
    vec3 right = normalize(cross(sky,forward));
    vec3 up = normalize(cross(forward,right));

    vec2 uv = (fragCoord.xy-iResolution.xy*.5)/iResolution.y;
    vec3 ray = forward*1.0 + right*uv.x + up*uv.y;
    ray = normalize(ray);

    vec3 c = vec3(0,0,0);
	float t = 0.0;
    float baseStride = 3.0; // small enough to detect the highest frequency details
    float stride = baseStride;
    float visibility = 1.0;
    for ( int i=0; i < 30; i++ )
    {
        if ( visibility < .001 ) break; // causes "ripples" on things, but not bad.

        vec4 samplev = Density( pos + t*ray );
        float visibilityAfterSpan = pow( 1.0-samplev.a, stride );

		// optional: don't allow any non-occluding glow
        samplev.rgb *= samplev.a;

        c += samplev.rgb*visibility*(1.0-visibilityAfterSpan); // this seems too easy!
        visibility *= visibilityAfterSpan;

//        float newStride = baseStride/visibility; // this is wrong, but looks amazing!
        float newStride = baseStride/mix(1.0,visibility,.3); // step further when visibility is reduced (but not too much
        t += (stride+newStride)*.5;
        stride = newStride;
    }

    c = pow(c,vec3(1.0/2.2));

    // dithering, because I can see banding
    c += (texture(iChannel1,(fragCoord.xy+.5)/8.0,-100.0).x-.5)/256.0;

	fragColor = vec4(c,1);
}