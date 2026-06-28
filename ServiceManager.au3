;===============================================================================
; Service Manager (AutoIt) - Hybrid elevation: user-mode default, elevate for Service/Task
;===============================================================================

;--- Standard includes ---
#include <TrayConstants.au3>
#include <GuiConstants.au3>
#include <WindowsConstants.au3>
#include <StaticConstants.au3>
#include <ButtonConstants.au3>
#include <ListViewConstants.au3>
#include <File.au3>
#include <GuiListView.au3>
#include <AutoItConstants.au3>

; Disable default "Script Paused" and "Exit" tray items
Opt("TrayMenuMode", 3)

;===============================================================================
; Constants and configuration
;===============================================================================
Global Const $APP_COUNT = 3

Global $g_aApps[$APP_COUNT][7] = [ _
    [ "LlaMA.C++ HTTP Server", _
      @LocalAppDataDir & "\Programs\Konnek\llamacpp\llama-server.exe", _
      "http://localhost:11434/", "11434", _
      "LlamaCppHttpServer", "LlamaCppHttpServer_Task", "LlamaCppHttpServer.lnk" ], _
    [ "AgentGateway", _
      @LocalAppDataDir & "\Programs\Konnek\agentgateway\agentgateway.exe", _
      "http://localhost:15000/ui", "15000", _
      "AgentGateway", "AgentGateway_Task", "AgentGateway.lnk" ], _
    [ "MCPJungle", _
      @LocalAppDataDir & "\Programs\Konnek\mcpjungle\mcpjungle.exe", _
      "http://localhost:8080/", "8080", _
      "MCPJungle", "MCPJungle_Task", "MCPJungle.lnk" ] _
]

; PID persistence
Global $g_sPIDFile = @ScriptDir & "\service_pids.dat"
Global $g_aPID[$APP_COUNT] = [-1, -1, -1]

; Autostart persistence
Global $g_sAutoFile = @ScriptDir & "\autostart.dat"
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
Global $g_hMI_AutoNone
Global $g_aAutoMI_Service[$APP_COUNT]
Global $g_aAutoMI_Scheduled[$APP_COUNT]
Global $g_aAutoMI_Startup[$APP_COUNT]
Global $g_aAutoMI_None[$APP_COUNT]
Global $g_hMenuAutoApp[$APP_COUNT]
Global $g_hMI_Advanced
Global $g_hMI_Exit

; Advanced window
Global $g_hWndAdv = -1
Global $g_hLV = -1
Global $g_bAdvOpen = False

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
; Autostart persistence
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
Func _RequireElevation($sCmd, $iAppIndex)
    If IsAdmin() Then Return True
    
    Local $sScript = @ScriptFullPath
    Local $sParams = $sCmd & " " & $iAppIndex
    Local $iPID = Run('"' & @AutoItExe & '" "' & $sScript & '" ' & $sParams, "", @SW_HIDE)
    If $iPID = 0 Then
        MsgBox($MB_ICONERROR, "Service Manager", "Failed to launch elevated process.")
        Return False
    EndIf
    ProcessWaitClose($iPID, 30)
    Return True
EndFunc

Func _Elevated_Service_Install($iAppIndex)
    If Not _RequireElevation($CMD_ELEVATE_SERVICE, $iAppIndex) Then Return False
    ; The elevated instance will do the actual work and save state
    Return True
EndFunc

Func _Elevated_Task_Install($iAppIndex)
    If Not _RequireElevation($CMD_ELEVATE_TASK, $iAppIndex) Then Return False
    Return True
EndFunc

Func _Elevated_RemoveAll($iExceptApp)
    If Not _RequireElevation($CMD_ELEVATE_REMOVE, $iExceptApp) Then Return False
    Return True
EndFunc

;===============================================================================
; Autostart methods (elevated versions for Service/Task)
;===============================================================================
Func _Service_Install($i)
    If Not IsAdmin() Then Return _Elevated_Service_Install($i)
    
    _Auto_RemoveAll($i)
    Local $sBin = '"' & $g_aApps[$i][1] & '"'
    Local $sName = $g_aApps[$i][4]
    Local $sDisp = "Service Manager - " & $g_aApps[$i][0]
    RunWait(@ComSpec & ' /c sc.exe create "' & $sName & '" binPath= ' & $sBin & ' type= own start= auto error= normal DisplayName= "' & $sDisp & '"', "", @SW_HIDE)
    _Auto_Save(1, $i)
    Return True
EndFunc

