// Domain warping applied to Voronoi noise
// Written by Claus O. Wilke, 2022
// Noise functions were adapted from code written by Inigo Quilez
// The MIT License
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions: The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

// --- Common ---

// color correction
// Taken from Matt Ebb (MIT license): https://www.shadertoy.com/view/fsSfDW
// Originally from: https://knarkowicz.wordpress.com/2016/01/06/aces-filmic-tone-mapping-curve/

vec3 s_curve(vec3 x)
{
    const float a = 2.51f;
    const float b = 0.03f;
    const float c = 2.43f;
    const float d = 0.59f;
    const float e = 0.14f;
    x = max(x, 0.0);
    return clamp((x*(a*x+b))/(x*(c*x+d)+e),0.0,1.0);
}

// --- Image ---

// voronoi smoothness
float voronoi_smooth = .05; // pick a number between 0 and about 1.2

float hash(in vec2 p) {
    ivec2 texp = ivec2(
        int(mod(p.x, 256.)),
        int(mod(p.y, 256.))
    );
    // return number between -1 and 1
    return -1.0 + 2.0*texelFetch(iChannel0, texp, 0).x;
}

vec2 hash2(in vec2 p)
{
    // return numbers between -1 and 1
    return vec2(hash(p), hash(p + vec2(32., 18.)));
}

// value noise
// Inigo Quilez (MIT License)
// https://www.shadertoy.com/view/lsf3WH
float noise1(in vec2 p)
{
    vec2 i = floor(p);
    vec2 f = fract(p);

	vec2 u = f*f*(3.0 - 2.0*f);

    return mix(mix(hash(i + vec2(0.0, 0.0)),
                   hash(i + vec2(1.0, 0.0)), u.x),
               mix(hash(i + vec2(0.0, 1.0)),
                   hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

// voronoi
// Inigo Quilez (MIT License)
// https://www.shadertoy.com/view/ldB3zc
// The parameter w controls the smoothness
float voronoi(in vec2 x, float w)
{
    vec2 n = floor(x);
    vec2 f = fract(x);

	float dout = 8.0;
    for( int j=-2; j<=2; j++ )
    for( int i=-2; i<=2; i++ )
    {
        vec2 g = vec2(float(i), float(j));
        vec2 o = .5 + .5*hash2(n + g); // o is between 0 and 1

        // distance to cell
		float d = length(g - f + o);

        // do the smooth min for distances
		float h = smoothstep(-1.0, 1.0, (dout - d)/w);
	    dout = mix(dout, d, h ) - h*(1.0 - h)*w/(1.0 + 3.0*w);
    }

	return dout;
}

float fbm1(in vec2 p, in int octaves)
{
    // rotation matrix for fbm
    mat2 m = 2.*mat2(4./5., 3./5., -3./5., 4./5.);

    float scale = 0.5;
    float f = scale * noise1(p);
    float norm = scale;
    for (int i = 0; i < octaves; i++) {
        p = m * p;
        scale *= .5;
        norm += scale;
        f += scale * noise1(p);
    }
	return 0.5 + 0.5 * f/norm;
}

float voronoise(in vec2 p)
{
    return voronoi(p, voronoi_smooth);
}

void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
    vec2 uv = (2.*fragCoord - iResolution.xy)/iResolution.y;

    vec2 toff = .1*iTime*vec2(4., 2.);

    vec2 p = (.6 + .5*sin(.07*iTime))*vec2(4., 4.)*uv;

    vec2 r = vec2(fbm1(p + vec2(5., 2.), 4), fbm1(p + vec2(1., 4.), 4));

    vec3 col = 1.2*vec3(1.4, 1., .5) *
        pow(vec3(
            voronoise(p + 1.5*r + toff),
            voronoise(p + 1.5*r + toff + .005*vec2(2., 4.)),
            voronoise(p + 1.5*r + toff + .01*vec2(5., 1.))
        ), vec3(1.5, 2.5, 2.9));

    col = s_curve(col);

    // Output to screen
    fragColor = vec4(col,1.0);
}