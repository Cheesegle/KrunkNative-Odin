@echo off
rem Build helper for Windows (requires Odin compiler in PATH).
rem
rem Usage:
rem   build.bat client            build the client      -> bin\krodin_client.exe
rem   build.bat dev               developer client with debug tools (F3 window)
rem                                                     -> bin\krodin_client_dev.exe
rem                               never packaged; package-windows.ps1 uses krodin_client.exe
rem   build.bat browser           build browser helper and restore WebView2 loader
rem   build.bat inspect           build standalone WebView2 inspector
rem   build.bat server            build the server      -> bin\krodin_server.exe
rem   build.bat tests             build + run the sim tests
rem   build.bat check             typecheck client + server without linking
rem   build.bat all               build client + server
rem   build.bat clean             remove built binaries
rem   build.bat (no args)         same as "all"
rem   build.bat client speed      build the client with -o:speed
rem   build.bat tests none        build and run tests with -o:none
rem   build.bat all speed minimal build client/server with separate levels
rem Optimization levels: none, minimal, size, speed, aggressive (default).

setlocal
set "BIN_DIR=bin"
set "ODIN=odin"
set "TARGET=%~1"
set "PROFILE=%~2"
set "SERVER_PROFILE=%~3"

if "%TARGET%"=="" set "TARGET=all"
if "%PROFILE%"=="" set "PROFILE=aggressive"
if "%SERVER_PROFILE%"=="" set "SERVER_PROFILE=%PROFILE%"

if /i "%TARGET%"=="help" goto usage
set "VALID_TARGET="
for %%T in (client dev browser inspect server tests check all clean) do if /i "%TARGET%"=="%%T" (
    set "TARGET=%%T"
    set "VALID_TARGET=1"
)
if not defined VALID_TARGET goto bad_arguments
if not "%~4"=="" goto bad_arguments
if not "%TARGET%"=="all" if not "%~3"=="" goto bad_arguments
if "%TARGET%"=="check" if not "%~2"=="" goto bad_arguments
if "%TARGET%"=="clean" if not "%~2"=="" goto bad_arguments

call :validate_profile "%PROFILE%"
if errorlevel 1 exit /b 1
if "%TARGET%"=="all" call :validate_profile "%SERVER_PROFILE%"
if errorlevel 1 exit /b 1

where %ODIN% >nul 2>nul
if errorlevel 1 (
    echo Error: Odin compiler not found in PATH. Install it from https://odin-lang.org
    exit /b 1
)

if not exist "%BIN_DIR%" mkdir "%BIN_DIR%"

rem The client names the commit it was built from when its shaders do not
rem match assets/shaders (src/client/build_stamp.odin). Without git it is 0.
set "COMMIT_DEFINE="
for /f "delims=" %%C in ('git rev-parse --short^=7 HEAD 2^>nul') do set "COMMIT_DEFINE=-define:KRODIN_COMMIT=0x%%C"

goto:%TARGET%

:browser
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\setup-webview2.ps1
if errorlevel 1 exit /b %errorlevel%
%ODIN% build src/browser_helper -out:%BIN_DIR%\krodin_browser.exe -o:%PROFILE% -subsystem:windows
exit /b %errorlevel%

:client
call :browser
if errorlevel 1 exit /b %errorlevel%
%ODIN% build src/client -out:%BIN_DIR%\krodin_client.exe -o:%PROFILE% %COMMIT_DEFINE%
exit /b %errorlevel%

:dev
rem Developer build: compiles in the debug tools (KRODIN_DEV). It uses its own
rem file name so it can never be packaged or mistaken for a tester build.
call :browser
if errorlevel 1 exit /b %errorlevel%
%ODIN% build src/client -out:%BIN_DIR%\krodin_client_dev.exe -o:%PROFILE% -define:KRODIN_DEV=true %COMMIT_DEFINE%
exit /b %errorlevel%

:inspect
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\setup-webview2.ps1
if errorlevel 1 exit /b %errorlevel%
%ODIN% build tools/browser_inspect -out:%BIN_DIR%\krodin_browser_inspect.exe -o:%PROFILE% -subsystem:windows
exit /b %errorlevel%

:server
%ODIN% build src/server -out:%BIN_DIR%\krodin_server.exe -o:%PROFILE%
exit /b %errorlevel%

:tests
%ODIN% build src/tests -out:%BIN_DIR%\krodin_tests.exe -o:%PROFILE%
if errorlevel 1 exit /b %errorlevel%
"%BIN_DIR%\krodin_tests.exe"
if errorlevel 1 exit /b %errorlevel%
%ODIN% test src/browser_access -out:%BIN_DIR%\browser_access_tests.exe -o:none
exit /b %errorlevel%

:check
%ODIN% check tools/browser_inspect
if errorlevel 1 exit /b %errorlevel%
%ODIN% check src/browser_helper
if errorlevel 1 exit /b %errorlevel%
%ODIN% check src/client %COMMIT_DEFINE%
if errorlevel 1 exit /b %errorlevel%
%ODIN% check src/client -define:KRODIN_DEV=true
if errorlevel 1 exit /b %errorlevel%
%ODIN% check src/server
exit /b %errorlevel%

:all
call :client
if errorlevel 1 exit /b %errorlevel%
set "PROFILE=%SERVER_PROFILE%"
call :server
exit /b %errorlevel%

:clean
if exist "%BIN_DIR%\krodin_browser_inspect.exe" del "%BIN_DIR%\krodin_browser_inspect.exe"
if exist "%BIN_DIR%\krodin_browser.exe" del "%BIN_DIR%\krodin_browser.exe"
if exist "%BIN_DIR%\WebView2Loader.dll" del "%BIN_DIR%\WebView2Loader.dll"
if exist "%BIN_DIR%\WebView2-LICENSE.txt" del "%BIN_DIR%\WebView2-LICENSE.txt"
if exist "%BIN_DIR%\WebView2-NOTICE.txt" del "%BIN_DIR%\WebView2-NOTICE.txt"
if exist "%BIN_DIR%\krodin_client.exe" del "%BIN_DIR%\krodin_client.exe"
if exist "%BIN_DIR%\krodin_client_dev.exe" del "%BIN_DIR%\krodin_client_dev.exe"
if exist "%BIN_DIR%\krodin_server.exe" del "%BIN_DIR%\krodin_server.exe"
if exist "%BIN_DIR%\krodin_tests.exe" del "%BIN_DIR%\krodin_tests.exe"
echo Cleaned %BIN_DIR%\
exit /b 0

:validate_profile
for %%P in (none minimal size speed aggressive) do if "%~1"=="%%P" exit /b 0
echo Error: Unknown optimization level "%~1".
echo Levels: none, minimal, size, speed, aggressive.
exit /b 1

:bad_arguments
echo Error: Invalid target or arguments.
call :usage
exit /b 1

:usage
echo Usage: build.bat [client ^| dev ^| browser ^| inspect ^| server ^| tests] [level]
echo        build.bat all [client-level] [server-level]
echo        build.bat [check ^| clean ^| help]
echo Levels: none, minimal, size, speed, aggressive ^(default^).
echo With all, the server level defaults to the client level.
exit /b 0