Func _Task_Install($i)
    If Not IsAdmin() Then Return _Elevated_Task_Install($i)
    
    _Auto_RemoveAll($i)
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
    _Auto_RemoveAll($i)
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

Func _Auto_RemoveAll($iExceptApp = -1)
    If Not IsAdmin() Then Return _Elevated_RemoveAll($iExceptApp)
    
    For $i = 0 To $APP_COUNT - 1
        If $i <> $iExceptApp Then
            RunWait(@ComSpec & ' /c sc.exe stop "' & $g_aApps[$i][4] & '"', "", @SW_HIDE)
            RunWait(@ComSpec & ' /c sc.exe delete "' & $g_aApps[$i][4] & '"', "", @SW_HIDE)
            RunWait(@ComSpec & ' /c schtasks.exe /delete /tn "' & $g_aApps[$i][5] & '" /f', "", @SW_HIDE)
            Local $sStartup = @AppDataDir & "\Microsoft\Windows\Start Menu\Programs\Startup"
            FileDelete($sStartup & "\" & $g_aApps[$i][6])
        EndIf
    Next
    If $iExceptApp = -1 Then _Auto_Save(0, -1)
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
    If Not FileExists($sExe) Then
        MsgBox($MB_ICONERROR, "Service Manager", "Executable not found:" & @CRLF & $sExe)
        Return False
    EndIf
    Local $sDir = @ScriptDir
    Local $pid = Run('"' & $sExe & '"', $sDir, @SW_HIDE)
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
    ShellExecute($g_aApps[$i][2])
EndFunc

;===============================================================================
; Tray menu building
;===============================================================================
Func _Tray_Build()
    For $i = 0 To $APP_COUNT - 1
        $g_hMenuApp[$i] = TrayCreateMenu($g_aApps[$i][0])
        $g_hMI_Start[$i] = TrayCreateItem("Start", $g_hMenuApp[$i])
        TrayItemSetOnEvent(-1, "__tray_start")
        $g_hMI_Stop[$i] = TrayCreateItem("Stop", $g_hMenuApp[$i])
        TrayItemSetOnEvent(-1, "__tray_stop")
        $g_hMI_UI[$i] = TrayCreateItem("UI", $g_hMenuApp[$i])
        TrayItemSetOnEvent(-1, "__tray_ui")
    Next

    TrayCreateItem("", 0)

    $g_hMenuAuto = TrayCreateMenu("Autostart")

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
    $g_hMI_Advanced = TrayCreateItem("Advanced Control Panel")
    TrayItemSetOnEvent(-1, "__tray_advanced")
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
    Next
EndFunc

;===============================================================================
; Tray event handlers
;===============================================================================
Func __tray_start()
    For $i = 0 To $APP_COUNT - 1
        If @TRAY_MENUID = $g_hMI_Start[$i] Then _StartApp($i)
    Next
EndFunc

Func __tray_stop()
    For $i = 0 To $APP_COUNT - 1
        If @TRAY_MENUID = $g_hMI_Stop[$i] Then _StopApp($i)
    Next
EndFunc

Func __tray_ui()
    For $i = 0 To $APP_COUNT - 1
        If @TRAY_MENUID = $g_hMI_UI[$i] Then _OpenUI($i)
    Next
EndFunc

Func __tray_autoNone()
    Local $i = _Auto_FindAppIndex(@TRAY_MENUID)
    If $i <> -1 Then
        _Auto_RemoveAll($i)
        _Tray_RefreshStates()
    EndIf
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
    Local $i = _Auto_FindAppIndex(@TRAY_MENUID)
    If $i <> -1 Then
        _Service_Install($i)
        _Tray_RefreshStates()
    EndIf
EndFunc

Func __tray_autoScheduled()
    Local $i = _Auto_FindAppIndex(@TRAY_MENUID)
    If $i <> -1 Then
        _Task_Install($i)
        _Tray_RefreshStates()
    EndIf
EndFunc

Func __tray_autoStartup()
    Local $i = _Auto_FindAppIndex(@TRAY_MENUID)
    If $i <> -1 Then
        _Startup_Install($i)
        _Tray_RefreshStates()
    EndIf
EndFunc

Func __tray_advanced()
    _Advanced_Toggle()
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
; Advanced control panel
;===============================================================================
Func _Advanced_Toggle()
    If $g_hWndAdv = -1 Then
        _Advanced_Open()
    Else
        _Advanced_Close()
    EndIf
EndFunc

Func _Advanced_Open()
    $g_hWndAdv = GUICreate("Service Manager - Advanced Control Panel", 860, 360, @DesktopWidth - 880, @DesktopHeight - 400, BitOR($GUI_WS_MINIMIZEBOX, $GUI_WS_MAXIMIZEBOX, $WS_SIZEBOX))
    $g_hLV = GUICtrlCreateListView("Status|Service Name|Executable|PID|Web UI", 10, 30, 840, 200, BitOR($LVS_REPORT, $LVS_SINGLESEL, $LVS_NOSORTHEADER, $WS_VSCROLL, $WS_HSCROLL), BitOR($LVS_EX_FULLROWSELECT, $LVS_EX_GRIDLINES))
    _GUICtrlListView_SetColumnWidth($g_hLV, 0, 65)
    _GUICtrlListView_SetColumnWidth($g_hLV, 1, 170)
    _GUICtrlListView_SetColumnWidth($g_hLV, 2, 270)
    _GUICtrlListView_SetColumnWidth($g_hLV, 3, 60)
    _GUICtrlListView_SetColumnWidth($g_hLV, 4, 130)
    Local $idStart = GUICtrlCreateButton("Start", 10, 240, 75, 28)
    GUICtrlSetOnEvent(-1, "__adv_start")
    Local $idStop = GUICtrlCreateButton("Stop", 92, 240, 75, 28)
    GUICtrlSetOnEvent(-1, "__adv_stop")
    Local $idUI = GUICtrlCreateButton("Open UI", 175, 240, 90, 28)
    GUICtrlSetOnEvent(-1, "__adv_ui")
    Local $idRefresh = GUICtrlCreateButton("Refresh", 750, 240, 75, 28)
    GUICtrlSetOnEvent(-1, "__adv_refresh")
    GUISetState(@SW_SHOW)
    $g_bAdvOpen = True
    _Advanced_Refresh()
EndFunc

Func _Advanced_Close()
    If $g_hWndAdv <> -1 Then
        GUIDelete($g_hWndAdv)
        $g_hWndAdv = -1
    EndIf
    $g_bAdvOpen = False
EndFunc

Func _Advanced_Refresh()
    If $g_hWndAdv = -1 Then Return
    _GUICtrlListView_DeleteAllItems($g_hLV)
    For $i = 0 To $APP_COUNT - 1
        Local $bRunning = _IsRunning($i)
        Local $hItem = _GUICtrlListView_AddItem($g_hLV, $bRunning ? "Running" : "Stopped")
        _GUICtrlListView_AddSubItem($g_hLV, $hItem, $g_aApps[$i][0], 1)
        _GUICtrlListView_AddSubItem($g_hLV, $hItem, $g_aApps[$i][1], 2)
        _GUICtrlListView_AddSubItem($g_hLV, $hItem, $bRunning ? String($g_aPID[$i]) : "-", 3)
        _GUICtrlListView_AddSubItem($g_hLV, $hItem, $g_aApps[$i][2], 4)
    Next
EndFunc

Func __adv_start()
    Local $idx = _Advanced_SelectedIndex()
    If $idx = -1 Then Return
    _StartApp($idx)
EndFunc

Func __adv_stop()
    Local $idx = _Advanced_SelectedIndex()
    If $idx = -1 Then Return
    _StopApp($idx)
EndFunc

Func __adv_ui()
    Local $idx = _Advanced_SelectedIndex()
    If $idx = -1 Then Return
    _OpenUI($idx)
EndFunc

Func __adv_refresh()
    _Advanced_Refresh()
EndFunc

Func _Advanced_SelectedIndex()
    If $g_hLV = -1 Then Return -1
    Return _GUICtrlListView_GetSelectedIndicies($g_hLV)
EndFunc

;===============================================================================
; Command line handling for elevated operations
;===============================================================================
Func _HandleCommandLine()
    If $CmdLine[0] < 2 Then Return False
    
    Local $sCmd = $CmdLine[1]
    Local $iApp = Int($CmdLine[2])
    
    Switch $sCmd
        Case $CMD_ELEVATE_SERVICE
            _Service_Install($iApp)
            Return True
        Case $CMD_ELEVATE_TASK
            _Task_Install($iApp)
            Return True
        Case $CMD_ELEVATE_REMOVE
            _Auto_RemoveAll($iApp)
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

Local $aAuto = _Auto_Load()
If Not @error Then
    $g_iAutoMode = $aAuto
    $g_iAutoApp = @extended
EndIf

_Tray_Build()

While 1
    Local $aMsg = TrayGetMsg()
    If IsArray($aMsg) Then
        _Tray_RefreshStates()
        If $g_bAdvOpen Then _Advanced_Refresh()
    EndIf
    Sleep(50)
WEnd