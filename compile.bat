@echo off
:: Thin wrapper for compile.ps1 — preserves double-click-from-Explorer behavior.
:: All logic lives in compile.ps1. This file just forwards arguments.
powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0compile.ps1" %*
exit /b %errorlevel%
