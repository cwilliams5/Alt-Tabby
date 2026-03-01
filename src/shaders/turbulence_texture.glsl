vec3 random_perlin( vec3 p ) {
    p = vec3(
            dot(p,vec3(127.1,311.7,69.5)),
            dot(p,vec3(269.5,183.3,132.7)),
            dot(p,vec3(247.3,108.5,96.5))
            );
    return -1.0 + 2.0*fract(sin(p)*43758.5453123);
}
float noise_perlin (vec3 p) {
    vec3 i = floor(p);
    vec3 s = fract(p);

    // 3D grid has 8 vertices
    float a = dot(random_perlin(i),s);
    float b = dot(random_perlin(i + vec3(1, 0, 0)),s - vec3(1, 0, 0));
    float c = dot(random_perlin(i + vec3(0, 1, 0)),s - vec3(0, 1, 0));
    float d = dot(random_perlin(i + vec3(0, 0, 1)),s - vec3(0, 0, 1));
    float e = dot(random_perlin(i + vec3(1, 1, 0)),s - vec3(1, 1, 0));
    float f = dot(random_perlin(i + vec3(1, 0, 1)),s - vec3(1, 0, 1));
    float g = dot(random_perlin(i + vec3(0, 1, 1)),s - vec3(0, 1, 1));
    float h = dot(random_perlin(i + vec3(1, 1, 1)),s - vec3(1, 1, 1));

    // Smooth Interpolation
    vec3 u = smoothstep(0.,1.,s);

    // Interpolate based on 8 vertices
    return mix(mix(mix( a, b, u.x),
                mix( c, e, u.x), u.y),
            mix(mix( d, f, u.x),
                mix( g, h, u.x), u.y), u.z);
}
float noise_turbulence(vec3 p)
{
    float f = 0.0;
    float a = 1.;
    p = 4.0 * p;
    for (int i = 0; i < 5; i++) {
        f += a * abs(noise_perlin(p));
        p = 2.0 * p;
        a /= 2.;
    }
    return f;
}
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord.xy/iResolution.xy;
    float c1 = noise_turbulence(vec3(1.*uv, iTime/10.0));
    vec3 color = vec3(1.5*c1, 1.5*c1*c1*c1, c1*c1*c1*c1*c1*c1);
    fragColor = vec4( color, 1.0 );
}