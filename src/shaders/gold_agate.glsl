mat2 rot( float a ){ return mat2( sin(a),  cos(a), -cos(a),  sin(a) ); }

float noise( in vec2 x ){ return smoothstep(0.,1.,sin(1.5*x.x)*sin(1.5*x.y)); }

float fbm( vec2 p ){

    mat2 m = rot(.4);
    float f = 0.0;
    f += 0.500000*(0.5+0.5*noise( p )); p = m*p*2.02;
    f += 0.250000*(0.5+0.5*noise( p )); p = m*p*2.03;
    f += 0.125000*(0.5+0.5*noise( p )); p = m*p*2.01;
    f += 0.015625*(0.5+0.5*noise( p ));
    return f/0.96875;
}


float pattern (in vec2 p, out vec2 q, out vec2 r, float t){


	q.x = fbm( 2.0*p + vec2(0.0,0.0) + 2.*t );
    q.y = fbm( 1.5*p + vec2(5.2,1.3) + 1.*t );

    r.x = fbm( p + 4.*q + vec2(1.7,9.2) + sin(t) + .9*sin(30.*length(q)));
    r.y = fbm( p + 8.*q + vec2(8.3,2.8) + cos(t) + .9*sin(20.*length(q)));

    return fbm( p + 7.*r*rot(t) );

}

void mainImage(out vec4 C, in vec2 U){

    vec2 uv = (U.xy-iMouse.xy)/iResolution.xy * 2.;
    uv.x *= iResolution.x/iResolution.y;

    vec2 q,r;
    vec3 col1 = vec3(.9,.7,.5);
    vec3 col2 = vec3(.3,.5,.4);
    vec3 c;

    float f = pattern(uv, q, r, 0.1*iTime);

    //mix colours
    c = mix(col1, vec3(0), pow(smoothstep(.0,.9,f), 2.));
    c += col2 * pow(smoothstep(0., .8, dot(q,r)*.6), 3.) * 1.5;
    //add contrast
    c *= pow(dot(q,r) + .3, 3.);
    //soften the bright parts
    c *= f*1.5;

    //c += vec3(1.7,1.2,1.2) * dot(q,r);
    //c += vec3(.2) * smoothstep(0., .2,pow(length(q),3.));
    //c += dot(q,r);
    //c += smoothstep(0.,3.,pow(length(df),0.12));


    C = vec4( c, 1. );
}
