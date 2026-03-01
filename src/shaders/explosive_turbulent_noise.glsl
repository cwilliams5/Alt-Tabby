#define UVScale 			 0.4
#define Speed				 0.6

#define FBM_WarpPrimary		-0.24
#define FBM_WarpSecond		 0.29
#define FBM_WarpPersist 	 0.78
#define FBM_EvalPersist 	 0.62
#define FBM_Persistence 	 0.5
#define FBM_Lacunarity 		 2.2
#define FBM_Octaves 		 5



//fork from Dave Hoskins
//https://www.shadertoy.com/view/4djSRW
vec4 hash43(vec3 p)
{
	vec4 p4 = fract(vec4(p.xyzx) * vec4(1031, .1030, .0973, .1099));
    p4 += dot(p4, p4.wzxy+19.19);
	return -1.0 + 2.0 * fract(vec4(
        (p4.x + p4.y)*p4.z, (p4.x + p4.z)*p4.y,
        (p4.y + p4.z)*p4.w, (p4.z + p4.w)*p4.x)
    );
}

//offsets for noise
const vec3 nbs[] = vec3[8] (
    vec3(0.0, 0.0, 0.0),vec3(0.0, 1.0, 0.0),vec3(1.0, 0.0, 0.0),vec3(1.0, 1.0, 0.0),
    vec3(0.0, 0.0, 1.0),vec3(0.0, 1.0, 1.0),vec3(1.0, 0.0, 1.0),vec3(1.0, 1.0, 1.0)
);

//'Simplex out of value noise', forked from: https://www.shadertoy.com/view/XltXRH
//not sure about performance, is this faster than classic simplex noise?
vec4 AchNoise3D(vec3 x)
{
    vec3 p = floor(x);
    vec3 fr = smoothstep(0.0, 1.0, fract(x));

    vec4 L1C1 = mix(hash43(p+nbs[0]), hash43(p+nbs[2]), fr.x);
    vec4 L1C2 = mix(hash43(p+nbs[1]), hash43(p+nbs[3]), fr.x);
    vec4 L1C3 = mix(hash43(p+nbs[4]), hash43(p+nbs[6]), fr.x);
    vec4 L1C4 = mix(hash43(p+nbs[5]), hash43(p+nbs[7]), fr.x);
    vec4 L2C1 = mix(L1C1, L1C2, fr.y);
    vec4 L2C2 = mix(L1C3, L1C4, fr.y);
    return mix(L2C1, L2C2, fr.z);
}

vec4 ValueSimplex3D(vec3 p)
{
	vec4 a = AchNoise3D(p);
	vec4 b = AchNoise3D(p + 120.5);
	return (a + b) * 0.5;
}

//my FBM
vec4 FBM(vec3 p)
{
    vec4 f, s, n = vec4(0.0);
    float a = 1.0, w = 0.0;
    for (int i=0; i<FBM_Octaves; i++)
    {
        n = ValueSimplex3D(p);
        f += (abs(n)) * a;	//billowed-like
        s += n.zwxy *a;
        a *= FBM_Persistence;
        w *= FBM_WarpPersist;
        p *= FBM_Lacunarity;
        p += n.xyz * FBM_WarpPrimary *w;
        p += s.xyz * FBM_WarpSecond;
        p.z *= FBM_EvalPersist +(f.w *0.5+0.5) *0.015;
    }
    return f;
}

void mainImage(out vec4 col, in vec2 uv)
{
    float aspect = iResolution.x / iResolution.y;
    uv /= iResolution.xy / UVScale *0.1; uv.x *= aspect;
    col = vec4(0.0, 0.0, 0.0, 1.0);

    vec4 fbm = (FBM(vec3(uv, iTime *Speed +100.0)));
    float explosionGrad = (dot(fbm.xyzw, fbm.yxwx)) *0.5;
    explosionGrad = pow(explosionGrad, 1.3);
    explosionGrad = smoothstep(0.0,1.0,explosionGrad);

    #define color0 vec3(1.2,0.0,0.0)
    #define color1 vec3(0.9,0.7,0.3)

    col.xyz = explosionGrad * mix(color0, color1, explosionGrad) *1.2 +0.05;
}
