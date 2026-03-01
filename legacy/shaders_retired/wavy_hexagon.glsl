float hexDist(vec2 p)
{
    p = abs(p);
    float d = dot(p, normalize(vec2(1.0, 1.73)));
	return max(p.x, d);
}

vec4 hexCoords(vec2 uv)
{
    vec2 r = vec2(1.0, 1.73);
    vec2 h = 0.5 * r;
    vec2 a = mod(uv, r) - h;
    vec2 b = mod(uv - h, r) - h;

    vec2 gv = length(a) < length(b) ? a : b;

    float x = atan(gv.x, gv.y);
    float y = 0.5 - hexDist(gv);
    vec2 id = uv - gv;

    return vec4(x, y, id);
}

void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
    vec2 uv = (fragCoord.xy - 0.5 * iResolution.xy) / iResolution.y;

    uv *= 10.0;

    vec3 col = vec3(0);
    vec4 hc = hexCoords(uv);

    float time = iTime * 0.5;
    float wavy = pow(sin(length(hc.zw) - time), 4.0) + 0.1;

	float c = smoothstep(0., 15./iResolution.y, hc.y);

    col = vec3(c * wavy);

    fragColor = vec4(col,1.0);
}
