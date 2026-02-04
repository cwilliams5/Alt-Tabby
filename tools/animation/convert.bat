@echo off
setlocal

REM ============================================================
REM Animation Conversion Pipeline
REM Usage: convert.bat [input.mp4]
REM
REM Runs full pipeline:
REM   1. Extract frames from video
REM   2. Add transparency (flood fill + defringe)
REM   3. Generate GIF
REM   4. Generate WebP
REM ============================================================

set INPUT=%~1
if "%INPUT%"=="" set INPUT=boot5.mp4

echo.
echo ============================================================
echo Animation Pipeline
echo ============================================================
echo Input: %INPUT%
echo.

echo === Step 1: Extracting frames ===
python "%~dp0extract_frames.py" "%~dp0%INPUT%"
if errorlevel 1 (
    echo ERROR: Frame extraction failed
    pause
    exit /b 1
)

echo.
echo === Step 2: Adding transparency ===
python "%~dp0add_transparency.py" "%~dp0frames" --flood
if errorlevel 1 (
    echo ERROR: Transparency processing failed
    pause
    exit /b 1
)

echo.
echo === Step 3: Creating GIF ===
python "%~dp0make_gif.py"
if errorlevel 1 (
    echo ERROR: GIF creation failed
    pause
    exit /b 1
)

echo.
echo === Step 4: Creating WebP ===
python "%~dp0make_webp.py"
if errorlevel 1 (
    echo ERROR: WebP creation failed
    pause
    exit /b 1
)

echo.
echo ============================================================
echo Done!
echo ============================================================
echo Frames: %~dp0frames\
echo GIF:    %~dp0animation.gif
echo WebP:   %~dp0animation.webp
echo.
echo Test scripts:
echo   test_animation.ahk     - PNG frames
echo   test_animation_gif.ahk - GIF
echo   test_webp_dll.ahk      - WebP (with fade in/out)
echo.
pause
