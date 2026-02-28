#Requires AutoHotkey v2.0
; D2D struct helpers — named offset constants for NumPut/NumGet.
; Same pattern as the working prototype (mock_d2d_overlay.ahk).
; Mechanical upgrade path to ctypes.ahk when AHK v2.1 goes stable.
#Warn VarUnset, Off

; ========================= D2D1_COLOR_F (16 bytes) =========================
; Layout: { float r, g, b, a }

D2D_ColorF(argb) { ; lint-ignore: dead-function
    buf := Buffer(16)
    NumPut("float", ((argb >> 16) & 0xFF) / 255.0,
           "float", ((argb >> 8) & 0xFF) / 255.0,
           "float", (argb & 0xFF) / 255.0,
           "float", ((argb >> 24) & 0xFF) / 255.0,
           buf)
    return buf
}

; ========================= D2D1_RECT_F (16 bytes) =========================
; Layout: { float left, top, right, bottom }

D2D_RectF(left, top, right, bottom) { ; lint-ignore: dead-function
    buf := Buffer(16)
    NumPut("float", Float(left), "float", Float(top),
           "float", Float(right), "float", Float(bottom), buf)
    return buf
}

; ========================= D2D1_ROUNDED_RECT (24 bytes) =========================
; Layout: { D2D1_RECT_F rect (16), float radiusX, float radiusY }

D2D_RoundedRect(left, top, right, bottom, radiusX, radiusY?) { ; lint-ignore: dead-function
    if !IsSet(radiusY)
        radiusY := radiusX
    buf := Buffer(24)
    NumPut("float", Float(left), "float", Float(top),
           "float", Float(right), "float", Float(bottom),
           "float", Float(radiusX), "float", Float(radiusY), buf)
    return buf
}

; ========================= D2D1_ELLIPSE (16 bytes) =========================
; Layout: { D2D1_POINT_2F center (8), float radiusX, float radiusY }

D2D_Ellipse(cx, cy, rx, ry) { ; lint-ignore: dead-function
    buf := Buffer(16)
    NumPut("float", Float(cx), "float", Float(cy),
           "float", Float(rx), "float", Float(ry), buf)
    return buf
}

; ========================= D2D1_POINT_2F as int64 (8 bytes) =========================
; Pack two floats for by-value passing in x64 ComCall/DllCall

D2D_Point2F(x, y) { ; lint-ignore: dead-function
    static buf := Buffer(8)
    NumPut("float", Float(x), "float", Float(y), buf)
    return NumGet(buf, "int64")
}

; ========================= D2D1_SIZE_U (8 bytes) =========================
; Layout: { uint32 width, uint32 height }

D2D_SizeU(w, h) { ; lint-ignore: dead-function
    buf := Buffer(8)
    NumPut("uint", w, "uint", h, buf)
    return buf
}

; ========================= D2D1_SIZE_F (8 bytes) =========================
; Layout: { float width, float height }

D2D_SizeF(w, h) { ; lint-ignore: dead-function
    buf := Buffer(8)
    NumPut("float", Float(w), "float", Float(h), buf)
    return buf
}

; ========================= D2D1_RENDER_TARGET_PROPERTIES (28 bytes) =========================
; Used with CreateHwndRenderTarget

D2D_RenderTargetProps(dpiX := 0.0, dpiY := 0.0, alphaMode := 1) { ; lint-ignore: dead-function
    ; alphaMode: 0=Unknown, 1=Premultiplied, 2=Straight, 3=Ignore
    buf := Buffer(28, 0)
    ; type (D2D1_RENDER_TARGET_TYPE): 0 = DEFAULT (auto hw/sw)
    ; pixelFormat: DXGI_FORMAT (0=UNKNOWN) at offset 4, alphaMode at offset 8
    NumPut("uint", alphaMode, buf, 8)
    NumPut("float", Float(dpiX), buf, 12)
    NumPut("float", Float(dpiY), buf, 16)
    ; usage (D2D1_RENDER_TARGET_USAGE): 0 = NONE at offset 20
    ; minLevel: 0 = DEFAULT at offset 24
    return buf
}

