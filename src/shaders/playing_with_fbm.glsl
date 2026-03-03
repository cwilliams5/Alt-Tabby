#define time iTime

float noise3D(vec3 p)
{
	return fract(sin(dot(p ,vec3(12.9898,78.233,126.7378))) * 43758.5453)*2.0-1.0;
}

float linear3D(vec3 p)
{
	vec3 p0 = floor(p);
	vec3 p1x = vec3(p0.x+1.0, p0.y, p0.z);
	vec3 p1y = vec3(p0.x, p0.y+1.0, p0.z);
	vec3 p1z = vec3(p0.x, p0.y, p0.z+1.0);
	vec3 p1xy = vec3(p0.x+1.0, p0.y+1.0, p0.z);
	vec3 p1xz = vec3(p0.x+1.0, p0.y, p0.z+1.0);
	vec3 p1yz = vec3(p0.x, p0.y+1.0, p0.z+1.0);
	vec3 p1xyz = p0+1.0;

	float r0 = noise3D(p0);
	float r1x = noise3D(p1x);
	float r1y = noise3D(p1y);
	float r1z = noise3D(p1z);
	float r1xy = noise3D(p1xy);
	float r1xz = noise3D(p1xz);
	float r1yz = noise3D(p1yz);
	float r1xyz = noise3D(p1xyz);

	float a = mix(r0, r1x, p.x-p0.x);
	float b = mix(r1y, r1xy, p.x-p0.x);
	float ab = mix(a, b, p.y-p0.y);
	float c = mix(r1z, r1xz, p.x-p0.x);
	float d = mix(r1yz, r1xyz, p.x-p0.x);
	float cd = mix(c, d, p.y-p0.y);


	float res = mix(ab, cd, p.z-p0.z);

	return res;
}

float fbm(vec3 p)
{
	float f = 0.5000*linear3D(p*1.0);
		  f+= 0.2500*linear3D(p*2.01);
		  f+= 0.1250*linear3D(p*4.02);
		  f+= 0.0625*linear3D(p*8.03);
		  f/= 0.9375;
	return f;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord)
{
	vec2 uv = fragCoord/iResolution.xy*2.0-1.0;
	uv.x*=1.78;
	float ang = time*0.1;
    mat2 rot = mat2(cos(ang),-sin(ang),sin(ang),cos(ang));
	uv*=16.0*(sin(time*0.1)+1.5)*rot;

	float f = fbm(vec3(uv,time)+fbm(vec3(uv,time)+fbm(vec3(uv,time))))*0.5+0.5;

    vec3 col, col2;
    col = vec3(fbm(vec3(uv*f*0.3,time*0.75)));
    col2 = col;

	col *= vec3((sin(time*0.2)*0.5+1.5),1.0,0.6);
    col +=  vec3(0.1,0.7,0.8)*f;

    col2 *= vec3(0.9,1.0,(sin(time*0.2)*0.5+1.5));
    col2 += vec3(0.8,0.5,0.1)*f;

	col = mix(col, col2, smoothstep(-50.0,50.0,uv.x));

    col *= mix(0.5,sin(time*0.5)*0.25+1.0,length(col));
	fragColor = vec4(col,1.0);
}