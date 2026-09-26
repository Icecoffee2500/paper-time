; Paper Time's part of the Windows installer.
;
; electron-builder writes the installer from its own templates
; (node_modules/app-builder-lib/templates/nsis) and inserts the macros below at
; the hooks it offers; `nsis.include` in electron-builder.yml points here. One
; file goes into two compilations — the installer, and the uninstaller the
; installer carries — so whatever belongs to one of them stays behind
; BUILD_UNINSTALLER: makensis runs with -WX, and a function or variable one of
; them never uses is an error in that one.
;
; The hooks, in the order they run:
;   installer    .onVerifyInstDir      the folder page, on every change
;                customUnInstallCheck  just after the previous version's
;                                      uninstaller, before the first file
;                customInstall         the end of the install section
;   uninstaller  customRemoveFiles     removing the installed files
;
; Why an upgrade stopped on two files
;
; An upgrade first runs the previous version's uninstaller (installUtil.nsh,
; uninstallOldVersion), which clears the folder by moving every file into
; %TEMP% (uninstaller.nsh, un.atomicRMDir). When the app sits on another drive
; than %TEMP% — D:\…\Programs\Paper Time — a move is a copy and a delete. A
; file that something still holds when it is deleted (a scanner looking at an
; executable that just ran, Explorer, the indexer) keeps its name until it is
; let go: the name stays listed and cannot be opened. A file that cannot be
; deleted at all stays where it was, and the move still reports success.
; Either way the name is taken.
;
; The new installer then writes two of the old install's names with NSIS's
; File, which does not retry: uninstallerIcon.ico right after the uninstaller,
; and "Uninstall Paper Time.exe" at the end. That is «다음 파일을 열 수
; 없습니다» ("Error opening file for writing") with Abort, Retry, Ignore —
; twice. The app's own files go in through a copy that retries, so they came
; through. Hence, below: the icon file is gone (electron-builder.yml has no
; uninstallerIcon, so both the uninstaller and Settings → Apps take the same
; icon from the executables), the installer waits for the uninstaller's name
; and writes it again at the end if it did not land, and this version's
; uninstaller renames its own file inside the folder before it removes
; anything — a rename in one folder is never a copy, and a file that is held
; can be renamed where it cannot be deleted, so the name comes free at once.

