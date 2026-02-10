;
; icon_alpha.ahk — Native icon alpha scan + mask application (MCode)
;
; Replaces AHK NumGet/NumPut pixel loops with embedded x64 machine code.
; Source: tools/native_benchmark/native_src/icon_alpha.c
; Build:  tools/native_benchmark/native_src/_compile_mcode.ps1
; Extract: tools/native_benchmark/native_src/_extract_mcode.ps1
;
; No imports, no CRT, pure buffer computation. Position-independent.
;
#Requires AutoHotkey v2.0

class IconAlpha {
    static code := IconAlpha._LoadCode()

    ; Offsets into the code buffer for each exported function
    static _offsetApplyMaskOnly := 0
    static _offsetScanOnly := 71
    static _offsetScanAndApplyMask := 177

    /**
     * Scan pixel buffer for any non-zero alpha byte.
     * @param pixelsBuf  Ptr to BGRA pixel buffer
     * @param pixelCount Number of pixels (width * height)
     * @returns {Integer} 1 if alpha found, 0 if all alpha bytes are zero
     */
    static ScanOnly(pixelsBuf, pixelCount) {
        return DllCall(this.code.Ptr + this._offsetScanOnly
            , "ptr", pixelsBuf, "uint", pixelCount, "cdecl int")
    }

    /**
     * Apply mask to pixel buffer without scanning for alpha first.
     * Use after ScanOnly returns 0 to avoid redundant re-scan.
     * @param pixelsBuf  Ptr to BGRA pixel buffer (modified in-place)
     * @param maskBuf    Ptr to BGRA mask buffer
     * @param pixelCount Number of pixels (width * height)
     */
    static ApplyMaskOnly(pixelsBuf, maskBuf, pixelCount) {
        DllCall(this.code.Ptr + this._offsetApplyMaskOnly
            , "ptr", pixelsBuf, "ptr", maskBuf, "uint", pixelCount, "cdecl")
    }

    /**
     * Combined alpha scan + mask application.
     * 1. Scans alpha bytes — if any non-zero, returns 1 (pixels unchanged)
     * 2. If no alpha AND maskBuf != 0, applies mask in-place:
     *    mask black (& 0xFFFFFF == 0) → alpha 255, mask white → alpha 0
     * @param pixelsBuf  Ptr to BGRA pixel buffer (modified in-place if mask applied)
     * @param maskBuf    Ptr to BGRA mask buffer (0 if no mask)
     * @param pixelCount Number of pixels (width * height)
     * @returns {Integer} 1 if original had alpha, 0 if not (mask applied)
     */
    static ScanAndApplyMask(pixelsBuf, maskBuf, pixelCount) {
        return DllCall(this.code.Ptr + this._offsetScanAndApplyMask
            , "ptr", pixelsBuf, "ptr", maskBuf, "uint", pixelCount, "cdecl int")
    }

    /**
     * Decode base64 machine code into an executable buffer.
     * Pattern: base64 → CryptStringToBinary → VirtualProtect(PAGE_EXECUTE_READWRITE)
     */
    static _LoadCode() {
        static b64 := ""
            . "TIvKSIXJdD5IhdJ0OUGD+AFyM0yL0Uwr0kGL0EwryZBB9wQJ////AEmN"
            . "BAl1CIEJAAAA/+sGQsZEEAMASIPBBEiD6gF12sNIhcl0XIXSdFhFM8BI"
            . "jUEDg/oIcjZBuQgAAAAPH0QAAA+2SBwKSBgKSBQKSBAKSAwKSAgKSAQK"
            . "CHUqSIPAIEGDwAhBg8EIRDvKdtVEO8JzEYA4AHUPSIPABEH/wEQ7wnLv"
            . "M8DDuAEAAADDSIlcJAhIi9pMi9FIhckPhK0AAABFhcAPhKQAAABFM8lI"
            . "jUEDQYP4CHIxQbsIAAAAD7ZIHApIGApIFApIEApIDApICApIBAoIdV1I"
            . "g8AgQYPBCEGDwwhFO9h21UU7yHMRgDgAdUJIg8AEQf/BRTvIcu9Ihdt0"
            . "S0WFwHRGSYvSQYvISCvTSSvaZg8fhAAAAAAAQvcEE////wBKjQQTdRRB"
            . "gQoAAAD/6xC4AQAAAEiLXCQIw8ZEEAMASYPCBEiD6QF1z0iLXCQIM8DD"

        ; 378 bytes of x64 machine code (3 functions)
        static codeSize := 378

        if (A_PtrSize != 8)
            throw Error("IconAlpha MCode requires 64-bit AHK")

        code := Buffer(codeSize)
        if !DllCall("Crypt32\CryptStringToBinary", "Str", b64, "UInt", 0, "UInt", 1
                , "Ptr", code, "UInt*", code.Size, "Ptr", 0, "Ptr", 0, "UInt")
            throw Error("IconAlpha: Failed to decode base64 machine code")

        if !DllCall("VirtualProtect", "Ptr", code, "Ptr", code.Size
                , "UInt", 0x40, "UInt*", &old := 0, "UInt")
            throw Error("IconAlpha: Failed to mark code as executable")

        return code
    }
}
