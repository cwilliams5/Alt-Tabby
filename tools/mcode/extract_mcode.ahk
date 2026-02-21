;
; extract_mcode.ahk — AHK runner for COFFReader + ExtractMCode
;
; Usage:
;   AutoHotkey64.exe extract_mcode.ahk <objPath> [importDlls]
;
; Arguments:
;   objPath     - Path to .obj file compiled by MSVC cl.exe
;   importDlls  - Optional comma-separated list of DLLs for import resolution
;                 e.g. "kernel32,user32"
;
; Output: Prints base64 MCode blob + export info to stdout (consumed by build_mcode.ps1)
;
#Requires AutoHotkey v2.0
#Include COFFReader.ahk

if (A_Args.Length < 1) {
    FileOpen('*', 'w').Write('Usage: extract_mcode.ahk <objPath> [importDlls]`n')
    ExitApp(1)
}

objPath := A_Args[1]
importDlls := A_Args.Length > 1 ? StrSplit(A_Args[2], ",") : []

msvc_obj := COFFReader(objPath)
ExtractMCode(msvc_obj, importDlls)

ExitApp(0)
