@echo off
setlocal

:: ============================================================
:: Alt-Tabby Development Starter
:: ============================================================
:: Starts the development mode components in sequence:
::   1. Store server (window data provider)
::   2. GUI (Alt-Tab overlay)
::   3. Viewer (debug window list)
:: ============================================================

echo.
echo ============================================================
echo Alt-Tabby Development Starter
echo ============================================================
echo.

:: Find AHK v2
set "AHK=C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"
if not exist "%AHK%" (
    echo ERROR: AutoHotkey v2 not found at: %AHK%
    pause
    exit /b 1
)

:: Get script directory and src path
set "BASEDIR=%~dp0"
if "%BASEDIR:~-1%"=="\" set "BASEDIR=%BASEDIR:~0,-1%"
set "SRCDIR=%BASEDIR%\..\src"

:: Verify src directory exists
if not exist "%SRCDIR%\store\store_server.ahk" (
    echo ERROR: Source files not found. Run from /release directory.
    echo Expected: %SRCDIR%\store\store_server.ahk
    pause
    exit /b 1
)

echo Starting Store Server...
start "" "%AHK%" "%SRCDIR%\store\store_server.ahk"
echo   - Waiting for store to initialize...
timeout /t 2 /nobreak >nul

echo Starting GUI...
start "" "%AHK%" "%SRCDIR%\gui\gui_main.ahk"
echo   - Waiting for GUI to initialize...
timeout /t 1 /nobreak >nul

echo Starting Viewer...
start "" "%AHK%" "%SRCDIR%\viewer\viewer.ahk"

echo.
echo ============================================================
echo All components started!
echo ============================================================
echo.
echo Components running:
echo   - Store Server (window data provider)
echo   - GUI (Alt-Tab overlay - try Alt+Tab)
echo   - Viewer (debug window list)
echo.
echo To stop: Close the windows or use Task Manager
echo.
