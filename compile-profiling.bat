@echo off
:: Wrapper for compile.ps1 with --profile and --force flags.
powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0compile.ps1" --profile --force %*
exit /b %errorlevel%
