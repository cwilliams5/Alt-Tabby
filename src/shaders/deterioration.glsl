// Deterioration by @blokatt
// 11/04/19
// Mesmerising...

mat2 rot(float a){
	return mat2 (
        cos(a), -sin(a),
        sin(a), cos(a)
    );
}

float rand(vec2 uv){
	return fract(sin(dot(vec2(12.9898,78.233), uv)) * 43758.5453123);
}

float valueNoise(vec2 uv){
    vec2 i = fract(uv);
    vec2 f = floor(uv);
	float a = rand(f);
    float b = rand(f + vec2(1.0, 0.0));
    float c = rand(f + vec2(0.0, 1.0));
    float d = rand(f + vec2(1.0, 1.0));
    return mix(mix(a, b, i.x), mix(c, d, i.x), i.y);
}

float fbm(vec2 uv) {
    float v = 0.0;
    float freq = 9.5;
    float amp = .75;
    float z = (20. * sin(iTime * .2)) + 30.;

    for (int i = 0; i < 10; ++i) {
        v += valueNoise(uv + (z * uv * .05) + (iTime * .1)) * amp;
    	uv *= 3.25;
        amp *= .5;
    }

    return v;
}

void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
    vec2 uv = fragCoord/iResolution.xy - .5;
	vec2 oldUV = uv;
    uv.x *= iResolution.x / iResolution.y;
    vec3 col = (0.5 * cos(iTime + uv.xyx + vec3(0., 2., 4.))) + 0.5;
    uv *= rot(iTime * .02);
    mat2 angle = rot(fbm(uv));
    fragColor = vec4(vec3(
                    	fbm((vec2(5.456, -2.8112) * angle) + uv),
                    	fbm((vec2(5.476, -2.8122) * angle) + uv),
                    	fbm((vec2(5.486, -2.8132) * angle) + uv)
                 	) - (smoothstep(.1, 1., length(oldUV))), 1.);
}
