#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn VarUnset, Off

; shader_compile_worker.ahk — Batch compile HLSL to DXBC bytecode
;
; Reads a manifest file (one line per shader: hlslPath|outputPath|entryPoint|target)
; For each entry: reads HLSL, calls D3DCompile, writes raw DXBC to outputPath.
; Outputs status lines to stdout. Exits with count of failures.
;
; Usage: AutoHotkey64.exe /ErrorStdOut tools/shader_compile_worker.ahk <manifestPath>

; --- Parse args ---
if (A_Args.Length < 1) {
    FileAppend("ERROR: No manifest path provided`n", "*")
    ExitApp(1)
}
manifestPath := A_Args[1]
if (!FileExist(manifestPath)) {
    FileAppend("ERROR: Manifest not found: " manifestPath "`n", "*")
    ExitApp(1)
}

; --- Load d3dcompiler_47.dll ---
hD3DCompiler := DllCall("LoadLibrary", "str", "d3dcompiler_47", "ptr")
if (!hD3DCompiler) {
    FileAppend("ERROR: Failed to load d3dcompiler_47.dll`n", "*")
    ExitApp(1)
}

; --- Process manifest ---
failures := 0
compiled := 0

Loop Read manifestPath {
    line := Trim(A_LoopReadLine)
    if (line = "" || SubStr(line, 1, 1) = "#")
        continue

    parts := StrSplit(line, "|")
    if (parts.Length < 4) {
        FileAppend("ERROR: Invalid manifest line: " line "`n", "*")
        failures++
        continue
    }

    hlslPath := parts[1]
    outputPath := parts[2]
    entryPoint := parts[3]
    target := parts[4]

    ; Read HLSL source
    if (!FileExist(hlslPath)) {
        FileAppend("FAIL " outputPath ": HLSL not found: " hlslPath "`n", "*")
        failures++
        continue
    }

    hlsl := FileRead(hlslPath, "UTF-8")
    if (hlsl = "") {
        FileAppend("FAIL " outputPath ": empty HLSL: " hlslPath "`n", "*")
        failures++
        continue
    }

    ; Compile
    bytecode := _CompileHLSL(hlsl, entryPoint, target, hlslPath)
    if (!bytecode) {
        failures++
        continue
    }

    ; Write raw DXBC to output
    try {
        ; Ensure output directory exists
        SplitPath(outputPath, , &outDir)
        if (outDir && !DirExist(outDir))
            DirCreate(outDir)

        f := FileOpen(outputPath, "w")
        f.RawWrite(bytecode, bytecode.Size)
        f.Close()
        FileAppend("OK " outputPath " (" bytecode.Size " bytes)`n", "*")
        compiled++
    } catch as e {
        FileAppend("FAIL " outputPath ": write error: " e.Message "`n", "*")
        failures++
    }
}

FileAppend("SUMMARY: " compiled " compiled, " failures " failed`n", "*")
ExitApp(failures)

; --- D3DCompile wrapper ---
_CompileHLSL(hlsl, entryPoint, target, sourceName := "") {
    ; D3DCompile expects UTF-8
    cbNeeded := StrPut(hlsl, "UTF-8")
    srcBuf := Buffer(cbNeeded)
    StrPut(hlsl, srcBuf, "UTF-8")
    srcLen := cbNeeded - 1

    pBlob := 0
    pErrors := 0
    hr := DllCall("d3dcompiler_47\D3DCompile",
        "ptr", srcBuf, "uptr", srcLen,
        "ptr", 0, "ptr", 0, "ptr", 0,
        "astr", entryPoint, "astr", target,
        "uint", 0, "uint", 0,
        "ptr*", &pBlob, "ptr*", &pErrors, "int")

    ; Extract error/warning messages
    errMsg := ""
    if (pErrors) {
        try {
            pErrStr := ComCall(3, pErrors, "ptr")
            errLen := ComCall(4, pErrors, "uptr")
            if (pErrStr && errLen)
                errMsg := StrGet(pErrStr, errLen, "UTF-8")
            ComCall(2, pErrors)  ; Release
        }
    }

    if (hr < 0 || !pBlob) {
        if (errMsg)
            FileAppend("FAIL " sourceName ": " errMsg "`n", "*")
        else
            FileAppend("FAIL " sourceName ": D3DCompile hr=" Format("{:#x}", hr) "`n", "*")
        return 0
    }

    ; Extract bytecode from blob
    pCode := ComCall(3, pBlob, "ptr")
    codeSize := ComCall(4, pBlob, "uptr")
    if (!pCode || !codeSize) {
        ComCall(2, pBlob)
        FileAppend("FAIL " sourceName ": empty bytecode blob`n", "*")
        return 0
    }

    bytecode := Buffer(codeSize)
    DllCall("ntdll\RtlMoveMemory", "ptr", bytecode, "ptr", pCode, "uptr", codeSize)
    ComCall(2, pBlob)  ; Release

    return bytecode
}
