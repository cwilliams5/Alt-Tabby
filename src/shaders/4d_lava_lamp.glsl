// The MIT License
// Copyright © 2013 Inigo Quilez
// substantial refactoring by 2021 Alalalat
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions: The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.


// Simplex Noise (http://en.wikipedia.org/wiki/Simplex_noise), a type of gradient noise
// that uses N+1 vertices for random gradient interpolation instead of 2^N as in regular
// latice based Gradient Noise.


// Value    Noise 2D, Derivatives: https://www.shadertoy.com/view/4dXBRH
// Gradient Noise 2D, Derivatives: https://www.shadertoy.com/view/XdXBRH
// Value    Noise 3D, Derivatives: https://www.shadertoy.com/view/XsXfRH
// Gradient Noise 3D, Derivatives: https://www.shadertoy.com/view/4dffRH
// Value    Noise 2D             : https://www.shadertoy.com/view/lsf3WH
// Value    Noise 3D             : https://www.shadertoy.com/view/4sfGzS
// Gradient Noise 2D             : https://www.shadertoy.com/view/XdXGW8
// Gradient Noise 3D             : https://www.shadertoy.com/view/Xsl3Dl
// Simplex  Noise 2D             : https://www.shadertoy.com/view/Msf3WH
// Wave     Noise 2D             : https://www.shadertoy.com/view/tldSRj


vec2 hash( vec2 p ) // replace this by something better
{
	p = vec2( dot(p,vec2(127.1,311.7)), dot(p,vec2(269.5,183.3)) );
	return -1.0 + 2.0*fract(sin(p)*43758.5453123);
}

float noise( in vec2 p )
{
    const float K1 = 0.366025404; // (sqrt(3)-1)/2;
    const float K2 = 0.211324865; // (3-sqrt(3))/6;

	vec2  i = floor( p + (p.x+p.y)*K1 );
    vec2  a = p - i + (i.x+i.y)*K2;
    float m = step(a.y,a.x);
    vec2  o = vec2(m,1.0-m);
    vec2  b = a - o + K2;
	vec2  c = a - 1.0 + 2.0*K2;
    vec3  h = max( 0.5-vec3(dot(a,a), dot(b,b), dot(c,c) ), 0.0 );
	vec3  n = h*h*h*h*vec3( dot(a,hash(i+0.0)), dot(b,hash(i+o)), dot(c,hash(i+1.0)));
    return dot( n, vec3(70.0) );
}

float maximum(vec3 p)
{
    float max = p.x;
    if (p.y > max)
    max = p.y;
    if (p.z > max)
    max = p.z;
    return max;


}
float minimum(vec3 p)
{
    float min = p.x;
    if (p.y < min)
    min = p.y;
    if (p.z < min)
    min = p.z;
    return min;


}
vec3 normalize2 (vec3 grosscolor)
{
    grosscolor = (grosscolor*grosscolor*grosscolor);
    float max = maximum(grosscolor);
    float min = minimum(grosscolor);
    return (grosscolor.xyz/(max+min));

}


vec2 rotate (vec2 oldpoint, float angle)
{
    float left, right;

    left = cos(angle)*oldpoint.x;
    left -= sin(angle)*oldpoint.y;
    right = sin(angle)*oldpoint.x;
    right += cos(angle)*oldpoint.y;

    return vec2(left,right);
}

float noise4( vec2 uv )
{
    float f = 0.5;
    float frequency = 1.75;
    float amplitude = 0.5;
    //for(int i = 0; i <int(floor(log(iTime*iTime))); i++){
    for(int i = 0; i <7; i++){
        f += amplitude*noise( frequency*uv - rotate(vec2(log(iTime+3.0),log(iTime+3.0)/999.0),iTime/9999.0) );
        frequency *= 2.0;                                                                                             //helper
        amplitude *= 0.5;
    }
    return f;
}
// -----------------------------------------------

void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
    vec2 p = fragCoord.xy / iResolution.xy;

	vec2 uv = p*vec2(iResolution.x/iResolution.y,0.8);
    uv = rotate(uv,log(iTime)/-7.0);

    //uv -= 2.0*vec2(iResolution.x/2.0, iResolution.y/2.0);

    float interval = 10.0;
    vec3 dblue = interval*vec3(1.8,2.6,2.6);
    vec3 cyan = interval*vec3(0,2.1,2);
    vec3 magenta = interval*vec3(1.8,1.0,1.8);




    float f = 0.0	;

    vec3 color = vec3(0.75,0.75,0.75);
	f = noise4( uv + noise4(uv)*((log(iTime+1.0)+(iTime/60.0))) );
    color += f*normalize2(dblue);

    f = noise4( f*rotate(uv,sin(iTime/11.0)) + f*noise4(f*uv));
    color += f*normalize2(cyan);

    f = noise4( f*rotate(uv,iTime/7.0) + f*noise4(uv)*noise4(uv));
    color += f*normalize2(magenta);

    color = normalize2(color);








	fragColor = vec4(color,1.0);
}
