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

    SetDpi(dpiX, dpiY) => ComCall(51, this, 'float', dpiX, 'float', dpiY, 'int')

    ; --- ID2D1DeviceContext new methods (index 57+) ---

    ; ID2D1DeviceContext::CreateBitmapFromDxgiSurface(surface, bitmapProperties) → ID2D1Bitmap1
    ; vtable index 62 (57:CreateBitmap, 58:CreateBitmapFromWicBitmap, 59:CreateColorContext,
    ;   60:CreateColorContextFromFilename, 61:CreateColorContextFromWicColorContext, 62:this)
    CreateBitmapFromDxgiSurface(surface, bitmapProperties) {
        ComCall(62, this, 'ptr', surface.ptr, 'ptr', bitmapProperties, 'ptr*', &pBitmap := 0, 'hresult')
        return ID2D1Bitmap1(pBitmap)
    }

    ; ID2D1DeviceContext::SetTarget(image)
    ; vtable index 74 (see d2d1_1.h method order — 17 methods after index 57)
    ; image: ID2D1Image ptr (ID2D1Bitmap1 inherits ID2D1Image). Pass 0 to clear.
    SetTarget(image) => ComCall(74, this, 'ptr', image is Integer ? image : image.ptr, 'int')
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
