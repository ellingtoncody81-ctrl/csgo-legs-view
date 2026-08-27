@echo off
cd /d "%~dp0"
echo ============================================
echo   CSGO Legs Injector - Hide Hands/Head
echo ============================================
echo Injecting csgo_legs_ext.dll into csgo.exe ...
injector.exe csgo_legs_ext.dll
echo.
echo After injection:
echo   1. In game: sm_legs to enable legs view
echo   2. sm_legs_dbg to check DLL status (ready=1 = active)
echo   3. State file: migi\csgo\legs_ext_state.txt
echo.
pause
