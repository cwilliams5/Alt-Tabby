#Requires AutoHotkey v2.0
; D2D1 DeviceContext pipeline — COM wrappers for ID2D1Factory1, ID2D1Device,
; ID2D1DeviceContext, DXGI SwapChain, and supporting interfaces.
; Extends the ID2DBase pattern from Direct2D.ahk (lib/).
;
; ID2D1DeviceContext extends ID2D1RenderTarget — all existing draw helpers
; (gui_gdip.ahk) work unchanged via vtable inheritance.
#Warn VarUnset, Off

; ========================= ID2D1Factory1 =========================
; Extends ID2D1Factory (vtable 0-16) with new methods at index 17+.
; We only use CreateDevice (index 17).

class ID2D1Factory1 extends ID2DBase {
    static IID := '{bb12d362-daee-4b9a-aa1d-14ba401cfa1f}'

    __New(p := 0) {
        if (!p) {
            #DllLoad 'd2d1.dll'
            if DllCall('ole32\CLSIDFromString', 'str', '{bb12d362-daee-4b9a-aa1d-14ba401cfa1f}', 'ptr', buf := Buffer(16, 0))
                throw OSError()
            ; D2D1CreateFactory with D2D1_FACTORY_TYPE_SINGLE_THREADED=0
            DllCall('d2d1\D2D1CreateFactory', 'uint', 0, 'ptr', buf, 'uint*', 0, 'ptr*', &pFactory := 0, 'hresult')
            this.ptr := pFactory
        } else {
            this.ptr := p
        }
    }

    ; ID2D1Factory1::CreateDevice(dxgiDevice) → ID2D1Device
    ; vtable index 17 (after all ID2D1Factory methods 0-16)
    CreateDevice(dxgiDevice) {
        ComCall(17, this, 'ptr', dxgiDevice.ptr, 'ptr*', &pDevice := 0, 'hresult')
        return ID2D1Device(pDevice)
    }
}

; ========================= ID2D1Device =========================
; Inherits ID2D1Resource (vtable 0-3). We use CreateDeviceContext at index 4.

class ID2D1Device extends ID2DBase {
    static IID := '{47dd575d-ac05-4cdd-8049-9b02cd16f44c}'

    ; ID2D1Device::CreateDeviceContext(options) → ID2D1DeviceContext
    ; vtable index 4 (ID2D1Resource::GetFactory=3, then CreateDeviceContext=4)
    ; options: D2D1_DEVICE_CONTEXT_OPTIONS_NONE = 0
    CreateDeviceContext(options := 0) {
        ComCall(4, this, 'uint', options, 'ptr*', &pDC := 0, 'hresult')
        return ID2D1DeviceContext(pDC)
    }
}

; ========================= ID2D1DeviceContext =========================
; Extends ID2D1RenderTarget (vtable 0-56).
; New methods start at index 57. We only need SetTarget and CreateBitmapFromDxgiSurface.
;
; Key: inherits ALL RenderTarget methods — BeginDraw, EndDraw, Clear, FillRect,
; DrawText, CreateSolidColorBrush, etc. all work at the same vtable indices.

class ID2D1DeviceContext extends ID2DBase {
    static IID := '{e8f7fe7a-191c-466d-ad95-975678bda998}'

    ; --- Inherited from ID2D1RenderTarget (same vtable indices) ---
    ; These mirror the methods in Direct2D.ahk's ID2D1RenderTarget class.
    ; Only the ones actually called by gui_overlay.ahk / gui_gdip.ahk are listed.

    CreateBitmap(size, srcData := 0, pitch := 0, bitmapProperties := 0) {
        ComCall(4, this, 'int64', NumGet(size, 'int64'), 'ptr', srcData, 'uint', pitch, 'ptr', bitmapProperties, 'ptr*', &pBitmap := 0, 'hresult')
        return ID2D1Bitmap(pBitmap)
    }

    CreateSolidColorBrush(color, brushProperties := 0) {
        ComCall(8, this, 'ptr', color, 'ptr', brushProperties, 'ptr*', &pBrush := 0, 'hresult')
        return ID2D1SolidColorBrush(pBrush)
    }

