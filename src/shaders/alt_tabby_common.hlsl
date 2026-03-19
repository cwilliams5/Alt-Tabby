// alt_tabby_common.hlsl — Shared definitions for all Alt-Tabby pixel shaders.
// Prepended automatically before D3DCompile. Do NOT #include manually.

cbuffer Constants : register(b0) {
    // --- Existing (32 bytes, offsets 0-28) ---
    float time;
    float2 resolution;
    float timeDelta;
    uint frame;
    float darken;
    float desaturate;
    float opacity;          // shader-level opacity (0.0-1.0)

    // --- Mouse (offsets 32-44, 16-byte aligned) ---
    float2 iMouse;          // cursor position in pixels
    float2 iMouseVel;       // cursor velocity in pixels/sec

    // --- Selection rect (offsets 48-60) ---
    float4 selRect;         // x, y, w, h of selected row

    // --- Selection color (offsets 64-76) ---
    float4 selColor;        // SelARGB as premultiplied RGBA

    // --- Border color (offsets 80-92) ---
    float4 borderColor;     // SelBorderARGB as premultiplied RGBA

    // --- Selection params (offsets 96-108, 16-byte aligned) ---
    float borderWidth;      // border thickness in pixels
    float isHovered;        // intensity: 1.0 = full (selected), <1.0 = dimmed (hovered)
    float entranceT;        // 0→1 entrance tween
    float iMouseSpeed;      // magnitude of iMouseVel (pixels/sec)

    // --- Compute grid/particle config (offsets 112-124, 16-byte aligned) ---
    uint gridW;             // grid width (0 = no grid)
    uint gridH;             // grid height (0 = no grid)
    uint maxParticles;      // particle slots (excluding grid cells)
    float reactivity;       // cursor force multiplier

    // --- Selection effect tuning (offsets 128-140, 16-byte aligned) ---
    float selGlow;          // outer glow radius multiplier (1.0 = default)
    float selIntensity;     // effect blend strength (1.0 = default)
    float rowRadius;        // user's RowRadius in pixels (0 = shader decides)
    float _pad1;
};

struct PSInput {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
};

// Post-process: darken, desaturate, premultiplied-alpha with opacity.
// Standard variant: alpha = max brightness of pre-darken color.
// Darken crushes color toward black without reducing alpha.
float4 AT_PostProcess(float3 col) {
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, (float3)lum, desaturate);
    float a = max(col.r, max(col.g, col.b)) * opacity;
    col *= (1.0 - darken);
    return float4(col * a, a);
}

// Custom-alpha variant: caller provides pre-computed alpha.
// Darken crushes color toward black; alpha controlled only by opacity.
float4 AT_PostProcess(float3 col, float a) {
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, (float3)lum, desaturate);
    col *= (1.0 - darken);
    a *= opacity;
    return float4(col * a, a);
}

// Hue to RGB: converts hue [0,1] to RGB color.
// Used by selection shaders for animated color effects.
float3 hue2rgb(float h) {
    float r = abs(h * 6.0 - 3.0) - 1.0;
    float g = 2.0 - abs(h * 6.0 - 2.0);
    float b = 2.0 - abs(h * 6.0 - 4.0);
    return saturate(float3(r, g, b));
}

// Rounded rect SDF: returns signed distance (negative = inside).
// Used by selection shaders for border/fill masking.
float roundedRectSDF(float2 p, float2 center, float2 halfSize, float radius) {
    float2 d = abs(p - center) - halfSize + radius;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}
