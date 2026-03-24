@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

echo ========================================
echo   鹅宝 GooseBaby 打包脚本
echo ========================================
echo.

:: 设置版本号
set VERSION=1.0.0
set OUTPUT_DIR=dist
set RELEASE_NAME=GooseBaby-v%VERSION%-Windows

:: 创建输出目录
if not exist %OUTPUT_DIR% mkdir %OUTPUT_DIR%

:: 清理旧的打包文件
if exist %OUTPUT_DIR%\%RELEASE_NAME%.zip del /f /q %OUTPUT_DIR%\%RELEASE_NAME%.zip

echo [1/3] 打包 Release 文件...

:: 使用 PowerShell 创建 ZIP（使用绝对路径）
powershell -Command "Compress-Archive -Path 'build\windows\x64\runner\Release\*' -DestinationPath '%OUTPUT_DIR%/%RELEASE_NAME%.zip' -Force"

echo.
echo [2/3] 检查打包结果...
if exist %OUTPUT_DIR%\%RELEASE_NAME%.zip (
    echo ✅ 打包成功！
    echo.
    for %%A in (%OUTPUT_DIR%\%RELEASE_NAME%.zip) do echo 文件大小: %%~zA 字节
    echo 文件位置: %OUTPUT_DIR%\%RELEASE_NAME%.zip
) else (
    echo ❌ 打包失败！
    exit /b 1
)

echo.
echo [3/3] 完成！
echo.
echo 发布步骤:
echo 1. 访问 https://github.com/shipbetweenwm/GooseBaby/releases/new
echo 2. 填写版本标签: v%VERSION%
echo 3. 上传文件: %OUTPUT_DIR%\%RELEASE_NAME%.zip
echo 4. 填写发布说明并发布
echo.

pause