    CreateGradientStopCollection(gradientStops, gradientStopsCount, gamma := 0, extendMode := 0) {
        ComCall(9, this, 'ptr', gradientStops, 'uint', gradientStopsCount, 'uint', gamma, 'uint', extendMode, 'ptr*', &pCollection := 0, 'hresult')
        return ID2D1GradientStopCollection(pCollection)
    }

    CreateLinearGradientBrush(lgbProps, brushProps, stopCollection) {
        ComCall(10, this, 'ptr', lgbProps, 'ptr', brushProps, 'ptr', stopCollection.ptr, 'ptr*', &pBrush := 0, 'hresult')
        return ID2D1LinearGradientBrush(pBrush)
    }

    DrawLine(point0, point1, brush, strokeWidth := 1.0, strokeStyle := 0) => ComCall(15, this, 'int64', point0, 'int64', point1, 'ptr', brush.ptr, 'float', strokeWidth, 'ptr', strokeStyle, 'int')
    DrawRectangle(rect, brush, strokeWidth := 1.0, strokeStyle := 0) => ComCall(16, this, 'ptr', rect, 'ptr', brush.ptr, 'float', strokeWidth, 'ptr', strokeStyle, 'int')
    FillRectangle(rect, brush) => ComCall(17, this, 'ptr', rect, 'ptr', brush.ptr, 'int')
    DrawRoundedRectangle(roundedRect, brush, strokeWidth := 1.0, strokeStyle := 0) => ComCall(18, this, 'ptr', roundedRect, 'ptr', brush.ptr, 'float', strokeWidth, 'ptr', strokeStyle, 'int')
    FillRoundedRectangle(roundedRect, brush) => ComCall(19, this, 'ptr', roundedRect, 'ptr', brush.ptr, 'int')
    DrawEllipse(ellipse, brush, strokeWidth := 1.0, strokeStyle := 0) => ComCall(20, this, 'ptr', ellipse, 'ptr', brush.ptr, 'float', strokeWidth, 'ptr', strokeStyle, 'int')
    FillEllipse(ellipse, brush) => ComCall(21, this, 'ptr', ellipse, 'ptr', brush.ptr, 'int')

    DrawBitmap(bitmap, destinationRectangle := 0, opacity := 1.0, interpolationMode := 1, sourceRectangle := 0) => ComCall(26, this, 'ptr', bitmap.ptr, 'ptr', destinationRectangle, 'float', opacity, 'uint', interpolationMode, 'ptr', sourceRectangle, 'int')
    DrawText(string, textFormat, layoutRect, defaultForegroundBrush, options := 0, measuringMode := 0) => ComCall(27, this, 'str', string, 'uint', StrLen(string), 'ptr', textFormat.ptr, 'ptr', layoutRect, 'ptr', defaultForegroundBrush.ptr, 'uint', options, 'uint', measuringMode, 'int')

    SetTransform(transform) => ComCall(30, this, 'ptr', transform, 'int')
    SetAntialiasMode(antialiasMode) => ComCall(32, this, 'uint', antialiasMode, 'int')
    SetTextAntialiasMode(textAntialiasMode) => ComCall(34, this, 'uint', textAntialiasMode, 'int')

    Clear(clearColor) => ComCall(47, this, 'ptr', clearColor, 'int')
    BeginDraw() => ComCall(48, this, 'int')
    EndDraw(&tag1 := 0, &tag2 := 0) => ComCall(49, this, 'int64*', &tag1 := 0, 'int64*', &tag2 := 0, 'int')

    ; ID2D1RenderTarget::PushLayer (vtable 40) — redirect drawing into a layer.
    ; Win8+: pass layer=0 for an auto-managed temporary layer.
    PushLayer(layerParams, layer := 0) => ComCall(40, this, 'ptr', layerParams, 'ptr', layer, 'int')

    ; ID2D1RenderTarget::PopLayer (vtable 41) — end layer redirection, composite result.
    PopLayer() => ComCall(41, this, 'int')

    SetDpi(dpiX, dpiY) => ComCall(51, this, 'float', dpiX, 'float', dpiY, 'int')

