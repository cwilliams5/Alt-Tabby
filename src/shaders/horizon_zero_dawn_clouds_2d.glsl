/**
I tried modeling clouds using perlin-worley noise as described by Andrew Schneider
in the chapter Real-Time Volumetric Cloudscapes of GPU Pro 7. There are two types
of worley fbm functions used, a low frequency one to model the cloud shapes, and
a high frequency one used to add finer details around the edges of the clouds. Finally,
a simple 2D ray march along the light direction to add some fake lighting and shadows
to the cloudscapes.

Drag around the sun with the mouse to see a change in the lighting.
*/

#define SAT(x) clamp(x, 0., 1.)

#define CLOUD_COVERAGE 0.64
#define CLOUD_DETAIL_COVERAGE .16
#define CLOUD_SPEED 1.6
#define CLOUD_DETAIL_SPEED 4.8
#define CLOUD_AMBIENT .01

// Hash functions by Dave_Hoskins
float hash12(vec2 p)
{
	uvec2 q = uvec2(ivec2(p)) * uvec2(1597334673U, 3812015801U);
	uint n = (q.x ^ q.y) * 1597334673U;
	return float(n) * (1.0 / float(0xffffffffU));
}

vec2 hash22(vec2 p)
{
	uvec2 q = uvec2(ivec2(p))*uvec2(1597334673U, 3812015801U);
	q = (q.x ^ q.y) * uvec2(1597334673U, 3812015801U);
	return vec2(q) * (1.0 / float(0xffffffffU));
}

float remap(float x, float a, float b, float c, float d)
{
    return (((x - a) / (b - a)) * (d - c)) + c;
}

