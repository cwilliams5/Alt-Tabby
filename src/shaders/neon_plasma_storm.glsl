// Neon Plasma Storm (Unoptomised, so it can be a learning aid to others)
// by Nickenstein79, Creative Commons Attribution-NonCommercial-ShareAlike 3.0 Unported License.
// Inspired by mu6k's Noise plasma, which can found at: https://www.shadertoy.com/view/XsS3Rd

// This is my first attempt with Shadertoy.
// I've heavily commented it and left it completely unoptimised as a learning aid to other newbs.
// There are plenty of tweekable paramaters so folks can see and learn how it all works. :)
// (A fully optomised version will be added later. But that one will be an impenitrable wall of trig to new comers.)

// Updated on 09/12/2015 to include a some additional toggle-able CRT-filter effects.

// Awesome tune: Clockwork, by Binster/.mepegasus - https://soundcloud.com/binster

#define NUM_LAYERS 				(7)
#define LAYER_SEPERATION_FACTOR		(0.041)
#define ZOOM_FACTOR_PERIOD 			(40.0)  	// The time taken for a full zoom-out/zoom-in phase
#define ZOOM_FACTOR_MIN 			(0.5)
#define ZOOM_FACTOR_MAX 			(2.8)
#define SCROLL_SPEED_AT_MIN_ZOOM	(4.0)
#define SCROLL_SPEED_AT_MAX_ZOOM	(12.000001)
#define ROTATION_MATRIX_MAX_SKEW	(0.4)		// The maximum skewing/warping of the rotation matrix
#define ROTATION_MATRIX_SKEW_PERIOD (7.4)		// The time taken to fully skew and un-skew the rotation matrix

//#define CRT_FILTER_ON							// Toggle this line to dissable/enable the CRT Filter
//#define CRT_VIGNETTE_ON						// Toggle this line to dissable/enable the CRT-edge vignette
//#define CRT_EXTRA_NOISE_ON					// Toggle this line to dissable/enable the CRT-Extra Noise

#define TWO_PI						(6.283185307179586476925286766559)
#define LAYER_STEP_SIZE 			(1.0/float(NUM_LAYERS))

// Returns a psuedo-random float value (in the range 0.0 to 1.0) generated from a 2D vector
// works by combining the input seed value with prime numbers.
// Using primes causes sequential inputs (such as pixel coordinates) to still generate non-sequential outputs.
float Hash_From2D(vec2 Vec)
{
    float f = Vec.x + Vec.y * 37.0;
    return fract(sin(f)*104003.9);
}

// Returns a sin wave driven value that oscilates between Min and Max over the given time period
float OscilateSinScalar(float Min, float Max, float Period)
{
	return (Max-Min) * (sin(iTime*TWO_PI/Period)*0.5+0.5) + Min;
}

// Returns the interpolant (fraction) of CurrentValue between Min and Max in the range (0.0 to 1.0)
float GetInterpolant(float Min, float Max, float CurrentValue)
{
    return (CurrentValue-Min) / (Max-Min);
}

// returns a skewed Z rotation matrix (The skewing changes over time)
mat2 ZRotate_Skewed(float Angle)
{
    // Get a value to skew the rotion matrix with, which bounces between 0.0 and ROTATION_MATRIX_MAX_SKEW, over a given time period.
    float Skew = 1.0 - OscilateSinScalar(0.0, ROTATION_MATRIX_MAX_SKEW, ROTATION_MATRIX_SKEW_PERIOD);

    // As the input angle is based on an incrimental timer multiplied by magic numbers and getting the cosine of these values,
    // this generates an animated angle which drifts chaotically and
    // unpredictably over time (Like a double-pendulum's motion. Actually, a triple-pendulum as we combine three cos() values).
    // twiddle with the multiply values being passed to cos() until you like the motion of the simulation.
	Angle = cos(Angle*0.1)*cos(Angle*0.7)*cos(Angle*0.73)*2.0;

    // build and return the skewed Z-rotation matrix
    return mat2(sin(Angle * Skew),cos(Angle),-cos(Angle * Skew),sin(Angle));
}

