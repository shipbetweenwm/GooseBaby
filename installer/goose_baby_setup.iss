; 鹅宝安装包脚本 — Inno Setup
; 使用方法：先运行 flutter build windows --release，然后用 Inno Setup 编译此脚本

#define MyAppName "鹅宝 GooseBaby"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "GooseBaby"
#define MyAppExeName "goose_baby.exe"
#define BuildDir "..\build\windows\x64\runner\Release"

[Setup]
; 应用基本信息
AppId={{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\GooseBaby
DefaultGroupName={#MyAppName}
; 输出安装包位置和文件名
OutputDir=..\dist
OutputBaseFilename=GooseBaby_v{#MyAppVersion}_Setup
; 安装包压缩方式
Compression=lzma2/ultra64
SolidCompression=yes
; UI 设置
WizardStyle=modern
; 需要管理员权限（安装到 Program Files）
PrivilegesRequired=admin
; 如果不需要管理员权限，改为以下两行：
; PrivilegesRequired=lowest
; DefaultDirName={localappdata}\GooseBaby

; 设置安装包图标（可选，取消注释并指定 ico 文件路径）
; SetupIconFile=..\windows\runner\resources\app_icon.ico

; 允许用户选择是否创建桌面快捷方式
AllowNoIcons=yes

; 卸载时显示的信息
UninstallDisplayName={#MyAppName}

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加选项:"; Flags: checked
Name: "autostart"; Description: "开机自动启动"; GroupDescription: "附加选项:"; Flags: unchecked

[Files]
; 复制整个 Release 目录的所有文件
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
; 开始菜单快捷方式
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\卸载 {#MyAppName}"; Filename: "{uninstallexe}"
; 桌面快捷方式
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Registry]
; 开机自启动（可选）
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; \
  ValueType: string; ValueName: "GooseBaby"; ValueData: """{app}\{#MyAppExeName}"""; \
  Flags: uninsdeletevalue; Tasks: autostart

[Run]
; 安装完成后运行
Filename: "{app}\{#MyAppExeName}"; Description: "立即启动鹅宝"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; 卸载时清理数据目录（可选）
Type: filesandordirs; Name: "{localappdata}\GooseBaby"
