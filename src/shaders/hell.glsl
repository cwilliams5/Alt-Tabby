float noise( in vec3 x )
{
    vec3 p = floor(x);
    vec3 f = fract(x);
	f = f*f*(3.0-2.0*f);
	
	vec2 uv = (p.xy+vec2(37.0,17.0)*p.z) + f.xy;
	vec2 rg = textureLod( iChannel0, (uv+ 0.5)/256.0, 0.0 ).yx;
	return mix( rg.x, rg.y, f.z );
}

vec4 map( vec3 p )
{
	float den = 0.2 - p.y;

    // invert space	
	p = -7.0*p/dot(p,p);

    // twist space	
	float co = cos(den - 0.25*iTime);
	float si = sin(den - 0.25*iTime);
	p.xz = mat2(co,-si,si,co)*p.xz;

    // smoke	
	float f;
	vec3 q = p                          - vec3(0.0,1.0,0.0)*iTime;;
    f  = 0.50000*noise( q ); q = q*2.02 - vec3(0.0,1.0,0.0)*iTime;
    f += 0.25000*noise( q ); q = q*2.03 - vec3(0.0,1.0,0.0)*iTime;
    f += 0.12500*noise( q ); q = q*2.01 - vec3(0.0,1.0,0.0)*iTime;
    f += 0.06250*noise( q ); q = q*2.02 - vec3(0.0,1.0,0.0)*iTime;
    f += 0.03125*noise( q );

	den = den + 4.0*f;
	
	vec3 col = mix( vec3(1.0,0.9,0.8), vec3(0.4,0.15,0.1), den ) + 0.05*sin(p);
	
	return vec4( col, den );
}

vec3 raymarch( in vec3 ro, in vec3 rd, in vec2 pixel )
{
	vec4 sum = vec4( 0.0 );

    // dithering	
    float t = 0.05*fract( 10.5421*dot(vec2(0.0149451,0.038921),pixel));
	
	for( int i=0; i<150; i++ )
	{
		vec3 pos = ro + t*rd;
		vec4 col = map( pos );
        if( col.w>0.0 )
        {
            //float len = length(pos);
            col.w = min(col.w,1.0);
            
            col.xyz *= mix( 3.1*vec3(1.0,0.5,0.05), vec3(0.48,0.53,0.5), clamp( (pos.y-0.2)/1.9, 0.0, 1.0 ) );
            //col.xyz *= mix( 3.1*vec3(1.0,0.5,0.05), vec3(0.48,0.53,0.5), clamp( 0.35*col.w+0.15*dot(pos,pos), 0.0, 1.0 ) );

            col.a *= 0.6;
            col.rgb *= col.a;

            sum = sum + col*(1.0 - sum.a);	
            if( sum.a > 0.99 ) break;
        }
		t += 0.05;
	}

	return clamp( sum.xyz, 0.0, 1.0 );
}

void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
    vec2 p = (2.0*fragCoord-iResolution.xy)/iResolution.y;
	
    // camera
    vec3 ro = 4.0*normalize(vec3(1.0, 1.5, 0.0));
	vec3 ta = vec3(0.0, 1.0, 0.0) + 0.05*(-1.0+2.0*textureLod( iChannel0, iTime*vec2(0.013,0.008), 0.0 ).xyz);
	float cr = 0.5*cos(0.7*iTime);
	
	// build ray
    vec3 ww = normalize( ta - ro);
    vec3 uu = normalize(cross( vec3(sin(cr),cos(cr),0.0), ww ));
    vec3 vv = normalize(cross(ww,uu));
    vec3 rd = normalize( p.x*uu + p.y*vv + 2.0*ww );
	
    // raymarch	
	vec3 col = raymarch( ro, rd, fragCoord );
	
	// color grade
	col = col*0.5 + 0.5*col*col*(3.0-2.0*col);
    
    // vignetting	
    vec2 q = fragCoord.xy / iResolution.xy;
	col *= 0.2 + 0.8*pow( 16.0*q.x*q.y*(1.0-q.x)*(1.0-q.y), 0.1 );
	
    fragColor = vec4( col, 1.0 );
}