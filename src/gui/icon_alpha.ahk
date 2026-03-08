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
#Include %A_LineFile%\..\..\lib\MCodeLoader.ahk

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
     * Premultiply BGRA pixel data in-place for D2D (expects premultiplied alpha).
     * alpha=0 → zero all channels, alpha=255 → skip, else → B,G,R *= alpha/255
     * @param pixelsBuf  Ptr to BGRA pixel buffer (modified in-place)
     * @param pixelCount Number of pixels (width * height)
     */
    static PremultiplyAlpha(pixelsBuf, pixelCount) {
        DllCall(this._mc['icon_premultiply_alpha']
            , "ptr", pixelsBuf, "uint", pixelCount, "cdecl")
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
    ; lint-ignore: dead-function
    static ScanAndApplyMask(pixelsBuf, maskBuf, pixelCount) {
        return DllCall(this._mc['icon_scan_and_apply_mask']
            , "ptr", pixelsBuf, "ptr", maskBuf, "uint", pixelCount, "cdecl int")
    }

    static _Init() {
        static configs := {
            64: "262,CbIATIvKSIXJdD4ASIXSdDlBg/gAAXIzTIvRTCsA0kGL0EwryZAAQfcECf///wAASY0ECXUIgQkAAAAA/+sGQsYARBADAEiDwQQASIPqAXXaw8xhBQBIg+wIAIAApg8EhK4AWIP6AQ+CAqUAEEiJXCQQSACJPCQz/4vaZhBmDx+EACgAAEUAixpBi8vB6RgAhcl1BUGJOusQZYH5/wAXc11BAIvDwegQD7bQALiBgICAD6/RAPfii8HB4AhEAIvKQcHpB0QLgsgCIQhED7bAAiIIQcHhAAyvwUH3EuACD8HqACTKQQ9MttMAPAEc9+IDEkUgiQpJg8IAuusBCA+Fe4BuSIs8JMRIi4FPg8QIh2WCZwUAjlyAjVhFM8BIAH1BA4P6CHI2iEG5CABRDx9EAAIAtkgcCkgYCkgAFApIEApIDAoASAgKSAQKCHUAKkiDwCBBg8AACEGDwQhEO8oAdtVEO8JzEYAQOAB1DwANBEH/AsAACHLvM8DDuA4BgCYEOwGTCEiL2gWFoa2BkYXAD4SkGQEEM8mBQQDTCHIxrEG7AkKVP12DP8GAPwDDCEU72HbVRVQ7yIM/QoM/wQAIckDvSIXbdEtAGHQIRkmLAH3ISCvTCEkr2sZnQvcEEwHBf0qNBBN1FEE0gQoCgBCCLIFMCMPDgoLDU+kBdc8CBQA1AAAAIIFQAJCBAAQ=",
            32: "205,yLEAi0QkBIXAdDUAi1QkCIXSdC0Ai0wkDIXJdCUAK9BmDx9EAAAA9wQC////AHUACIEIAAAA/+sABMZAAwCDwAQAg+kBdePDzMwIVot0AHD2D4SMAQA8VYtsJBCF7QgPhH4AGFMz24UA7XR2V4sEnosAyMHpGIXJdQUAiQye616B+f8BADxzVsHoEA+2ANC4gYCAgA+vANH34ovBi/rBgOAIwe8HC/gANEDB6AgPtvAEHvEgwecI9+YAaxTB8OoHC/oADQAhCj0CFwCJPJ5DO91yjHBfW11eAJwAAAHfViJXAOFTi3wAm/90AEuDwAMz0oP/AAhyKo1eCJCKAEgcCkgYCkgUAApIEApIDApIAAgKSAQKCHUpAIPGCIPAIIPCAAg793baO9dzAhODh4A4AHUNQgEAgDvXcvNfM8BgXsNfuAEAZwQ3zAmAowRTADjSD4SXKwALgFgYgY6LgAUz/wCNQgOD/ghyMUCNXwgPH4QACQAiAJU/SIPDgj/HCJQ73oA//ok/LEeBPyj+cvMAbhQAbTGFoPZ0LSvChNcQgteIEYEKgtcNX16CTxBbw8ZCANzCBIMA7gF12l9eM8AAW8MAAOCAQAAAUIEE",
            export: "icon_scan_and_apply_mask,icon_apply_mask_only,icon_premultiply_alpha,icon_scan_alpha_only"
        }
        return MCodeLoader(configs)
    }
}
