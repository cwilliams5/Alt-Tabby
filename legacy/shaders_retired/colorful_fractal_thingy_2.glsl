vec3 palette(float t) {
    vec3 a = vec3(0.2, 0.4, 0.6);
    vec3 b = vec3(0.1, 0.2, 0.3);
    vec3 c = vec3(0.3, 0.5, 0.7);

    return a + b * sin(6.0 * (c * t + a));
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = (fragCoord * 1000.0 / iResolution.xy) / iResolution.y;
    vec2 uv0 = sin(uv * 2.5);

    vec3 finalColor = vec3(0.5);

    for (float i = 0.0; i < 3.3; i++) {
        uv = uv * 1.5 + sin(uv.yx * 3.0) * 1.5;

        float dist = length(uv) * exp(-length(uv0 * 0.5));

        vec3 col = palette(length(uv0) + i * 0.3 + iTime * 0.3);

        dist = sin(dist * 3.33 + iTime * 1.0) / 15.0;
        dist = abs(dist);
        dist = pow(0.025 / dist, 1.5);

        finalColor += col - dist;
    }

    fragColor = vec4(finalColor, 1.0);
}
