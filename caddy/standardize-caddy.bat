@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Standardize-Caddy.ps1" %*
set "run_result=%errorlevel%"
if not "%run_result%"=="0" (
  echo.
  echo Failed or SSH disconnected. Review the output.
) else (
  echo.
  echo Completed. Default mode only inspects; use -Apply to migrate.
)
pause
exit /b %run_result%
