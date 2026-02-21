;
; icon_alpha.ahk — Native icon alpha scan + mask application (MCode)
;
; Replaces AHK NumGet/NumPut pixel loops with embedded machine code.
; Source: tools/native_benchmark/native_src/icon_alpha.c
; Build:  tools/mcode/build_mcode.ps1
;
; No imports, no CRT, pure buffer computation. 32+64 bit support.
;
#Requires AutoHotkey v2.0
#Include MCodeLoader.ahk

class IconAlpha {
    static _mc := IconAlpha._Init()

    /**
     * Scan pixel buffer for any non-zero alpha byte.
     * @param pixelsBuf  Ptr to BGRA pixel buffer
     * @param pixelCount Number of pixels (width * height)
     * @returns {Integer} 1 if alpha found, 0 if all alpha bytes are zero
     */
    static ScanOnly(pixelsBuf, pixelCount) {
        return DllCall(this._mc['icon_scan_alpha_only']
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
        DllCall(this._mc['icon_apply_mask_only']
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
        return DllCall(this._mc['icon_scan_and_apply_mask']
            , "ptr", pixelsBuf, "ptr", maskBuf, "uint", pixelCount, "cdecl int")
    }

    static _Init() {
        static configs := {
            64: "TIvKSIXJdD5IhdJ0OUGD+AFyM0yL0Uwr0kGL0EwryZBB9wQJ////AEmNBAl1CIEJAAAA/+sGQsZEEAMASIPBBEiD6gF12sPMzMzMzMzMzMxIhcl0XIXSdFhFM8BIjUEDg/oIcjZBuQgAAAAPH0QAAA+2SBwKSBgKSBQKSBAKSAwKSAgKSAQKCHUqSIPAIEGDwAhBg8EIRDvKdtVEO8JzEYA4AHUPSIPABEH/wEQ7wnLvM8DDuAEAAADDzMzMzMzMSIlcJAhIi9pMi9FIhckPhK0AAABFhcAPhKQAAABFM8lIjUEDQYP4CHIxQbsIAAAAD7ZIHApIGApIFApIEApIDApICApIBAoIdV1Ig8AgQYPBCEGDwwhFO9h21UU7yHMRgDgAdUJIg8AEQf/BRTvIcu9Ihdt0S0WFwHRGSYvSQYvISCvTSSvaZg8fhAAAAAAAQvcEE////wBKjQQTdRRBgQoAAAD/6xC4AQAAAEiLXCQIw8ZEEAMASYPCBEiD6QF1z0iLXCQIM8DDAABQAMCAAw==",
            32: "i0QkBIXAdDWLVCQIhdJ0LYtMJAyFyXQlK9BmDx9EAAD3BAL///8AdQiBCAAAAP/rBMZAAwCDwASD6QF148PMzItEJARWV4XAdFOLfCQQhf90S4PAAzPSg/8IciqNcgiQikgcCkgYCkgUCkgQCkgMCkgICkgECgh1KYPGCIPAIIPCCDv3dto713MTZg8fRAAAgDgAdQ1Cg8AEO9dy818zwF7DX7gBAAAAXsPMzMzMzMyLVCQEU1ZXhdIPhJcAAACLdCQYhfYPhIsAAAAz/41CA4P+CHIxjV8IDx+EAAAAAACKSBwKSBgKSBQKSBAKSAwKSAgKSAQKCHVIg8MIg8Agg8cIO9522jv+cxNmDx9EAACAOAB1LEeDwAQ7/nLzi0QkFIXAdDGF9nQtK8IPH0QAAPcEEP///wB1EYEKAAAA/+sNX164AQAAAFvDxkIDAIPCBIPuAXXaX14zwFvDAABAALCAAw==",
            export: "icon_scan_and_apply_mask,icon_apply_mask_only,icon_scan_alpha_only"
        }
        return MCodeLoader(configs)
    }
}
