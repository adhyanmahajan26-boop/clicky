; Theo's additions to the Windows installer that Tauri generates.

; Uninstalling takes Theo out of the programs Windows starts at sign-in (the entry "Open Theo when you sign in" adds), so
; Windows doesn't try to start a program that isn't there. Not when an update runs the uninstaller: the setting stays as it was.
!macro NSIS_HOOK_POSTUNINSTALL
  ${If} $UpdateMode <> 1
    DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "Theo"
    DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run" "Theo"
  ${EndIf}
!macroend
