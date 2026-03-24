@echo off
chcp 65001 >nul
echo ============================================
echo   鹅宝 GooseBaby 一键打包工具
echo ============================================
echo.

cd /d e:\baby\GooseBaby

echo [1/3] 清理旧的构建产物...
rmdir /s /q build\windows 2>nul
echo.

echo [2/3] 正在编译 Release 版本（这可能需要几分钟）...
set PUB_HOSTED_URL=https://pub.flutter-io.cn
set FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
call e:\flutter324\flutter\bin\flutter.bat build windows --release
if errorlevel 1 (
    echo.
    echo ❌ 编译失败！请检查错误信息。
    pause
    exit /b 1
)
echo.
echo ✅ 编译成功！
echo.

echo [3/3] 正在生成安装包...
REM 请确保 Inno Setup 已安装，默认路径如下：
set ISCC="C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
if not exist %ISCC% (
    echo ⚠️ 未检测到 Inno Setup，跳过安装包生成。
    echo    请从 https://jrsoftware.org/isinfo.php 下载安装。
    echo.
    echo 📁 Release 文件夹位于：
    echo    e:\baby\GooseBaby\build\windows\x64\runner\Release\
    echo    你可以直接压缩该文件夹分发。
    echo.
    pause
    exit /b 0
)

if not exist dist mkdir dist
%ISCC% installer\goose_baby_setup.iss
if errorlevel 1 (
    echo.
    echo ❌ 安装包生成失败！
    pause
    exit /b 1
)

echo.
echo ============================================
echo ✅ 打包完成！
echo.
echo 📦 安装包位于：e:\baby\GooseBaby\dist\
echo ============================================
echo.
pause
