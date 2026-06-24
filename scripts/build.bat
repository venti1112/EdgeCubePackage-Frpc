@echo off
REM Windows build script for EdgeCubePackage-Frpc
REM This is a convenience wrapper for build.ps1

setlocal

set SCRIPT_DIR=%~dp0
set PS_SCRIPT=%SCRIPT_DIR%build.ps1

REM Pass all arguments to the PowerShell script
powershell -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %*

if %ERRORLEVEL% neq 0 (
    echo.
    echo Build failed with error code %ERRORLEVEL%
    exit /b %ERRORLEVEL%
)

exit /b 0
