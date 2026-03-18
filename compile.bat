@echo off
:: Thin wrapper for tools/compile.ps1 — preserves double-click-from-Explorer behavior.
:: All logic lives in tools/compile.ps1. This file just forwards arguments.
powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0tools\compile.ps1" %*
exit /b %errorlevel%
