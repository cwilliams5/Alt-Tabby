// Day 134 !
// Having a play with isolayers.

# define res iResolution.xy

vec3 pal( in float t, in vec3 a, in vec3 b, in vec3 c, in vec3 d )
{
    return a + b*cos( 6.28318*(c*t+d) );
}

float hash(vec2 p) {p += .4; vec3 p3 = fract(vec3(p.xyx) * 0.13); p3 += dot(p3, p3.yzx + 3.333); return fract((p3.x + p3.y) * p3.z); }
float noise(vec2 x) {
    vec2 i = floor(x);
    vec2 f = fract(x);

	float a = hash(i);
    float b = hash(i + vec2(1.0, 0.0));
    float c = hash(i + vec2(0.0, 1.0));
    float d = hash(i + vec2(1.0, 1.0));

    vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

float fbm(vec2 x) {
	float v = 0.0;
	float a = 0.5;
	vec2 shift = vec2(100);

    mat2 rot = mat2(cos(0.5), sin(0.5), -sin(0.5), cos(0.50));
	for (int i = 0; i < 7; ++i) {
		v += a * noise(x);
		x = rot * x * 2.0 + shift;
		a *= 0.5;
	}
	return v;
}

vec3 getColor(vec2 p) {
    float f = fbm(p) - 0.1 * iTime;
    float n = floor(f * 10.0) / 10.0;

    vec3 col;

    float t = 2.0 * abs(fract(f * 10.0) - 0.5);

    vec3 a = vec3(0.5, 0.5, 0.5),
         b = vec3(0.5, 0.5, 0.5),
         c = vec3(1.0, 1.0, 1.0),
         d = vec3(0.3, 0.5, 0.7);

    vec3 c1 = pal( 9.19232 * n, a, b, c, d);
    vec3 c2 = pal( 9.19232 * (n - 1.0 / 10.0), a, b, c, d);

    col = mix(c1, c2, pow(t, 15.0));

    return col;
}

void mainImage( out vec4 O, in vec2 I )
{
    vec2 p = 5.0 * (I - 0.5 * res) / res.y;

    vec3 col;

    col = getColor(p) - 0.3 * getColor(p + 0.02) - 0.3 * getColor(p + 0.01);
    col *= 2.0;

    col = pow(col, vec3(1) / 2.2);

    O = vec4(col, 1.0);
}
