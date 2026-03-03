vec2 random2(vec2 st){
    st = vec2( dot(st,vec2(127.1,311.7)),
              dot(st,vec2(269.5,183.3)) );
    return -1.0 + 2.0*fract(sin(st)*43758.5453123);
}

// Gradient Noise by Inigo Quilez - iq/2013
// https://www.shadertoy.com/view/XdXGW8
float noise(vec2 st) {
    vec2 i = floor(st);
    vec2 f = fract(st);

    vec2 u = f*f*(3.0-2.0*f);

    return mix( mix( dot( random2(i + vec2(0.0,0.0) ), f - vec2(0.0,0.0) ),
                     dot( random2(i + vec2(1.0,0.0) ), f - vec2(1.0,0.0) ), u.x),
                mix( dot( random2(i + vec2(0.0,1.0) ), f - vec2(0.0,1.0) ),
                     dot( random2(i + vec2(1.0,1.0) ), f - vec2(1.0,1.0) ), u.x), u.y);
}

void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
    // Normalized pixel coordinates (from 0 to 1)
    vec2 uv = fragCoord/iResolution.xy;
    float calmness = 0.1;
    float waveIntensity = 0.5;

    vec2 noiseCoord = uv;
    noiseCoord.x += cos(iTime / 10.0);
    noiseCoord.y += sin(iTime / 10.0);

    uv.x += noise(noiseCoord / calmness) * waveIntensity;
    uv.y += noise((noiseCoord + 100.0) / calmness) * waveIntensity;

    vec4 col = texture(iChannel0, uv);
    col += noise(noiseCoord);
    col *= vec4(0.3, 0.6, 1.0, 1.0);

    // Output to screen
    fragColor = vec4(col);
}
