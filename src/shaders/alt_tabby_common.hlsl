// alt_tabby_common.hlsl — Shared definitions for all Alt-Tabby pixel shaders.
// Prepended automatically before D3DCompile. Do NOT #include manually.

cbuffer Constants : register(b0) {
    float time;
    float2 resolution;
    float timeDelta;
    uint frame;
    float darken;
    float desaturate;
    float opacity;          // shader-level opacity (0.0-1.0)
};

struct PSInput {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
};

// Post-process: darken, desaturate, brightness-alpha with opacity.
// Standard variant: alpha = max brightness channel.
float4 AT_PostProcess(float3 col) {
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, (float3)lum, desaturate);
    col *= (1.0 - darken);
    float a = max(col.r, max(col.g, col.b)) * opacity;
    return float4(col * a, a);
}

// Custom-alpha variant: caller provides pre-computed alpha.
float4 AT_PostProcess(float3 col, float a) {
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, (float3)lum, desaturate);
    col *= (1.0 - darken);
    a *= opacity;
    return float4(col * a, a);
}
