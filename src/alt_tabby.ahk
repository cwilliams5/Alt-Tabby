#Requires AutoHotkey v2.0
#SingleInstance Off  ; Multiple instances allowed for multi-process

;@Ahk2Exe-Base C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe

; ============================================================
; Alt-Tabby - Unified Launcher & Mode Router
; ============================================================
; Usage:
;   alt_tabby.exe             - Launch GUI + Store (default)
;   alt_tabby.exe --store     - Run as WindowStore server
;   alt_tabby.exe --viewer    - Run as Debug Viewer
;   alt_tabby.exe --gui-only  - Run as GUI only (store must be running)
;
; IMPORTANT: Mode flag is set BEFORE includes. Each module checks
; this flag and only initializes if it matches.
; ============================================================

; ============================================================
; MODE FLAG - SET BEFORE ANY INCLUDES!
; ============================================================
global g_AltTabbyMode := "launch"

for _, arg in A_Args {
    switch StrLower(arg) {
        case "--store":
            g_AltTabbyMode := "store"
            A_IconHidden := true  ; Hide tray icon IMMEDIATELY to minimize flicker
        case "--viewer":
            g_AltTabbyMode := "viewer"
            A_IconHidden := true
        case "--gui-only":
            g_AltTabbyMode := "gui"
            A_IconHidden := true
    }
}

; Launcher mode: stay alive and manage subprocesses
if (g_AltTabbyMode = "launch") {
    global g_StorePID := 0
    global g_GuiPID := 0
    global g_ViewerPID := 0

    ; Set up tray with on-demand menu updates
    SetupLauncherTray()
    OnMessage(0x404, TrayIconClick)  ; WM_TRAYICON

    ; Launch store and GUI
    LaunchStore()
    Sleep(300)
    LaunchGui()

    ; Stay alive to manage subprocesses
    Persistent()
}

; Note: Subprocess tray icon hiding is done immediately in arg parsing above
; to minimize flicker (A_IconHidden := true set as soon as mode detected)

; ============================================================
; INCLUDES
; ============================================================
; Use #Include <Dir> to set the include base directory before
; including each module, so relative paths resolve correctly.

; Shared libraries (from src/shared/)
#Include %A_ScriptDir%\shared\
#Include config.ahk
#Include config_loader.ahk
#Include json.ahk
#Include ipc_pipe.ahk
#Include blacklist.ahk

; Store module (from src/store/)
#Include %A_ScriptDir%\store\
#Include windowstore.ahk
#Include winenum_lite.ahk
#Include mru_lite.ahk
#Include komorebi_lite.ahk
#Include komorebi_sub.ahk
#Include icon_pump.ahk
#Include proc_pump.ahk
#Include winevent_hook.ahk
#Include store_server.ahk

; Viewer module (from src/viewer/)
#Include %A_ScriptDir%\viewer\
#Include viewer.ahk

; GUI module (from src/gui/)
; Note: GUI settings are now in shared/config.ahk
#Include %A_ScriptDir%\gui\
#Include gui_gdip.ahk
#Include gui_win.ahk
#Include gui_overlay.ahk
#Include gui_workspace.ahk
#Include gui_paint.ahk
#Include gui_input.ahk
#Include gui_store.ahk
#Include gui_state.ahk
#Include gui_interceptor.ahk
#Include gui_main.ahk

; ============================================================
; LAUNCHER FUNCTIONS
; ============================================================

LaunchStore() {
    global g_StorePID
    if (A_IsCompiled) {
        Run('"' A_ScriptFullPath '" --store', , , &g_StorePID)
    } else {
        Run('"' A_AhkPath '" "' A_ScriptDir '\store\store_server.ahk"', , , &g_StorePID)
    }
}

LaunchGui() {
    global g_GuiPID
    if (A_IsCompiled) {
        Run('"' A_ScriptFullPath '" --gui-only', , , &g_GuiPID)
    } else {
        Run('"' A_AhkPath '" "' A_ScriptDir '\gui\gui_main.ahk"', , , &g_GuiPID)
    }
}

