void mainImage(out vec4 fragColor, in vec2 fragCoord) {

    float speed = 1.5;
    int starCount = 600;
    float starSize = 0.0015;
    float minZ = 0.3;



    vec2 uv = (2.0 * fragCoord - iResolution.xy) / iResolution.y;


    vec3 color = vec3(0.0);


    for (int i = 0; i < starCount; i++) {
    float seed = float(i) * 0.01337;



        vec2 starXY = vec2(
            fract(sin(seed * 734.631) * 5623.541) * 2.0 - 1.0,
            fract(cos(seed * 423.891) * 3245.721) * 2.0 - 1.0
        );


               float z = mod(iTime * speed * -0.2 + seed, 1.0) + minZ*0.1;



        float size = starSize / z;
        float brightness = 0.7 / z;


        vec2 starUV = uv - starXY * (0.5 / z);
        float star = smoothstep(size, 0.0, length(starUV));


        color += vec3(star * brightness);
    }


    color = min(color, vec3(1.0));
    color *= 0.9 + 0.1 * sin(fragCoord.y * 3.14159 * 2.0); //scanlines
    fragColor = vec4(color, 1.0);
}