; ========================= D2D1_HWND_RENDER_TARGET_PROPERTIES =========================
; Layout: { HWND hwnd, D2D1_SIZE_U pixelSize (8), D2D1_PRESENT_OPTIONS }
; Size: A_PtrSize + 12

D2D_HwndRenderTargetProps(hwnd, w, h, presentOptions := 0) { ; lint-ignore: dead-function
    buf := Buffer(A_PtrSize + 12, 0)
    NumPut("uptr", hwnd, buf, 0)
    NumPut("uint", w, buf, A_PtrSize)
    NumPut("uint", h, buf, A_PtrSize + 4)
    NumPut("uint", presentOptions, buf, A_PtrSize + 8)
    return buf
}

; ========================= D2D1_BITMAP_PROPERTIES (20 bytes) =========================
; Layout: { D2D1_PIXEL_FORMAT pixelFormat (8), float dpiX, float dpiY }

D2D_BitmapProps(dpiX := 96.0, dpiY := 96.0, format := 87, alphaMode := 1) { ; lint-ignore: dead-function
    ; format 87 = DXGI_FORMAT_B8G8R8A8_UNORM
    ; alphaMode 1 = D2D1_ALPHA_MODE_PREMULTIPLIED
    buf := Buffer(20, 0)
    NumPut("uint", format, buf, 0)
    NumPut("uint", alphaMode, buf, 4)
    NumPut("float", Float(dpiX), buf, 8)
    NumPut("float", Float(dpiY), buf, 12)
    return buf
}

; ========================= D2D1_MATRIX_3X2_F (24 bytes) =========================
; Layout: { float _11, _12, _21, _22, _31, _32 }

D2D_Matrix3x2_Identity() { ; lint-ignore: dead-function
    buf := Buffer(24, 0)
    NumPut("float", 1.0, buf, 0)   ; _11
    NumPut("float", 1.0, buf, 12)  ; _22
    return buf
}

; ========================= DWM_THUMBNAIL_PROPERTIES (48 bytes) =========================
; Used with DwmUpdateThumbnailProperties

; Flag constants ; lint-ignore: dead-global (consumed by dwm_thumbnail.ahk in Phase 2)
global DWM_TNP_RECTDESTINATION := 0x01
global DWM_TNP_RECTSOURCE      := 0x02 ; lint-ignore: dead-global
global DWM_TNP_OPACITY         := 0x04
global DWM_TNP_VISIBLE         := 0x08
global DWM_TNP_SOURCECLIENTAREAONLY := 0x10

DWM_ThumbnailProps(destL, destT, destR, destB, visible := true, opacity := 255, clientOnly := true) { ; lint-ignore: dead-function
    global DWM_TNP_RECTDESTINATION, DWM_TNP_VISIBLE, DWM_TNP_OPACITY, DWM_TNP_SOURCECLIENTAREAONLY
    ; Layout: { DWORD flags (4), RECT dest (16), RECT source (16),
    ;           BYTE opacity (1+3 pad), BOOL visible (4), BOOL srcClientOnly (4) }
    buf := Buffer(48, 0)
    flags := DWM_TNP_RECTDESTINATION | DWM_TNP_VISIBLE | DWM_TNP_OPACITY | DWM_TNP_SOURCECLIENTAREAONLY
    NumPut("uint", flags, buf, 0)
    ; rcDestination (RECT: left, top, right, bottom as int32)
    NumPut("int", destL, "int", destT, "int", destR, "int", destB, buf, 4)
    ; rcSource left at zero (use whole source)
    ; opacity
    NumPut("uchar", opacity, buf, 36)
    ; fVisible
    NumPut("int", visible ? 1 : 0, buf, 40)
    ; fSourceClientAreaOnly
    NumPut("int", clientOnly ? 1 : 0, buf, 44)
    return buf
}

; ========================= D2D1_ARC_SEGMENT (28 bytes) =========================
; Used with path geometry for per-corner rounded rects

