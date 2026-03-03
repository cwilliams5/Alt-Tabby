//Warping Study

//Learning from IQ's tutorial at https://iquilezles.org/articles/warp
//after seeing countless "FBM" calculations and going "What are these?"

//Fractal Brownian Motion is great stuff.

//--Replay


//Helpers

vec3 rgb2hsv(vec3 c)
{
    vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
    vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));

    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

vec3 hsv2rgb(vec3 c)
{
    vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

//FBM (Fractal Brownian Motion)

float rand(vec2 n) {
    return fract(cos(dot(n, vec2(12.9898,4.1414))) * (3758.5453));
}

float noise(vec2 n) {
    const vec2 d = vec2(0.0, 1.0);
    vec2 b = floor(n), f = smoothstep(vec2(0.0), vec2(1.0), fract(n));
    return mix(mix(rand(b), rand(b + d.yx), f.x), mix(rand(b + d.xy), rand(b + d.yy), f.x), f.y);
}

float fbm(vec2 n) {
    float total = 0.0, amplitude = 1.0;
    for (int i = 0; i <10; i++) {
        total += noise(n) * amplitude;
        amplitude *= 0.4;
    }
    return total;
}


 float pattern( in vec2 p )
  {
      vec2 q = vec2( fbm( p + vec2(0.0,0.0) ),
                     fbm( p + vec2(5.2 + sin(iTime)/10.0,1.3 - cos(iTime)/10.0) ) );

      vec2 r = vec2( fbm( p + 4.0*q + vec2(1.7+ sin(iTime)/10.0,9.2) ),
                     fbm( p + 4.0*q + vec2(8.3,2.8-cos(iTime)/10.0) ) );

      vec2 adjusted_coordinate = p + 4.0*r;
      adjusted_coordinate.x += sin(iTime);
      adjusted_coordinate.y += cos(iTime);
      return sqrt(pow(fbm( adjusted_coordinate + iTime
                 + fbm(adjusted_coordinate - iTime
                      + fbm(adjusted_coordinate + sin(iTime) ))), -2.0));
  }

//Main Calculation

void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
	vec2 uv = fragCoord.xy / iResolution.xy;
    float intensity = pattern(uv);
    vec3 color = vec3(uv, 0.5+0.5*sin(iTime));
    vec3 hsv = rgb2hsv(color);
    hsv.z = cos(hsv.y) - 0.1;
    color = hsv2rgb(hsv);
    fragColor = vec4(color, 1.0) * intensity;

}
