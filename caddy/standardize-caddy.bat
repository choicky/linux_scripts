@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Standardize-Caddy.ps1" %*
if errorlevel 1 (
  echo.
  echo Failed or SSH disconnected. Review the output.
) else (
  echo.
  echo Completed. Default mode only inspects; use -Apply to migrate.
)
pause