D2D_ArcSegment(endX, endY, rx, ry, rotation := 0.0, sweepDir := 1, arcSize := 0) { ; lint-ignore: dead-function
    buf := Buffer(28, 0)
    NumPut("float", Float(endX), "float", Float(endY), buf, 0)
    NumPut("float", Float(rx), "float", Float(ry), buf, 8)
    NumPut("float", Float(rotation), buf, 16)
    NumPut("uint", sweepDir, buf, 20)   ; 1 = clockwise
    NumPut("uint", arcSize, buf, 24)    ; 0 = small
    return buf
}

; ========================= DXGI_SWAP_CHAIN_DESC1 =========================
; Layout: { UINT Width, Height, DXGI_FORMAT Format, BOOL Stereo,
;            DXGI_SAMPLE_DESC {Count, Quality}, DXGI_USAGE BufferUsage,
;            UINT BufferCount, DXGI_SCALING Scaling, DXGI_SWAP_EFFECT SwapEffect,
;            DXGI_ALPHA_MODE AlphaMode, UINT Flags }
; Size: 48 bytes

D2D_SwapChainDesc1(w, h, format, bufferCount, swapEffect, alphaMode) { ; lint-ignore: dead-function
    buf := Buffer(48, 0)
    NumPut("uint", w, buf, 0)           ; Width
    NumPut("uint", h, buf, 4)           ; Height
    NumPut("uint", format, buf, 8)      ; Format (DXGI_FORMAT)
    ; Stereo = FALSE (offset 12, already 0)
    NumPut("uint", 1, buf, 16)          ; SampleDesc.Count = 1
    ; SampleDesc.Quality = 0 (offset 20, already 0)
    NumPut("uint", 0x20, buf, 24)       ; BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT
    NumPut("uint", bufferCount, buf, 28) ; BufferCount
    NumPut("uint", 0, buf, 32)          ; Scaling = DXGI_SCALING_STRETCH
    NumPut("uint", swapEffect, buf, 36) ; SwapEffect
    NumPut("uint", alphaMode, buf, 40)  ; AlphaMode
    ; Flags = 0 (offset 44, already 0)
    return buf
}

; ========================= D2D1_BITMAP_PROPERTIES1 =========================
; Layout: { D2D1_PIXEL_FORMAT {format, alphaMode}, float dpiX, float dpiY,
;            D2D1_BITMAP_OPTIONS options, ID2D1ColorContext* colorContext }
; Size: 24 bytes (on x64: 20 + 4 pad = 24 with ptr alignment)

D2D_BitmapProps1(options, dpiX := 96.0, dpiY := 96.0, format := 87, alphaMode := 1) { ; lint-ignore: dead-function
    ; format 87 = DXGI_FORMAT_B8G8R8A8_UNORM
    ; alphaMode 1 = D2D1_ALPHA_MODE_PREMULTIPLIED
    buf := Buffer(A_PtrSize = 8 ? 32 : 24, 0)
    NumPut("uint", format, buf, 0)      ; pixelFormat.format
    NumPut("uint", alphaMode, buf, 4)   ; pixelFormat.alphaMode
    NumPut("float", Float(dpiX), buf, 8)
    NumPut("float", Float(dpiY), buf, 12)
    NumPut("uint", options, buf, 16)    ; bitmapOptions
    ; colorContext = NULL (offset 20/24, already 0)
    return buf
}

; ========================= D2D ENUMS ========================= ; lint-ignore: dead-global (consumed by gui_render.ahk / gui_paint.ahk in Phase 0)

global D2DERR_RECREATE_TARGET     := 0x8899000C ; lint-ignore: dead-global
global D2D1_ALPHA_MODE_PREMULTIPLIED := 1 ; lint-ignore: dead-global
global D2D1_ANTIALIAS_MODE_PER_PRIMITIVE := 0 ; lint-ignore: dead-global
global D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE := 2 ; lint-ignore: dead-global
global D2D1_DRAW_TEXT_OPTIONS_CLIP := 2 ; lint-ignore: dead-global
global D2D1_PRESENT_OPTIONS_NONE := 0 ; lint-ignore: dead-global
global D2D1_PRESENT_OPTIONS_IMMEDIATELY := 2 ; lint-ignore: dead-global
global DXGI_FORMAT_B8G8R8A8_UNORM := 87 ; lint-ignore: dead-global

