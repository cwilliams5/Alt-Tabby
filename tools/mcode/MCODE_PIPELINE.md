# MCode Build Pipeline

Embed native C functions as machine code in AHK scripts for performance-critical operations.

## Components

| Component | Location | Role |
|-----------|----------|------|
| **MCodeLoader.ahk** | `src/lib/` | Runtime: loads base64 MCode blobs, resolves imports, named exports |
| **COFFReader.ahk** | `tools/mcode/` | Build-time: parses MSVC `.obj` files, extracts MCode blobs |
| **build_mcode.ps1** | `tools/mcode/` | Build-time: end-to-end C source → paste-ready AHK blob |
| **extract_mcode.ahk** | `tools/mcode/` | Build-time: AHK runner wrapping COFFReader + ExtractMCode |

## Prerequisites

- **MSVC** — Visual Studio Build Tools (or full VS) with C++ workload
- **AutoHotkey v2 x64** — for running the extraction step

## Adding New MCode Functions

### 1. Write C source

```c
/* No CRT dependency. Use __declspec(dllexport) for all functions. */

#ifdef _WIN64
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __declspec(dllexport) __cdecl
#endif

int EXPORT my_function(const unsigned char *data, unsigned int count) {
    /* pure computation — no CRT calls */
    return 0;
}
```

Constraints:
- No CRT functions unless you add the DLL to `-ImportDlls`
- `__declspec(dllexport)` on all functions you want accessible
- `__cdecl` calling convention on x86 (the `EXPORT` macro handles this)

### 2. Compile + extract

```powershell
.\tools\mcode\build_mcode.ps1 -Source path\to\my_func.c
```

This compiles for both x64 and x86, then prints paste-ready base64 blobs.

Compile flags used: `cl /O2 /c /GS- /Zl /nologo`
- `/O2` — optimize for speed
- `/c` — compile only (no link)
- `/GS-` — disable stack buffer security checks (no CRT dependency)
- `/Zl` — omit default library name from .obj
- `/nologo` — suppress banner

### 3. Paste into AHK wrapper

```ahk
#Include MCodeLoader.ahk

class MyNativeFunc {
    static _mc := MyNativeFunc._Init()

    static DoWork(dataBuf, count) {
        return DllCall(this._mc['my_function']
            , "ptr", dataBuf, "uint", count, "cdecl int")
    }

    static _Init() {
        static configs := {
            64: {
                code: "<paste x64 BASE64 blob here>"
            },
            32: {
                code: "<paste x86 BASE64 blob here>"
            },
            export: "my_function"
        }
        return MCodeLoader(configs)
    }
}
```

### 4. Call it

```ahk
result := MyNativeFunc.DoWork(buf.Ptr, buf.Size // 4)
```

## Import Support

When C code calls Windows APIs (e.g., `MessageBoxA`, `VirtualAlloc`):

```powershell
.\tools\mcode\build_mcode.ps1 -Source my_func.c -ImportDlls kernel32,user32
```

MCodeLoader resolves these at load time via `GetProcAddress`. The import info is embedded in the blob by COFFReader.

In the AHK configs, imports appear automatically:

```ahk
64: {
    code: "<blob>",
    import: "kernel32:VirtualAlloc|user32:MessageBoxA"
}
```

## Architecture Support

- Compile for both with `-Arch both` (default)
- Compile for one with `-Arch x64` or `-Arch x86`
- MCodeLoader selects the right blob at runtime based on `A_PtrSize`
- If only one architecture is provided, MCodeLoader throws `ValueError` on mismatch

## Existing MCode in the Project

| Module | Loader | Source | Notes |
|--------|--------|--------|-------|
| **icon_alpha.ahk** | MCodeLoader | `tools/native_benchmark/native_src/icon_alpha.c` | Alpha scan + mask for icons. 32+64 bit. |
| **cjson.ahk** | MCLib (G33kDude) | N/A (pre-built) | Third-party JSON parser. Don't touch. |
| **ShinsOverlayClass.ahk** | Custom GlobalAlloc | N/A (pre-built) | Third-party overlay. Don't touch. |

## Benchmarking

Before embedding new MCode, validate performance gains using `tools/native_benchmark/`:

1. Write an AHK benchmark script comparing native vs AHK implementation
2. Run multiple iterations to get stable measurements
3. Verify correctness (same output as AHK version)

## Troubleshooting

**"Could not find vcvarsall.bat"**
Install Visual Studio Build Tools with "Desktop development with C++" workload.

**"Could not find AutoHotkey64.exe"**
Install AutoHotkey v2 or ensure it's on PATH.

**"unknown import symbol"**
The C code references a Windows API that isn't in the listed import DLLs. Add the DLL with `-ImportDlls`.

**"No matching machine code"**
Running 32-bit AHK but only 64-bit blob provided (or vice versa). Compile for both architectures.

**Wrong results after recompilation**
If you changed the C source and recompiled, make sure to paste the NEW base64 blob. Old blobs with magic offsets won't work if function layout changed — MCodeLoader's named exports handle this automatically.
