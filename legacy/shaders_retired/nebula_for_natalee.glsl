float fbm(vec2 uv) {
    float f = 0.5;

    float amp = 0.5;
    float freq = 2.0;
    for (int i = 0; i < 5; i++) {
        f += amp * (texture(iChannel0, uv).r - 0.5);

        uv *= freq;
        uv += 10.0;

        freq *= 2.0;
        amp *= 0.5;
    }

    return f;
}

void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
    // Normalized pixel coordinates (from 0 to 1)
    vec2 uv = fragCoord/iResolution.xy;

    // Time varying pixel color
    float x0 = fbm(uv * 0.1 + iTime * 0.007);
    float y0 = fbm(uv * 0.1523 + iTime * 0.007);


    vec3 col = vec3(0.0);

    float amp = 0.5;
    float freq = 0.1;

    vec2 off = vec2(x0, y0);

    float ff = 0.0;

    for (int i = 0; i < 8; i++) {
        float f = fbm(uv * freq + off * 0.03 + ff * 0.02 + iTime * 0.0004 * (8.0 - float(i)));

        f = pow(f + 0.25, float(i) * 6.2 + 5.5);
        ff += f;

        float r = sin(x0 * 18.0);
        float g = sin(y0 * 13.0 + 1.7);
        float b = sin(f * 11.0 + 1.1);

        col += amp * f * mix(vec3(0.3, 0.5, 0.9), vec3(r, g, b), pow(float(i) / 8.0, f));

        amp *= 0.9;
        freq *= 2.7;
    }

    // Output to screen
    fragColor = vec4(col,1.0);
}