; DXGI / D3D11 / D2D1.1 enums
global DXGI_SWAP_EFFECT_FLIP_DISCARD := 4 ; lint-ignore: dead-global
global DXGI_ALPHA_MODE_PREMULTIPLIED := 1 ; lint-ignore: dead-global
global D2D1_BITMAP_OPTIONS_TARGET := 0x00000001 ; lint-ignore: dead-global
global D2D1_BITMAP_OPTIONS_CANNOT_DRAW := 0x00000002 ; lint-ignore: dead-global
global D3D11_CREATE_DEVICE_BGRA_SUPPORT := 0x00000020 ; lint-ignore: dead-global

; DirectWrite enums
global DWRITE_FONT_WEIGHT_REGULAR  := 400 ; lint-ignore: dead-global
global DWRITE_FONT_WEIGHT_SEMIBOLD := 600 ; lint-ignore: dead-global
global DWRITE_FONT_WEIGHT_BOLD     := 700 ; lint-ignore: dead-global
global DWRITE_FONT_WEIGHT_EXTRABOLD := 800 ; lint-ignore: dead-global
global DWRITE_FONT_STYLE_NORMAL    := 0 ; lint-ignore: dead-global
global DWRITE_FONT_STRETCH_NORMAL  := 5 ; lint-ignore: dead-global
global DWRITE_WORD_WRAPPING_NO_WRAP := 1 ; lint-ignore: dead-global
global DWRITE_TEXT_ALIGNMENT_LEADING := 0 ; lint-ignore: dead-global
global DWRITE_TEXT_ALIGNMENT_TRAILING := 1 ; lint-ignore: dead-global
global DWRITE_TEXT_ALIGNMENT_CENTER := 2 ; lint-ignore: dead-global
global DWRITE_PARAGRAPH_ALIGNMENT_NEAR := 0 ; lint-ignore: dead-global
global DWRITE_PARAGRAPH_ALIGNMENT_FAR := 1 ; lint-ignore: dead-global
global DWRITE_PARAGRAPH_ALIGNMENT_CENTER := 2 ; lint-ignore: dead-global

; ========================= D2D1 EFFECT CLSIDs =========================
; Pre-computed 16-byte GUID buffers for ID2D1DeviceContext::CreateEffect.
; Initialized by FX_InitCLSIDs() at startup; declared here for global access.

global CLSID_D2D1GaussianBlur ; lint-ignore: dead-global
global CLSID_D2D1Shadow       ; lint-ignore: dead-global
global CLSID_D2D1Flood        ; lint-ignore: dead-global
global CLSID_D2D1Crop         ; lint-ignore: dead-global
global CLSID_D2D1ColorMatrix  ; lint-ignore: dead-global
global CLSID_D2D1Saturation   ; lint-ignore: dead-global
global CLSID_D2D1Blend        ; lint-ignore: dead-global
global CLSID_D2D1Composite    ; lint-ignore: dead-global
global CLSID_D2D1Turbulence   ; lint-ignore: dead-global
global CLSID_D2D1Morphology   ; lint-ignore: dead-global
global CLSID_D2D1GammaTransfer ; lint-ignore: dead-global
global CLSID_D2D1DirectionalBlur ; lint-ignore: dead-global
global CLSID_D2D1PointSpecular  ; lint-ignore: dead-global

; Convert a GUID string to a 16-byte CLSID buffer.
_D2D_CLSID(str) { ; lint-ignore: dead-function
    buf := Buffer(16, 0)
    DllCall("ole32\CLSIDFromString", "str", str, "ptr", buf, "hresult")
    return buf
}

