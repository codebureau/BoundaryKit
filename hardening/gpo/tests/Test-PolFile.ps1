<#
    .SYNOPSIS
    Round-trip tests for lib\PolFile.psm1 - the only part of this feature that
    encodes a binary Windows file format by hand, so it's the part most worth
    verifying byte-for-byte rather than just by reading the code.

    Runs entirely against a scratch temp file. Touches no registry, no real Windows
    directory, no admin rights required.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\lib\PolFile.psm1') -Force

$failures = 0
function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ("$Expected" -ne "$Actual") {
        Write-Host "FAIL: $Message (expected '$Expected', got '$Actual')" -ForegroundColor Red
        $script:failures++
    } else {
        Write-Host "PASS: $Message" -ForegroundColor Green
    }
}

$scratch = Join-Path $env:TEMP "boundarykit-poltest-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
$polPath = Join-Path $scratch 'Registry.pol'

try {
    # --- 1. Basic round-trip: DWord + String -----------------------------------
    $entries = @(
        @{ KeyPath = 'Software\Policies\Microsoft\Windows\System'; ValueName = 'DisableCMD'; Type = 'DWord'; Data = 2 }
        @{ KeyPath = 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\DisallowCpl'; ValueName = '1'; Type = 'String'; Data = 'Microsoft.UserAccounts' }
    )
    $bytes = ConvertTo-PolBytes -Entries $entries
    [System.IO.File]::WriteAllBytes($polPath, $bytes)

    $raw = [System.IO.File]::ReadAllBytes($polPath)
    Assert-Equal -Expected 'P' -Actual ([char]$raw[0]) -Message 'Signature byte 0 is P'
    Assert-Equal -Expected 'R' -Actual ([char]$raw[1]) -Message 'Signature byte 1 is R'
    Assert-Equal -Expected 'e' -Actual ([char]$raw[2]) -Message 'Signature byte 2 is e'
    Assert-Equal -Expected 'g' -Actual ([char]$raw[3]) -Message 'Signature byte 3 is g'
    Assert-Equal -Expected 1 -Actual ([BitConverter]::ToUInt32($raw, 4)) -Message 'Version DWORD is 1'

    $parsed = @(Read-PolEntries -Path $polPath)
    Assert-Equal -Expected 2 -Actual $parsed.Count -Message 'Round-trip parses back 2 entries'
    Assert-Equal -Expected 'Software\Policies\Microsoft\Windows\System' -Actual $parsed[0].KeyPath -Message 'Entry 0 KeyPath round-trips'
    Assert-Equal -Expected 'DisableCMD' -Actual $parsed[0].ValueName -Message 'Entry 0 ValueName round-trips'
    Assert-Equal -Expected 4 -Actual $parsed[0].Type -Message 'Entry 0 Type is REG_DWORD (4)'
    Assert-Equal -Expected 2 -Actual $parsed[0].Data -Message 'Entry 0 DWord data round-trips as 2'
    Assert-Equal -Expected 'Microsoft.UserAccounts' -Actual $parsed[1].Data -Message 'Entry 1 String data round-trips'

    # --- 2. Empty-string / zero-length edge case --------------------------------
    $emptyEntries = @(
        @{ KeyPath = 'Software\Test'; ValueName = 'EmptyString'; Type = 'String'; Data = '' }
    )
    $emptyBytes = ConvertTo-PolBytes -Entries $emptyEntries
    $emptyPath = Join-Path $scratch 'Empty.pol'
    [System.IO.File]::WriteAllBytes($emptyPath, $emptyBytes)
    $emptyParsed = @(Read-PolEntries -Path $emptyPath)
    Assert-Equal -Expected 1 -Actual $emptyParsed.Count -Message 'Zero-length-adjacent entry (empty string) round-trips without corrupting the stream'
    Assert-Equal -Expected '' -Actual $emptyParsed[0].Data -Message 'Empty string decodes back to empty string'

    # --- 3. Bad signature is rejected, not silently accepted --------------------
    $badPath = Join-Path $scratch 'Bad.pol'
    [System.IO.File]::WriteAllBytes($badPath, [byte[]](0x00, 0x01, 0x02, 0x03, 0x01, 0x00, 0x00, 0x00))
    $threw = $false
    try { Read-PolEntries -Path $badPath | Out-Null } catch { $threw = $true }
    Assert-Equal -Expected $true -Actual $threw -Message 'A file with a bad signature is rejected'

    # --- 4. The real settings catalog round-trips end-to-end, per scope ---------
    $catalog = (Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot '..\lib\GpoSettings.psd1')).Settings
    foreach ($scope in @('Machine', 'NonAdminUser')) {
        $scopeEntries = $catalog | Where-Object { $_.Scope -eq $scope } | ForEach-Object { $_.Entries }
        if (@($scopeEntries).Count -eq 0) { continue }

        $scopeBytes = ConvertTo-PolBytes -Entries $scopeEntries
        $scopePath = Join-Path $scratch "Catalog-$scope.pol"
        [System.IO.File]::WriteAllBytes($scopePath, $scopeBytes)
        $scopeParsed = @(Read-PolEntries -Path $scopePath)

        Assert-Equal -Expected (@($scopeEntries).Count) -Actual $scopeParsed.Count -Message "Full '$scope' catalog round-trips with the same entry count"
    }

    # Spot-check two specific known values decode correctly out of the real catalog
    $cmdSetting = $catalog | Where-Object { $_.Id -eq 'GPO-23a' }
    $cmdBytes = ConvertTo-PolBytes -Entries $cmdSetting.Entries
    $cmdPath = Join-Path $scratch 'Cmd.pol'
    [System.IO.File]::WriteAllBytes($cmdPath, $cmdBytes)
    $cmdParsed = @(Read-PolEntries -Path $cmdPath)
    Assert-Equal -Expected 2 -Actual $cmdParsed[0].Data -Message 'GPO-23a (DisableCMD) decodes back to value 2'

    $storeSetting = $catalog | Where-Object { $_.Id -eq 'GPO-26a' }
    $storeBytes = ConvertTo-PolBytes -Entries $storeSetting.Entries
    $storePath = Join-Path $scratch 'Store.pol'
    [System.IO.File]::WriteAllBytes($storePath, $storeBytes)
    $storeParsed = @(Read-PolEntries -Path $storePath)
    Assert-Equal -Expected 'RemoveWindowsStore' -Actual $storeParsed[0].ValueName -Message 'GPO-26a ValueName decodes back correctly'

} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failures -gt 0) {
    Write-Host "$failures assertion(s) FAILED." -ForegroundColor Red
    exit 1
} else {
    Write-Host 'All PolFile assertions passed.' -ForegroundColor Green
    exit 0
}
