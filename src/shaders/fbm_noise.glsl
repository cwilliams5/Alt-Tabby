// inspired by https://iquilezles.org/articles/warp

float random(vec2 p)
{
	float x = dot(p,vec2(4371.321,-9137.327));
    return 2.0 * fract(sin(x)*17381.94472) - 1.0;
}

float noise( in vec2 p )
{
    vec2 id = floor( p );
    vec2 f = fract( p );

	vec2 u = f*f*(3.0-2.0*f);

    return mix(mix(random(id + vec2(0.0,0.0)),
                   random(id + vec2(1.0,0.0)), u.x),
               mix(random(id + vec2(0.0,1.0)),
                   random(id + vec2(1.0,1.0)), u.x),
               u.y);
}

float fbm( vec2 p )
{
    float f = 0.0;
    float gat = 0.0;

    for (float octave = 0.; octave < 5.; ++octave)
    {
        float la = pow(2.0, octave);
        float ga = pow(0.5, octave + 1.);
        f += ga*noise( la * p );
        gat += ga;
    }

    f = f/gat;

    return f;
}

float noise_fbm(vec2 p)
{
    float h = fbm(0.09*iTime + p + fbm(0.065*iTime + 2.0 * p - 5.0 * fbm(4.0 * p)));
    return h;
}

float outline(vec2 p, float eps)
{
    float f = noise_fbm(p - vec2(0.0, 0.0));

    float ft = noise_fbm(p - vec2(0.0, eps));
    float fl = noise_fbm(p - vec2(eps, 0.0));
    float fb = noise_fbm(p + vec2(0.0, eps));
    float fr = noise_fbm(p + vec2(eps, 0.0));

    float gg = clamp(abs(4. * f - ft - fr - fl - fb), 0., 1.);

    return gg;
}

void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
    vec2 p = (2.0 * fragCoord - iResolution.xy) / iResolution.y;

    float f = noise_fbm(p);

    float a2 = smoothstep(-0.5, 0.5, f);
    float a1 = smoothstep(-1.0, 1.0, fbm(p));

    vec3 cc = mix(mix(vec3(0.50,0.00,0.10),
                     vec3(0.50,0.75,0.35), a1),
                     vec3(0.00,0.00,0.02), a2);

    cc += vec3(0.0,0.2,1.0) * outline(p, 0.0005);
    cc += vec3(1.0,1.0,1.0) * outline(p, 0.0025);

    cc += 0.5 * vec3(0.1, 0.0, 0.2) * noise_fbm(p);
    cc += 0.25 * vec3(0.3, 0.4, 0.6) * noise_fbm(2.0 * p);

    fragColor = vec4( vec3(cc), 1.0 );
}
