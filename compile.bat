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

:: Get script directory (remove trailing backslash if present)
set "BASEDIR=%~dp0"
if "%BASEDIR:~-1%"=="\" set "BASEDIR=%BASEDIR:~0,-1%"

:: Create release directory
if not exist "%BASEDIR%\release" mkdir "%BASEDIR%\release"

:: Set paths
set "SCRIPT_DIR=%BASEDIR%\src"
set "INPUT=%SCRIPT_DIR%\alt_tabby.ahk"
set "OUTPUT=%BASEDIR%\release\AltTabby.exe"

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

:: Kill any running AltTabby processes first
echo Checking for running AltTabby processes...
tasklist /FI "IMAGENAME eq AltTabby.exe" 2>nul | find /I "AltTabby.exe" >nul
if not errorlevel 1 (
    echo Found running AltTabby.exe - attempting to terminate...
    taskkill /IM AltTabby.exe /F >nul 2>&1
    if errorlevel 1 (
        echo WARNING: Could not terminate AltTabby.exe
        echo          Process may be running as Administrator.
        echo          Please close it manually and try again.
        echo.
        pause
        exit /b 1
    ) else (
        echo   - Terminated AltTabby.exe
        :: Give the OS a moment to release file handles
        timeout /t 2 /nobreak >nul
    )
) else (
    echo   - No running AltTabby.exe found
)
echo.

:: Set icon path
set "ICON=%BASEDIR%\img\icon.ico"

:: Compile using v2 base interpreter
:: /base specifies the v2 exe to use as the runtime
:: /icon sets the exe icon
"%AHK2EXE%" /in "%INPUT%" /out "%OUTPUT%" /base "%AHK2BASE%" /icon "%ICON%" /silent verbose

:: Check result
if errorlevel 1 (
    echo.
    echo ERROR: Compilation failed with error code %errorlevel%
    echo.
    echo Try running Ahk2Exe.exe GUI and selecting:
    echo   Source: %INPUT%
    echo   Base File: v2.0.19 U64 AutoHotkey64.exe
    echo.
    pause
    exit /b 1
)

:: Verify output exists
if not exist "%OUTPUT%" (
    echo.
    echo ERROR: Output file not created!
    echo Expected: %OUTPUT%
    echo.
    echo The compilation may have failed silently. Try:
    echo   1. Run Ahk2Exe.exe GUI manually
    echo   2. Select Source: %INPUT%
    echo   3. Select Base File: v2.0.19 U64 AutoHotkey64.exe
    echo.
    pause
    exit /b 1
)

:: Success!
echo.
echo ============================================================
echo SUCCESS! Compiled to: %OUTPUT%
echo ============================================================
echo.

:: Copy config files to release directory (alongside exe)
echo Copying config files...
if exist "%SCRIPT_DIR%\config.ini" (
    copy /Y "%SCRIPT_DIR%\config.ini" "%BASEDIR%\release\config.ini" >nul
    echo   - config.ini copied
) else (
    echo   - config.ini not found (will use defaults)
)

if exist "%SCRIPT_DIR%\shared\blacklist.txt" (
    copy /Y "%SCRIPT_DIR%\shared\blacklist.txt" "%BASEDIR%\release\blacklist.txt" >nul
    echo   - blacklist.txt copied
)

:: Copy img folder for splash screen
if exist "%BASEDIR%\img" (
    if not exist "%BASEDIR%\release\img" mkdir "%BASEDIR%\release\img"
    xcopy /Y /Q "%BASEDIR%\img\*" "%BASEDIR%\release\img\" >nul 2>&1
    echo   - img folder copied
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

pause
