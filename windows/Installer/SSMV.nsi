; -*- coding: utf-8 -*-
; Compile through scripts/build-installer.ps1. Payload lists are generated from staging.
Unicode true
RequestExecutionLevel user
ManifestSupportedOS Win10
ManifestDPIAware true
!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "WinVer.nsh"
!include "${INSTALL_FILES}"
!include "${UNINSTALL_FILES}"

!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\SSMV"
!define CAPABILITIES "Software\SSMV\Capabilities"
!define OPEN_COMMAND '$\"$INSTDIR\SSMV.exe$\" $\"%1$\"'
Var FailureStage
Name "So Simple Markdown Viewer"
OutFile "${OUTPUT_FILE}"
InstallDir "$LOCALAPPDATA\Programs\SSMV"
BrandingText "SSMV"
SetCompressor /SOLID lzma
VIProductVersion "${PRODUCT_VERSION}"
VIAddVersionKey /LANG=1033 "ProductName" "So Simple Markdown Viewer"
VIAddVersionKey /LANG=1033 "FileDescription" "SSMV ${ARCH} installer"
VIAddVersionKey /LANG=1033 "FileVersion" "${PRODUCT_VERSION}"
VIAddVersionKey /LANG=1033 "ProductVersion" "${BUILD_LABEL}"
VIAddVersionKey /LANG=1033 "LegalCopyright" "SSMV contributors"
!define MUI_ICON "..\Assets\AppIcon.ico"
!define MUI_UNICON "..\Assets\AppIcon.ico"
!define MUI_ABORTWARNING
!insertmacro MUI_PAGE_LICENSE "${PAYLOAD_DIR}\LICENSE"
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_UNPAGE_FINISH
!insertmacro MUI_LANGUAGE "English"
!insertmacro MUI_LANGUAGE "Korean"

LangString CloseApp ${LANG_ENGLISH} "Close SSMV before installing or uninstalling it, then try again."
LangString CloseApp ${LANG_KOREAN} "SSMV를 종료한 뒤 설치 또는 제거를 다시 실행해 주세요."
LangString Unsupported ${LANG_ENGLISH} "This installer requires Windows 10 version 2004 or later on ${ARCH}. Download the installer for your PC's architecture."
LangString Unsupported ${LANG_KOREAN} "이 설치 파일은 ${ARCH}용 Windows 10 버전 2004 이상에서 사용할 수 있습니다. PC 아키텍처에 맞는 설치 파일을 다운로드해 주세요."
LangString UnknownInstall ${LANG_ENGLISH} "The SSMV installation folder does not match a registered SSMV installation. Move the existing folder or reinstall from its original installer before trying again."
LangString UnknownInstall ${LANG_KOREAN} "SSMV 설치 폴더가 등록된 설치 정보와 일치하지 않습니다. 기존 폴더를 옮기거나 원래 설치 파일로 다시 설치한 뒤 실행해 주세요."
LangString UpgradeFailed ${LANG_ENGLISH} "The previous SSMV installation could not be removed. No new files were installed."
LangString UpgradeFailed ${LANG_KOREAN} "이전 SSMV 설치를 제거하지 못했습니다. 새 파일은 설치하지 않았습니다."
LangString InstallFailed ${LANG_ENGLISH} "SSMV could not be installed completely. Check available disk space and folder permissions, then run the installer again."
LangString InstallFailed ${LANG_KOREAN} "SSMV 설치를 완료하지 못했습니다. 디스크 여유 공간과 폴더 권한을 확인한 뒤 설치 파일을 다시 실행해 주세요."
LangString UninstallFailed ${LANG_ENGLISH} "Some SSMV files could not be removed. Close applications using the installation folder and run the uninstaller again."
LangString UninstallFailed ${LANG_KOREAN} "일부 SSMV 파일을 제거하지 못했습니다. 설치 폴더를 사용 중인 프로그램을 종료한 뒤 제거를 다시 실행해 주세요."

