---
name: review-paint
description: Audit the D2D paint pipeline for per-frame waste — allocations, recomputation, redundant API calls at 120-240fps
user-invocable: true
disable-model-invocation: true
---
Enter planning mode. Deep-audit the D2D paint pipeline for anything that wastes cycles per frame — from per-frame allocations to redundant D2D API calls. Use maximum parallelism — spawn explore agents for independent subsystems.

## Context

The overlay renders at 120-240fps via Direct2D 1.1. At these frame rates, per-frame waste compounds fast: a 5μs allocation ×30/frame ×240fps = 36ms/s of pure garbage. The AHK runtime allocates objects on the heap — every `Buffer()`, `Array()`, `Object()`, and `Map()` lookup is a real cost.

This review covers the **D2D rendering pipeline only** — from `BeginDraw` to `EndDraw`, including effect chains, compositing layers, and resource management. It does NOT cover:
- Shader compilation or D3D11 interop (use `review-shader` for that)
- Window data / store operations (use `review-latency` Path 1)
- Keyboard hook latency (use `review-latency` Path 2 preamble)

## What to Look For

### 1. Per-Frame Allocations (Highest Priority)

Any `Buffer()`, `[]` array literal, `{}` object literal, or `Map()` creation inside a function called every frame.

**The fix pattern is established** (from `ahk-patterns.md`):
```ahk
; WRONG — allocates every call
MyHotFunc() {
    buf := Buffer(72)
    NumPut("float", x, buf, 0)
    DllCall(..., "Ptr", buf, ...)
}

; CORRECT — static buffer, repopulated
MyHotFunc() {
    static buf := Buffer(72)
    NumPut("float", x, buf, 0)
    DllCall(..., "Ptr", buf, ...)
}
```

Scan for: `Buffer(`, `Array(`, literal `[`, literal `{` inside any function reachable from the paint path.

**Exception**: Buffers whose size varies per call cannot be made static. Flag them but note the constraint.

### 2. Redundant D2D API Calls

