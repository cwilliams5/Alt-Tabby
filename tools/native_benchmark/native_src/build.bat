@echo off
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat" x64 >nul 2>&1
cd /d "%~dp0"
echo Compiling icon_alpha.c ...
cl /O2 /LD /nologo icon_alpha.c /Fe:icon_alpha.dll
if errorlevel 1 (
    echo FAILED
    exit /b 1
)
echo SUCCESS
dir icon_alpha.dll
