// domain warping based on the master's notes at https://iquilezles.org/articles/warp

// NOISE ////
vec2 hash2( float n )
{
    return fract(sin(vec2(n,n+1.0))*vec2(13.5453123,31.1459123));
}

float noise( in vec2 x )
{
    vec2 p = floor(x);
    vec2 f = fract(x);
    f = f*f*(3.0-2.0*f);
    float a = textureLod(iChannel0,(p+vec2(0.5,0.5))/256.0,0.0).x;
	float b = textureLod(iChannel0,(p+vec2(1.5,0.5))/256.0,0.0).x;
	float c = textureLod(iChannel0,(p+vec2(0.5,1.5))/256.0,0.0).x;
	float d = textureLod(iChannel0,(p+vec2(1.5,1.5))/256.0,0.0).x;
    return mix(mix( a, b,f.x), mix( c, d,f.x),f.y);
}

const mat2 mtx = mat2( 0.80,  0.60, -0.60,  0.80 );

float fbm( vec2 p )
{
    float f = 0.0;

    f += 0.500000*noise( p ); p = mtx*p*2.02;
    f += 0.250000*noise( p ); p = mtx*p*2.03;
    f += 0.125000*noise( p ); p = mtx*p*2.01;
    f += 0.062500*noise( p ); p = mtx*p*2.04;
    f += 0.031250*noise( p ); p = mtx*p*2.01;
    f += 0.015625*noise( p );

    return f/0.96875;
}

// -----------------------------------------------------------------------

float pattern(in vec2 p, in float t, in vec2 uv, out vec2 q, out vec2 r, out vec2 g)
{
	q = vec2(fbm(p), fbm(p + vec2(10, 1.3)));

    float s = dot(uv.x + 0.5, uv.y + 0.5);
    r = vec2(fbm(p + 4.0 * q + vec2(t) + vec2(1.7, 9.2)), fbm(p + 4.0 * q + vec2(t) + vec2(8.3, 2.8)));
    g = vec2(fbm(p + 2.0 * r + vec2(t * 20.0) + vec2(2, 6)), fbm(p + 2.0 * r + vec2(t * 10.0) + vec2(5, 3)));
    return fbm(p + 5.5 * g + vec2(-t * 7.0));
}

// Gradient Function
vec3 getGradientColor(float t) {
    // Convert provided RGB colors to vec3 with range 0-1
    vec3 color1 = vec3(255.0, 199.0, 51.0) / 255.0; // Yellow
    vec3 color2 = vec3(245.0, 42.0, 116.0) / 255.0; // Red
    vec3 color3 = vec3(7.0, 49.0, 143.0) / 255.0; // Blue
    vec3 color4 = vec3(71.0, 205.0, 255.0) / 255.0; // Cyan
    vec3 color5 = vec3(185.0, 73.0, 255.0) / 255.0; // Purple
    vec3 color6 = vec3(255.0, 180.0, 204.0) / 255.0; // Pink

    // Fixed ratios for color transitions
    float ratio1 = 0.1; // Transition point for color1 and color2
    float ratio2 = 0.3; // Transition point for color2 and color3
    float ratio3 = 0.6; // Transition point for color3 and color4
    float ratio4 = 0.8; // Transition point for color4 and color5

    if (t < ratio1)
        return mix(color1, color2, t / ratio1);
    else if (t < ratio2)
        return mix(color2, color3, (t - ratio1) / (ratio2 - ratio1));
    else if (t < ratio3)
        return mix(color3, color4, (t - ratio2) / (ratio3 - ratio2));
    else if (t < ratio4)
        return mix(color4, color5, (t - ratio3) / (ratio4 - ratio3));
    else
        return mix(color5, color6, (t - ratio4) / (1.0 - ratio4));
}



// Main Image Function
void mainImage( out vec4 fragColor, in vec2 fragCoord ) {
    // Define zoom and speed factors
    float zoom = 0.05; // Example zoom value; smaller values zoom in
    float speed = 0.2; // Example speed value; larger values speed up the animation

    // Apply zoom by scaling the fragment coordinates
    vec2 zoomedCoord = fragCoord * zoom;

    // Apply speed by scaling the time
    float adjustedTime = iTime * speed;

    // Normalized pixel coordinates (from 0 to 1)
    vec2 uv = zoomedCoord / iResolution.xy;

    // Noise generation with zoomed and time-adjusted coordinates
    vec2 q, r, g;
    float noise = pattern(zoomedCoord * vec2(.004), adjustedTime * 0.007, uv, q, r, g);

    // Convert noise to a value between 0 and 1
    float t = fract(noise * 2.6 - 1.0);

    // Get color from gradient
    vec3 col = getGradientColor(t);

    // Apply a vignette effect
    col *= 0.5 + 0.5 * pow(16.0 * uv.x * uv.y * (1.0 - uv.x) * (1.0 - uv.y), 0.1);

    // Output to screen
    fragColor = vec4(col, 1.0);
}
