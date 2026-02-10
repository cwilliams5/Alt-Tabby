@echo off
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat" x64 >nul 2>&1
cd /d "%~dp0"
echo Compiling icon_alpha.c to minimal .obj ...
cl /O2 /c /GS- /Zl /nologo icon_alpha.c /Fo:icon_alpha_mcode.obj
if errorlevel 1 (
    echo FAILED
    exit /b 1
)
echo SUCCESS
dumpbin /disasm icon_alpha_mcode.obj