; Opening an executable for exclusive write fails while Windows maps it into a process.
; Do not terminate processes or schedule replacement/removal at reboot.
!macro CheckApplication PREFIX
Function ${PREFIX}CheckApplication
  IfFileExists "$INSTDIR\SSMV.exe" 0 done
  System::Call 'kernel32::CreateFileW(w "$INSTDIR\SSMV.exe", i 0x40000000, i 0, p 0, i 3, i 0, p 0) p.r0'
  ${If} $0 = -1
    MessageBox MB_OK|MB_ICONEXCLAMATION "$(CloseApp)" /SD IDOK
    SetErrorLevel 2
    Quit
  ${EndIf}
  System::Call 'kernel32::CloseHandle(p r0)'
done:
FunctionEnd
!macroend
!insertmacro CheckApplication ""
!insertmacro CheckApplication "un."

Function InstallFailure
  ; Keep a small failure-only diagnostic for silent deployments. Never log user files.
  System::Call 'kernel32::GetLastError() i.r3'
  FileOpen $4 "$TEMP\SSMV-install-error.txt" w
  FileWrite $4 "stage=$FailureStage$\r$\narchitecture=${ARCH}$\r$\nbuild=${BUILD_LABEL}$\r$\nwin32_error=$3$\r$\n"
  FileClose $4
  MessageBox MB_OK|MB_ICONSTOP "$(InstallFailed)" /SD IDOK
  SetErrorLevel 6
  Quit
FunctionEnd

Function .onInit
  SetShellVarContext current
  SetRegView 64
  Delete "$TEMP\SSMV-install-error.txt"
  ; Deliberately ignore /D=: uninstallation is restricted to this one owned location.
  StrCpy $INSTDIR "$LOCALAPPDATA\Programs\SSMV"
  ${IfNot} ${AtLeastWin10}
    Goto unsupported
  ${EndIf}
  ${IfNot} ${AtLeastBuild} 19041
    Goto unsupported
  ${EndIf}
  System::Call 'kernel32::IsWow64Process2(p -1, *i .r0, *i .r1) i.r2'
  ${If} $2 = 0
    Goto unsupported
  ${EndIf}
  ; System returns a decimal number; <> uses IntCmp rather than string comparison.
!if "${ARCH}" == "ARM64"
  ${If} $1 <> 0xAA64
!else if "${ARCH}" == "x64"
  ${If} $1 <> 0x8664
!else
  !error "ARCH must be x64 or ARM64"
!endif
    Goto unsupported
  ${EndIf}
  Call CheckApplication
  Return
unsupported:
  MessageBox MB_OK|MB_ICONSTOP "$(Unsupported)" /SD IDOK
  SetErrorLevel 3
  Quit
FunctionEnd

Function un.onInit
  SetShellVarContext current
  SetRegView 64
  ${If} $INSTDIR != "$LOCALAPPDATA\Programs\SSMV"
    MessageBox MB_OK|MB_ICONSTOP "$(UnknownInstall)" /SD IDOK
    SetErrorLevel 4
    Quit
  ${EndIf}
  Call un.CheckApplication
FunctionEnd

!macro RegisterExtension EXT
  WriteRegStr HKCU "Software\Classes\${EXT}\OpenWithProgids" "SSMV.Markdown" ""
  WriteRegStr HKCU "Software\Classes\Applications\SSMV.exe\SupportedTypes" "${EXT}" ""
  WriteRegStr HKCU "${CAPABILITIES}\FileAssociations" "${EXT}" "SSMV.Markdown"
  WriteRegStr HKCU "Software\Classes\SystemFileAssociations\${EXT}\shell\SSMV" "MUIVerb" "Open with SSMV"
  WriteRegStr HKCU "Software\Classes\SystemFileAssociations\${EXT}\shell\SSMV" "Icon" '$\"$INSTDIR\SSMV.exe$\",0'
  WriteRegStr HKCU "Software\Classes\SystemFileAssociations\${EXT}\shell\SSMV\command" "" '${OPEN_COMMAND}'
!macroend

Section "SSMV"
  Call CheckApplication
  ; The previous uninstaller knows its exact payload, including files no longer shipped.
  ; Never recursively remove the install folder or the separate user-data directory.
  IfFileExists "$INSTDIR\SSMV.exe" existing
  IfFileExists "$INSTDIR\Uninstall.exe" existing new
