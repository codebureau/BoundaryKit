# PolFile.psm1
#
# Minimal, dependency-free reader/writer for the Windows "Registry.pol" file format
# (the binary file Group Policy uses to carry Administrative Template registry
# settings - both for domain GPOs and for Local Group Policy). Format reference:
# Microsoft's published [MS-GPREG] protocol document.
#
# Why hand-rolled instead of shelling out to Microsoft's LGPO.exe:
#   - No external binary to download, trust, or vendor into source control.
#   - The whole pipeline (settings catalog -> bytes on disk) is plain, reviewable
#     PowerShell, consistent with this project's "a learner will read this" rule.
#   - It can be exercised and round-trip-tested against a scratch file with nothing
#     more than PowerShell itself - no admin rights, no real Group Policy engine,
#     no machine changes. See tests/Test-PolFile.ps1.
#
# File layout:
#   4 bytes   signature "PReg" (0x50 0x52 0x65 0x67)
#   4 bytes   version, little-endian UInt32 = 1
#   then a repeated sequence of entries, each:
#     '['  (UTF-16LE, 2 bytes)
#     key path,   UTF-16LE, null-terminated
#     ';'  (UTF-16LE, 2 bytes)
#     value name, UTF-16LE, null-terminated
#     ';'
#     type,  UInt32 little-endian (1=REG_SZ, 2=REG_EXPAND_SZ, 3=REG_BINARY,
#            4=REG_DWORD, 7=REG_MULTI_SZ, 11=REG_QWORD)
#     ';'
#     size,  UInt32 little-endian - byte length of the data that follows
#     ';'
#     data,  `size` bytes, encoded per `type`
#     ']'

Set-StrictMode -Version Latest

$script:PolSignature = [byte[]](0x50, 0x52, 0x65, 0x67)   # ASCII "PReg"
$script:PolVersion    = [byte[]](0x01, 0x00, 0x00, 0x00)  # version 1, little-endian

$script:RegTypeMap = @{
    'String'       = 1   # REG_SZ
    'ExpandString' = 2   # REG_EXPAND_SZ
    'Binary'       = 3   # REG_BINARY
    'DWord'        = 4   # REG_DWORD
    'MultiString'  = 7   # REG_MULTI_SZ
    'QWord'        = 11  # REG_QWORD
}

function ConvertTo-PolValueBytes {
    <#
        .SYNOPSIS
        Encodes one registry value's data the way PReg expects it, for a given type.
    #>
    param(
        [Parameter(Mandatory)] [string]$Type,
        [Parameter(Mandatory)] [AllowEmptyString()] $Data
    )

    switch ($Type) {
        'DWord' { return [BitConverter]::GetBytes([uint32]$Data) }
        'QWord' { return [BitConverter]::GetBytes([uint64]$Data) }
        'String' { return [System.Text.Encoding]::Unicode.GetBytes([string]$Data + "`0") }
        'ExpandString' { return [System.Text.Encoding]::Unicode.GetBytes([string]$Data + "`0") }
        'MultiString' {
            $bytes = [System.Collections.Generic.List[byte]]::new()
            foreach ($s in [string[]]$Data) {
                $bytes.AddRange([System.Text.Encoding]::Unicode.GetBytes([string]$s + "`0"))
            }
            $bytes.AddRange([System.Text.Encoding]::Unicode.GetBytes("`0"))
            return $bytes.ToArray()
        }
        'Binary' { return [byte[]]$Data }
        default { throw "Unsupported registry value type '$Type'." }
    }
}

function ConvertTo-PolBytes {
    <#
        .SYNOPSIS
        Builds the full byte content of a Registry.pol file from a list of entries.

        .PARAMETER Entries
        Array of hashtables/objects with KeyPath, ValueName, Type, Data.
    #>
    param(
        [Parameter(Mandatory)] [array]$Entries
    )

    $enc = [System.Text.Encoding]::Unicode
    $ob  = $enc.GetBytes('[')
    $sep = $enc.GetBytes(';')
    $cb  = $enc.GetBytes(']')

    $out = [System.Collections.Generic.List[byte]]::new()
    $out.AddRange([byte[]]$script:PolSignature)
    $out.AddRange([byte[]]$script:PolVersion)

    foreach ($e in $Entries) {
        if (-not $script:RegTypeMap.ContainsKey($e.Type)) {
            throw "Unknown Type '$($e.Type)' for value '$($e.ValueName)' under '$($e.KeyPath)'."
        }
        $typeNum    = $script:RegTypeMap[$e.Type]
        $valueBytes = ConvertTo-PolValueBytes -Type $e.Type -Data $e.Data

        $out.AddRange([byte[]]$ob)
        $out.AddRange([byte[]]$enc.GetBytes($e.KeyPath + "`0"))
        $out.AddRange([byte[]]$sep)
        $out.AddRange([byte[]]$enc.GetBytes($e.ValueName + "`0"))
        $out.AddRange([byte[]]$sep)
        $out.AddRange([byte[]][BitConverter]::GetBytes([uint32]$typeNum))
        $out.AddRange([byte[]]$sep)
        $out.AddRange([byte[]][BitConverter]::GetBytes([uint32]$valueBytes.Length))
        $out.AddRange([byte[]]$sep)
        $out.AddRange([byte[]]$valueBytes)
        $out.AddRange([byte[]]$cb)
    }

    return $out.ToArray()
}

