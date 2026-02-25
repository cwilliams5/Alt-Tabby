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

; ========================= D2D ENUMS ========================= ; lint-ignore: dead-global (consumed by gui_render.ahk / gui_paint.ahk in Phase 0)

global D2DERR_RECREATE_TARGET     := 0x8899000C ; lint-ignore: dead-global
global D2D1_ALPHA_MODE_PREMULTIPLIED := 1 ; lint-ignore: dead-global
global D2D1_ANTIALIAS_MODE_PER_PRIMITIVE := 0 ; lint-ignore: dead-global
global D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE := 2 ; lint-ignore: dead-global
global D2D1_DRAW_TEXT_OPTIONS_CLIP := 2 ; lint-ignore: dead-global
global D2D1_PRESENT_OPTIONS_NONE := 0 ; lint-ignore: dead-global
global D2D1_PRESENT_OPTIONS_IMMEDIATELY := 2 ; lint-ignore: dead-global
global DXGI_FORMAT_B8G8R8A8_UNORM := 87 ; lint-ignore: dead-global

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