; Inserted after electron-builder's own includes (LogicLib, FileFunc,
; StrContains, the install-mode variables), which the function below uses.
!macro customHeader
  !ifndef BUILD_UNINSTALLER
    Var PaperTimeTries
    Var PaperTimeHandle
    Var PaperTimePath
    Var PaperTimeIntro

    ; The folder page calls this whenever the path changes, and Abort greys out
    ; Install. Installing only for me runs without administrator rights, which
    ; cannot write to a folder like C:\Program Files; such a choice used to go
    ; ahead and fail file by file — the app's files with a message that Paper
    ; Time could not be closed. Now the page says why before anything happens.
    ;
    ; It asks Windows whether this account may add to the folder, the way
    ; opening it for writing would be judged, and creates nothing — so it is
    ; cheap enough for every keystroke. (A folder that Windows Security's
    ; ransomware protection guards passes this: that is decided at the write.)
    Function .onVerifyInstDir
      Push $0   ; the folder asked about
      Push $1   ; the page's text
      Push $2   ; what is asked for, then the answer
      Push $3   ; what to say ("" when the folder is fine)
      Push $4   ; Windows' reason, when it says no

      ; The page's text sits above the path box (1006, and the box is 1019).
      ; NSIS first calls this while the page is still being made, so take the
      ; dialog that has the path box rather than whichever comes first.
      StrCpy $1 0
      ${Do}
        FindWindow $1 "#32770" "" $HWNDPARENT $1
        ${If} $1 = 0
          ${Break}
        ${EndIf}
        GetDlgItem $2 $1 1019
        ${If} $2 <> 0
          ${Break}
        ${EndIf}
      ${Loop}
      ${If} $1 <> 0
        GetDlgItem $1 $1 1006
      ${EndIf}
      ${If} $PaperTimeIntro == ""
        System::Call 'user32::GetWindowTextW(p r1, w .r2, i ${NSIS_MAX_STRLEN}) i'
        StrCpy $PaperTimeIntro $2
      ${EndIf}

      ; Only a path that names a drive or a share is ours to judge; NSIS turns
      ; down the rest by itself.
      StrCpy $3 ""
      StrCpy $0 $INSTDIR 1 1
      StrCpy $2 $INSTDIR 2
      ${If} $0 == ":"
      ${OrIf} $2 == "\\"
        ; The folder the install makes: electron-builder's instFilesPre adds
        ; the app's name to a path that does not have it.
        ${StrContains} $0 "${APP_FILENAME}" $INSTDIR
        ${If} $0 == ""
          StrCpy $0 "$INSTDIR\${APP_FILENAME}"
        ${Else}
          StrCpy $0 $INSTDIR
        ${EndIf}

        ; Windows answers only for a folder that exists. Files go into the
        ; install folder when it is there; otherwise it is made inside the
        ; nearest folder that is.
        StrCpy $2 6          ; FILE_ADD_FILE | FILE_ADD_SUBDIRECTORY
        ${IfNot} ${FileExists} "$0\*.*"
          StrCpy $2 4        ; FILE_ADD_SUBDIRECTORY
          ${Do}
            ${GetParent} $0 $0
            ${If} $0 == ""
            ${OrIf} ${FileExists} "$0\*.*"
              ${Break}
            ${EndIf}
          ${Loop}
        ${EndIf}

        ; Install is greyed out only when Windows says, in so many words, that
        ; this account may not write here (ERROR_ACCESS_DENIED). Anything else
        ; — no folder found above the path (a share, a drive that is gone), a
        ; call that did not run, another error — leaves the page as it was,
        ; for NSIS and the install to judge: this has never run on Windows
        ; here, and a check that said no by mistake would leave no folder
        ; anyone could install to.
        StrCpy $3 ""
        ${If} $0 != ""
          ; "C:" alone names the current folder on C:, not its root.
          StrLen $4 $0
          ${If} $4 = 2
            StrCpy $0 "$0\"
          ${EndIf}
          ; OPEN_EXISTING and FILE_FLAG_BACKUP_SEMANTICS, the only way a folder
          ; opens; every kind of sharing, so nobody else is in the way. ?e
          ; puts GetLastError on the stack.
          System::Call 'kernel32::CreateFileW(w r0, i r2, i 7, p 0, i 3, i 0x02000000, p 0) p .r2 ?e'
          Pop $4
          ${If} $2 P<> -1
            System::Call 'kernel32::CloseHandle(p r2)'
          ${ElseIf} $4 = 5
            StrCpy $3 "denied"
          ${EndIf}
        ${EndIf}
      ${EndIf}

      ${If} $3 == ""
        SendMessage $1 ${WM_SETTEXT} 0 "STR:$PaperTimeIntro"
      ${Else}
        ${If} $LANGUAGE = 1042
          ${If} $installMode == "all"
            StrCpy $3 "이 폴더에는 설치할 수 없어요. 다른 폴더를 골라 주세요."
          ${Else}
            StrCpy $3 "이 폴더에는 설치할 수 없어요. 다른 폴더를 골라 주세요.$\r$\nProgram Files에 두려면 뒤로 가서 «모든 사용자»를 고르면 돼요."
          ${EndIf}
        ${Else}
          ${If} $installMode == "all"
            StrCpy $3 "Paper Time can't write to this folder. Choose another one."
          ${Else}
            StrCpy $3 "Paper Time can't write to this folder. Choose another one.$\r$\nFor Program Files, go back and choose to install for all users."
          ${EndIf}
        ${EndIf}
        SendMessage $1 ${WM_SETTEXT} 0 "STR:$3"
      ${EndIf}

      ; Abort here is what greys out Install, so the verdict is read before
      ; the registers go back.
      ${If} $3 == ""
        Pop $4
        Pop $3
        Pop $2
        Pop $1
        Pop $0
        Return
      ${EndIf}
      Pop $4
      Pop $3
      Pop $2
      Pop $1
      Pop $0
      Abort
    FunctionEnd
  !endif
!macroend

; Runs right after the previous version's uninstaller. Defining this hook
; replaces electron-builder's handling of the uninstaller's result
; (installUtil.nsh, handleUninstallResult), so that comes first, unchanged.
!macro customUnInstallCheck
  ${If} ${Errors}
    DetailPrint `Uninstall was not successful. Not able to launch uninstaller!`
    Return
  ${EndIf}
  ${If} $R0 != 0
    MessageBox MB_OK|MB_ICONEXCLAMATION "$(uninstallFailed): $R0"
    DetailPrint `Uninstall was not successful. Uninstaller error code: $R0.`
    SetErrorLevel 2
    Quit
  ${EndIf}

  ; The previous version is gone, but its names may not be free yet, and the
  ; uninstaller's is written without a retry. Wait for it — at most 20 s —
  ; deleting it whenever it can be: a file the old uninstaller left behind
  ; goes at once, and a deleted one that is still held disappears when it is
  ; let go. After that the write itself says what is wrong.
  StrCpy $PaperTimeTries 0
  ${Do}
    ClearErrors
    Delete "$INSTDIR\${UNINSTALL_FILENAME}"
    ${IfNot} ${FileExists} "$INSTDIR\${UNINSTALL_FILENAME}"
      ${Break}
    ${EndIf}
    IntOp $PaperTimeTries $PaperTimeTries + 1
    ${If} $PaperTimeTries >= 80
      DetailPrint `Still in use after 20 s: $INSTDIR\${UNINSTALL_FILENAME}`
      ${Break}
    ${EndIf}
    Sleep 250
  ${Loop}
  ClearErrors