// Noise function by morgan3d
float perlinNoise(vec2 x) {
    vec2 i = floor(x);
    vec2 f = fract(x);

	float a = hash12(i);
    float b = hash12(i + vec2(1.0, 0.0));
    float c = hash12(i + vec2(0.0, 1.0));
    float d = hash12(i + vec2(1.0, 1.0));

    vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

vec2 curlNoise(vec2 uv)
{
    vec2 eps = vec2(0., 1.);

    float n1, n2, a, b;
    n1 = perlinNoise(uv + eps);
    n2 = perlinNoise(uv - eps);
    a = (n1 - n2) / (2. * eps.y);

    n1 = perlinNoise(uv + eps.yx);
    n2 = perlinNoise(uv - eps.yx);
    b = (n1 - n2)/(2. * eps.y);

    return vec2(a, -b);
}

float worleyNoise(vec2 uv, float freq, float t, bool curl)
{
    uv *= freq;
    uv += t + (curl ? curlNoise(uv*2.) : vec2(0.)); // exaggerate the curl noise a bit

    vec2 id = floor(uv);
    vec2 gv = fract(uv);

    float minDist = 100.;
    for (float y = -1.; y <= 1.; ++y)
    {
        for(float x = -1.; x <= 1.; ++x)
        {
            vec2 offset = vec2(x, y);
            vec2 h = hash22(id + offset) * .8 + .1; // .1 - .9
    		h += offset;
            vec2 d = gv - h;
           	minDist = min(minDist, dot(d, d));
        }
    }

    return minDist;
}

float perlinFbm (vec2 uv, float freq, float t)
{
    uv *= freq;
    uv += t;
    float amp = .5;
    float noise = 0.;
    for (int i = 0; i < 8; ++i)
    {
        noise += amp * perlinNoise(uv);
        uv *= 1.9;
        amp *= .55;
    }
    return noise;
}

// Worley fbm inspired by Andrew Schneider's Real-Time Volumetric Cloudscapes
// chapter in GPU Pro 7.
vec4 worleyFbm(vec2 uv, float freq, float t, bool curl)
{
    // worley0 isn't used for high freq noise, so we can save a few ops here
    float worley0 = 0.;
    if (freq < 4.)
    	worley0 = 1. - worleyNoise(uv, freq * 1., t * 1., false);
    float worley1 = 1. - worleyNoise(uv, freq * 2., t * 2., curl);
    float worley2 = 1. - worleyNoise(uv, freq * 4., t * 4., curl);
    float worley3 = 1. - worleyNoise(uv, freq * 8., t * 8., curl);
    float worley4 = 1. - worleyNoise(uv, freq * 16., t * 16., curl);

    // Only generate fbm0 for low freq
    float fbm0 = (freq > 4. ? 0. : worley0 * .625 + worley1 * .25 + worley2 * .125);
    float fbm1 = worley1 * .625 + worley2 * .25 + worley3 * .125;
    float fbm2 = worley2 * .625 + worley3 * .25 + worley4 * .125;
    float fbm3 = worley3 * .75 + worley4 * .25;
    return vec4(fbm0, fbm1, fbm2, fbm3);
}

float clouds(vec2 uv, float t)
{
    float coverage = hash12(vec2(uv.x * iResolution.y/iResolution.x, uv.y)) *
        .1 + ((SAT(CLOUD_COVERAGE) * 1.6) * .5 + .5); // coverage between whatever value and 1.
 	float pfbm = perlinFbm(uv, 2., t);
    vec4 wfbmLowFreq = worleyFbm(uv, 1.6, t * CLOUD_SPEED, false); // low freq without curl
    vec4 wfbmHighFreq = worleyFbm(uv, 8., t * CLOUD_DETAIL_SPEED, true); // high freq with curl
    float perlinWorley = remap(abs(pfbm * 2. - 1.),
                               1. - wfbmLowFreq.r, 1., 0., 1.);
    perlinWorley = remap(perlinWorley, 1. - coverage, 1., 0., 1.) * coverage;
    float worleyLowFreq = wfbmLowFreq.g * .625 + wfbmLowFreq.b * .25
        + wfbmLowFreq.a * .125;
    float worleyHighFreq = wfbmHighFreq.g * .625 + wfbmHighFreq.b * .25
        + wfbmHighFreq.a * .125;
    float c = remap(perlinWorley, (worleyLowFreq - 1.) * .64, 1., 0., 1.);
    c = remap(c, worleyHighFreq * CLOUD_DETAIL_COVERAGE, 1., 0., 1.);
    return max(0., c);
}

void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
    vec2 uv = fragCoord / iResolution.y;
    vec2 m = iMouse.xy / iResolution.y;
    float t = mod(iTime + 600., 7200.) * .03;

    // set up 2D ray march variables
    vec2 marchDist = vec2(.35 * max(iResolution.x, iResolution.y)) / iResolution.xy;
    const float steps = 10.;
    float stepsInv = 1. / steps;
    vec2 sunDir = normalize(m - uv) * marchDist * stepsInv;
    vec2 marchUv = uv;
    float cloudColor = 1.;
    float cloudShape = clouds(uv, t);

    // 2D ray march lighting loop based on uncharted 4
    for (float i = 0.; i < marchDist.x; i += marchDist.x * stepsInv)
    {
        marchUv += sunDir * i;
   		float c = clouds(marchUv, t);
        cloudColor *= clamp(1. - c, 0., 1.);
    }

    cloudColor += CLOUD_AMBIENT; // ambient
    // beer's law + powder sugar
    cloudColor = exp(-cloudColor) * (1. - exp(-cloudColor*2.)) * 2.;
    cloudColor *= cloudShape;

    vec3 skyCol = mix(vec3(.1, .5, .9), vec3(.1, .1, .9), uv.y);
    vec3 col = vec3(0.);
    col = skyCol + cloudShape;
  	col = mix(vec3(cloudColor) * 25., col, 1.-cloudShape);
    float sun = .002 / pow(length(uv - m), 1.7);
    col += (1. - smoothstep(.0, .4, cloudShape)) * sun;
    fragColor = vec4(sqrt(col), 1.0);
}