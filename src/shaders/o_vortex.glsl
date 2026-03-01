// Original shader author: poopsock
// Extracted and adapted to Shadertoy by: akai_hana

int cell_amount = 2;
vec2 period = vec2(5., 10.);

vec2 modulo(vec2 divident, vec2 divisor){
	vec2 positiveDivident = mod(divident, divisor) + divisor;
	return mod(positiveDivident, divisor);
}

vec2 random(vec2 value){
	value = vec2( dot(value, vec2(127.1,311.7) ),
				  dot(value, vec2(269.5,183.3) ) );
	return -1.0 + 2.0 * fract(sin(value) * 43758.5453123);
}

float noise(vec2 uv) {
    vec2 _period = vec2(3.);
	uv = uv * float(cell_amount);
	vec2 cMin = floor(uv);
	vec2 cMax = ceil(uv);
	vec2 uvFract = fract(uv);

	cMin = modulo(cMin, _period);
	cMax = modulo(cMax, _period);

	vec2 blur = smoothstep(0.0, 1.0, uvFract);

	vec2 ll = random(vec2(cMin.x, cMin.y));
	vec2 lr = random(vec2(cMax.x, cMin.y));
	vec2 ul = random(vec2(cMin.x, cMax.y));
	vec2 ur = random(vec2(cMax.x, cMax.y));

	vec2 fraction = fract(uv);

	return mix( mix( dot( ll, fraction - vec2(0, 0) ),
                     dot( lr, fraction - vec2(1, 0) ), blur.x),
                mix( dot( ul, fraction - vec2(0, 1) ),
                     dot( ur, fraction - vec2(1, 1) ), blur.x), blur.y) * 0.8 + 0.5;
}

float fbm(vec2 uv) {
    float amplitude = 0.5;
    float frequency = 3.0;
	float value = 0.0;

    for(int i = 0; i < 6; i++) {
        value += amplitude * noise(frequency * uv);
        amplitude *= 0.5;
        frequency *= 2.0;
    }
    return value;
}

vec2 polar(vec2 uv, vec2 center, float zoom, float repeat)
{
	vec2 dir = uv - center;
	float radius = length(dir) * 2.0;
	float angle = atan(dir.y, dir.x) * 1.0/(3.1416 * 2.0);
	return vec2(radius * zoom, angle * repeat);
}

float sdfCircle(vec2 p, vec2 o, float r) {
    return 0.0;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord)
{
    vec2 uv = floor((2. * fragCoord - iResolution.xy) / iResolution.y * 1000.) / 500.;
    vec2 puv = polar(uv, vec2(0.), .5, 1.);
    vec3 c = vec3(0.);

	vec4 milkBlack = vec4(vec3(0.050980392156862744, 0.050980392156862744, 0.0784313725490196), 1.0);
    vec4 milkGrey = vec4(vec3(0.3215686274509804, 0.14901960784313725, 0.24313725490196078), 1.0);
    vec4 milkWhite = vec4(vec3(0.6745098039215687, 0.19607843137254902, 0.19607843137254902), 1.0);

    float n = fbm(puv * vec2(1., 1.) + vec2(iTime * .2, 5. / (puv.x) * -.1) * .5);
    n = n*n / sqrt(puv.x) * .8;

    c = vec3(milkBlack);
    if (n > 0.2) {
        c = vec3(milkGrey);
    }
    if (n > 0.25) {
        c = vec3(milkWhite);
    }
    if (puv.x < .4) {
        c = vec3(milkBlack);
    }
    fragColor = vec4(c, 1.);
}