// sample the input textures which create our desired material surface effect
vec4 SampleMaterial(vec2 uv)
{
   float t = iTime * 0.5;

   // sample texture 0, just the red channel to get an initial grey-scale value in range 0.0 to 1.0
   float Sample0 = texture(iChannel0, uv * 0.1 ).b;

   // Modify Sample0 by subtracting circlular patterns that grow across the texture over time
   // fiddle with the numbers to get differening circular patterns
   Sample0 -= 0.5 + sin(t + sin(uv.x) + sin(uv.y)) * 0.7;

   // adjust brightness
   Sample0 *= 1.6;

   // ensure no negative values with abs(), this also causes a double
   // concentric-circle pattern as sin() returns -1 to +1 values.
   Sample0 = abs(Sample0);

   // invert these fat bright negative-circles to get thin bright circles and curves
   Sample0 = 1.0/(Sample0*10.0+1.0);

   // make a greyscale colour from Sample0, then multiply it by a full-colour sample from eleswhere on texture 0
   vec4 Colour = vec4(Sample0) * texture(iChannel0, uv * 0.05);

   // multiple this colour by a scrolling sample from texture 1 (random coloured noise texture)
   // Adjust the multiplyer to expand or shrink the range of the coloured noise texture in use
   return Colour * texture(iChannel1,(uv + (iTime*1.3)) * 0.001735);
}

// Generate fast downward cycling fat scanlines
float scanline(vec2 uv, float TexHeight)
{
	return sin(iResolution.y * uv.y * 0.7 - iTime * 10.0);
}

// Generate slow upward cycling thin scanlines
float slowscan(vec2 uv, float TexHeight)
{
	return sin(iResolution.y * uv.y * 0.02 + iTime * 6.0);
}

// warp uv coordinates to emulate a curved crt screen
vec2 crt_bend_uv_coords(vec2 coord, float bend)
{
	// put in symmetrical coords
	//coord = (coord - 0.5) * 2.0;
	//coord *= 0.5;

	// deform coords
	coord.x *= 1.0 + pow((abs(coord.y) / bend), 2.0);
	coord.y *= 1.0 + pow((abs(coord.x) / bend), 2.0);

	// transform back to 0.0 - 1.0 space
	coord  = (coord / 1.0) + 0.5;

	return coord;
}

// wibble the screen, crt magnetic interferance distortion effect
vec2 scandistort(vec2 uv)
{
	float scan1 = clamp(cos(uv.y * 2.0 + iTime), 0.0, 1.0);
	float scan2 = clamp(cos(uv.y * 2.0 + iTime + 4.0) * 10.0, 0.0, 1.0);
	float amount = scan1 * scan2 * uv.x;
	uv.x -= 0.05 * mix( texture(iChannel1, vec2(uv.x, amount)).x * amount, amount, 0.9 );

	return uv;
}

// CRT edge vignette
vec3 CRT_Vignette(vec3 Colour, vec2 uv)
{
    uv.x /= iResolution.x / iResolution.y;
	float Vignette = clamp(pow(cos(uv.x * 3.1415), 1.3) * pow(cos(uv.y * 3.1415), 1.3) * 50.0, 0.0, 1.0);
    Colour *= Vignette;

    return Colour;
}

// Cathode ray tube filter, to look like an old cathode ray-tube monitor with scanlines, and V-Hold, etc...
vec3 CRT_Filter(vec3 Colour, vec2 uv)
{
#ifdef CRT_EXTRA_NOISE_ON
    Colour.r += Hash_From2D(uv * iTime * 911.911 * 4.0) * 0.19;
    Colour.g += Hash_From2D(uv * iTime * 563.577 * 4.0) * 0.19;
    Colour.b += Hash_From2D(uv * iTime * 487.859 * 4.0) * 0.19;
#endif

    vec2 sd_uv = uv;
	vec2 crt_uv = crt_bend_uv_coords(sd_uv, 2.0);
    vec3 scanline_Colour;
	vec3 slowscan_Colour;
	scanline_Colour.x = scanline(crt_uv, iResolution.y);
    slowscan_Colour.x = slowscan(crt_uv, iResolution.y);
    scanline_Colour.y = scanline_Colour.z = scanline_Colour.x;
	slowscan_Colour.y = slowscan_Colour.z = slowscan_Colour.x;
	Colour = mix(Colour, mix(scanline_Colour, slowscan_Colour, 0.5), 0.04);

    // apply the CRT-vignette filter
#ifdef CRT_VIGNETTE_ON
    Colour = CRT_Vignette(Colour, uv);
#endif

    return Colour;
}

