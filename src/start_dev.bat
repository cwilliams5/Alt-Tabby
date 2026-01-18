@echo off
setlocal

:: ============================================================
:: Alt-Tabby Development Starter
:: ============================================================
:: Starts the development mode components in sequence:
::   1. Store server (window data provider)
::   2. GUI (Alt-Tab overlay)
::   3. Viewer (debug window list)
::
:: Run from: src/ directory OR release/ directory
:: ============================================================

echo.
echo ============================================================
echo Alt-Tabby Development Starter
echo ============================================================
echo.

:: Find AHK v2 - check PATH first, then standard location
where AutoHotkey64.exe >nul 2>&1
if %ERRORLEVEL%==0 (
    set "AHK=AutoHotkey64.exe"
) else (
    set "AHK=C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"
)

if not exist "%AHK%" (
    echo ERROR: AutoHotkey v2 not found.
    echo Install from: https://www.autohotkey.com/
    pause
    exit /b 1
)

:: Get script directory
set "BASEDIR=%~dp0"
if "%BASEDIR:~-1%"=="\" set "BASEDIR=%BASEDIR:~0,-1%"

:: Determine src directory based on where we're running from
:: If running from src/, BASEDIR is src/
:: If running from release/, need to go up to find src/
if exist "%BASEDIR%\store\store_server.ahk" (
    set "SRCDIR=%BASEDIR%"
) else if exist "%BASEDIR%\..\src\store\store_server.ahk" (
    set "SRCDIR=%BASEDIR%\..\src"
) else (
    echo ERROR: Source files not found.
    echo Run this script from the src/ or release/ directory.
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
