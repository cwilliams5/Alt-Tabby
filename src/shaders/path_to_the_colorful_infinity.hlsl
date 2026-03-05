// Path to the colorful infinity by benoitM
// Ported from https://www.shadertoy.com/view/WtjyzR
// 2D fractal space-folding with layered depth

#define NUM_LAYERS 16.
#define ITER 23

float4 tex_fractal(float3 p) {
    float t = time + 78.;
    float4 o = float4(p.xyz, 3.*sin(t*.1));
    float4 dec = float4(1., .9, .1, .15) + float4(.06*cos(t*.1), 0, 0, .14*cos(t*.23));
    [loop]
    for (int i = 0; i++ < ITER;) o.xzyw = abs(o / dot(o, o) - dec);
    return o;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float2 uv = (fragCoord - resolution.xy*.5) / resolution.y;
    float3 col = (float3)0;
    float t = time * .3;

    [loop]
    for (float i = 0.; i <= 1.; i += 1./NUM_LAYERS) {
        float d = frac(i + t);
        float s = lerp(5., .5, d);
        float f = d * smoothstep(1., .9, d);
        col += tex_fractal(float3(uv*s, i*4.)).xyz * f;
    }

    col /= NUM_LAYERS;
    col *= float3(2, 1., 2.);
    col = sqrt(col);

    return AT_PostProcess(col);
}