    ; --- ID2D1DeviceContext new methods (index 57+) ---
    ;
    ; Full vtable map for ID2D1DeviceContext (index 57-90):
    ; 57:CreateBitmap1, 58:CreateBitmapFromWicBitmap1, 59:CreateColorContext,
    ; 60:CreateColorContextFromFilename, 61:CreateColorContextFromWicColorContext,
    ; 62:CreateBitmapFromDxgiSurface, 63:CreateEffect, 64:CreateGradientStopCollection1,
    ; 65:CreateImageBrush, 66:CreateBitmapBrush1, 67:CreateCommandList,
    ; 68:IsDxgiFormatSupported, 69:IsBufferPrecisionSupported,
    ; 70:GetImageLocalBounds, 71:GetImageWorldBounds, 72:GetGlyphRunWorldBounds,
    ; 73:GetDevice, 74:SetTarget, 75:GetTarget, 76:SetRenderingControls,
    ; 77:GetRenderingControls, 78:SetPrimitiveBlend, 79:GetPrimitiveBlend,
    ; 80:SetUnitMode, 81:GetUnitMode, 82:DrawGlyphRun1, 83:DrawImage,
    ; 84:DrawGdiMetafile, 85:DrawBitmap1, 86:PushLayer1

    CreateBitmapFromDxgiSurface(surface, bitmapProperties) {
        ComCall(62, this, 'ptr', surface.ptr, 'ptr', bitmapProperties, 'ptr*', &pBitmap := 0, 'hresult')
        return ID2D1Bitmap1(pBitmap)
    }

    ; ID2D1DeviceContext::CreateEffect(effectId) → ID2D1Effect
    ; vtable index 63
    CreateEffect(clsid) {
        ComCall(63, this, 'ptr', clsid, 'ptr*', &pEffect := 0, 'hresult')
        return ID2D1Effect(pEffect)
    }

    ; ID2D1DeviceContext::CreateCommandList() → ID2D1CommandList
    ; vtable index 67
    CreateCommandList() {
        ComCall(67, this, 'ptr*', &pCL := 0, 'hresult')
        return ID2D1CommandList(pCL)
    }

    ; ID2D1DeviceContext::SetTarget(image)
    ; vtable index 74
    SetTarget(image) => ComCall(74, this, 'ptr', image is Integer ? image : image.ptr, 'int')

    ; ID2D1DeviceContext::GetTarget() → ID2D1Image
    ; vtable index 75
    GetTarget() {
        ComCall(75, this, 'ptr*', &pImage := 0, 'int')
        return pImage ? ID2D1Image(pImage) : 0
    }

    ; ID2D1DeviceContext::DrawImage(image, targetOffset, imageRect, interpolation, composite)
    ; vtable index 83
    ; targetOffset: D2D1_POINT_2F* (or 0 for origin)
    ; imageRect: D2D1_RECT_F* (or 0 for entire image)
    ; interpolation: D2D1_INTERPOLATION_MODE (1=LINEAR default)
    ; composite: D2D1_COMPOSITE_MODE (0=SOURCE_OVER default)
    DrawImage(image, targetOffset := 0, imageRect := 0, interpolation := 1, composite := 0) {
        ComCall(83, this, 'ptr', image is Integer ? image : image.ptr,
            'ptr', targetOffset, 'ptr', imageRect,
            'uint', interpolation, 'uint', composite, 'int')
    }
}

; ========================= ID2D1Bitmap1 =========================
; Extends ID2D1Bitmap (vtable 0-10). We just need to hold and release it.

class ID2D1Bitmap1 extends ID2DBase {
    static IID := '{a898a84c-3873-4588-b08b-ebbf978df041}'
}

; ========================= DXGI Interfaces =========================

class IDXGIDevice extends ID2DBase {
    static IID := '{54ec77fa-1377-44e6-8c32-88fd5f44c84c}'
}

class IDXGIAdapter extends ID2DBase {
    static IID := '{2411e7e1-12ac-4ccf-bd14-9798e8534dc0}'

