---
name: convert-shaders
description: Convert Shadertoy GLSL shaders to HLSL for Alt-Tabby's D3D11 pipeline
user-invocable: true
disable-model-invocation: true
---

# /convert-shaders — GLSL to HLSL Shader Conversion

Convert Shadertoy GLSL shaders to the Alt-Tabby HLSL pixel shader format.

## Invocation

- `/convert-shaders` — Scan `src/shaders/` for any `.glsl` without matching `.hlsl`, convert all
- `/convert-shaders <pasted GLSL or Shadertoy URL>` — Convert a specific shader

**Not supported:** Multi-buffer shaders (Buffer A/B/C/D tabs). Our pipeline is single-pass only. Skip shaders that require inter-frame feedback or multi-pass rendering.

## Two Modes

### Mode A — Scan Directory (no args)

1. Scan `src/shaders/` for any `name.glsl` that has no matching `name.hlsl`
2. For each unconverted shader: convert, create `.hlsl` (and `.json` if missing)

### Mode B — Paste GLSL (with args)

1. Ask for a shader name if not obvious from the source
2. Write `src/shaders/name.glsl` with the pasted source
3. Create `src/shaders/name.json` with metadata (prompt for Shadertoy URL/author if not provided)
4. Convert to `src/shaders/name.hlsl`

## Conversion Steps (both modes)

### 1. Mechanical Type Conversions

| GLSL | HLSL |
|------|------|
| `vec2`, `vec3`, `vec4` | `float2`, `float3`, `float4` |
| `ivec2`, `ivec3`, `ivec4` | `int2`, `int3`, `int4` |
| `mat2`, `mat3`, `mat4` | `float2x2`, `float3x3`, `float4x4` |
| `fract()` | `frac()` |
| `mod(a, b)` | `fmod(a, b)` |
| `mix(a, b, t)` | `lerp(a, b, t)` |
| `texture(sampler, uv)` | `tex.Sample(samplerState, uv)` |
| `texelFetch(sampler, coord, lod)` | `tex.Load(int3(coord, lod))` |
| `atan(y, x)` | `atan2(y, x)` |
| `dFdx()`, `dFdy()` | `ddx()`, `ddy()` |

### 2. Constructor Broadcasts

GLSL allows `vec3(x)` as shorthand for `vec3(x, x, x)`. HLSL does too with `float3(x, x, x)` or `(float3)x`.

### 3. Replace Shadertoy Uniforms

| Shadertoy | HLSL cbuffer |
|-----------|-------------|
| `iTime` | `time` |
| `iResolution.xy` | `resolution` |
| `iResolution` (vec3) | `float3(resolution, 1.0)` |
| `iTimeDelta` | `timeDelta` |
| `iFrame` | `frame` |
| `fragCoord` | `input.pos.xy` (from SV_Position) |
| `fragColor` | return value of PSMain |

### 4. Entry Point Wrapper

Replace `void mainImage(out vec4 fragColor, in vec2 fragCoord)` with:

```hlsl
struct PSInput {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
};

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    // ... converted body ...
    return fragColor;  // instead of out parameter
}
```

**Y-axis flip:** Shadertoy's `fragCoord.y = 0` is at the **bottom** of the screen; `SV_Position.y = 0` is at the **top**. For shaders with gravity, falling particles, directional motion, or any up/down asymmetry, flip Y at the start:

```hlsl
float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);
```

Symmetric shaders (noise fields, clouds, fractals) usually don't need the flip.

### 5. Constant Buffer Header

Always include at the top of the `.hlsl`:

```hlsl
cbuffer Constants : register(b0) {
    float time;
    float2 resolution;
    float timeDelta;
    uint frame;
    float darken;
    float desaturate;
    float _pad;
};
```

### 6. Alpha Handling

Shadertoy shaders typically output opaque (alpha=1.0). For Alt-Tabby compositing:

- If the original outputs opaque, derive alpha from brightness: `float a = max(color.r, max(color.g, color.b));`
- Premultiply: `return float4(color * a, a);`
- If the shader already handles transparency, keep its alpha logic
- Apply darken/desaturate post-processing before premultiply:
  ```hlsl
  float lum = dot(color, float3(0.299, 0.587, 0.114));
  color = lerp(color, float3(lum, lum, lum), desaturate);
  color = color * (1.0 - darken);
  ```

