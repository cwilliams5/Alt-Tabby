$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$objPath = Join-Path $scriptDir "icon_alpha_mcode.obj"

# Parse COFF .obj to find all .text$mn sections and extract raw code bytes
$bytes = [System.IO.File]::ReadAllBytes($objPath)

$machine = [BitConverter]::ToUInt16($bytes, 0)
$numSections = [BitConverter]::ToUInt16($bytes, 2)
$symTableOffset = [BitConverter]::ToUInt32($bytes, 8)
$numSymbols = [BitConverter]::ToUInt32($bytes, 12)
$optHeaderSize = [BitConverter]::ToUInt16($bytes, 16)

Write-Host "Machine: 0x$($machine.ToString('X4')), Sections: $numSections, Symbols: $numSymbols"

$sectionStart = 20 + $optHeaderSize
$strTableOffset = $symTableOffset + ($numSymbols * 18)

function Get-SectionName($offset) {
    $nameBytes = $bytes[$offset..($offset+7)]
    if ($nameBytes[0] -eq 0x2F) {
        $strOffset = [int]::Parse([System.Text.Encoding]::ASCII.GetString($nameBytes[1..7]).TrimEnd("`0").Trim())
        $end = $strTableOffset + $strOffset
        while ($bytes[$end] -ne 0) { $end++ }
        return [System.Text.Encoding]::ASCII.GetString($bytes, $strTableOffset + $strOffset, $end - $strTableOffset - $strOffset)
    }
    return [System.Text.Encoding]::ASCII.GetString($nameBytes).TrimEnd("`0")
}

# Find ALL .text$mn sections (COMDAT: one per function)
$textSections = @()
for ($i = 0; $i -lt $numSections; $i++) {
    $secOffset = $sectionStart + ($i * 40)
    $name = Get-SectionName $secOffset
    $rawDataOffset = [BitConverter]::ToUInt32($bytes, $secOffset + 20)
    $rawDataSize = [BitConverter]::ToUInt32($bytes, $secOffset + 16)
    $flags = [BitConverter]::ToUInt32($bytes, $secOffset + 36)

    Write-Host ("  Section {0}: name='{1}' rawSize=0x{2:X} rawOffset=0x{3:X} flags=0x{4:X}" -f $i, $name, $rawDataSize, $rawDataOffset, $flags)

    if ($name -eq ".text`$mn") {
        $textSections += @{
            Index = $i
            Offset = $rawDataOffset
            Size = $rawDataSize
        }
    }
}

Write-Host "`nFound $($textSections.Count) .text`$mn sections"

# Concatenate all code bytes (functions in order: icon_scan_alpha_only, icon_scan_and_apply_mask)
$totalSize = 0
foreach ($sec in $textSections) { $totalSize += $sec.Size }

$allCode = New-Object byte[] $totalSize
$pos = 0
$funcOffsets = @()
foreach ($sec in $textSections) {
    $funcOffsets += $pos
    Write-Host ("  Copying section at obj offset 0x{0:X}, size 0x{1:X} -> code offset 0x{2:X}" -f $sec.Offset, $sec.Size, $pos)
    [Array]::Copy($bytes, $sec.Offset, $allCode, $pos, $sec.Size)
    $pos += $sec.Size
}

Write-Host "`nTotal code size: $totalSize bytes (0x$($totalSize.ToString('X')))"
Write-Host "Function 1 (icon_scan_alpha_only):    offset $($funcOffsets[0]) (0x$($funcOffsets[0].ToString('X3')))"
if ($funcOffsets.Count -gt 1) {
    Write-Host "Function 2 (icon_scan_and_apply_mask): offset $($funcOffsets[1]) (0x$($funcOffsets[1].ToString('X3')))"
}

# Base64 of raw code
$b64 = [Convert]::ToBase64String($allCode)
Write-Host "`nRaw base64 ($($b64.Length) chars):"
Write-Host $b64

# LZNT1 compress + base64
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class NtDll2 {
    [DllImport("ntdll.dll")]
    public static extern int RtlCompressBuffer(
        ushort CompressionFormatAndEngine,
        byte[] UncompressedBuffer, int UncompressedBufferSize,
        byte[] CompressedBuffer, int CompressedBufferSize,
        int UncompressedChunkSize,
        out int FinalCompressedSize,
        IntPtr WorkSpace);

    [DllImport("ntdll.dll")]
    public static extern int RtlGetCompressionWorkSpaceSize(
        ushort CompressionFormatAndEngine,
        out int CompressBufferWorkSpaceSize,
        out int CompressFragmentWorkSpaceSize);
}
"@ -ErrorAction SilentlyContinue

$wsSize = 0
$fragSize = 0
[NtDll2]::RtlGetCompressionWorkSpaceSize(0x0102, [ref]$wsSize, [ref]$fragSize) | Out-Null
$ws = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($wsSize)

$compBuf = New-Object byte[] ($totalSize * 2)
$compSize = 0

$r = [NtDll2]::RtlCompressBuffer(0x0102, $allCode, $totalSize, $compBuf, $compBuf.Length, 4096, [ref]$compSize, $ws)
[System.Runtime.InteropServices.Marshal]::FreeHGlobal($ws)

if ($r -eq 0) {
    $compressedBytes = New-Object byte[] $compSize
    [Array]::Copy($compBuf, $compressedBytes, $compSize)
    $compB64 = [Convert]::ToBase64String($compressedBytes)
    Write-Host "`nLZNT1 compressed: $totalSize -> $compSize bytes"
    Write-Host "Compressed base64 ($($compB64.Length) chars):"
    Write-Host $compB64
} else {
    Write-Host "LZNT1 compression failed: 0x$($r.ToString('X8'))"
    Write-Host "(For 307 bytes, just use raw base64 above)"
}