    ; IDXGIAdapter::GetParent(riid) → IDXGIFactory2
    ; IUnknown(0-2), IDXGIObject::SetPrivateData(3), SetPrivateDataInterface(4),
    ; GetPrivateData(5), GetParent(6)
    GetParent() {
        if DllCall('ole32\CLSIDFromString', 'str', IDXGIFactory2.IID, 'ptr', iid := Buffer(16, 0))
            throw OSError()
        ComCall(6, this, 'ptr', iid, 'ptr*', &pFactory := 0, 'hresult')
        return IDXGIFactory2(pFactory)
    }
}

class IDXGIFactory2 extends ID2DBase {
    static IID := '{50c83a1c-e072-4c48-87b0-3630fa36a6d0}'

    ; IDXGIFactory2::CreateSwapChainForHwnd
    ; IUnknown(0-2), IDXGIObject(3-6), IDXGIFactory(7-11),
    ; IDXGIFactory1(12-13), IDXGIFactory2::IsWindowedStereoEnabled(14),
    ; CreateSwapChainForHwnd(15)
    CreateSwapChainForHwnd(device, hwnd, desc, fullscreenDesc := 0, restrictToOutput := 0) {
        ComCall(15, this, 'ptr', device.ptr, 'ptr', hwnd, 'ptr', desc,
            'ptr', fullscreenDesc, 'ptr', restrictToOutput, 'ptr*', &pSwapChain := 0, 'hresult')
        return IDXGISwapChain1(pSwapChain)
    }
}

class IDXGISwapChain1 extends ID2DBase {
    static IID := '{790a45f7-0d42-4876-983a-0a55cfe6f4aa}'

    ; IDXGISwapChain::GetBuffer(index, riid) → surface
    ; IUnknown(0-2), IDXGIObject(3-6), IDXGIDeviceSubObject::GetDevice(7),
    ; IDXGISwapChain::Present(8), GetBuffer(9)
    GetBuffer(index := 0) {
        if DllCall('ole32\CLSIDFromString', 'str', IDXGISurface.IID, 'ptr', iid := Buffer(16, 0))
            throw OSError()
        ComCall(9, this, 'uint', index, 'ptr', iid, 'ptr*', &pSurface := 0, 'hresult')
        return IDXGISurface(pSurface)
    }

    ; IDXGISwapChain::Present(syncInterval, flags)
    ; vtable index 8
    Present(syncInterval := 0, flags := 0) => ComCall(8, this, 'uint', syncInterval, 'uint', flags, 'hresult')

    ; IDXGISwapChain::ResizeBuffers(bufferCount, width, height, format, flags)
    ; vtable index 13
    ResizeBuffers(bufferCount, width, height, format, flags := 0) {
        return ComCall(13, this, 'uint', bufferCount, 'uint', width, 'uint', height, 'uint', format, 'uint', flags, 'hresult')
    }
}

class IDXGISurface extends ID2DBase {
    static IID := '{cafcb56c-6ac3-4889-bf47-9e23bbd260ec}'
}

; NOTE: ID2D1Image is already defined in Direct2D.ahk (extends ID2D1Resource).
; We reuse that class for effect outputs. No redeclaration needed.

; ========================= ID2D1Effect =========================
; Wraps ID2D1Effect (extends ID2D1Properties : IUnknown).
; Effect graph node — configure properties, connect inputs, get output.
;
; Vtable layout:
;   IUnknown:       0=QI, 1=AddRef, 2=Release
;   ID2D1Properties: 3=GetPropertyCount, 4=GetPropertyName, 5=GetPropertyNameLength,
;     6=GetType, 7=GetPropertyIndex, 8=SetValueByName, 9=SetValue, 10=GetValueByName,
;     11=GetValue, 12=GetValueSize, 13=GetSubProperties
;   ID2D1Effect:    14=SetInput, 15=SetInputCount, 16=GetInput, 17=GetInputCount,
;     18=GetOutput

class ID2D1Effect extends ID2DBase {
    static IID := '{28211a43-7d89-476f-8181-2d6159b220ad}'

    ; SetValue(index, type, data, dataSize) — set a property by index.
    ; For simple types, use the typed helpers below instead.
    SetValue(index, type, data, dataSize) {
        ComCall(9, this, 'uint', index, 'uint', type, 'ptr', data, 'uint', dataSize, 'hresult')
    }

