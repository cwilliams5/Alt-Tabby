#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================
; Build Config Docs - Generate docs/options.md from Registry
; ============================================================
; Reads gConfigRegistry and generates markdown documentation.
; Run this script to regenerate docs after editing config_registry.ahk.
;
; Usage: AutoHotkey64.exe build-config-docs.ahk
; ============================================================

; Include the config registry (we only need the registry, not full loader)
#Include src\shared\config_registry.ahk

Main()

Main() {
    global gConfigRegistry

    ; Ensure docs directory exists
    docsDir := A_ScriptDir "\docs"
    if (!DirExist(docsDir))
        DirCreate(docsDir)

    outPath := docsDir "\options.md"

    ; Build the markdown content
    md := BuildMarkdown()

    ; Write to file
    try {
        if (FileExist(outPath))
            FileDelete(outPath)
        FileAppend(md, outPath, "UTF-8")
        FileAppend("`n", "*")  ; stdout
        FileAppend("Generated: " outPath "`n", "*")
        FileAppend("Total settings: " CountSettings() "`n", "*")
    } catch as e {
        FileAppend("ERROR: " e.Message "`n", "*")
        ExitApp(1)
    }

    ExitApp(0)
}

BuildMarkdown() {
    global gConfigRegistry

    md := ""

    ; Header
    md .= "# Alt-Tabby Configuration Options`n`n"
    md .= "> **Auto-generated from ``config_registry.ahk``** - Do not edit manually.`n"
    md .= "> Run ``build-config-docs.ahk`` to regenerate.`n`n"
    md .= "This document lists all configuration options available in ``config.ini``.`n"
    md .= "Edit ``config.ini`` (next to AltTabby.exe) to customize behavior.`n`n"

    ; Build table of contents
    md .= "## Table of Contents`n`n"
    for _, entry in gConfigRegistry {
        if (entry.HasOwnProp("type") && entry.type = "section") {
            anchor := MakeAnchor(entry.name)
            md .= "- [" entry.name "](#" anchor ")`n"
        }
    }
    md .= "`n---`n`n"

    ; Build sections
    currentSection := ""
    currentSubsection := ""
    settingsBuffer := []  ; Collect settings to render as table

    for _, entry in gConfigRegistry {
        ; Section header
        if (entry.HasOwnProp("type") && entry.type = "section") {
            ; Flush previous section's settings
            if (settingsBuffer.Length > 0) {
                md .= RenderSettingsTable(settingsBuffer)
                settingsBuffer := []
            }

            currentSection := entry.name
            currentSubsection := ""
            md .= "## " entry.name "`n`n"
            if (entry.HasOwnProp("long") && entry.long != "")
                md .= entry.long "`n`n"
            else if (entry.HasOwnProp("desc") && entry.desc != "")
                md .= entry.desc "`n`n"
        }
        ; Subsection header
        else if (entry.HasOwnProp("type") && entry.type = "subsection") {
            ; Flush settings before new subsection
            if (settingsBuffer.Length > 0) {
                md .= RenderSettingsTable(settingsBuffer)
                settingsBuffer := []
            }

            currentSubsection := entry.name
            md .= "### " entry.name "`n`n"
            if (entry.HasOwnProp("desc") && entry.desc != "")
                md .= entry.desc "`n`n"
        }
        ; Setting entry
        else if (entry.HasOwnProp("default")) {
            settingsBuffer.Push(entry)
        }
    }

    ; Flush final settings
    if (settingsBuffer.Length > 0) {
        md .= RenderSettingsTable(settingsBuffer)
    }

    ; Footer
    md .= "---`n`n"
    md .= "*Generated on " FormatTime(, "yyyy-MM-dd") " with " CountSettings() " total settings.*`n"

    return md
}

RenderSettingsTable(settings) {
    if (settings.Length = 0)
        return ""

    md := "| Option | Type | Default | Description |`n"
    md .= "|--------|------|---------|-------------|`n"

    for _, entry in settings {
        ; INI key (what user edits)
        key := entry.k

        ; Type
        typeStr := entry.t

        ; Default value (formatted, pass key for hex detection)
        defaultStr := FormatDefault(entry.default, entry.t, entry.k)

        ; Description (escape pipes for markdown table)
        desc := StrReplace(entry.d, "|", "\|")

        md .= "| ``" key "`` | " typeStr " | ``" defaultStr "`` | " desc " |`n"
    }

    md .= "`n"
    return md
}

FormatDefault(val, type, key := "") {
    if (type = "bool")
        return val ? "true" : "false"
    if (type = "int" && IsInteger(val)) {
        ; Use hex for color values (ARGB/RGB patterns in key name)
        if (RegExMatch(key, "i)(ARGB|Rgb|Alpha)$") && val > 0)
            return Format("0x{:X}", val)
        return String(val)
    }
    if (type = "float")
        return Format("{:.2f}", val)
    if (type = "string") {
        if (val = "")
            return "(empty)"
        ; Escape backticks and truncate long strings
        val := StrReplace(val, "``", "\``")
        if (StrLen(val) > 40)
            val := SubStr(val, 1, 37) "..."
        return val
    }
    return String(val)
}

MakeAnchor(name) {
    ; Convert section name to markdown anchor
    ; "Alt-Tab Behavior" -> "alt-tab-behavior"
    anchor := StrLower(name)
    anchor := StrReplace(anchor, " ", "-")
    anchor := StrReplace(anchor, "&", "")
    anchor := RegExReplace(anchor, "[^a-z0-9\-]", "")
    return anchor
}

CountSettings() {
    global gConfigRegistry
    count := 0
    for _, entry in gConfigRegistry {
        if (entry.HasOwnProp("default"))
            count++
    }
    return count
}
