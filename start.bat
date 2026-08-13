@echo off
rem Image Resolution Resizer - Copyright (C) 2026 FANCHUAN
rem Licensed under the GNU General Public License v3.0 or later (see LICENSE).
echo.
echo ==================================================
echo   Image Resolution Resizer  /  Author: FANCHUAN
echo ==================================================
echo.
if "%~1"=="" (
    echo   Double-click without files: opens the full-screen TUI.
    echo   Drag images onto this file: batch converts with defaults.
    echo   TUI shortcuts: A add files, S start, Q quit.
    echo.
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0resize800x600.ps1" %*
echo.
pause
