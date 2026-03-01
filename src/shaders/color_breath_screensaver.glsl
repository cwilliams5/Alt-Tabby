void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
    // Normalize and center pixel coordinates
    vec2 uv = (fragCoord * 2.0 - iResolution.xy) /iResolution.y;

    // Round mask
    float dMask = 1.0 - length(uv);
    dMask = smoothstep(0.25, 1.0, clamp(dMask, 0.0, 1.0)) * pow(abs(sin(iTime * 0.888) * 1.5), 3.0);

    // Time varying pixel color using deformed uvs
    vec3 col = 0.5 + 0.5*cos(iTime * 1.0123 + uv.xyx + vec3(0,2,4));

    // Output to screen
    fragColor = vec4(col * dMask,1.0);
}