D2D operations that produce the same result every frame:
- Setting the same effect property to the same value (e.g., blur radius that hasn't changed)
- Creating/releasing resources that could be cached (brushes, geometries, layers)
- `SetTransform` / `GetTransform` pairs that could be avoided
- Effect chain `SetInput` / `GetOutput` calls that don't change between frames

### 3. Cacheable Computation

Values computed every frame that only change on config change, resize, or state transition:
- Layout math (positions, rects) recomputed on every paint when overlay size hasn't changed
- Color conversions (hex → ARGB) done per-frame instead of on config load
- Gradient stop arrays rebuilt identically every frame
- Shadow/glow parameters recomputed from config values that haven't changed

### 4. Map Lookup Overhead

`gFX_GPU["effectName"]` string-keyed Map lookups on the hot path. Each lookup hashes the string and walks the bucket. When the same key is accessed multiple times per frame, cache it in a local variable.

### 5. Unnecessary DrawImage / DrawBitmap Calls

- Drawing layers with zero opacity (should early-exit)
- Drawing effects whose inputs haven't changed (could cache output bitmap like `gui_bgimage.ahk` does)
- Drawing off-screen content that will be fully occluded by later layers

### 6. PushLayer / PopLayer Overhead

Each `PushLayer` / `PopLayer` pair forces D2D to create and composite an intermediate surface. Check whether any layers could be eliminated by:
- Using opacity on `DrawBitmap` directly instead of a layer
- Merging adjacent layers with compatible parameters
- Skipping layers entirely when their effect is identity (opacity=1.0, no clip)

### 7. Any other detected optimizations. 

## Files to Audit

Primary (called every frame):
- `src/gui/gui_paint.ahk` — main paint orchestrator (`_GUI_PaintOverlay`)
- `src/gui/gui_effects.ahk` — D2D effect helpers (`FX_LayerParams`, `FX_LinearGradient`, `FX_DrawSoftRect`, etc.)
- `src/gui/gui_bgimage.ahk` — background image layer
- `src/gui/gui_animation.ahk` — animation tick + opacity

Supporting (called from paint path):
- `src/gui/gui_gdip.ahk` — D2D resource management, bitmap creation, cached brushes
- `src/gui/gui_math.ahk` — layout calculations
- `src/gui/d2d_shader.ahk` — shader layer draw (D3D11 side is out of scope, but the D2D `DrawBitmap` call is in scope)

Init/config (not per-frame, but relevant for cache invalidation):
- `src/gui/gui_effects.ahk` — `FX_GPU_Init()`, `FX_GPU_Dispose()`
- `src/shared/config_registry.ahk` — which values feed into paint-path computations

## Explore Strategy

Split by subsystem (run in parallel):

- **Paint orchestrator agent**: `gui_paint.ahk` — trace `_GUI_PaintOverlay` from `BeginDraw` to `EndDraw`. Map every function call, every Buffer allocation, every D2D API call. Count per-frame frequency.
- **Effects agent**: `gui_effects.ahk` — every public function. For each: is it called per-frame? Does it allocate? Does it recompute invariants? Check `FX_LayerParams`, `FX_LinearGradient`, `FX_DrawSoftRect`, `_FX_BuildStops`, `_FX_GetShadowParams`.
- **Resource agent**: `gui_gdip.ahk`, `gui_math.ahk`, `gui_animation.ahk` — resource caching effectiveness, layout recomputation, animation state updates.

### Tools

- `query_function.ps1 <func>` — extract function bodies without loading full files
- `query_interface.ps1 <file>` — public API surface of paint path files
- `query_timers.ps1` — find animation/repaint timers and their frequencies
- `query_global_ownership.ps1 <global>` — trace who writes paint-path globals

## Assessment Format

Surface **everything** — do not auto-exclude findings based on estimated size. At 240fps, a 2μs saving ×240 = 480μs/s. That matters.

For each finding:

| Finding | File:Lines | Per-Call Cost | Calls/Frame | Per-Frame Cost | Complexity | Fix |
|---------|-----------|--------------|-------------|----------------|------------|-----|
| `FX_LayerParams` allocates 72B Buffer | `gui_effects.ahk:123` | ~3μs | 4 | ~12μs | One-line static | `static buf := Buffer(72)` |

**Columns:**
- **Per-Call Cost**: Estimated cost of one invocation (allocation + computation)
- **Calls/Frame**: How many times this runs per frame (trace the paint path, don't guess)
- **Per-Frame Cost**: Per-Call × Calls/Frame — the actual per-frame waste
- **Complexity**: One-line, small refactor, medium refactor, architectural
- **Fix**: Concrete fix description

**Do not filter.** A 1μs saving ×30/frame is 30μs/frame = 7.2ms/s at 240fps. List everything, ordered by per-frame cost (highest first).

## Validation

After explore agents report back, **validate every finding yourself**:

1. **Trace the call path**: Confirm the function is actually called per-frame by tracing from `_GUI_PaintOverlay` → ... → the function. Don't flag init-time code as per-frame.
2. **Check for existing optimization**: This codebase has been through optimization passes. Some functions already use `static` buffers, cached brushes, or early-exits. Verify the waste still exists.
3. **Verify mutability**: Before suggesting `static`, confirm the buffer content actually changes between calls (otherwise it could be a one-time init). If content is frame-invariant, the fix might be "compute once, cache" rather than "static buffer."
4. **Check AHK semantics**: `static` in AHK v2 persists across calls to the same function. Verify this is safe — no reentrancy issues, no size changes between calls.
5. **Distinguish from shader path**: If a finding is in `d2d_shader.ahk` and relates to D3D11 operations (texture creation, SRV binding, shader dispatch), it's out of scope. Only flag the D2D-side draw call.

## Plan Format

**Section 1 — Per-Frame Allocations:**

| Finding | File:Lines | Per-Call Cost | Calls/Frame | Per-Frame Cost | Complexity | Fix |
|---------|-----------|--------------|-------------|----------------|------------|-----|

**Section 2 — Redundant D2D API Calls:**

| Finding | File:Lines | Per-Call Cost | Calls/Frame | Per-Frame Cost | Complexity | Fix |
|---------|-----------|--------------|-------------|----------------|------------|-----|

**Section 3 — Cacheable Computation:**

| Finding | File:Lines | Per-Call Cost | Calls/Frame | Per-Frame Cost | Complexity | Fix |
|---------|-----------|--------------|-------------|----------------|------------|-----|

**Section 4 — Map Lookups & Misc:**

| Finding | File:Lines | Per-Call Cost | Calls/Frame | Per-Frame Cost | Complexity | Fix |
|---------|-----------|--------------|-------------|----------------|------------|-----|

Order within each section by per-frame cost (highest first).

Ignore any existing plans — create a fresh one.