// Perform some post processing effects on the output colour
vec3 PostProcessColour(vec3 Colour, vec2 uv)
{
    // Vignette (Darken the pixels nearer the corners of the screen)
    Colour -= vec3(length(uv*0.1));

    // Add some random noise to the colour with the Hashing function
	Colour += Hash_From2D(uv*iTime*0.01)*0.02;

    // apply the CRT-screen filter
#ifdef CRT_FILTER_ON
    Colour = CRT_Filter(Colour, uv);
#endif

    // Approximate the brightness of the colour by using it as a 3d spacial vector and getting its length in colour space
    float Brightness = length(Colour);

    // inrease the colour contrast, by dimming the darker colours and brightening the lighter ones,
    // via linear interpolation of the colour and its approximated brightness value
	Colour = mix(Colour, vec3(Brightness), Brightness - 0.5);

    return Colour;
}

void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
    // get a UV chord for each texel in the range -1.0 to 1.0 (so we can scale/rotate everything from the center of the screen)
	vec2 uv = fragCoord.xy / iResolution.xy - 0.5;

    // modify the X component of the uv, by the screen's aspect ratio to avoid stretching of the input textures in width
	uv.x *= iResolution.x / iResolution.y;

    // start with black
	vec3 Colour = vec3(0.0, 0.0, 0.0);

    // Determine a scale value that oscilates between MIN_ZOOM and MAX_ZOOM over the desired time period
    float ScaleValue = OscilateSinScalar(ZOOM_FACTOR_MIN, ZOOM_FACTOR_MAX, ZOOM_FACTOR_PERIOD);

    // Determine a speed to scroll through the texture space.
    // This works by generating a speed value between MIN_SCROLL and MAX_SCROLL
    // which is guided by the current zoom value, such that when the texture
    // is fully zoomed out, the scroll speed is at the desired maximum, and when
    // the texture is fully zoomed in, the scroll speed is at the desired minimum.
    float ScrollInterpolant = GetInterpolant(ZOOM_FACTOR_MIN, ZOOM_FACTOR_MAX, ScaleValue);
    // mix performs a linear interpolation between two inputs
    float ScrollValue = mix(SCROLL_SPEED_AT_MIN_ZOOM, SCROLL_SPEED_AT_MAX_ZOOM, ScrollInterpolant);

	// Sum the colour contribution of each layer
	for (float i = 0.0; i < 1.0; i += LAYER_STEP_SIZE)
	{
        // clone the uv, so the original is preserved for each itteration of the loop
		vec2 uv2 = uv;

        // Rotate with a Z-Rotation matrix that skewes over time
        // (Giving a slighlty different input angle for each layer, as i-squared is combined in)
        uv2 *= ZRotate_Skewed(iTime * i*i * 12.0 * LAYER_SEPERATION_FACTOR);

        // Scale (Again, giving a slighlty different scale for each layer, as i-squared is combined in)
		uv2 *= ScaleValue * (i*i+1.0);

        // Scroll the sampling position over time
		uv2.xy += ScrollValue + iTime*0.125;

        // sample the material, building up each layer's colour contribution
		Colour += SampleMaterial(uv2).xyz*LAYER_STEP_SIZE*3.5;
	}

    // Perform some post processing on the accumulated colour layers
    Colour = PostProcessColour(Colour, uv);

    // set the generated colour as the final output pixel colour
	fragColor = vec4(Colour, 1.0);
}
