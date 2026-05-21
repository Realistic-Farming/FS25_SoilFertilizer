@echo off
REM ================================================================
REM FS25_SoilFertilizer Validation Suite
REM Run this before testing in-game or releasing
REM ================================================================

echo.
echo ========================================
echo   FS25_SoilFertilizer Validation Suite
echo ========================================
echo.

cd /d "%~dp0"

echo Running static analysis...
echo.
powershell -ExecutionPolicy Bypass -File validate_mod.ps1
set VALIDATE_RESULT=%ERRORLEVEL%

echo.
echo ========================================
echo.
echo To analyze game logs after testing, run:
echo   powershell -ExecutionPolicy Bypass -File extract_log_errors.ps1
echo.
echo ========================================
echo.

REM Summarize
if %VALIDATE_RESULT% NEQ 0 (
    echo [REVIEW] Static analysis found issues to review
) else (
    echo [PASSED] Static analysis - no errors found
)

echo.
pause
