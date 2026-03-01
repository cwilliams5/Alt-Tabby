float Perlin3D( vec3 P )
{
	//  https://github.com/BrianSharpe/Wombat/blob/master/Perlin3D.glsl

	// establish our grid cell and unit position
	vec3 Pi = floor(P);
	vec3 Pf = P - Pi;
	vec3 Pf_min1 = Pf - 1.0;

	// clamp the domain
	Pi.xyz = Pi.xyz - floor(Pi.xyz * ( 1.0 / 69.0 )) * 69.0;
	vec3 Pi_inc1 = step( Pi, vec3( 69.0 - 1.5 ) ) * ( Pi + 1.0 );

	// calculate the hash
	vec4 Pt = vec4( Pi.xy, Pi_inc1.xy ) + vec2( 50.0, 161.0 ).xyxy;
	Pt *= Pt;
	Pt = Pt.xzxz * Pt.yyww;
	const vec3 SOMELARGEFLOATS = vec3( 635.298681, 682.357502, 668.926525 );
	const vec3 ZINC = vec3( 48.500388, 65.294118, 63.934599 );
	vec3 lowz_mod = vec3( 1.0 / ( SOMELARGEFLOATS + Pi.zzz * ZINC ) );
	vec3 highz_mod = vec3( 1.0 / ( SOMELARGEFLOATS + Pi_inc1.zzz * ZINC ) );
	vec4 hashx0 = fract( Pt * lowz_mod.xxxx );
	vec4 hashx1 = fract( Pt * highz_mod.xxxx );
	vec4 hashy0 = fract( Pt * lowz_mod.yyyy );
	vec4 hashy1 = fract( Pt * highz_mod.yyyy );
	vec4 hashz0 = fract( Pt * lowz_mod.zzzz );
	vec4 hashz1 = fract( Pt * highz_mod.zzzz );

	// calculate the gradients
	vec4 grad_x0 = hashx0 - 0.49999;
	vec4 grad_y0 = hashy0 - 0.49999;
	vec4 grad_z0 = hashz0 - 0.49999;
	vec4 grad_x1 = hashx1 - 0.49999;
	vec4 grad_y1 = hashy1 - 0.49999;
	vec4 grad_z1 = hashz1 - 0.49999;
	vec4 grad_results_0 = inversesqrt( grad_x0 * grad_x0 + grad_y0 * grad_y0 + grad_z0 * grad_z0 ) * ( vec2( Pf.x, Pf_min1.x ).xyxy * grad_x0 + vec2( Pf.y, Pf_min1.y ).xxyy * grad_y0 + Pf.zzzz * grad_z0 );
	vec4 grad_results_1 = inversesqrt( grad_x1 * grad_x1 + grad_y1 * grad_y1 + grad_z1 * grad_z1 ) * ( vec2( Pf.x, Pf_min1.x ).xyxy * grad_x1 + vec2( Pf.y, Pf_min1.y ).xxyy * grad_y1 + Pf_min1.zzzz * grad_z1 );

	// Classic Perlin Interpolation
	vec3 blend = Pf * Pf * Pf * (Pf * (Pf * 6.0 - 15.0) + 10.0);
	vec4 res0 = mix( grad_results_0, grad_results_1, blend.z );
	vec4 blend2 = vec4( blend.xy, vec2( 1.0 - blend.xy ) );
	float final = dot( res0, blend2.zxzx * blend2.wwyy );
	return ( final * 1.1547005383792515290182975610039 );  // scale things to a strict -1.0->1.0 range  *= 1.0/sqrt(0.75)
}


vec2 rotate2( vec2 xy, float r ) {
	vec2 ab = xy;
	ab.x = xy.x * cos(r) - xy.y * sin(r);
	ab.y = xy.y * cos(r) + xy.x * sin(r);
	return ab;
}

float Screen(float a, float b) {
	return 1.0 - ((1.0 - a) * (1.0 - b));
}

vec2 Rotate(vec2 xy, float angle){
	return vec2(xy.x*cos(angle) - xy.y*sin(angle), xy.x*sin(angle) + xy.y*cos(angle));
}

vec2 Triangle(vec2 uv, float c){
	float r = 0.5235988;
	vec2 o = uv;
	o.x = floor(uv.x * c + 0.5);
	o.y = mix(floor(Rotate(uv * c + 0.5, r).y), floor(Rotate(uv * c + 0.5, -r).y), 0.5);
//	o.y /= cos(0.5235988);
//	o.y /= 0.86602539158;
	o.y *= 1.154700555; // This shifts the Y channel back into a -0.5 to +0.5 range, otherwise scrolling the pattern actually changes the output range as well
	return o / c;
}

vec2 TriangleUV(vec2 uv, float c, float r, float s){
	uv = Rotate(uv, r);
	// Fix alignment (based on the pre-rendered lines)
	// uv.x += (1.0/c)*0.25;
	// uv.y -= 0.01;
	// Larger numbers (over 10k) hit major issues with value rounding.
	// Scrolling needs to be within a much smaller range, so this is designed for a 0-1 loop.
	// The magic number scales the scrolling value to a compatible loop point.
	uv.y += s;// * 1.154700555;
	uv = Triangle(uv, c);
	// Invert the vertical scroll so the output UV values remain static, just the pattern scrolls
	uv.y -= s;// * 1.154700555;
	uv = Rotate(uv, -r);
	uv += 0.5;

	return uv;
}

void mainImage(out vec4 fragColor, vec2 fragCoord)
{
	fragColor = vec4((fragCoord/iResolution.xy).rg, 0.5, 1); // This is the default UV output

	// Declare variables (these were all dynamic inputs in the Quartz composition)
	float Time = iTime;
	float Scroll = 0.0125;
	float Depth = 0.25;
	float Rotation = -0.7854;
	float Contrast = 0.2;
	float NoiseSpeed = 1.0;
	vec4 Color1 = vec4(0.07451, 0.09022, 0.2471, 1.0); // Background
	vec4 Color2 = vec4(0.1804, 0.1922, 0.4942, 1.0); // Foreground

	// Process UV map
	vec2 uv = fragCoord.xy * 0.00025; // This sets a fixed resolution for the texture patterns instead of being screen dependent

	// Create triangular noise pattern (initial magic number for the scale = 11.0)
	// float n1 = smoothstep(-Contrast, Contrast, Perlin3D(vec3(TriangleUV(uv, 11.0, Rotation, Time * Scroll)*10.0, Time * NoiseSpeed)));
	// float n2 = smoothstep(-Contrast, Contrast, Perlin3D(vec3(TriangleUV(uv*2.0+vec2(10.0, 10.0), 11.0, Rotation, Time * Scroll)*10.0, Time * NoiseSpeed)));
	// n1 = mix(n1, n2, 0.5);
	float n1 = Perlin3D(vec3(TriangleUV(uv, 11.0, Rotation, Time * Scroll)*10.0, Time * NoiseSpeed));
	float n2 = Perlin3D(vec3(TriangleUV(uv*2.0+vec2(10.0, 10.0), 11.0, Rotation, Time * Scroll)*10.0, Time * NoiseSpeed));
	n1 = clamp((n1+n2)*0.5+0.5, 0.0, 1.0);

	// Final output
	fragColor = mix(Color1, Color2, n1);
}
