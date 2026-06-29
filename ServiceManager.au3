;===============================================================================
; Service Manager (AutoIt) - Hybrid elevation: user-mode default, elevate for Service/Task
;===============================================================================

;--- Standard includes ---
#include <TrayConstants.au3>
#include <File.au3>
#include <AutoItConstants.au3>

; Disable default "Script Paused" and "Exit" tray items
Opt("TrayMenuMode", 3)

; Enable tray event mode for TrayItemSetOnEvent handlers
Opt("TrayOnEventMode", 1)

; Require all variables to be declared (catches typos at compile time)
Opt("MustDeclareVars", 1)

;===============================================================================
; Constants and configuration
;===============================================================================
Global Const $APP_COUNT = 3

Global $g_aApps[$APP_COUNT][8] = [ _
    [ "LlaMA.C++ HTTP Server", _
      @LocalAppDataDir & "\Programs\Konnek\llamacpp\llama-server.exe", _
      "", _
      "http://localhost:11434/", "11434", _
      "LlamaCppHttpServer", "LlamaCppHttpServer_Task", "LlamaCppHttpServer.lnk" ], _
    [ "AgentGateway", _
      @LocalAppDataDir & "\Programs\Konnek\agentgateway\agentgateway.exe", _
      "", _
      "http://localhost:15000/ui", "15000", _
      "AgentGateway", "AgentGateway_Task", "AgentGateway.lnk" ], _
    [ "MCPJungle", _
      @LocalAppDataDir & "\Programs\Konnek\mcpjungle\mcpjungle.exe", _
      "start --port 8080 --sqlite-db-path " & EnvGet("APPDATA") & "\Konnek\mcpjungle\mcpjungle.db", _
      "http://localhost:8080/", "8080", _
      "MCPJungle", "MCPJungle_Task", "MCPJungle.lnk" ] _
]

; PID persistence
Global $g_sPIDFile = @LocalAppDataDir & "\Konnek\servicemanager\service_pids.dat"
Global $g_aPID[$APP_COUNT] = [-1, -1, -1]

; Autostart persistence
Global $g_sAutoFile = @LocalAppDataDir & "\Konnek\servicemanager\autostart.dat"
Global $g_iAutoMode = 0 ; 0=none, 1=service, 2=scheduled, 3=startup
Global $g_iAutoApp = -1

; Single instance mutex
Global $g_hMutex = DllCall("kernel32.dll", "handle", "CreateMutexW", "ptr", 0, "int", 1, "wstr", "Global\ServiceManagerMutex")
If IsArray($g_hMutex) And $g_hMutex[0] <> 0 Then
    Local $aErr = DllCall("kernel32.dll", "int", "GetLastError")
    If IsArray($aErr) And $aErr[0] = 183 Then
        DllCall("kernel32.dll", "int", "CloseHandle", "handle", $g_hMutex[0])
        Exit
    EndIf
EndIf

; Tray menu handles
Global $g_hMenuApp[$APP_COUNT]
Global $g_hMI_Start[$APP_COUNT]
Global $g_hMI_Stop[$APP_COUNT]
Global $g_hMI_UI[$APP_COUNT]
Global $g_hMenuAuto
Global $g_hMenuAutoApp[$APP_COUNT]
Global $g_aAutoMI_Service[$APP_COUNT]
Global $g_aAutoMI_Scheduled[$APP_COUNT]
Global $g_aAutoMI_Startup[$APP_COUNT]
Global $g_aAutoMI_None[$APP_COUNT]
Global $g_hMI_Exit
Global $g_hMI_StartAll
Global $g_hMI_StopAll
Global $g_hMI_Show[$APP_COUNT]
Global $g_hMI_Hide[$APP_COUNT]
Global $g_hMI_ShowAll
Global $g_hMI_HideAll
Global $g_hMenuAutoStartAll
Global $g_aAutoStartAllMI[8]
Global $g_hMI_AutoStartAll

