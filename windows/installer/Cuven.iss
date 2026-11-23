; Cuven for Windows 的安装程序（Inno Setup 6）
;   iscc /DAppVersion=1.0.0 /DSourceDir=<dotnet publish 的输出> /DOutDir=<放安装程序的目录> Cuven.iss
; 装在当前用户下（%LOCALAPPDATA%\Programs\Cuven），不要管理员权限；卸载留着片库缓存和下载（在 %LOCALAPPDATA%\Cuven）
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\out\Cuven"
#endif
#ifndef OutDir
  #define OutDir "..\.."
#endif

[Setup]
AppId={{8F2A6C4E-3B1D-4E7A-9C5F-2D8E1A7B6C30}
AppName=Cuven
AppVersion={#AppVersion}
AppVerName=Cuven {#AppVersion}
AppPublisher=Cuven
DefaultDirName={localappdata}\Programs\Cuven
DefaultGroupName=Cuven
DisableProgramGroupPage=yes
DisableDirPage=auto
PrivilegesRequired=lowest
OutputDir={#OutDir}
OutputBaseFilename=Cuven-Setup-x64
Compression=lzma2/ultra64
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.19041
WizardStyle=modern
SetupIconFile=..\src\Cuven.App\Assets\cuven.ico
UninstallDisplayIcon={app}\Cuven.exe
UninstallDisplayName=Cuven
CloseApplications=yes

[Languages]
#if FileExists(CompilerPath + "Languages\ChineseSimplified.isl")
Name: "chs"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
#elif FileExists(CompilerPath + "Languages\Unofficial\ChineseSimplified.isl")
Name: "chs"; MessagesFile: "compiler:Languages\Unofficial\ChineseSimplified.isl"
#else
Name: "en"; MessagesFile: "compiler:Default.isl"
#endif

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[InstallDelete]
; 升级时清掉旧版本留下的文件（运行库换了版本，文件名会变）
Type: filesandordirs; Name: "{app}\*"

[Icons]
Name: "{autoprograms}\Cuven"; Filename: "{app}\Cuven.exe"
Name: "{autodesktop}\Cuven"; Filename: "{app}\Cuven.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\Cuven.exe"; Description: "{cm:LaunchProgram,Cuven}"; Flags: nowait postinstall skipifsilent
