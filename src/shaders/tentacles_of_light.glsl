float Hash11(in float x) {
    return fract(sin(x * 1254.5763) * 57465.57);
}

vec3 hue2rgb(in float hue) {
    hue *= 6.0;
    float x = 1.0 - abs(mod(hue, 2.0) - 1.0);

    vec3 rgb = vec3(1.0, x, 0.0);
    if (hue < 2.0 && hue >= 1.0) {
        rgb = vec3(x, 1.0, 0.0);
    }

    if (hue < 3.0 && hue >= 2.0) {
        rgb = vec3(0.0, 1.0, x);
    }

    if (hue < 4.0 && hue >= 3.0) {
        rgb = vec3(0.0, x, 1.0);
    }

    if (hue < 5.0 && hue >= 4.0) {
        rgb = vec3(x, 0.0, 1.0);
    }

    if (hue < 6.0 && hue >= 5.0) {
        rgb = vec3(1.0, 0.0, x);
    }

    return rgb;
}

float line(in vec2 p, in vec2 a, in vec2 b) {
    vec2 pa = p - a, ba = b - a;
    return length(pa - ba * clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0));
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;
    vec3 color = vec3(0.0);

    float t = iTime * 0.25;
    float c = cos(t), s = sin(t);
    uv -= vec2(cos(t), sin(t)) * 0.15;

    for (float tentacleID=0.0; tentacleID < 8.0; tentacleID++) {
        float distFromOrigin = length(uv);
        float tentacleHash = Hash11(tentacleID + 1.0);
        float angle = tentacleID / 4.0 * 3.14 + iTime * (tentacleHash - 0.5);

        vec3 tentacleColor = hue2rgb(fract(0.5 * (distFromOrigin - 0.1 * iTime)));
        float fadeOut = 1.0 - pow(distFromOrigin, sin(tentacleHash * iTime) + 1.5);

        vec2 offsetVector = uv.yx * vec2(-1.0, 1.0);
        vec2 offset = offsetVector * sin(tentacleHash * (distFromOrigin + tentacleHash * iTime)) * (1.0 - distFromOrigin);

        color += smoothstep(0.03, 0.0, line(uv + offset, vec2(0.0, 0.0), vec2(cos(angle), sin(angle)) * 1000.0)) * fadeOut * tentacleColor;
    }

    fragColor = vec4(color, 1.0);
}
