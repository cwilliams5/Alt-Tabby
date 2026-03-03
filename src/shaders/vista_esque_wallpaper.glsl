vec3 palette( float t ) {

    vec3 a = vec3(0.667, 0.500, 0.500);
    vec3 b = vec3(0.500, 0.667, 0.500);
    vec3 c = vec3(0.667, 0.666, 0.500);
    vec3 d = vec3(0.200, 0.000, 0.500);

    return a + b*cos( 6.28318*(c*t*d) );
}

void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
    float wave = sin(iTime*2.);

    vec2 uv = fragCoord / iResolution.xy;
    vec3 finalCol = vec3(0);



    for (float i = 0.0; i < 7.0; i++) {

        float d = uv.g;
        float w = uv.r;

        d = sin(d - 0.3 * 0.1 * (wave/5.+5.)) + sin(uv.r * 2. + iTime/2.)/20. - sin(i)/10. + sin(uv.r * 4.3 + iTime*1.3 * i*0.2)/20.;
        d = abs(d/2.);
        d = 0.003/d /8. *i;

        w += sin(uv.g*2. + iTime)/60.;
        w = abs(sin(w*20.*i/4. + iTime*sin(i))/20. + sin(w*10.*i)/17.)*30.;
        w += uv.g*2.4-1.6;
        w /= 3.;
        w = smoothstep(0.4, 0.7, w)/20.;

        vec3 col = palette(uv.r + iTime/3.);

        finalCol += col *= d + w;
    }

    fragColor = vec4(finalCol,1.0);
}
