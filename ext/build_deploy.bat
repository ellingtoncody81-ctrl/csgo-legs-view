@echo off
chcp 65001 >nul
REM 检查游戏是否运行（运行中则 DLL 被锁定无法部署）
tasklist /FI "IMAGENAME eq csgo.exe" 2>nul | find /I "csgo.exe" >nul
if %errorlevel%==0 (
  echo [WARN] csgo.exe 正在运行，DLL 被锁定，无法部署！请先完全退出游戏。
  exit /b 1
)
call E:\2\VC\Auxiliary\Build\vcvars32.bat >nul
cd /d C:\Users\test\Desktop\CSGOBetterBots\csgo_legs_ext
del /Q csgo_legs_ext.obj 2>nul
cl /nologo /O2 /MT /W3 /utf-8 /LD csgo_legs_ext.cpp /Fe:csgo_legs_ext.dll /link /DLL kernel32.lib user32.lib
if errorlevel 1 (
  echo [ERROR] 编译失败
  exit /b 1
)
copy /Y csgo_legs_ext.dll "D:\SteamLibrary\steamapps\common\csgo legacy\csgo_legs_ext.dll" >nul
if errorlevel 1 (
  echo [ERROR] 部署失败
  exit /b 1
)
echo [OK] 编译+部署完成