existing:
  ReadRegStr $0 HKCU "${UNINSTALL_KEY}" "InstallLocation"
  ReadRegStr $1 HKCU "${UNINSTALL_KEY}" "UninstallString"
  ${If} $0 != $INSTDIR
  ${OrIf} $1 != '$\"$INSTDIR\Uninstall.exe$\"'
    MessageBox MB_OK|MB_ICONSTOP "$(UnknownInstall)" /SD IDOK
    SetErrorLevel 4
    Quit
  ${EndIf}
  ; Run the old uninstaller from a private temporary copy, as NSIS normally does.
  ; Waiting on that copy avoids keeping the installed image mapped while replacing it.
  InitPluginsDir
  ClearErrors
  CopyFiles /SILENT "$INSTDIR\Uninstall.exe" "$PLUGINSDIR\SSMV-old-uninstall.exe"
  ${If} ${Errors}
    MessageBox MB_OK|MB_ICONSTOP "$(UpgradeFailed)" /SD IDOK
    SetErrorLevel 5
    Quit
  ${EndIf}
  ExecWait '$\"$PLUGINSDIR\SSMV-old-uninstall.exe$\" /S _?=$INSTDIR' $0
  ${If} ${Errors}
  ${OrIf} $0 <> 0
    MessageBox MB_OK|MB_ICONSTOP "$(UpgradeFailed)" /SD IDOK
    SetErrorLevel 5
    Quit
  ${EndIf}
new:
  ; Establish an owned recovery uninstaller before extracting any application file.
  ; A failed extraction can then be retried through the normal upgrade path.
  StrCpy $FailureStage "recovery registration"
  ClearErrors
  SetOutPath "$INSTDIR"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName" "So Simple Markdown Viewer"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString" '$\"$INSTDIR\Uninstall.exe$\"'
  ${If} ${Errors}
    Call InstallFailure
  ${EndIf}
  StrCpy $FailureStage "recovery uninstaller"
  StrCpy $5 0
write_recovery:
  ClearErrors
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  ${If} ${Errors}
    IntOp $5 $5 + 1
    ${If} $5 < 20
      ; Security scanners may retain a handle briefly after the old process exits.
      Sleep 250
      Goto write_recovery
    ${EndIf}
    Call InstallFailure
  ${EndIf}
  StrCpy $FailureStage "payload extraction"
  ClearErrors
  SetOverwrite on
  !insertmacro InstallPayload
  ${If} ${Errors}
    Call InstallFailure
  ${EndIf}
  StrCpy $FailureStage "application registration"
  WriteRegStr HKCU "Software\Classes\SSMV.Markdown" "" "Markdown document"
  WriteRegStr HKCU "Software\Classes\SSMV.Markdown\DefaultIcon" "" '$\"$INSTDIR\SSMV.exe$\",0'
  WriteRegStr HKCU "Software\Classes\SSMV.Markdown\shell\open\command" "" '${OPEN_COMMAND}'
  WriteRegStr HKCU "Software\Classes\Applications\SSMV.exe" "FriendlyAppName" "So Simple Markdown Viewer"
  WriteRegStr HKCU "Software\Classes\Applications\SSMV.exe\shell\open\command" "" '${OPEN_COMMAND}'
  WriteRegStr HKCU "${CAPABILITIES}" "ApplicationName" "So Simple Markdown Viewer"
  WriteRegStr HKCU "${CAPABILITIES}" "ApplicationDescription" "Read Markdown documents with SSMV."
  WriteRegStr HKCU "${CAPABILITIES}" "ApplicationIcon" '$\"$INSTDIR\SSMV.exe$\",0'
  WriteRegStr HKCU "Software\RegisteredApplications" "SSMV" "${CAPABILITIES}"
  !insertmacro RegisterExtension ".md"
  !insertmacro RegisterExtension ".markdown"
  !insertmacro RegisterExtension ".mdown"
  CreateShortcut "$SMPROGRAMS\SSMV.lnk" "$INSTDIR\SSMV.exe" "" "$INSTDIR\SSMV.exe" 0
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName" "So Simple Markdown Viewer"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion" "${BUILD_LABEL}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "Publisher" "SSMV contributors"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon" '$\"$INSTDIR\SSMV.exe$\",0'
  WriteRegStr HKCU "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString" '$\"$INSTDIR\Uninstall.exe$\"'
  WriteRegStr HKCU "${UNINSTALL_KEY}" "QuietUninstallString" '$\"$INSTDIR\Uninstall.exe$\" /S'
  WriteRegStr HKCU "${UNINSTALL_KEY}" "URLInfoAbout" "https://github.com/raeseoklee/ssmv"
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair" 1
  ${If} ${Errors}
    Call InstallFailure
  ${EndIf}
  System::Call 'shell32::SHChangeNotify(i 0x08000000, i 0, p 0, p 0)'
  SetErrorLevel 0