; Elevation command line constants
Global Const $CMD_ELEVATE_SERVICE = "/elevate_service"
Global Const $CMD_ELEVATE_TASK    = "/elevate_task"
Global Const $CMD_ELEVATE_REMOVE  = "/elevate_remove"

;===============================================================================
; PID persistence
;===============================================================================
Func _PID_Load()
    If Not FileExists($g_sPIDFile) Then Return
    Local $h = FileOpen($g_sPIDFile, $FO_READ)
    If $h = -1 Then Return
    For $i = 0 To $APP_COUNT - 1
        Local $s = FileReadLine($h)
        If @error Then ExitLoop
        $s = StringStripWS($s, $STR_STRIPALL)
        If $s = "" Then ContinueLoop
        Local $a = StringSplit($s, "=", $STR_NOCOUNT)
        If UBound($a) = 2 Then
            Local $idx = Int($a[0]), $pid = Int($a[1])
            If $idx >= 0 And $idx < $APP_COUNT Then
                If $pid > 0 And ProcessExists($pid) Then
                    $g_aPID[$idx] = $pid
                Else
                    $g_aPID[$idx] = -1
                EndIf
            EndIf
        EndIf
    Next
    FileClose($h)
EndFunc

Func _PID_Save()
    Local $h = FileOpen($g_sPIDFile, $FO_OVERWRITE)
    If $h = -1 Then Return
    For $i = 0 To $APP_COUNT - 1
        FileWriteLine($h, $i & "=" & $g_aPID[$i])
    Next
    FileClose($h)
EndFunc

;===============================================================================
; Autostart persistence (per-app: Service / Scheduled Task / Startup Shortcut)
;===============================================================================
Func _Auto_Load()
    If Not FileExists($g_sAutoFile) Then Return SetError(1, 0, 0)
    Local $h = FileOpen($g_sAutoFile, $FO_READ)
    If $h = -1 Then Return SetError(1, 0, 0)
    Local $iMode = 0, $iApp = -1
    For $i = 0 To 1
        Local $s = FileReadLine($h)
        If @error Then ExitLoop
        $s = StringStripWS($s, $STR_STRIPALL)
        If StringLeft($s, 5) = "Mode=" Then $iMode = Int(StringTrimLeft($s, 5))
        If StringLeft($s, 4) = "App=" Then $iApp = Int(StringTrimLeft($s, 4))
    Next
    FileClose($h)
    If $iMode < 0 Or $iMode > 3 Then $iMode = 0
    Return SetError(0, $iApp, $iMode)
EndFunc

Func _Auto_Save($iMode, $iApp)
    Local $h = FileOpen($g_sAutoFile, $FO_OVERWRITE)
    If $h = -1 Then Return
    FileWriteLine($h, "Mode=" & $iMode)
    FileWriteLine($h, "App=" & $iApp)
    FileClose($h)
EndFunc

;===============================================================================
; Elevation helper - re-launches self with admin rights for specific operation
;===============================================================================
Func _RequireElevation($sCmd, $iAppIndex, $bExclude = False)
    If IsAdmin() Then Return True
    
    Local $sScript = @ScriptFullPath
    Local $sParams = $sCmd & " " & $iAppIndex & " " & ($bExclude ? "1" : "0")
    Local $iPID = Run('"' & @AutoItExe & '" "' & $sScript & '" ' & $sParams, "", @SW_HIDE)
    If $iPID = 0 Then
        MsgBox($MB_ICONERROR, "Service Manager", "Failed to launch elevated process.")
        Return False
    EndIf
    ProcessWaitClose($iPID, 30)
    Return True
EndFunc

Func _Elevated_Service_Install($iAppIndex)
    If Not _RequireElevation($CMD_ELEVATE_SERVICE, $iAppIndex, True) Then Return False
    Return True
EndFunc