LaunchViewer() {
    global g_ViewerPID
    if (A_IsCompiled) {
        Run('"' A_ScriptFullPath '" --viewer', , , &g_ViewerPID)
    } else {
        Run('"' A_AhkPath '" "' A_ScriptDir '\viewer\viewer.ahk"', , , &g_ViewerPID)
    }
}

; ============================================================
; TRAY MENU (ON-DEMAND UPDATES)
; ============================================================

TrayIconClick(wParam, lParam, msg, hwnd) {
    ; 0x205 = WM_RBUTTONUP (right-click release)
    if (lParam = 0x205) {
        UpdateTrayMenu()
        A_TrayMenu.Show()  ; Must explicitly show the menu
        return 1  ; Prevent default handling (we showed it ourselves)
    }
    return 0  ; Let default handling continue for other events
}

SetupLauncherTray() {
    TraySetIcon("shell32.dll", 15)
    A_IconTip := "Alt-Tabby"
    UpdateTrayMenu()
}

UpdateTrayMenu() {
    global g_StorePID, g_GuiPID, g_ViewerPID

    tray := A_TrayMenu
    tray.Delete()

    ; Header
    tray.Add("Alt-Tabby", (*) => 0)
    tray.Disable("Alt-Tabby")
    tray.Add()

    ; Store status
    storeRunning := g_StorePID && ProcessExist(g_StorePID)
    if (storeRunning) {
        tray.Add("Store: Restart", (*) => RestartStore())
    } else {
        tray.Add("Store: Launch", (*) => LaunchStore())
    }

    ; GUI status
    guiRunning := g_GuiPID && ProcessExist(g_GuiPID)
    if (guiRunning) {
        tray.Add("GUI: Restart", (*) => RestartGui())
    } else {
        tray.Add("GUI: Launch", (*) => LaunchGui())
    }

    ; Viewer status (optional, launch from menu)
    viewerRunning := g_ViewerPID && ProcessExist(g_ViewerPID)
    if (viewerRunning) {
        tray.Add("Viewer: Restart", (*) => RestartViewer())
    } else {
        tray.Add("Viewer: Launch", (*) => LaunchViewer())
    }

    tray.Add()

    ; Restart option (only if something is running)
    if (storeRunning || guiRunning || viewerRunning) {
        tray.Add("Restart All", (*) => RestartAll())
        tray.Add()
    }

    tray.Add("Exit", (*) => ExitAll())
}

RestartStore() {
    global g_StorePID
    if (g_StorePID && ProcessExist(g_StorePID))
        ProcessClose(g_StorePID)
    g_StorePID := 0
    Sleep(300)
    LaunchStore()
}

RestartGui() {
    global g_GuiPID
    if (g_GuiPID && ProcessExist(g_GuiPID))
        ProcessClose(g_GuiPID)
    g_GuiPID := 0
    Sleep(300)
    LaunchGui()
}

RestartViewer() {
    global g_ViewerPID
    if (g_ViewerPID && ProcessExist(g_ViewerPID))
        ProcessClose(g_ViewerPID)
    g_ViewerPID := 0
    Sleep(300)
    LaunchViewer()
}

RestartAll() {
    global g_StorePID, g_GuiPID, g_ViewerPID

    ; Kill existing processes
    if (g_StorePID && ProcessExist(g_StorePID))
        ProcessClose(g_StorePID)
    if (g_GuiPID && ProcessExist(g_GuiPID))
        ProcessClose(g_GuiPID)
    if (g_ViewerPID && ProcessExist(g_ViewerPID))
        ProcessClose(g_ViewerPID)

    g_StorePID := 0
    g_GuiPID := 0
    g_ViewerPID := 0

    Sleep(500)

    ; Relaunch core processes
    LaunchStore()
    Sleep(300)
    LaunchGui()
}

ExitAll() {
    global g_StorePID, g_GuiPID, g_ViewerPID

    ; Kill all subprocesses
    if (g_StorePID && ProcessExist(g_StorePID))
        ProcessClose(g_StorePID)
    if (g_GuiPID && ProcessExist(g_GuiPID))
        ProcessClose(g_GuiPID)
    if (g_ViewerPID && ProcessExist(g_ViewerPID))
        ProcessClose(g_ViewerPID)

    ExitApp()
}
