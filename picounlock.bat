@echo off
if not "%1"=="am_admin" (
    powershell start -verb runas '%0' am_admin
    exit /b
)

:: Set working directory for batch script
cd /d "%~dp0"

:: Strip trailing backslash for Windows Terminal -d flag
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

:: Launch script inside Windows Terminal
wt.exe -d "%SCRIPT_DIR%" powershell.exe -ExecutionPolicy Bypass -File "%~dp0picounlock.ps1"
