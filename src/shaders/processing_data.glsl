float N21(vec2 uv) { return fract(sin(uv.x * 21.281 + uv.y * 93.182) * 5821.92); }

float line(vec2 uv) { return smoothstep(0.0, 0.05, uv.x) - smoothstep(0.0, 0.95, uv.x); }

void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
    vec2 uv = (fragCoord/iResolution.xy) * 2.0 - 1.0;

    vec2 offset = abs(uv.yx) / vec2(30., 5.2);
    uv = uv + uv * offset * offset;
    uv = uv * 0.5 + 0.5;

    vec2 scale = vec2(128, 90);

    vec2 lUV = fract(uv * scale);
    vec2 gID = floor(uv * scale);

    float rowNoise = N21(vec2(0.0, gID.y));
    float dir = ((rowNoise * 2.0) - 1.0) + 0.2;
    gID.x += floor(iTime * dir * 30.);

    float cellNoise = N21(gID);
    float drawBlock = float(cellNoise > 0.38);
    int even = int(gID.y) % 2;

    vec3 col = vec3(line(lUV)) * drawBlock * float(even);
    col *= fract(sin(gID.y)) + 0.24;
    col *= vec3(0.224,0.996,0.557);

    fragColor = vec4(vec3(col), col.g * 0.2);
}
