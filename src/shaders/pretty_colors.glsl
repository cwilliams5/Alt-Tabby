#define N_DELTA 0.015625
float rand(vec3 n) {
    return fract(sin(dot(n, vec3(95.43583, 93.323197, 94.993431))) * 65536.32);
}

float perlin2(vec3 n)
{
    vec3 base = floor(n / N_DELTA) * N_DELTA;
    vec3 dd = vec3(N_DELTA, 0.0, 0.0);
    float
        tl = rand(base + dd.yyy),
        tr = rand(base + dd.xyy),
        bl = rand(base + dd.yxy),
        br = rand(base + dd.xxy);
    vec3 p = (n - base) / dd.xxx;
    float t = mix(tl, tr, p.x);
    float b = mix(bl, br, p.x);
    return mix(t, b, p.y);
}

float perlin3(vec3 n)
{
    vec3 base = vec3(n.x, n.y, floor(n.z / N_DELTA) * N_DELTA);
    vec3 dd = vec3(N_DELTA, 0.0, 0.0);
    vec3 p = (n - base) / dd.xxx;
    float front = perlin2(base + dd.yyy);
    float back = perlin2(base + dd.yyx);
    return mix(front, back, p.z);
}

float fbm(vec3 n)
{
    float total = 0.0;
    float m1 = 1.0;
    float m2 = 0.1;
    for (int i = 0; i < 5; i++)
    {
        total += perlin3(n * m1) * m2;
        m2 *= 2.0;
        m1 *= 0.5;
    }
    return total;
}

float nebula1(vec3 uv)
{
    float n1 = fbm(uv * 2.9 - 1000.0);
    float n2 = fbm(uv + n1 * 0.05);
    return n2;
}

float nebula2(vec3 uv)
{
    float n1 = fbm(uv * 1.3 + 115.0);
    float n2 = fbm(uv + n1 * 0.35);
    return fbm(uv + n2 * 0.17);
}

float nebula3(vec3 uv)
{
    float n1 = fbm(uv * 3.0);
    float n2 = fbm(uv + n1 * 0.15);
    return n2;
}

vec3 nebula(vec3 uv)
{
    uv *= 10.0;
	return nebula1(uv * 0.5) * vec3(1.0, 0.0, 0.0) +
        	nebula2(uv * 0.4) * vec3(0.0, 1.0, 0.0) +
        	nebula3(uv * 0.6) * vec3(0.0, 0.0, 1.0);

}

void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
    float size = max(iResolution.x, iResolution.y);
	vec2 xy = (fragCoord.xy - iResolution.xy * 0.5)  / size * 2.0;
    vec3 rayDir = normalize(vec3(xy, 1.0));
    vec2 uv = xy * 0.5 + 0.5;

    fragColor = vec4(vec3((nebula(vec3(uv * 5.1, iTime * 0.1) * 0.1) - 1.0)), 1.0);

}