@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo ============================================
echo   CSGO Legs 自动注入守护器 (常驻后台)
echo ============================================
echo  效果: 之后无论从 Steam 还是快捷方式启动 csgo.exe,
echo        都会在 client.dll 加载后自动注入看腿 DLL。
echo  用法: 窗口会最小化到任务栏, 放着别管即可。
echo        关闭窗口 = 停止守护 (不影响游戏)。
echo.
echo 正在启动守护器...
start "" /min cmd /c "cd /d ""%~dp0"" && auto_injector.exe csgo_legs_ext.dll csgo.exe 300 1"
echo 守护器已启动。
echo   - 游戏内: sm_legs 开启看腿
echo   - 查看日志: 点击任务栏窗口看输出
echo.
pause