; Initialize all effect CLSIDs. Call once at startup.
FX_InitCLSIDs() { ; lint-ignore: dead-function
    global CLSID_D2D1GaussianBlur, CLSID_D2D1Shadow, CLSID_D2D1Flood
    global CLSID_D2D1Crop, CLSID_D2D1ColorMatrix, CLSID_D2D1Saturation
    global CLSID_D2D1Blend, CLSID_D2D1Composite, CLSID_D2D1Turbulence
    global CLSID_D2D1Morphology, CLSID_D2D1GammaTransfer, CLSID_D2D1DirectionalBlur
    global CLSID_D2D1PointSpecular

    CLSID_D2D1GaussianBlur  := _D2D_CLSID("{1FEB6D69-2FE6-4AC9-8C58-1D7F93E7A6A5}")
    CLSID_D2D1Shadow        := _D2D_CLSID("{C67EA361-1863-4E69-89DB-695D3E9A5B6B}")
    CLSID_D2D1Flood         := _D2D_CLSID("{61C23C20-AE69-4D8E-94CF-50078DF638F2}")
    CLSID_D2D1Crop          := _D2D_CLSID("{E23F7110-0E9A-4324-AF47-6A2C0C46F35B}")
    CLSID_D2D1ColorMatrix   := _D2D_CLSID("{921F03D6-641C-47DF-852D-B4BB6153AE11}")
    CLSID_D2D1Saturation    := _D2D_CLSID("{5CB2D9CF-327D-459F-A0CE-40C0B2086BF7}")
    CLSID_D2D1Blend         := _D2D_CLSID("{81C5B77B-13F8-4CDD-AD20-C890547AC65D}")
    CLSID_D2D1Composite     := _D2D_CLSID("{48FC9F51-F6AC-48F1-8B58-3B28AC46F76D}")
    CLSID_D2D1Turbulence    := _D2D_CLSID("{CF2BB6AE-889A-4AD7-BA29-A2FD732C9FC9}")
    CLSID_D2D1Morphology    := _D2D_CLSID("{EAE6C40D-626A-4C2D-BFCB-391001ABE202}")
    CLSID_D2D1GammaTransfer := _D2D_CLSID("{409444C4-C419-41A0-B0C1-8CD0C0A18E42}")
    CLSID_D2D1DirectionalBlur := _D2D_CLSID("{174319A6-58E9-49B2-BB63-CAF2C811A3DB}")
    CLSID_D2D1PointSpecular := _D2D_CLSID("{09C3CA26-3AE2-4F09-9EBC-ED3865D53F22}")
}

; ========================= D2D1 EFFECT PROPERTY INDICES =========================
; Property indices for SetFloat/SetUInt/SetEnum/SetColorF on each effect type.

; D2D1_GAUSSIANBLUR_PROP
global FX_BLUR_STDEV      := 0  ; FLOAT — standard deviation (px) ; lint-ignore: dead-global
global FX_BLUR_OPTIMIZATION := 1  ; ENUM  — speed vs quality ; lint-ignore: dead-global
global FX_BLUR_BORDER_MODE := 2  ; ENUM  — soft/hard edge ; lint-ignore: dead-global

; D2D1_SHADOW_PROP
global FX_SHADOW_BLUR      := 0  ; FLOAT — shadow blur radius ; lint-ignore: dead-global
global FX_SHADOW_COLOR     := 1  ; VECTOR4 — shadow color (r,g,b,a) ; lint-ignore: dead-global

; D2D1_FLOOD_PROP
global FX_FLOOD_COLOR      := 0  ; VECTOR4 — flood fill color ; lint-ignore: dead-global

; D2D1_CROP_PROP
global FX_CROP_RECT        := 0  ; VECTOR4 — crop rectangle (l,t,r,b) ; lint-ignore: dead-global
global FX_CROP_BORDER_MODE := 1  ; ENUM ; lint-ignore: dead-global

; D2D1_COLORMATRIX_PROP
global FX_CMATRIX_MATRIX   := 0  ; MATRIX_5X4 — 5×4 color transform ; lint-ignore: dead-global
global FX_CMATRIX_ALPHA_MODE := 1  ; ENUM ; lint-ignore: dead-global
global FX_CMATRIX_CLAMP    := 2  ; BOOL ; lint-ignore: dead-global

