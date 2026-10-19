; Inno Setup script — 6 VPN Blocker (Flutter Windows)
; Build first:  flutter build windows --release
; Compile:       "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer_script.iss
;
; Source payload: build\windows\x64\runner\Release\
; Main executable: six_clean_room.exe  (NOT isle.exe — see pubspec name / CMake BINARY_NAME)

#define MyAppName "6 VPN Blocker"
#define MyAppVersion "1.0.0"
#define MyAppVersionFull "1.0.0.148"
#define MyAppPublisher "6 VPN Blocker"
#define MyAppExeName "six_clean_room.exe"
#define MyBuildDir "build\windows\x64\runner\Release"

[Setup]
AppId={{A7B3C9E1-6VPN-BLOCKER-2026-FLUTTER-WIN}}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersionFull}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\Programs\SixVPNBlocker
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
; Flutter bundle: exe + all DLLs + data\ (assets, icudtl.dat, app.so)
OutputDir=installer_output
OutputBaseFilename=6VPN_Blocker_Setup
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
SetupIconFile=assets\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "korean"; MessagesFile: "compiler:Languages\Korean.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: checkedonce

[Files]
; Entire Release folder — .exe, plugin .dll files, data\ subtree
Source: "{#MyBuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; Search-friendly alias (matches existing OS integration)
Source: "{#MyBuildDir}\{#MyAppExeName}"; DestDir: "{app}"; DestName: "6VPNBlocker.exe"; Flags: ignoreversion
; Branded icon for shortcuts / taskbar
Source: "assets\app_icon.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
; Start Menu
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\app_icon.ico"
Name: "{autoprograms}\{#MyAppName} (Search)"; Filename: "{app}\6VPNBlocker.exe"; IconFilename: "{app}\app_icon.ico"
; Desktop (checked by default via [Tasks])
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\app_icon.ico"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}"