### 7. Audio Channels

Shadertoy shaders may use `iChannel0..3` for audio input (spectrum/waveform) or produce audio output via a "Sound" tab.

- **Audio input** (e.g., `texture(iChannel0, vec2(freq, 0.0)).r` for spectrum): Replace with a gentle time-based pulse so the shader retains dynamic variation without requiring audio hardware:
  ```hlsl
  float getBeat() {
      return smoothstep(0.6, 0.9, pow(sin(time * 1.5) * 0.5 + 0.5, 4.0)) * 0.3;
  }
  ```
  Adjust frequency/amplitude to match how the original used the audio data (subtle background pulse vs heavy bass reactivity).

- **Audio output** ("Sound" tab shaders): Remove entirely. Alt-Tabby is visual only.

### 8. Mouse Input (iMouse)

Shadertoy provides `iMouse` (pixel coordinates, click state). Alt-Tabby has no mouse interaction with the shader layer.

- **Shader has an automated path without mouse** (camera moves via time, mouse just offsets/rotates): Zero out `iMouse`. Set any derived mouse variables to `(float2)0` and simplify away dead code (e.g., `P.x -= bsMo.x * 2.0` becomes a no-op, remove it).

- **Mouse is the sole camera or parameter control** (orbiting a fractal, controlling zoom/distortion — zeroing it produces a static or broken view): Replace with a gentle time-based sweep so the shader explores its parameter space:
  ```hlsl
  float2 fakeMouse = float2(
      sin(time * 0.1) * 0.3,
      cos(time * 0.07) * 0.2
  );
  ```
  Tune the frequency, amplitude, and coordinate space to match how the shader consumes mouse input (normalized `0..1`, centered `-0.5..0.5`, or raw pixels). Preview the result at several time values to ensure the sweep stays in a visually interesting range.

### 9. iChannel Textures

If the shader uses `iChannel0..3`:

1. Save texture PNGs as `src/shaders/name_i0.png`, `name_i1.png`, etc.
2. Add entries to the `.json` metadata:
   ```json
   "iChannels": [{"index": 0, "file": "name_i0.png", "filter": "linear", "wrap": "repeat"}]
   ```
3. In HLSL, declare textures:
   ```hlsl
   Texture2D iChannel0 : register(t0);
   SamplerState samp0 : register(s0);
   ```
4. Replace `texture(iChannelN, uv)` with `iChannelN.Sample(sampN, uv)`

## Final Steps (always, after all conversions)

10. Run the bundle script:
    ```
    powershell -File tools/shader_bundle.ps1
    ```

11. Run tests:
    ```
    .\tests\test.ps1
    ```

## .json Metadata Format

```json
{
  "name": "Display Name",
  "shadertoyId": "XXXXXX",
  "author": "Author Name",
  "license": "CC BY-NC-SA 3.0",
  "opacity": 0.50,
  "iChannels": [],
  "timeOffsetMin": 40,
  "timeOffsetMax": 120,
  "timeAccumulate": true
}
```

- `opacity`: Default layer opacity when compositing (0.0-1.0)
- `iChannels`: Array of texture references (empty if no textures needed)
- `timeOffsetMin`: (optional) Minimum random time offset in seconds. Skips the shader's warmup period so it looks interesting immediately. Falls back to config `ShaderTimeOffsetMin` (default 30) if omitted.
- `timeOffsetMax`: (optional) Maximum random time offset in seconds. Falls back to config `ShaderTimeOffsetMax` (default 90) if omitted. Set higher for shaders with long warmup (e.g., volumetric fog needs 40-120s).
- `timeAccumulate`: (optional) When true, shader time persists across overlay show/hide so it picks up where it left off. Falls back to config `ShaderTimeAccumulate` (default true) if omitted. Set false for shaders with a deliberate intro animation you want to see each time.

Add time fields when the shader has a notable warmup period or deliberate intro. Omit them for shaders that look good immediately at any time value.