; D2D1_SATURATION_PROP
global FX_SAT_SATURATION   := 0  ; FLOAT — 0.0 (grayscale) to 1.0 (original) ; lint-ignore: dead-global

; D2D1_BLEND_PROP
global FX_BLEND_MODE       := 0  ; ENUM — blend mode ; lint-ignore: dead-global

; D2D1_COMPOSITE_PROP
global FX_COMPOSITE_MODE   := 0  ; ENUM — composite mode ; lint-ignore: dead-global

; D2D1_TURBULENCE_PROP
global FX_TURB_OFFSET      := 0  ; VECTOR2 — noise offset ; lint-ignore: dead-global
global FX_TURB_SIZE        := 1  ; VECTOR2 — bounding size of noise output (default {0,0} = infinite) ; lint-ignore: dead-global
global FX_TURB_FREQ        := 2  ; VECTOR2 — base frequency ; lint-ignore: dead-global
global FX_TURB_OCTAVES     := 3  ; UINT32 — octave count ; lint-ignore: dead-global
global FX_TURB_SEED        := 4  ; UINT32 — random seed ; lint-ignore: dead-global
global FX_TURB_NOISE       := 5  ; ENUM — fractalSum(0) or turbulence(1) ; lint-ignore: dead-global
global FX_TURB_STITCHABLE  := 6  ; BOOL ; lint-ignore: dead-global

; D2D1_MORPHOLOGY_PROP
global FX_MORPH_MODE       := 0  ; ENUM — erode(0) or dilate(1) ; lint-ignore: dead-global
global FX_MORPH_WIDTH      := 1  ; UINT32 — kernel width ; lint-ignore: dead-global
global FX_MORPH_HEIGHT     := 2  ; UINT32 — kernel height ; lint-ignore: dead-global

; D2D1_GAMMATRANSFER_PROP (per-channel: Red, Green, Blue, Alpha)
global FX_GAMMA_RED_AMP    := 0  ; FLOAT ; lint-ignore: dead-global
global FX_GAMMA_RED_EXP    := 1  ; FLOAT ; lint-ignore: dead-global
global FX_GAMMA_RED_OFF    := 2  ; FLOAT ; lint-ignore: dead-global
global FX_GAMMA_RED_DISABLE := 3 ; BOOL ; lint-ignore: dead-global
global FX_GAMMA_GREEN_AMP  := 4  ; FLOAT ; lint-ignore: dead-global
global FX_GAMMA_GREEN_EXP  := 5  ; FLOAT ; lint-ignore: dead-global
global FX_GAMMA_GREEN_OFF  := 6  ; FLOAT ; lint-ignore: dead-global
global FX_GAMMA_GREEN_DISABLE := 7 ; BOOL ; lint-ignore: dead-global
global FX_GAMMA_BLUE_AMP   := 8  ; FLOAT ; lint-ignore: dead-global
global FX_GAMMA_BLUE_EXP   := 9  ; FLOAT ; lint-ignore: dead-global
global FX_GAMMA_BLUE_OFF   := 10 ; FLOAT ; lint-ignore: dead-global
global FX_GAMMA_BLUE_DISABLE := 11 ; BOOL ; lint-ignore: dead-global
global FX_GAMMA_ALPHA_AMP  := 12 ; FLOAT ; lint-ignore: dead-global
global FX_GAMMA_ALPHA_EXP  := 13 ; FLOAT ; lint-ignore: dead-global
global FX_GAMMA_ALPHA_OFF  := 14 ; FLOAT ; lint-ignore: dead-global
global FX_GAMMA_ALPHA_DISABLE := 15 ; BOOL ; lint-ignore: dead-global

