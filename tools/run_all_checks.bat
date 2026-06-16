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
echo ----------------------------------------
echo   Lua 5.1 self-test suite (Node)
echo ----------------------------------------
echo.
pushd "%~dp0test"
if not exist node_modules (
    echo Installing test deps ^(first run^)...
    call npm install
)
call npm run all
set SELFTEST_RESULT=%ERRORLEVEL%
popd

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
if %SELFTEST_RESULT% NEQ 0 (
    echo [FAILED] Lua self-test suite - syntax/lint/logic failures above
) else (
    echo [PASSED] Lua self-test suite - syntax, lint and logic tests green
)

echo.
pause
