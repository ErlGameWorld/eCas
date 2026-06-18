@echo off
setlocal
setlocal EnableDelayedExpansion

set "ROOT=%~dp0"
set "USER_ARGS=%*"
cd /d "%ROOT%"

where erl >nul 2>&1
if errorlevel 1 (
    echo [ERROR] erl.exe not found in PATH.
    exit /b 1
)

where rebar3 >nul 2>&1
if errorlevel 1 (
    echo [ERROR] rebar3 not found in PATH.
    exit /b 1
)

echo [1/3] Compiling project modules...
call rebar3 compile
if errorlevel 1 goto compile_error

echo [2/3] Compiling test profile modules...
call rebar3 as test compile
if errorlevel 1 goto compile_error

echo [3/3] Starting Erlang shell with src and test code paths...
echo.
echo Available examples after startup:
echo   field_diff_bench:run().                 # baseline + actual eCas diffDirtyMask
echo   field_diff_bench:run_ecas().            # actual eCas diffDirtyMask only
echo   field_diff_bench:run(#{iterations => 100000, change_count => 4}).
echo   field_diff_bench:run(#{sizes => [32,64,128], iterations => 50000}).
echo   eCas_bench:run().
echo   eCas_bench:run(#{iterations => 1000, flush_rows => 500}).
echo   tcCas:tcall(false).                     # txn lock perf: 2~128 keys, 2~512 procs
echo   tcCas:tlock().                          # single-process lock sweep
echo   tcCas:tlock(256).                        # 256-process concurrency
echo   eCas:start().
echo.

set "ERL_PA_ARGS="
for /d %%D in ("%ROOT%_build\default\lib\*") do (
    if exist "%%~fD\ebin" (
        set "ERL_PA_ARGS=!ERL_PA_ARGS! -pa ""%%~fD\ebin"""
    )
)
for /d %%D in ("%ROOT%_build\test\lib\*") do (
    if exist "%%~fD\ebin" (
        set "ERL_PA_ARGS=!ERL_PA_ARGS! -pa ""%%~fD\ebin"""
    )
)
if exist "%ROOT%_build\test\lib\eCas\test" (
    set "ERL_PA_ARGS=!ERL_PA_ARGS! -pa ""%ROOT%_build\test\lib\eCas\test"""
)
if exist "%ROOT%test" (
    set "ERL_PA_ARGS=!ERL_PA_ARGS! -pa ""%ROOT%test"""
)

call erl !ERL_PA_ARGS! !USER_ARGS!
set "ERL_EXIT=%ERRORLEVEL%"
exit /b %ERL_EXIT%

:compile_error
echo [ERROR] Compile failed. Shell not started.
exit /b 1