; D2D1_POINTSPECULAR_PROP
global FX_SPEC_LIGHT_POS     := 0  ; VECTOR3 — light position (x, y, z in px) ; lint-ignore: dead-global
global FX_SPEC_EXPONENT      := 1  ; FLOAT — specular exponent (1-128, higher=tighter) ; lint-ignore: dead-global
global FX_SPEC_SURFACE_SCALE := 2  ; FLOAT — height map multiplier ; lint-ignore: dead-global
global FX_SPEC_CONSTANT      := 3  ; FLOAT — specular intensity (0-10000) ; lint-ignore: dead-global
global FX_SPEC_COLOR         := 4  ; VECTOR3 — light color (r, g, b as 0.0-1.0) ; lint-ignore: dead-global
global FX_SPEC_KERNEL_UNIT   := 5  ; VECTOR2 — kernel unit length ; lint-ignore: dead-global
global FX_SPEC_SCALE_MODE    := 6  ; ENUM — scale mode ; lint-ignore: dead-global

; D2D1_DIRECTIONALBLUR_PROP
global FX_DIRBLUR_STDEV    := 0  ; FLOAT — standard deviation (px) ; lint-ignore: dead-global
global FX_DIRBLUR_ANGLE    := 1  ; FLOAT — angle in degrees (0=right, 90=down) ; lint-ignore: dead-global
global FX_DIRBLUR_OPT      := 2  ; ENUM — optimization (speed/balanced/quality) ; lint-ignore: dead-global
global FX_DIRBLUR_BORDER   := 3  ; ENUM — border mode (soft/hard) ; lint-ignore: dead-global

; D2D1_BLEND_MODE enum values (for FX_BLEND_MODE)
global D2D1_BLEND_MULTIPLY  := 0  ; lint-ignore: dead-global
global D2D1_BLEND_SCREEN    := 1  ; lint-ignore: dead-global
global D2D1_BLEND_DARKEN    := 2  ; lint-ignore: dead-global
global D2D1_BLEND_LIGHTEN   := 3  ; lint-ignore: dead-global
global D2D1_BLEND_OVERLAY   := 11 ; lint-ignore: dead-global
global D2D1_BLEND_SOFTLIGHT := 13 ; lint-ignore: dead-global

; D2D1_COMPOSITE_MODE enum values (for FX_COMPOSITE_MODE / DrawImage)
global D2D1_COMPOSITE_SOURCE_OVER := 0 ; lint-ignore: dead-global
global D2D1_COMPOSITE_SOURCE_IN   := 5 ; lint-ignore: dead-global
global D2D1_COMPOSITE_SOURCE_ATOP := 7 ; lint-ignore: dead-global

; D2D1_GAUSSIANBLUR_OPTIMIZATION
global D2D1_BLUR_OPT_SPEED   := 0 ; lint-ignore: dead-global
global D2D1_BLUR_OPT_BALANCED := 1 ; lint-ignore: dead-global
global D2D1_BLUR_OPT_QUALITY  := 2 ; lint-ignore: dead-global

; D2D1_BORDER_MODE
global D2D1_BORDER_SOFT := 0 ; lint-ignore: dead-global
global D2D1_BORDER_HARD := 1 ; lint-ignore: dead-global

; ========================= Color Matrix Helpers =========================

; Build a 5×4 identity color matrix (80 bytes, 20 floats).
D2D_ColorMatrix_Identity() { ; lint-ignore: dead-function
    m := Buffer(80, 0)
    NumPut("float", 1.0, m, 0)   ; [0][0] = R→R
    NumPut("float", 1.0, m, 20)  ; [1][1] = G→G
    NumPut("float", 1.0, m, 40)  ; [2][2] = B→B
    NumPut("float", 1.0, m, 60)  ; [3][3] = A→A
    return m
}

; Build a tint matrix: multiplies RGB by tint color, preserves alpha.
; tintR/G/B in 0.0-1.0 range.
D2D_ColorMatrix_Tint(tintR, tintG, tintB) { ; lint-ignore: dead-function
    m := Buffer(80, 0)
    NumPut("float", Float(tintR), m, 0)   ; R scale
    NumPut("float", Float(tintG), m, 20)  ; G scale
    NumPut("float", Float(tintB), m, 40)  ; B scale
    NumPut("float", 1.0, m, 60)           ; A = passthrough
    return m
}