!macroend

!macro customInstall
  ; If the uninstaller's name was still held when electron-builder wrote it
  ; and the question was answered with Ignore — or the install is silent,
  ; where NSIS skips the file without asking — the folder has no uninstaller
  ; and Settings → Apps cannot remove Paper Time. By now the name has had the
  ; whole install to come free, so write it again once it is. A file that is
  ; there and can be read is left alone: it may well be the one just written.
  ; (The data is the same as electron-builder's, and makensis stores it once.)
  StrCpy $PaperTimeTries 0
  ${Do}
    ClearErrors
    FileOpen $PaperTimeHandle "$INSTDIR\${UNINSTALL_FILENAME}" r
    ${IfNot} ${Errors}
      FileClose $PaperTimeHandle
      ${Break}
    ${EndIf}
    ${IfNot} ${FileExists} "$INSTDIR\${UNINSTALL_FILENAME}"
      SetOverwrite try
      File "/oname=$INSTDIR\${UNINSTALL_FILENAME}" "${UNINSTALLER_OUT_FILE}"
      SetOverwrite on
      ${Break}
    ${EndIf}
    ; Listed but not readable: deleted and still held. Wait for it to go.
    IntOp $PaperTimeTries $PaperTimeTries + 1
    ${If} $PaperTimeTries >= 80
      DetailPrint `Still in use after 20 s: $INSTDIR\${UNINSTALL_FILENAME}`
      ${Break}
    ${EndIf}
    Sleep 250
  ${Loop}
  ClearErrors

  ; The icon file versions before 0.9.10 wrote next to the uninstaller: this
  ; one does not, and the registry now points at the app itself.
  Delete "$INSTDIR\uninstallerIcon.ico"
  ClearErrors

  ; What customRemoveFiles set aside and could not delete — the uninstaller
  ; itself, when policy made it run from this folder instead of %TEMP% — is
  ; no longer running now.
  FindFirst $PaperTimeHandle $PaperTimePath "$INSTDIR\${UNINSTALL_FILENAME}.*.old"
  ${DoWhile} $PaperTimePath != ""
    Delete "$INSTDIR\$PaperTimePath"
    FindNext $PaperTimeHandle $PaperTimePath
  ${Loop}
  FindClose $PaperTimeHandle
  ClearErrors

  ; electron-builder leaves a copy of this installer — about 250 MB — in
  ; %LOCALAPPDATA%\paper-time-updater for electron-updater, which Paper Time
  ; does not use. Nothing reads it, and it stayed even after an uninstall,
  ; taking room on C: that the next install needs. (If electron-updater ever
  ; comes in, this has to go: it is the cache that update diffs against.)
  ${If} $installMode == "all"
    SetShellVarContext current
  ${EndIf}
  Delete "$LOCALAPPDATA\${APP_INSTALLER_STORE_FILE}"
  ${GetParent} "$LOCALAPPDATA\${APP_INSTALLER_STORE_FILE}" $PaperTimePath
  RMDir $PaperTimePath
  ${If} $installMode == "all"
    SetShellVarContext all
  ${EndIf}
  ClearErrors
!macroend

; Replaces electron-builder's removal of the installed files
; (uninstaller.nsh), which follows unchanged after the first step.
!macro customRemoveFiles
  ; The next version's installer writes this file's name with File, which does
  ; not retry. Renaming the file inside its own folder frees the name now —
  ; whatever happens to the file after this, under its new name.
  Var /GLOBAL PaperTimeAside
  System::Call 'kernel32::GetTickCount() i .s'
  Pop $PaperTimeAside
  StrCpy $PaperTimeAside "$INSTDIR\${UNINSTALL_FILENAME}.$PaperTimeAside.old"
  ClearErrors
  Rename "$INSTDIR\${UNINSTALL_FILENAME}" "$PaperTimeAside"
  ${If} ${Errors}
    StrCpy $PaperTimeAside ""
  ${EndIf}
  ClearErrors

  ${if} ${isUpdated}
    CreateDirectory "$PLUGINSDIR\old-install"

    Push ""
    Call un.atomicRMDir
    Pop $R0

    ${if} $R0 != 0
      DetailPrint "File is busy, aborting: $R0"

      ; Put the folder back as it was, the uninstaller under its own name.
      Push ""
      Call un.restoreFiles
      Pop $R0
      ${If} $PaperTimeAside != ""
        Rename "$PaperTimeAside" "$INSTDIR\${UNINSTALL_FILENAME}"
      ${EndIf}

      Abort `Can't rename "$INSTDIR" to "$PLUGINSDIR\old-install".`
    ${endif}
  ${endif}

  ; Remove all files (or remaining shallow directories from the block above)
  RMDir /r $INSTDIR
!macroend
