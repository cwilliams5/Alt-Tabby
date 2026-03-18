@echo off
:: Wrapper for tools/compile.ps1 with --profile and --force flags.
powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0tools\compile.ps1" --profile --force %*
exit /b %errorlevel%
