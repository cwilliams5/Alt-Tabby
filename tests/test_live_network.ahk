; Live Tests - Network / I/O-bound Integration
; GitHub API, Workspace Data E2E (in-process)
; Included by test_live.ahk
#Include test_utils.ahk

RunLiveTests_Network() {
    global TestPassed, TestErrors, cfg
    global DoInvasiveTests

    ; ============================================================
    ; GitHub API Auto-Update Test
    ; ============================================================
    Log("`n--- GitHub API Auto-Update Test ---")

    ; Test that we can reach the GitHub API and parse the response
    apiUrl := "https://api.github.com/repos/cwilliams5/Alt-Tabby/releases/latest"
    Log("  Fetching: " apiUrl)

    try {
        whr := ComObject("WinHttp.WinHttpRequest.5.1")
        whr.Open("GET", apiUrl, false)
        whr.SetRequestHeader("User-Agent", "Alt-Tabby-Tests/" GetAppVersion())
        whr.Send()

        if (whr.Status = 200) {
            Log("PASS: GitHub API returned HTTP 200")
            TestPassed++

            response := whr.ResponseText

            ; Test tag_name parsing
            if (RegExMatch(response, '"tag_name"\s*:\s*"v?([^"]+)"', &tagMatch)) {
                Log("PASS: Found tag_name: v" tagMatch[1])
                TestPassed++

                ; Validate version format
                if (RegExMatch(tagMatch[1], "^\d+\.\d+\.\d+$")) {
                    Log("PASS: Version format is valid semver")
                    TestPassed++
                } else {
                    Log("FAIL: Version format invalid: " tagMatch[1])
                    TestErrors++
                }
            } else {
                Log("FAIL: Could not find tag_name in response")
                TestErrors++
            }

            ; Test download URL parsing
            downloadUrl := _Update_FindExeDownloadUrl(response)
            if (downloadUrl != "") {
                Log("PASS: Found AltTabby.exe download URL")
                TestPassed++

                ; Validate URL format
                if (InStr(downloadUrl, "github.com") && InStr(downloadUrl, "AltTabby.exe")) {
                    Log("PASS: Download URL format is valid: " SubStr(downloadUrl, 1, 60) "...")
                    TestPassed++
                } else {
                    Log("FAIL: Download URL format unexpected: " downloadUrl)
                    TestErrors++
                }

                ; Test actual download - download to temp and verify PE header
                Log("  Testing actual download...")
                tempExe := A_Temp "\AltTabby_download_test.exe"
                try {
                    dlWhr := ComObject("WinHttp.WinHttpRequest.5.1")
                    dlWhr.Open("GET", downloadUrl, false)
                    dlWhr.SetRequestHeader("User-Agent", "Alt-Tabby-Tests/" GetAppVersion())
                    dlWhr.Send()

                    if (dlWhr.Status = 200) {
                        ; Save to file
                        stream := ComObject("ADODB.Stream")
                        stream.Type := 1  ; Binary
                        stream.Open()
                        stream.Write(dlWhr.ResponseBody)
                        stream.SaveToFile(tempExe, 2)  ; Overwrite
                        stream.Close()

                        ; Verify file size is reasonable (>1MB for compiled AHK)
                        fileSize := FileGetSize(tempExe)
                        if (fileSize > 1000000) {
                            Log("PASS: Downloaded exe is valid size (" Round(fileSize / 1024 / 1024, 2) " MB)")
                            TestPassed++

                            ; Verify MZ header (PE executable)
                            f := FileOpen(tempExe, "r")
                            f.RawRead(header := Buffer(2))
                            f.Close()
                            if (NumGet(header, 0, "UChar") = 0x4D && NumGet(header, 1, "UChar") = 0x5A) {
                                Log("PASS: Downloaded exe has valid PE header (MZ)")
                                TestPassed++
                            } else {
                                Log("FAIL: Downloaded file is not a valid PE executable")
                                TestErrors++
                            }
                        } else {
                            Log("FAIL: Downloaded exe too small (" fileSize " bytes)")
                            TestErrors++
                        }

                        ; Cleanup
                        try FileDelete(tempExe)
                    } else {
                        Log("FAIL: Download returned HTTP " dlWhr.Status)
                        TestErrors++
                    }
                } catch as dlErr {
                    Log("FAIL: Download failed: " dlErr.Message)
                    TestErrors++
                }
            } else {
                Log("FAIL: Could not find AltTabby.exe download URL in release")
                TestErrors++
            }
        } else if (whr.Status = 404) {
            Log("FAIL: GitHub API returned 404 - repo may be private or release missing")
            TestErrors++
        } else {
            Log("FAIL: GitHub API returned HTTP " whr.Status)
            TestErrors++
        }
    } catch as e {
        Log("FAIL: GitHub API request failed: " e.Message)
        TestErrors++
    }

    ; ============================================================
    ; Workspace Data E2E Test (in-process via komorebic state)
    ; ============================================================
    Log("`n--- Workspace Data E2E Test ---")

    komorebicPath := cfg.KomorebicExe
    if (!FileExist(komorebicPath)) {
        Log("SKIP: Workspace E2E - komorebic.exe not found at " komorebicPath)
        return
    }

    ; Fetch komorebic state directly
    Log("  [WS E2E] Fetching komorebic state...")
    directTxt := _KSub_GetStateDirect()
    if (directTxt = "") {
        Log("SKIP: komorebic state returned empty (komorebi may not be running)")
        return
    }

    directObj := ""
    try directObj := JSON.Load(directTxt)
    if !(directObj is Map) {
        Log("SKIP: Could not parse komorebic state JSON")
        return
    }

    ; Count hwnds from komorebi state
    directHwnds := 0
    firstTestHwnd := 0
    for _, monObj in KSub_GetMonitorsArray(directObj) {
        for _, wsObj in KSub_GetWorkspacesArray(monObj) {
            if !(wsObj is Map) || !wsObj.Has("containers")
                continue
            for _, cont in KSafe_Elements(wsObj["containers"]) {
                if !(cont is Map)
                    continue
                if (cont.Has("windows")) {
                    for _, win in KSafe_Elements(cont["windows"]) {
                        if (win is Map && win.Has("hwnd")) {
                            directHwnds++
                            if (!firstTestHwnd)
                                firstTestHwnd := KSafe_Int(win, "hwnd")
                        }
                    }
                }
            }
        }
    }
    Log("  [WS E2E] Komorebi state has " directHwnds " hwnds")

    if (directHwnds = 0) {
        Log("SKIP: No windows managed by komorebi")
        return
    }

    ; Populate WindowList and enrich with workspace data from komorebi
    WL_Init()
    WL_BeginScan()
    realWindows := WinEnumLite_ScanAll()
    WL_UpsertWindow(realWindows, "winenum_lite")
    WL_EndScan()

    ; Enrich windows with workspace data extracted from komorebi state
    ; Manually iterate state and call WL_UpdateFields (mirrors _KSub_ProcessFullState)
    enrichedCount := 0
    for _, monObj in KSub_GetMonitorsArray(directObj) {
        for _, wsObj in KSub_GetWorkspacesArray(monObj) {
            if !(wsObj is Map)
                continue
            wsName := KSafe_Str(wsObj, "name")
            if (wsName = "" && wsObj.Has("containers")) {
                ; Fallback to workspace index
                wsName := "ws-" A_Index
            }
            if !wsObj.Has("containers")
                continue
            for _, cont in KSafe_Elements(wsObj["containers"]) {
                if !(cont is Map) || !cont.Has("windows")
                    continue
                for _, win in KSafe_Elements(cont["windows"]) {
                    if !(win is Map) || !win.Has("hwnd")
                        continue
                    hwnd := KSafe_Int(win, "hwnd")
                    if (hwnd > 0) {
                        WL_UpdateFields(hwnd, {workspaceName: wsName}, "ksub_test")
                        enrichedCount++
                    }
                }
            }
        }
    }
    Log("  [WS E2E] Enriched " enrichedCount " windows with workspace data")

    ; Verify workspace data flows to display list
    proj := WL_GetDisplayList({ sort: "Z", includeCloaked: true, includeMinimized: true })

    itemsWithWs := 0
    for _, item in proj.items {
        if (item.workspaceName != "")
            itemsWithWs++
    }

    Log("  Items with workspaceName: " itemsWithWs "/" proj.items.Length)

    if (itemsWithWs > 0) {
        Log("PASS: Workspace data flows through to display list (" itemsWithWs " items enriched)")
        TestPassed++
    } else {
        Log("WARN: No workspace data in display list (komorebi windows may not overlap with Alt-Tab eligible windows)")
    }

    ; Test workspace lookup for a specific hwnd
    if (firstTestHwnd > 0) {
        testWs := KSub_FindWorkspaceByHwnd(directObj, firstTestHwnd)
        if (testWs != "") {
            Log("PASS: KSub_FindWorkspaceByHwnd returned '" testWs "' for hwnd " firstTestHwnd)
            TestPassed++
        } else {
            Log("FAIL: KSub_FindWorkspaceByHwnd returned empty for komorebi-managed hwnd " firstTestHwnd)
            TestErrors++
        }
    }

    ; isCloaked field should always be present
    if (proj.items.Length > 0 && proj.items[1].HasOwnProp("isCloaked")) {
        Log("PASS: isCloaked field present in display list items")
        TestPassed++
    } else if (proj.items.Length > 0) {
        Log("FAIL: isCloaked field missing from display list items")
        TestErrors++
    }

}
