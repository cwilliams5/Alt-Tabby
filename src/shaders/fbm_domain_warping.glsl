// #define DEBUG_PALETTE

float hash21(vec2 v) {
    return fract(sin(dot(v, vec2(12.9898, 78.233))) * 43758.5453123);
}

float noise(vec2 uv) {
	vec2 f = fract(uv);
	vec2 i = floor(uv);
	f = f * f * (3. - 2. * f);
	return mix(
		mix(hash21(i), hash21(i + vec2(1,0)), f.x),
		mix(hash21(i + vec2(0,1)), hash21(i + vec2(1,1)), f.x), f.y);
}

float fbm(vec2 uv) {
	float freq = 2.;
	float amp = .5;
	float gain = .54;
	float v = 0.;
	for(int i = 0; i < 6; ++i) {
		v += amp * noise(uv);
		amp *= gain;
		uv *= freq;
	}
	return v;
}

float fbmPattern(vec2 p, out vec2 q, out vec2 r) {
	float qCoef = 2.;
	float rCoef = 3.;
	q.x = fbm(p             + .0  * iTime);
	q.y = fbm(p             - .02 * iTime + vec2(10., 7.36));
	r.x = fbm(p + qCoef * q + .1  * iTime + vec2(5., 3.));
	r.y = fbm(p + qCoef * q - .07 * iTime + vec2(10., 7.36));
	return fbm(p + rCoef * r + .1 * iTime);
}

vec3 basePalette(float t) {
	return .5 + .6 * cos(6.283185 * (-t + vec3(.0, .1, .2) - .2));
}

vec3 smokePalette(float t) {
	return vec3(.6, .5, .5)
		+ .5 * cos(6.283185 * (-vec3(1., 1., .5) * t + vec3(.2, .15, -.1) - .2));
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
	vec2 uv = fragCoord/iResolution.yy;

	float scale = 5.;
	vec3 col = vec3(.1);
	float n;

	vec2 q;
	vec2 r;
	n = fbmPattern(scale * uv, q, r);
	vec3 baseCol = basePalette(r.x);
	vec3 smokeCol = smokePalette(n);

	col = mix(baseCol, smokeCol, pow(q.y, 1.3));

#ifdef DEBUG_PALETTE
    float x = fragCoord.x / iResolution.x;
	col = mix(col, basePalette(x), step(abs(uv.y - .03), .02));
	col = mix(col, smokePalette(x), step(abs(uv.y - .08), .02));
#endif

	fragColor = vec4(col, 1);
}
