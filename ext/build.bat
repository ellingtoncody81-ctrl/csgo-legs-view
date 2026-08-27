@echo off
rem ============================================================
rem CSGO Legs 注入 DLL + 注入器编译脚本（32 位）
rem 需要 Visual Studio（E:\2）
rem ============================================================
cd /d "%~dp0"

echo [build] 初始化 MSVC 32 位环境...
call "E:\2\VC\Auxiliary\Build\vcvars32.bat" >nul
if errorlevel 1 (
    echo [build] vcvars32 初始化失败
    exit /b 1
)

echo [build] 编译 csgo_legs_ext.dll ...
cl /nologo /O2 /MT /W3 /utf-8 /LD csgo_legs_ext.cpp /Fe:csgo_legs_ext.dll /link /DLL kernel32.lib user32.lib >nul
if errorlevel 1 (
    echo [build] DLL 编译失败
    exit /b 1
)

echo [build] 编译 injector.exe ...
cl /nologo /O2 /MT /W3 /utf-8 injector.cpp /Fe:injector.exe /link kernel32.lib >nul
if errorlevel 1 (
    echo [build] 注入器编译失败
    exit /b 1
)

echo [build] 完成!
echo   注入 DLL:   %~dp0csgo_legs_ext.dll
echo   注入器:     %~dp0injector.exe
echo   用法: 启动游戏后运行 injector.exe csgo_legs_ext.dll
pause
