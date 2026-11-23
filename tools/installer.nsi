; Windows installer for the release (make installer, after make dist): build/dist/PokemonSword-<ver>-setup.exe.
; Per-user install (no administrator rights): %LOCALAPPDATA%\Programs\Pokemon Sword. The program keeps its game files,
; saves, settings and shader caches in its own folder (runtime/paths.c), so that folder has to be writable - which is
; why it is not Program Files. Installing a new version over an old one keeps all of that; the start screen rebuilds the
; game code by itself when the version changed. Uninstalling removes the program; the game files copied during setup
; are removed only if the player says so, and saves / settings / keys always stay.
;   makensis -DVERSION=.. -DSRC=<abs dist folder> -DICON=<abs icon.ico> -DOUT=<abs setup.exe> tools/installer.nsi (paths
;   absolute: makensis resolves relative ones from this script's folder)

Unicode true
SetCompressor /SOLID lzma
RequestExecutionLevel user
ManifestDPIAware true

!ifndef VERSION
  !error "-DVERSION=<x.y.z>"
!endif
!ifndef SRC
  !error "-DSRC=<the dist folder>"
!endif
!ifndef OUT
  !define OUT "PokemonSword-${VERSION}-setup.exe"
!endif

!define NAME "Pokemon Sword Recomp"
!define EXE "PokemonSword.exe"
!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\PokemonSwordRecomp"

Name "${NAME}"
OutFile "${OUT}"
InstallDir "$LOCALAPPDATA\Programs\Pokemon Sword"
InstallDirRegKey HKCU "${UNINST_KEY}" "InstallLocation"
BrandingText "${NAME} ${VERSION}"

VIProductVersion "${VERSION}.0"
VIAddVersionKey "ProductName" "${NAME}"
VIAddVersionKey "FileDescription" "${NAME} installer"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "LegalCopyright" "MIT licence. Fan project, no game files included."

!include "MUI2.nsh"
!include "FileFunc.nsh"

!ifndef ICON
  !error "-DICON=<icon.ico>"
!endif
!define MUI_ICON "${ICON}"
!define MUI_UNICON "${ICON}"
!define MUI_ABORTWARNING

!define MUI_WELCOMEPAGE_TITLE "${NAME} ${VERSION}"
!define MUI_WELCOMEPAGE_TEXT "A native PC port of Pokemon Sword (Nintendo Switch) made by static recompilation.$\r$\n$\r$\nNO GAME FILES ARE INCLUDED. You need your own copy of the game:$\r$\n  - the game (.xci or .nsp), the 1.3.2 update (.nsp) and optionally the DLC (.nsp), and$\r$\n  - prod.keys dumped from your own Switch,$\r$\nor a folder with the game already extracted (exefs and romfs).$\r$\n$\r$\nAfter installing, open the program and choose those files. It sets the game up once (about 20 to 60 minutes). Keep about 60 GB free for that step; about 20 GB stay used afterwards."
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "${SRC}\LICENSE.txt"
!define MUI_DIRECTORYPAGE_TEXT_TOP "The game files, saves and settings are kept in this folder too, so pick a drive with about 60 GB free. Don't pick a folder inside Program Files (the program must be able to write there)."
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_RUN "$INSTDIR\${EXE}"
!define MUI_FINISHPAGE_RUN_TEXT "Open ${NAME} now"
!define MUI_FINISHPAGE_SHOWREADME "$INSTDIR\README.txt"
!define MUI_FINISHPAGE_SHOWREADME_TEXT "Show the README"
!define MUI_FINISHPAGE_SHOWREADME_NOTCHECKED
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

Function .onVerifyInstDir
  ; (the program refuses to start from a folder it can't write to)
  StrCpy $0 "$INSTDIR" 13
  StrCmp $0 "$PROGRAMFILES" bad
  StrCpy $0 "$INSTDIR" 19
  StrCmp $0 "$PROGRAMFILES64" bad
  Return
  bad:
    Abort
FunctionEnd

Section "Install"
  SetOutPath "$INSTDIR"
  ; a running copy locks the exe: ask to close it instead of failing half way
  retry:
    ClearErrors
    IfFileExists "$INSTDIR\${EXE}" 0 +3
      FileOpen $0 "$INSTDIR\${EXE}" a
      IfErrors locked
      FileClose $0
    Goto go
  locked:
    MessageBox MB_RETRYCANCEL|MB_ICONEXCLAMATION "${NAME} is running. Close it and click Retry." IDRETRY retry
    Abort
  go:
  ; the program files (everything in the release folder); the game data next to them is not touched
  File /r "${SRC}\*.*"

  CreateDirectory "$SMPROGRAMS"
  CreateShortcut "$SMPROGRAMS\${NAME}.lnk" "$INSTDIR\${EXE}" "" "$INSTDIR\${EXE}" 0
  CreateShortcut "$DESKTOP\${NAME}.lnk" "$INSTDIR\${EXE}" "" "$INSTDIR\${EXE}" 0

  WriteUninstaller "$INSTDIR\Uninstall.exe"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayName" "${NAME}"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "${UNINST_KEY}" "Publisher" "Pokemon Sword Recomp (fan project)"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayIcon" "$INSTDIR\${EXE}"
  WriteRegStr HKCU "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINST_KEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKCU "${UNINST_KEY}" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoRepair" 1
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  WriteRegDWORD HKCU "${UNINST_KEY}" "EstimatedSize" $0
SectionEnd

Section "Uninstall"
  ; the program's own files
  RMDir /r "$INSTDIR\lasgen"
  RMDir /r "$INSTDIR\zig"
  RMDir /r "$INSTDIR\gamelib-src"
  Delete "$INSTDIR\*.exe"
  Delete "$INSTDIR\*.dll"
  Delete "$INSTDIR\*.dll.a"
  Delete "$INSTDIR\*.txt"
  Delete "$INSTDIR\*.ttf"
  Delete "$INSTDIR\icon.png"
  Delete "$SMPROGRAMS\${NAME}.lnk"
  Delete "$DESKTOP\${NAME}.lnk"
  DeleteRegKey HKCU "${UNINST_KEY}"

  ; what the setup made (the game's copy, its recompiled code, shader caches): big, and rebuilt from the player's files
  IfSilent keep
  MessageBox MB_YESNO|MB_ICONQUESTION|MB_DEFBUTTON2 "Also delete the game files copied during setup and the shader caches (about 20 GB)?$\r$\n$\r$\nYour saves, settings and keys are kept either way, in:$\r$\n$INSTDIR" IDNO keep
    RMDir /r "$INSTDIR\extracted"
    RMDir /r "$INSTDIR\cache"
    RMDir /r "$INSTDIR\unpack-tmp"
    Delete "$INSTDIR\*.log"
  keep:
  RMDir "$INSTDIR"  ; (only if empty)
SectionEnd
