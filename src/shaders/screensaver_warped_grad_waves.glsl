vec2 rot2(vec2 st, float theta) {
    float c = cos(theta);
    float s = sin(theta);
    mat2 M = mat2(c, -s, s, c);
    return M*st;
}

void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
    // Normalized pixel coordinates (from 0 to 1)
    vec2 uv = fragCoord/iResolution.xy;
    uv -= .5;
    uv *= 5.;

    uv = rot2(uv, .5*3.1415*uv.x);

    // Time varying pixel color
    vec3 col = vec3(0.);
    //col.rg = uv.xy;
    col = 0.5 + 0.5*cos(iTime+uv.xyx+vec3(0,2,4));


    // Output to screen
    fragColor = vec4(col,1.0);
}