SectionEnd

!macro UnregisterExtension EXT
  ; Keep other applications' associations and all UserChoice/default values.
  ${If} $2 = 1
    DeleteRegValue HKCU "Software\Classes\${EXT}\OpenWithProgids" "SSMV.Markdown"
    DeleteRegKey /ifempty HKCU "Software\Classes\${EXT}\OpenWithProgids"
    DeleteRegKey /ifempty HKCU "Software\Classes\${EXT}"
  ${EndIf}
  ReadRegStr $0 HKCU "Software\Classes\SystemFileAssociations\${EXT}\shell\SSMV\command" ""
  ${If} $0 == '${OPEN_COMMAND}'
    DeleteRegKey HKCU "Software\Classes\SystemFileAssociations\${EXT}\shell\SSMV"
  ${EndIf}
!macroend

Section "Uninstall"
  Call un.CheckApplication
  ; Remove tracked files first; keep registrations available if a file is locked.
  ; The generated macro ignores nonempty directories but records Delete failures.
  !insertmacro UninstallPayload
  ${If} $R9 <> 0
    MessageBox MB_OK|MB_ICONSTOP "$(UninstallFailed)" /SD IDOK
    SetErrorLevel 7
    Quit
  ${EndIf}
  StrCpy $2 0
  ReadRegStr $0 HKCU "Software\Classes\SSMV.Markdown\shell\open\command" ""
  ${If} $0 == '${OPEN_COMMAND}'
    StrCpy $2 1
    DeleteRegKey HKCU "Software\Classes\SSMV.Markdown"
  ${EndIf}
  !insertmacro UnregisterExtension ".md"
  !insertmacro UnregisterExtension ".markdown"
  !insertmacro UnregisterExtension ".mdown"
  ReadRegStr $0 HKCU "Software\Classes\Applications\SSMV.exe\shell\open\command" ""
  ${If} $0 == '${OPEN_COMMAND}'
    DeleteRegKey HKCU "Software\Classes\Applications\SSMV.exe"
  ${EndIf}
  ReadRegStr $0 HKCU "${CAPABILITIES}" "ApplicationIcon"
  ${If} $0 == '$\"$INSTDIR\SSMV.exe$\",0'
    ReadRegStr $0 HKCU "Software\RegisteredApplications" "SSMV"
    ${If} $0 == "${CAPABILITIES}"
      DeleteRegValue HKCU "Software\RegisteredApplications" "SSMV"
    ${EndIf}
    DeleteRegKey HKCU "${CAPABILITIES}"
    DeleteRegKey /ifempty HKCU "Software\SSMV"
  ${EndIf}
  ReadRegStr $0 HKCU "${UNINSTALL_KEY}" "InstallLocation"
  ReadRegStr $1 HKCU "${UNINSTALL_KEY}" "UninstallString"
  ${If} $0 == $INSTDIR
  ${AndIf} $1 == '$\"$INSTDIR\Uninstall.exe$\"'
    DeleteRegKey HKCU "${UNINSTALL_KEY}"
    Delete "$SMPROGRAMS\SSMV.lnk"
  ${EndIf}
  Delete "$INSTDIR\Uninstall.exe"
  ; An extra user file intentionally keeps this directory alive.
  SetOutPath "$TEMP"
  RMDir "$INSTDIR"
  System::Call 'shell32::SHChangeNotify(i 0x08000000, i 0, p 0, p 0)'
  SetErrorLevel 0
SectionEnd