Func _Elevated_Task_Install($iAppIndex)
    If Not _RequireElevation($CMD_ELEVATE_TASK, $iAppIndex, True) Then Return False
    Return True
EndFunc

Func _Elevated_RemoveAll($iAppIndex, $bExclude = False)
    If Not _RequireElevation($CMD_ELEVATE_REMOVE, $iAppIndex, $bExclude) Then Return False
    Return True
EndFunc

;===============================================================================
; Autostart methods (elevated versions for Service/Task)
;===============================================================================
Func _Service_Install($i)
    If Not IsAdmin() Then Return _Elevated_Service_Install($i)
    
    _Auto_RemoveAll($i, True) ; Mutual exclusion: clear all EXCEPT this app
    Local $sBin = '"' & $g_aApps[$i][1] & '"'
    Local $sName = $g_aApps[$i][4]
    Local $sDisp = "Service Manager - " & $g_aApps[$i][0]
    RunWait(@ComSpec & ' /c sc.exe create "' & $sName & '" binPath= ' & $sBin & ' type= own start= auto error= normal DisplayName= "' & $sDisp & '"', "", @SW_HIDE)
    _Auto_Save(1, $i)
    Return True
EndFunc

Func _Task_Install($i)
    If Not IsAdmin() Then Return _Elevated_Task_Install($i)
    
    _Auto_RemoveAll($i, True) ; Mutual exclusion: clear all EXCEPT this app
    Local $sXML = '<?xml version="1.0" encoding="UTF-16"?>' & @CRLF & _
        '<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">' & @CRLF & _
        ' <Triggers><LogonTrigger><Enabled>true</Enabled></LogonTrigger></Triggers>' & @CRLF & _
        ' <Principals><Principal id="Author"><LogonType>InteractiveToken</LogonType><RunLevel>HighestAvailable</RunLevel></Principal></Principals>' & @CRLF & _
        ' <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartWhenAvailable>false</StartWhenAvailable><RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable><AllowStartOnDemand>true</AllowStartOnDemand><Enabled>true</Enabled><Hidden>false</Hidden><RunOnlyIfIdle>false</RunOnlyIfIdle><WakeToRun>false</WakeToRun><ExecutionTimeLimit>PT0S</ExecutionTimeLimit><Priority>7</Priority></Settings>' & @CRLF & _
        ' <Actions Context="Author"><Exec><Command>' & $g_aApps[$i][1] & '</Command><WorkingDirectory>' & @ScriptDir & '</WorkingDirectory></Exec></Actions>' & @CRLF & _
        '</Task>'
    Local $sXMLPath = @TempDir & "\sm_task_" & $i & ".xml"
    Local $h = FileOpen($sXMLPath, $FO_OVERWRITE)
    FileWrite($h, $sXML)
    FileClose($h)
    RunWait(@ComSpec & ' /c schtasks.exe /create /tn "' & $g_aApps[$i][5] & '" /xml "' & $sXMLPath & '" /f', "", @SW_HIDE)
    FileDelete($sXMLPath)
    _Auto_Save(2, $i)
    Return True
EndFunc

Func _Startup_Install($i)
    ; Startup shortcuts work without admin (per-user)
    _Auto_RemoveAll($i, True) ; Mutual exclusion: clear all EXCEPT this app
    Local $o = ObjCreate("WScript.Shell")
    If Not IsObj($o) Then Return False
    Local $sStartup = @AppDataDir & "\Microsoft\Windows\Start Menu\Programs\Startup"
    Local $sLnk = $sStartup & "\" & $g_aApps[$i][6]
    Local $sShort = $o.CreateShortcut($sLnk)
    $sShort.TargetPath = $g_aApps[$i][1]
    $sShort.WorkingDirectory = @ScriptDir
    $sShort.WindowStyle = 7
    $sShort.Save()
    _Auto_Save(3, $i)
    Return True
EndFunc

