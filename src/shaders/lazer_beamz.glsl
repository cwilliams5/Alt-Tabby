float distanceToLine (vec2 s, vec2 p, vec2 q)
{
    return abs ((q.y - p.y) * s.x - (q.x - p.x) * s.y
        + q.x * p.y - q.y * p.x) / distance (p, q);
}

float triangle (vec2 pos, float t, float val, float step)
{
    float t1 = t * 0.523;
    float t2 = t * 0.645;
    float t3 = t * 0.779;

    vec2 p1 = 0.5 + 0.5 * vec2 (cos (t1      ), sin (t2      ));
    vec2 p2 = 0.5 + 0.5 * vec2 (cos (t2 + 1.0), sin (t3 + 1.0));
    vec2 p3 = 0.5 + 0.5 * vec2 (cos (t3 + 2.0), sin (t1 + 2.0));

    float d = distanceToLine (pos, p1, p2);
    val += d < 0.01 ? step : 0.0;

    d = distanceToLine (pos, p2, p3);
    val += d < 0.01 ? step : 0.0;

    d = distanceToLine (pos, p3, p1);
    val += d < 0.01 ? step : 0.0;

    return val;
}

vec3 Red     = vec3 (1.0, 0.0, 0.0);
vec3 Yellow  = vec3 (1.0, 1.0, 0.0);
vec3 Green   = vec3 (0.0, 1.0, 0.0);
vec3 Cyan    = vec3 (0.0, 1.0, 1.0);
vec3 Blue    = vec3 (0.0, 0.0, 1.0);
vec3 Magenta = vec3 (1.0, 0.0, 1.0);

vec3 hue (float t)
{
    float f = 1.0 / 6.0;

    if (t < f)
    {
        return mix (Red, Yellow, t / f);
    }
    else if (t < 2.0 * f)
    {
        return mix (Yellow, Green, (t - f) / f);
    }
    else if (t < 3.0 * f)
    {
        return mix (Green, Cyan, (t - 2.0 * f) / f);
    }
    else if (t < 4.0 * f)
    {
        return mix (Cyan, Blue, (t - 3.0 * f) / f);
    }
    else if (t < 5.0 * f)
    {
        return mix (Blue, Magenta, (t - 4.0 * f) / f);
    }
    else
    {
        return mix (Magenta, Red, (t - 5.0 * f) / f);
    }
}

void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
	vec2 res = iResolution.xy;
    vec2 pos = (fragCoord - 0.5 * res) / res.y + 0.5;

    float val = 0.0;

    for (float f = 0.0; f < 10.0; f++)
    {
        val += triangle (pos, iTime + f*0.05, val, 0.01 * f / 10.0);
    }

    val = min (1.0, val);
    val = 1.0 - (1.0 - val) * (1.0 - val);

	fragColor = vec4(val * hue (0.5 + 0.5 * sin (iTime + val)), 1.0);
}
