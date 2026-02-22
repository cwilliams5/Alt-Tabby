#Requires AutoHotkey v2.0
; file_watcher.ahk — File-level watcher using DirectoryWatcher.ahk
; Watches a single file for changes with debouncing.
; Handles: direct writes (Notepad), atomic temp+rename (VS Code), rapid saves.

FileWatch_Start(filePath, callback, debounceMs := 300) {
    SplitPath(filePath, &fileName, &dirPath)
    debounceFn := callback.Bind(filePath)
    w := {
        filePath: filePath,
        fileName: fileName,
        callback: callback,
        debounceMs: debounceMs,
        _debounceFn: debounceFn
    }
    ; Watch directory for file writes and renames (atomic save pattern)
    ; 0x19 = FILE_NAME (0x1) | SIZE (0x8) | LAST_WRITE (0x10)
    try {
        w._dirWatcher := DirectoryWatcher(dirPath, _FileWatch_OnChange.Bind(w), 0x19)
    } catch as e {
        ; Parent directory doesn't exist or access denied — continue without watching
        return w
    }
    w.DefineProp("Stop", { call: _FileWatch_Stop })
    return w
}

_FileWatch_OnChange(w, dw, notify) { ; lint-ignore: dead-param
    ; Filter: only care about our target file
    if (notify.name != w.fileName) {
        ; Also catch RENAMED where our file is the new name
        if (notify.action != "RENAMED" || notify.name != w.fileName)
            return
    }
    ; Reset debounce timer — fires after last event settles
    SetTimer(w._debounceFn, -w.debounceMs)
}

_FileWatch_Stop(w, *) {
    SetTimer(w._debounceFn, 0)
    if (w.HasOwnProp("_dirWatcher"))
        w._dirWatcher.Stop()
}
