@echo off
rem Start this before connecting the PKU VPN; it prepares routes and then
rem avoids rewriting them after the Pulse virtual adapter is up.
rem A UAC prompt will appear; accept it.
setlocal
set "SCRIPT=%~dp0pku-clash.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath 'powershell' -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','%SCRIPT%','-Action','watch'"
endlocal