function Read-PolNullTerminatedString {
    # Reads a UTF-16LE, null-terminated string starting at $Bytes[$Position.Value];
    # advances $Position past the terminator.
    param(
        [Parameter(Mandatory)] [byte[]]$Bytes,
        [Parameter(Mandatory)] [ref]$Position
    )
    $enc   = [System.Text.Encoding]::Unicode
    $start = $Position.Value
    $p     = $start
    while (-not ($Bytes[$p] -eq 0x00 -and $Bytes[$p + 1] -eq 0x00)) { $p += 2 }
    $str = $enc.GetString($Bytes, $start, $p - $start)
    $Position.Value = $p + 2
    return $str
}

function ConvertFrom-PolValueBytes {
    # Decodes raw data bytes back into a native value, per REG_* type number.
    param(
        [Parameter(Mandatory)] [uint32]$Type,
        [Parameter(Mandatory)] [byte[]]$Data
    )
    switch ($Type) {
        4  { return [BitConverter]::ToUInt32($Data, 0) }                       # REG_DWORD
        11 { return [BitConverter]::ToUInt64($Data, 0) }                       # REG_QWORD
        1  { return ([System.Text.Encoding]::Unicode.GetString($Data)).TrimEnd("`0") }  # REG_SZ
        2  { return ([System.Text.Encoding]::Unicode.GetString($Data)).TrimEnd("`0") }  # REG_EXPAND_SZ
        7  {
            $s = [System.Text.Encoding]::Unicode.GetString($Data)
            return ($s -split "`0") | Where-Object { $_ -ne '' }               # REG_MULTI_SZ
        }
        default { return $Data }                                              # REG_BINARY / unknown
    }
}

function Read-PolEntries {
    <#
        .SYNOPSIS
        Parses an existing Registry.pol file back into entries with decoded values.
        Used for round-trip tests and to confirm exactly what a backup file contains
        before it is restored.
    #>
    param(
        [Parameter(Mandatory)] [string]$Path
    )

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 8 -or
        -not ($bytes[0] -eq 0x50 -and $bytes[1] -eq 0x52 -and $bytes[2] -eq 0x65 -and $bytes[3] -eq 0x67)) {
        throw "'$Path' is not a valid Registry.pol file (bad signature)."
    }
    $version = [BitConverter]::ToUInt32($bytes, 4)
    if ($version -ne 1) {
        throw "'$Path' has unsupported Registry.pol version $version (expected 1)."
    }

    $pos = 8
    $entries = [System.Collections.Generic.List[object]]::new()

    while ($pos -lt $bytes.Length) {
        if (-not ($bytes[$pos] -eq 0x5B -and $bytes[$pos + 1] -eq 0x00)) {
            throw "Malformed Registry.pol at offset $pos (expected '[')."
        }
        $pos += 2

        $keyPath = Read-PolNullTerminatedString -Bytes $bytes -Position ([ref]$pos)
        $pos += 2  # ';'
        $valueName = Read-PolNullTerminatedString -Bytes $bytes -Position ([ref]$pos)
        $pos += 2  # ';'
        $type = [BitConverter]::ToUInt32($bytes, $pos); $pos += 4
        $pos += 2  # ';'
        $size = [BitConverter]::ToUInt32($bytes, $pos); $pos += 4
        $pos += 2  # ';'

        if ($size -eq 0) {
            $data = [byte[]]@()
        } else {
            $data = $bytes[$pos..($pos + $size - 1)]
        }
        $pos += [int]$size
        $pos += 2  # ']'

        $entries.Add([pscustomobject]@{
            KeyPath   = $keyPath
            ValueName = $valueName
            Type      = $type
            Size      = $size
            Data      = ConvertFrom-PolValueBytes -Type $type -Data $data
        })
    }

    return $entries.ToArray()
}

Export-ModuleMember -Function ConvertTo-PolBytes, Read-PolEntries, ConvertTo-PolValueBytes, ConvertFrom-PolValueBytes
