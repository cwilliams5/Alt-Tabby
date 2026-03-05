float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float2 uv = fragCoord.xy / resolution.xy;
    uv.y = uv.y * ( resolution.x / resolution.y );
    float tt = 1024.0 * frac( time / 16384.0 );
    float3 c = float3( cos( ( uv.x*uv.y + uv.y + 5.0*tt ) * 3.0 ),
                        cos( ( 3.0*uv.y*uv.x + 7.0*tt ) * 2.0 ),
                        cos( sin(tt)*(1.0-uv.x-uv.y)*3.0 ) );
    float3 color = c * 0.5 + 0.5;

    return AT_PostProcess(color);
}
