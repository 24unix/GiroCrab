; Inno Setup script for the GiroCrab Windows installer.
; Built by scripts/package-windows.ps1:
;   iscc /DAppVersion=0.7.5 /DSourceDir=<dir with girocrab.exe, notices, readme> /DOutputDir=<dir> girocrab.iss
#ifndef AppVersion
  #error AppVersion is not defined (pass /DAppVersion=x.y.z)
#endif
#ifndef SourceDir
  #error SourceDir is not defined
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif

[Setup]
; Fixed GUID: lets a newer installer replace an older install instead of installing next to it.
AppId={{6B1D6C7E-3E4B-4C55-9B52-7F0A1D2E9A61}
AppName=GiroCrab
AppVersion={#AppVersion}
AppVerName=GiroCrab {#AppVersion}
AppPublisher=GiroCrab
AppPublisherURL=https://github.com/GiroCrab/GiroCrab
AppSupportURL=https://github.com/GiroCrab/GiroCrab/issues
AppUpdatesURL=https://github.com/GiroCrab/GiroCrab/releases
VersionInfoVersion={#AppVersion}
VersionInfoProductName=GiroCrab
VersionInfoDescription=GiroCrab Setup
DefaultDirName={autopf}\GiroCrab
DefaultGroupName=GiroCrab
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=girocrab-windows-x86_64-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=GiroCrab {#AppVersion}
UninstallDisplayIcon={app}\girocrab.exe
LicenseFile={#SourceDir}\LICENSE

[Languages]
Name: "german"; MessagesFile: "compiler:Languages\German.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\girocrab.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\THIRD_PARTY_NOTICES.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\README-Windows.txt"; DestDir: "{app}"; Flags: ignoreversion isreadme
Source: "{#SourceDir}\LICENSE"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\GiroCrab"; Filename: "{app}\girocrab.exe"
Name: "{group}\{cm:UninstallProgram,GiroCrab}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\GiroCrab"; Filename: "{app}\girocrab.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\girocrab.exe"; Description: "{cm:LaunchProgram,GiroCrab}"; Flags: nowait postinstall skipifsilent

; The vault (%LOCALAPPDATA%\GiroCrab) and its key in the Credential Manager are user data and are
; deliberately NOT removed by the uninstaller.