    ; GetValue(index, type, &data, dataSize) — get a property by index.
    GetValue(index, type, data, dataSize) {
        ComCall(11, this, 'uint', index, 'uint', type, 'ptr', data, 'uint', dataSize, 'hresult')
    }

    ; --- Typed property setters (convenience wrappers) ---

    ; Set a FLOAT property (D2D1_PROPERTY_TYPE_FLOAT = 5)
    SetFloat(index, value) {
        static buf := Buffer(4)
        NumPut("float", Float(value), buf)
        this.SetValue(index, 5, buf, 4)
    }

    ; Set a UINT32 property (D2D1_PROPERTY_TYPE_UINT32 = 3)
    SetUInt(index, value) {
        static buf := Buffer(4)
        NumPut("uint", value, buf)
        this.SetValue(index, 3, buf, 4)
    }

    ; Set an ENUM property (D2D1_PROPERTY_TYPE_ENUM = 11)
    SetEnum(index, value) {
        static buf := Buffer(4)
        NumPut("uint", value, buf)
        this.SetValue(index, 11, buf, 4)
    }

    ; Set a BOOL property (D2D1_PROPERTY_TYPE_BOOL = 2)
    SetBool(index, value) {
        static buf := Buffer(4)
        NumPut("uint", value ? 1 : 0, buf)
        this.SetValue(index, 2, buf, 4)
    }

    ; Set a VECTOR2 property (D2D1_PROPERTY_TYPE_VECTOR2 = 6) — e.g., shadow offset
    SetVector2(index, x, y) {
        static buf := Buffer(8)
        NumPut("float", Float(x), "float", Float(y), buf)
        this.SetValue(index, 6, buf, 8)
    }

    ; Set a VECTOR4 property (D2D1_PROPERTY_TYPE_VECTOR4 = 8) — e.g., color
    SetVector4(index, x, y, z, w) {
        static buf := Buffer(16)
        NumPut("float", Float(x), "float", Float(y), "float", Float(z), "float", Float(w), buf)
        this.SetValue(index, 8, buf, 16)
    }

    ; Set a D2D1_COLOR_F from ARGB integer
    SetColorF(index, argb) {
        static buf := Buffer(16)
        NumPut("float", ((argb >> 16) & 0xFF) / 255.0,
               "float", ((argb >> 8) & 0xFF) / 255.0,
               "float", (argb & 0xFF) / 255.0,
               "float", ((argb >> 24) & 0xFF) / 255.0, buf)
        this.SetValue(index, 8, buf, 16)
    }

    ; Set a D2D1_RECT_F property (stored as VECTOR4)
    SetRectF(index, left, top, right, bottom) {
        static buf := Buffer(16)
        NumPut("float", Float(left), "float", Float(top),
               "float", Float(right), "float", Float(bottom), buf)
        this.SetValue(index, 8, buf, 16)
    }

    ; Set a MATRIX_5X4 property (D2D1_PROPERTY_TYPE_MATRIX_5X4 = 17) — e.g., ColorMatrix
    SetMatrix5x4(index, m) {
        ; m is a Buffer(80) containing 20 floats (5 rows × 4 cols)
        this.SetValue(index, 17, m, 80)
    }

    ; SetInput(inputIndex, image, invalidate)
    ; Connects an effect output or bitmap as input to this effect.
    SetInput(inputIndex, image, invalidate := true) {
        ComCall(14, this, 'uint', inputIndex, 'ptr', image is Integer ? image : image.ptr, 'int', invalidate ? 1 : 0, 'int')
    }

    ; GetOutput() → ID2D1Image
    ; Returns this effect's output as an image for chaining or DrawImage.
    GetOutput() {
        ComCall(18, this, 'ptr*', &pImage := 0, 'int')
        return ID2D1Image(pImage)
    }
}

; ========================= ID2D1CommandList =========================
; Records drawing commands for replay. Used as effect input.
; Inherits ID2D1Image (vtable 0-3). Close at index 4.

class ID2D1CommandList extends ID2DBase {
    static IID := '{b4f34a19-2383-4d76-94f6-ec343657c3dc}'

    ; ID2D1CommandList::Close() — finalize the command list.
    ; Must be called before using as effect input.
    Close() => ComCall(4, this, 'hresult')
}