Func _Auto_RemoveAll($iAppIndex = -1, $bExclude = False)
    If Not IsAdmin() Then Return _Elevated_RemoveAll($iAppIndex, $bExclude)
    
    For $i = 0 To $APP_COUNT - 1
        Local $bShouldRemove = False
        If $iAppIndex = -1 Then
            $bShouldRemove = True ; Clear all
        ElseIf $bExclude Then
            $bShouldRemove = ($i <> $iAppIndex) ; Clear all EXCEPT this app
        Else
            $bShouldRemove = ($i = $iAppIndex) ; Clear only this app
        EndIf
        
        If $bShouldRemove Then
            RunWait(@ComSpec & ' /c sc.exe stop "' & $g_aApps[$i][4] & '"', "", @SW_HIDE)
            RunWait(@ComSpec & ' /c sc.exe delete "' & $g_aApps[$i][4] & '"', "", @SW_HIDE)
            RunWait(@ComSpec & ' /c schtasks.exe /delete /tn "' & $g_aApps[$i][5] & '" /f', "", @SW_HIDE)
            Local $sStartup = @AppDataDir & "\Microsoft\Windows\Start Menu\Programs\Startup"
            FileDelete($sStartup & "\" & $g_aApps[$i][6])
        EndIf
    Next
    If $iAppIndex = -1 Then _Auto_Save(0, -1)
    Return True
EndFunc

;===============================================================================
; Process management
;===============================================================================
Func _IsRunning($i)
    Local $p = $g_aPID[$i]
    If $p = -1 Then Return False
    If ProcessExists($p) Then Return True
    $g_aPID[$i] = -1
    _PID_Save()
    Return False
EndFunc

Func _StartApp($i)
    If _IsRunning($i) Then
        MsgBox($MB_ICONWARNING, "Service Manager", $g_aApps[$i][0] & " is already running.")
        Return False
    EndIf
    Local $sExe = $g_aApps[$i][1]
    Local $sArgs = $g_aApps[$i][2]
    If Not FileExists($sExe) Then
        MsgBox($MB_ICONERROR, "Service Manager", "Executable not found:" & @CRLF & $sExe)
        Return False
    EndIf
    Local $sDir = @ScriptDir
    Local $sCmdLine = '"' & $sExe & '"'
    If $sArgs <> "" Then $sCmdLine &= " " & $sArgs
    Local $pid = Run($sCmdLine, $sDir, @SW_HIDE)
    If $pid = 0 Then
        MsgBox($MB_ICONERROR, "Service Manager", "Failed to start " & $g_aApps[$i][0])
        Return False
    EndIf
    Sleep(400)
    If Not ProcessExists($pid) Then
        MsgBox($MB_ICONERROR, "Service Manager", "Process exited immediately for " & $g_aApps[$i][0])
        Return False
    EndIf
    $g_aPID[$i] = $pid
    _PID_Save()
    Return True
EndFunc

Func _StopApp($i)
    If Not _IsRunning($i) Then Return True
    Local $pid = $g_aPID[$i]
    ProcessClose($pid)
    Sleep(300)
    If ProcessExists($pid) Then ProcessWaitClose($pid, 3)
    $g_aPID[$i] = -1
    _PID_Save()
    Return True
EndFunc

Func _OpenUI($i)
    If Not _IsRunning($i) Then
        MsgBox($MB_ICONWARNING, "Service Manager", $g_aApps[$i][0] & " is not running.")
        Return
    EndIf
    ShellExecute($g_aApps[$i][3])
EndFunc

;===============================================================================
; Tray menu building
;===============================================================================
Func _Tray_Build()
    ; Global Start All / Stop All at top level
    $g_hMI_StartAll = TrayCreateItem("Start All")
    TrayItemSetOnEvent(-1, "__tray_startAll")
    $g_hMI_StopAll = TrayCreateItem("Stop All")
    TrayItemSetOnEvent(-1, "__tray_stopAll")
    $g_hMI_ShowAll = TrayCreateItem("Show All")
    TrayItemSetOnEvent(-1, "__tray_showAll")
    $g_hMI_HideAll = TrayCreateItem("Hide All")
    TrayItemSetOnEvent(-1, "__tray_hideAll")
    TrayCreateItem("", 0)

    For $i = 0 To $APP_COUNT - 1
        $g_hMenuApp[$i] = TrayCreateMenu($g_aApps[$i][0])
        $g_hMI_Start[$i] = TrayCreateItem("Start", $g_hMenuApp[$i])
        TrayItemSetOnEvent(-1, "__tray_start")
        $g_hMI_Stop[$i] = TrayCreateItem("Stop", $g_hMenuApp[$i])
        TrayItemSetOnEvent(-1, "__tray_stop")
        $g_hMI_UI[$i] = TrayCreateItem("UI", $g_hMenuApp[$i])
        TrayItemSetOnEvent(-1, "__tray_ui")
        TrayCreateItem("", $g_hMenuApp[$i])
        $g_hMI_Show[$i] = TrayCreateItem("Show", $g_hMenuApp[$i])
        TrayItemSetOnEvent(-1, "__tray_show")
        $g_hMI_Hide[$i] = TrayCreateItem("Hide", $g_hMenuApp[$i])
        TrayItemSetOnEvent(-1, "__tray_hide")
    Next

    TrayCreateItem("", 0)

    $g_hMenuAuto = TrayCreateMenu("Autostart")

    ; Submenu: Start on ServiceManager Start
    $g_hMenuAutoStartAll = TrayCreateMenu("Start on ServiceManager Start", $g_hMenuAuto)
    $g_aAutoStartAllMI[0] = TrayCreateItem("All (LlamaCPP + AgentGateway + MCPJungle)", $g_hMenuAutoStartAll)
    TrayItemSetOnEvent(-1, "__tray_autoStartAll_0")
    $g_aAutoStartAllMI[1] = TrayCreateItem("LlamaCPP HTTP Server", $g_hMenuAutoStartAll)
    TrayItemSetOnEvent(-1, "__tray_autoStartAll_1")
    $g_aAutoStartAllMI[2] = TrayCreateItem("AgentGateway", $g_hMenuAutoStartAll)
    TrayItemSetOnEvent(-1, "__tray_autoStartAll_2")
    $g_aAutoStartAllMI[3] = TrayCreateItem("MCPJungle", $g_hMenuAutoStartAll)
    TrayItemSetOnEvent(-1, "__tray_autoStartAll_3")
    $g_aAutoStartAllMI[4] = TrayCreateItem("LlamaCPP HTTP Server + AgentGateway", $g_hMenuAutoStartAll)
    TrayItemSetOnEvent(-1, "__tray_autoStartAll_4")
    $g_aAutoStartAllMI[5] = TrayCreateItem("LlamaCPP HTTP Server + MCPJungle", $g_hMenuAutoStartAll)
    TrayItemSetOnEvent(-1, "__tray_autoStartAll_5")
    $g_aAutoStartAllMI[6] = TrayCreateItem("AgentGateway + MCPJungle", $g_hMenuAutoStartAll)
    TrayItemSetOnEvent(-1, "__tray_autoStartAll_6")
    TrayCreateItem("", $g_hMenuAutoStartAll)
    $g_aAutoStartAllMI[7] = TrayCreateItem("None", $g_hMenuAutoStartAll)
    TrayItemSetOnEvent(-1, "__tray_autoStartAll_7")

    TrayCreateItem("", $g_hMenuAuto)

    ; Create per-application autostart submenus
    For $i = 0 To $APP_COUNT - 1
        $g_hMenuAutoApp[$i] = TrayCreateMenu($g_aApps[$i][0], $g_hMenuAuto)
        $g_aAutoMI_Service[$i] = TrayCreateItem("Service", $g_hMenuAutoApp[$i])
        TrayItemSetOnEvent(-1, "__tray_autoService")
        $g_aAutoMI_Scheduled[$i] = TrayCreateItem("Scheduled Task", $g_hMenuAutoApp[$i])
        TrayItemSetOnEvent(-1, "__tray_autoScheduled")
        $g_aAutoMI_Startup[$i] = TrayCreateItem("Startup Shortcut", $g_hMenuAutoApp[$i])
        TrayItemSetOnEvent(-1, "__tray_autoStartup")
        TrayCreateItem("", $g_hMenuAutoApp[$i])
        $g_aAutoMI_None[$i] = TrayCreateItem("None", $g_hMenuAutoApp[$i])
        TrayItemSetOnEvent(-1, "__tray_autoNone")
    Next

    TrayCreateItem("", 0)
    $g_hMI_Exit = TrayCreateItem("Exit")
    TrayItemSetOnEvent(-1, "__tray_exit")

    TraySetToolTip("Service Manager")
    TraySetState($TRAY_ICONSTATE_SHOW)
    _Tray_RefreshStates()
EndFunc

Func _Tray_RefreshStates()
    For $i = 0 To $APP_COUNT - 1
        Local $bRunning = _IsRunning($i)
        Local $iStartState = $TRAY_ENABLE
        Local $iStopState = $TRAY_DISABLE
        Local $iUIState = $TRAY_DISABLE
        If $bRunning Then
            $iStartState = $TRAY_DISABLE
            $iStopState = $TRAY_ENABLE
            $iUIState = $TRAY_ENABLE
        EndIf
        TrayItemSetState($g_hMI_Start[$i], $iStartState)
        TrayItemSetState($g_hMI_Stop[$i], $iStopState)
        TrayItemSetState($g_hMI_UI[$i], $iUIState)
        TrayItemSetState($g_hMI_Show[$i], $iUIState)
        TrayItemSetState($g_hMI_Hide[$i], $iUIState)
    Next
EndFunc

;===============================================================================
; Tray event handlers
;===============================================================================
Func __tray_start()
    For $i = 0 To $APP_COUNT - 1
        If @TRAY_ID = $g_hMI_Start[$i] Then _StartApp($i)
    Next
    _Tray_RefreshStates()
EndFunc

Func __tray_stop()
    For $i = 0 To $APP_COUNT - 1
        If @TRAY_ID = $g_hMI_Stop[$i] Then _StopApp($i)
    Next
    _Tray_RefreshStates()
EndFunc

Func __tray_ui()
    For $i = 0 To $APP_COUNT - 1
        If @TRAY_ID = $g_hMI_UI[$i] Then _OpenUI($i)
    Next
    _Tray_RefreshStates()
EndFunc

Func _ShowAppWindow($i)
    Local $aWins = _WinListByPID($g_aPID[$i])
    If UBound($aWins) > 0 Then
        For $j = 0 To UBound($aWins) - 1
            WinSetState($aWins[$j][1], "", @SW_SHOW)
        Next
    EndIf
EndFunc

Func _HideAppWindow($i)
    Local $aWins = _WinListByPID($g_aPID[$i])
    If UBound($aWins) > 0 Then
        For $j = 0 To UBound($aWins) - 1
            WinSetState($aWins[$j][1], "", @SW_HIDE)
        Next
    EndIf
EndFunc

Func _WinListByPID($iPID)
    Local $aWins = WinList()
    Local $aResult[0][2]
    For $i = 1 To $aWins[0][0]
        Local $iWinPID = WinGetProcess($aWins[$i][1])
        If $iWinPID = $iPID And $aWins[$i][0] <> "" Then
            ReDim $aResult[UBound($aResult) + 1][2]
            $aResult[UBound($aResult) - 1][0] = $aWins[$i][0]
            $aResult[UBound($aResult) - 1][1] = $aWins[$i][1]
        EndIf
    Next
    Return $aResult
EndFunc

Func __tray_show()
    For $i = 0 To $APP_COUNT - 1
        If @TRAY_ID = $g_hMI_Show[$i] Then _ShowAppWindow($i)
    Next
    _Tray_RefreshStates()
EndFunc

Func __tray_hide()
    For $i = 0 To $APP_COUNT - 1
        If @TRAY_ID = $g_hMI_Hide[$i] Then _HideAppWindow($i)
    Next
    _Tray_RefreshStates()
EndFunc

Func __tray_showAll()
    For $i = 0 To $APP_COUNT - 1
        _ShowAppWindow($i)
    Next
    _Tray_RefreshStates()
EndFunc

Func __tray_hideAll()
    For $i = 0 To $APP_COUNT - 1
        _HideAppWindow($i)
    Next
    _Tray_RefreshStates()
EndFunc

Func __tray_autoNone()
    Local $i = _Auto_FindAppIndex(@TRAY_ID)
    If $i <> -1 Then
        _Auto_RemoveAll($i, False) ; Per-app "None": clear only this app
        _Tray_RefreshStates()
    EndIf
EndFunc

;===============================================================================
; Autostart on ServiceManager launch (bitmask-based: 1=LlamaCPP, 2=AgentGateway, 4=MCPJungle)
;===============================================================================
Global $g_sAutoStartAllDir = EnvGet("APPDATA") & "\Konnek\servicemanager"
Global $g_sAutoStartAllFile = $g_sAutoStartAllDir & "\autostart_all.dat"
Global $g_iAutoStartAllMask = 7 ; Default: All (1+2+4)

Func _AutoStartAll_Load()
    DirCreate($g_sAutoStartAllDir)
    If Not FileExists($g_sAutoStartAllFile) Then
        ; Default to All (7) if no file exists
        $g_iAutoStartAllMask = 7
        _AutoStartAll_Save(7)
        Return
    EndIf
    Local $h = FileOpen($g_sAutoStartAllFile, $FO_READ)
    If $h = -1 Then Return
    Local $s = FileReadLine($h)
    FileClose($h)
    $s = StringStripWS($s, $STR_STRIPALL)
    If $s <> "" Then
        $g_iAutoStartAllMask = Int($s)
    Else
        $g_iAutoStartAllMask = 7
        _AutoStartAll_Save(7)
    EndIf
EndFunc

Func _AutoStartAll_Save($iMask)
    $g_iAutoStartAllMask = $iMask
    DirCreate($g_sAutoStartAllDir)
    Local $h = FileOpen($g_sAutoStartAllFile, $FO_OVERWRITE)
    If $h = -1 Then Return
    FileWriteLine($h, $iMask)
    FileClose($h)
EndFunc

Func _AutoStartAll_Apply()
    If $g_iAutoStartAllMask = 0 Then Return
    ; Bit 0 = LlamaCPP (index 0), Bit 1 = AgentGateway (index 1), Bit 2 = MCPJungle (index 2)
    If BitAND($g_iAutoStartAllMask, 1) Then _StartApp(0)
    If BitAND($g_iAutoStartAllMask, 2) Then _StartApp(1)
    If BitAND($g_iAutoStartAllMask, 4) Then _StartApp(2)
EndFunc

Func __tray_autoStartAll_0()
    _AutoStartAll_Save(7) ; 1+2+4 = All
    _Tray_RefreshStates()
EndFunc

Func __tray_autoStartAll_1()
    _AutoStartAll_Save(1) ; LlamaCPP only
    _Tray_RefreshStates()
EndFunc

Func __tray_autoStartAll_2()
    _AutoStartAll_Save(2) ; AgentGateway only
    _Tray_RefreshStates()
EndFunc

Func __tray_autoStartAll_3()
    _AutoStartAll_Save(4) ; MCPJungle only
    _Tray_RefreshStates()
EndFunc

Func __tray_autoStartAll_4()
    _AutoStartAll_Save(3) ; 1+2 = LlamaCPP + AgentGateway
    _Tray_RefreshStates()
EndFunc

Func __tray_autoStartAll_5()
    _AutoStartAll_Save(5) ; 1+4 = LlamaCPP + MCPJungle
    _Tray_RefreshStates()
EndFunc

Func __tray_autoStartAll_6()
    _AutoStartAll_Save(6) ; 2+4 = AgentGateway + MCPJungle
    _Tray_RefreshStates()
EndFunc

Func __tray_autoStartAll_7()
    _AutoStartAll_Save(0) ; None
    _Tray_RefreshStates()
EndFunc

Func _Auto_FindAppIndex($id)
    For $i = 0 To $APP_COUNT - 1
        If $id = $g_aAutoMI_Service[$i] Then Return $i
        If $id = $g_aAutoMI_Scheduled[$i] Then Return $i
        If $id = $g_aAutoMI_Startup[$i] Then Return $i
        If $id = $g_aAutoMI_None[$i] Then Return $i
    Next
    Return -1
EndFunc

Func __tray_autoService()
    Local $i = _Auto_FindAppIndex(@TRAY_ID)
    If $i <> -1 Then
        _Service_Install($i)
        _Tray_RefreshStates()
    EndIf
EndFunc

Func __tray_autoScheduled()
    Local $i = _Auto_FindAppIndex(@TRAY_ID)
    If $i <> -1 Then
        _Task_Install($i)
        _Tray_RefreshStates()
    EndIf
EndFunc

Func __tray_autoStartup()
    Local $i = _Auto_FindAppIndex(@TRAY_ID)
    If $i <> -1 Then
        _Startup_Install($i)
        _Tray_RefreshStates()
    EndIf
EndFunc

Func __tray_startAll()
    For $i = 0 To $APP_COUNT - 1
        _StartApp($i)
    Next
    _Tray_RefreshStates()
EndFunc

Func __tray_stopAll()
    For $i = 0 To $APP_COUNT - 1
        _StopApp($i)
    Next
    _Tray_RefreshStates()
EndFunc

Func __tray_exit()
    If MsgBox($MB_YESNO + $MB_ICONQUESTION, "Service Manager", "Exit Service Manager?") = $IDYES Then
        For $i = 0 To $APP_COUNT - 1
            _StopApp($i)
        Next
        Exit
    EndIf
EndFunc

;===============================================================================
; Command line handling for elevated operations
;===============================================================================
Func _HandleCommandLine()
    If $CmdLine[0] < 2 Then Return False
    
    Local $sCmd = $CmdLine[1]
    Local $iApp = Int($CmdLine[2])
    Local $bExclude = False
    If $CmdLine[0] >= 3 Then $bExclude = ($CmdLine[3] = "1")
    
    Switch $sCmd
        Case $CMD_ELEVATE_SERVICE
            _Service_Install($iApp)
            Return True
        Case $CMD_ELEVATE_TASK
            _Task_Install($iApp)
            Return True
        Case $CMD_ELEVATE_REMOVE
            _Auto_RemoveAll($iApp, $bExclude)
            Return True
    EndSwitch
    Return False
EndFunc

;===============================================================================
; Main
;===============================================================================
; Handle elevated command line first (before mutex/tray)
If _HandleCommandLine() Then Exit

_PID_Load()
_AutoStartAll_Load()

Local $aAuto = _Auto_Load()
If Not @error Then
    $g_iAutoMode = $aAuto
    $g_iAutoApp = @extended
EndIf

_Tray_Build()
_AutoStartAll_Apply()

While 1
    Local $aMsg = TrayGetMsg()
    If IsArray($aMsg) Then
        _Tray_RefreshStates()
    EndIf
    Sleep(50)
WEnd