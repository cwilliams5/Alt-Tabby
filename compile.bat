@echo off
setlocal enabledelayedexpansion

:: ============================================================
:: Alt-Tabby Compile Script
:: ============================================================
:: Compiles alt_tabby.ahk to release/AltTabby.exe
:: Usage: compile.bat
:: ============================================================

echo.
echo ============================================================
echo Alt-Tabby Compiler
echo ============================================================
echo.

:: Find Ahk2Exe compiler
set "AHK2EXE=C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe"
set "AHK2BASE=C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"

:: Check if compiler exists
if not exist "%AHK2EXE%" (
    echo ERROR: Ahk2Exe.exe not found at: %AHK2EXE%
    echo Please install AutoHotkey with the compiler component.
    pause
    exit /b 1
)

:: Check if v2 base exists
if not exist "%AHK2BASE%" (
    echo ERROR: AutoHotkey v2 not found at: %AHK2BASE%
    echo Please install AutoHotkey v2.
    pause
    exit /b 1
)

echo Found compiler: %AHK2EXE%
echo Found v2 base:  %AHK2BASE%
echo.

:: Create release directory
if not exist "release" mkdir release

:: Set paths
set "SCRIPT_DIR=%~dp0src"
set "INPUT=%SCRIPT_DIR%\alt_tabby.ahk"
set "OUTPUT=%~dp0release\AltTabby.exe"

:: Check input exists
if not exist "%INPUT%" (
    echo ERROR: Source file not found: %INPUT%
    pause
    exit /b 1
)

echo Compiling: %INPUT%
echo Output:    %OUTPUT%
echo Base:      %AHK2BASE%
echo.

:: Compile using v2 base interpreter
:: /base specifies the v2 exe to use as the runtime
"%AHK2EXE%" /in "%INPUT%" /out "%OUTPUT%" /base "%AHK2BASE%" /silent verbose

if errorlevel 1 (
    echo.
    echo ERROR: Compilation failed!
    echo.
    echo Try running Ahk2Exe.exe GUI and selecting:
    echo   Source: %INPUT%
    echo   Base File: v2.0.19 U64 AutoHotkey64.exe
    echo.
    pause
    exit /b 1
)

:: Verify output
if exist "%OUTPUT%" (
    echo.
    echo ============================================================
    echo SUCCESS! Compiled to: %OUTPUT%
    echo ============================================================
    echo.

    :: Copy config files to release directory (alongside exe)
    echo Copying config files...
    if exist "%SCRIPT_DIR%\config.ini" (
        copy /Y "%SCRIPT_DIR%\config.ini" "%~dp0release\config.ini" >nul
        echo   - config.ini copied
    ) else (
        echo   - config.ini not found (will use defaults)
    )

    if exist "%SCRIPT_DIR%\shared\blacklist.txt" (
        copy /Y "%SCRIPT_DIR%\shared\blacklist.txt" "%~dp0release\blacklist.txt" >nul
        echo   - blacklist.txt copied
    )

    echo.
    echo Usage:
    echo   AltTabby.exe             - Launch GUI + Store
    echo   AltTabby.exe --store     - Store server only
    echo   AltTabby.exe --viewer    - Debug viewer only
    echo   AltTabby.exe --gui-only  - GUI only (store must be running)
    echo.
    echo TIP: Run as Administrator for full functionality
    echo      (required to intercept Alt+Tab in admin windows)
    echo.
) else (
    echo.
    echo ERROR: Output file not created!
    echo.
    echo The compilation may have failed silently. Try:
    echo   1. Run Ahk2Exe.exe GUI manually
    echo   2. Select Source: %INPUT%
    echo   3. Select Base File: v2.0.19 U64 AutoHotkey64.exe
    echo.
    pause
    exit /b 1
)

pause
