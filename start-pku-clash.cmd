@echo off
setlocal EnableExtensions

rem One-click startup for PKU VPN + Clash Verge.
rem The Pulse second-factor response must still be entered by the user.

set "ROOT=%~dp0"

rem Optional overrides:
rem   set PKU_CLASH_EXE=D:\Apps\Clash Verge\clash-verge.exe
rem   set PKU_PULSE_EXE=D:\Apps\Pulse Secure\Pulse.exe
set "CLASH="
if defined PKU_CLASH_EXE set "CLASH=%PKU_CLASH_EXE%"
if not defined CLASH if exist "%ROOT%..\Clash Verge\clash-verge.exe" set "CLASH=%ROOT%..\Clash Verge\clash-verge.exe"
if not defined CLASH if exist "%LOCALAPPDATA%\Programs\Clash Verge\clash-verge.exe" set "CLASH=%LOCALAPPDATA%\Programs\Clash Verge\clash-verge.exe"
if not defined CLASH if exist "%ProgramFiles%\Clash Verge\clash-verge.exe" set "CLASH=%ProgramFiles%\Clash Verge\clash-verge.exe"

set "PULSE="
if defined PKU_PULSE_EXE set "PULSE=%PKU_PULSE_EXE%"
if not defined PULSE if exist "%ProgramFiles(x86)%\Common Files\Pulse Secure\JamUI\Pulse.exe" set "PULSE=%ProgramFiles(x86)%\Common Files\Pulse Secure\JamUI\Pulse.exe"
if not defined PULSE if exist "%ProgramFiles%\Common Files\Pulse Secure\JamUI\Pulse.exe" set "PULSE=%ProgramFiles%\Common Files\Pulse Secure\JamUI\Pulse.exe"

echo [PKU-VPN] Starting Clash Verge and the route monitor...

if not defined CLASH (
    echo [ERROR] Clash Verge was not found.
    echo [ERROR] Install it in a standard location or set PKU_CLASH_EXE.
    pause
    exit /b 1
)

if not defined PULSE (
    echo [ERROR] Ivanti Secure Access Client was not found.
    echo [ERROR] Install it in a standard location or set PKU_PULSE_EXE.
    pause
    exit /b 1
)

tasklist /FI "IMAGENAME eq clash-verge.exe" 2>NUL | find /I "clash-verge.exe" >NUL
if errorlevel 1 (
    echo [1/3] Starting Clash Verge...
    start "Clash Verge" "%CLASH%"
) else (
    echo [1/3] Clash Verge is already running.
)

echo [2/3] Starting the administrator route monitor...
start "PKU-VPN route monitor" "%ROOT%watch-admin.cmd"

tasklist /FI "IMAGENAME eq Pulse.exe" 2>NUL | find /I "Pulse.exe" >NUL
if errorlevel 1 (
    echo [3/3] Starting Ivanti Secure Access Client...
    start "Ivanti Secure Access Client" "%PULSE%"
) else (
    echo [3/3] Ivanti Secure Access Client is already running.
)

echo.
echo [READY] 请在 Ivanti 中连接“北大电子资源等（全网）”，并输入二次验证响应。
echo [READY] 连接成功后，监视器会保持 Clash 代理并避免重写 Pulse 路由。
echo.
pause
endlocal
