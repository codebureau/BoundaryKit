<#
    .SYNOPSIS
    End-to-end test of Apply-GpoLockdown.ps1 and Undo-GpoLockdown.ps1 against a fake
    -TargetRoot under $env:TEMP - never the real $env:WinDir. Both scripts detect
    this (Test-IsRealTargetRoot) and skip secedit.exe/gpupdate.exe entirely, so this
    test only exercises file I/O: container backup, Registry.pol generation/parsing,
    GPT.INI version bumping, the manifest, and both rollback strategies (snapshot and
    best-effort fallback).

    This is real, executed verification of the file-writing pipeline - it is NOT a
    substitute for running Apply-GpoLockdown.ps1 for real on the target PC, which is
    the only way to confirm Windows' Group Policy engine actually recognises and
    applies what these scripts write.
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
function Assert-True {
    param([bool]$Condition, [string]$Message)
    Assert-Equal -Expected $true -Actual $Condition -Message $Message
}

$scratchRoot = Join-Path $env:TEMP "boundarykit-gpotest-$([guid]::NewGuid())"
$targetRoot  = Join-Path $scratchRoot 'FakeWindows'
$backupRoot  = Join-Path $scratchRoot 'backups'
New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null

$applyScript = Join-Path $PSScriptRoot '..\Apply-GpoLockdown.ps1'
$undoScript  = Join-Path $PSScriptRoot '..\Undo-GpoLockdown.ps1'

try {
    # --- 0. Simulate the one-time manual bootstrap of the Non-Administrators ----
    #        container (Apply-GpoLockdown.ps1 must refuse to fabricate this itself).
    $nonAdminRoot = Join-Path $targetRoot 'System32\GroupPolicyUsers\S-1-5-32-545'
    New-Item -ItemType Directory -Path $nonAdminRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $nonAdminRoot 'GPT.INI') -Value @('[General]', 'Version=0') -Encoding ASCII

    $machineRoot = Join-Path $targetRoot 'System32\GroupPolicy'
    New-Item -ItemType Directory -Path $machineRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $machineRoot 'GPT.INI') -Value @('[General]', 'Version=0') -Encoding ASCII

    # --- 1. Precondition check: refuses to run without the bootstrap ------------
    $unBootstrappedRoot = Join-Path $scratchRoot 'NoBootstrap'
    New-Item -ItemType Directory -Path $unBootstrappedRoot -Force | Out-Null
    $threw = $false
    try {
        & $applyScript -TargetRoot $unBootstrappedRoot -BackupRoot (Join-Path $scratchRoot 'unused-backups') -SkipPrivileges -SkipGpUpdate -ErrorAction Stop | Out-Null
    } catch {
        $threw = $true
    }
    Assert-True $threw 'Apply-GpoLockdown.ps1 refuses to run when the Non-Administrators container has not been bootstrapped'

    # --- 2. First real (scratch) apply -------------------------------------------
    & $applyScript -TargetRoot $targetRoot -BackupRoot $backupRoot -SkipPrivileges | Out-Null

    $machinePol   = Join-Path $targetRoot 'System32\GroupPolicy\Machine\Registry.pol'
    $nonAdminPol  = Join-Path $nonAdminRoot 'User\Registry.pol'

    Assert-True (Test-Path -LiteralPath $machinePol) 'Machine Registry.pol was written'
    Assert-True (Test-Path -LiteralPath $nonAdminPol) 'Non-Administrators Registry.pol was written'

    $catalog = (Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot '..\lib\GpoSettings.psd1')).Settings
    $expectedMachineEntries  = @($catalog | Where-Object { $_.Scope -eq 'Machine' } | ForEach-Object { $_.Entries }).Count
    $expectedNonAdminEntries = @($catalog | Where-Object { $_.Scope -eq 'NonAdminUser' } | ForEach-Object { $_.Entries }).Count

    $machineParsed  = @(Read-PolEntries -Path $machinePol)
    $nonAdminParsed = @(Read-PolEntries -Path $nonAdminPol)
    Assert-Equal -Expected $expectedMachineEntries -Actual $machineParsed.Count 'Machine Registry.pol has exactly the catalog''s Machine-scope entry count'
    Assert-Equal -Expected $expectedNonAdminEntries -Actual $nonAdminParsed.Count 'Non-Administrators Registry.pol has exactly the catalog''s NonAdminUser-scope entry count'

    $disableCmd = $nonAdminParsed | Where-Object { $_.ValueName -eq 'DisableCMD' }
    Assert-Equal -Expected 2 -Actual $disableCmd.Data 'DisableCMD=2 present in the Non-Administrators container'

    $gptVersion = (Get-Content -LiteralPath (Join-Path $machineRoot 'GPT.INI') | Where-Object { $_ -match '^Version=' })
    Assert-Equal -Expected 'Version=1' -Actual $gptVersion 'Machine GPT.INI version was bumped from 0 to 1'

    $manifestPath = Get-ChildItem -LiteralPath $backupRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1 |
        ForEach-Object { Join-Path $_.FullName 'manifest.json' }
    Assert-True (Test-Path -LiteralPath $manifestPath) 'A manifest.json was written'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Assert-Equal -Expected 11 -Actual $manifest.AppliedSettingIds.Count 'Manifest records all 11 applied setting ids'
    $machineBackupEntry = $manifest.ContainerBackups | Where-Object { $_.Name -eq 'Machine' }
    Assert-Equal -Expected $false -Actual $machineBackupEntry.PolExisted 'Manifest correctly records that Machine Registry.pol did NOT exist before this first apply'

    # --- 3. Idempotent second apply: backs up its own output, doesn't error -----
    #        (Undoing once only unwinds the MOST RECENT apply - that is correct
    #        "undo the last change" semantics, not "wipe everything ever applied" -
    #        so this section runs its own apply and asserts against that apply's
    #        own manifest, rather than assuming a later full-unwind.)
    Start-Sleep -Milliseconds 1100   # ensure a distinct timestamp-named backup dir
    & $applyScript -TargetRoot $targetRoot -BackupRoot $backupRoot -SkipPrivileges | Out-Null
    $manifests = Get-ChildItem -LiteralPath $backupRoot -Directory
    Assert-True ($manifests.Count -ge 2) 'A second apply run produced a second, distinct backup'

    $secondManifestPath = $manifests | Sort-Object Name -Descending | Select-Object -First 1 | ForEach-Object { Join-Path $_.FullName 'manifest.json' }
    $secondManifest = Get-Content -LiteralPath $secondManifestPath -Raw | ConvertFrom-Json
    $secondMachineBackup = $secondManifest.ContainerBackups | Where-Object { $_.Name -eq 'Machine' }
    Assert-Equal -Expected $true -Actual $secondMachineBackup.PolExisted 'Second apply correctly records that Machine Registry.pol DID already exist (from the first apply)'

    # --- 4. Undo via snapshot restore, unwound back to "never applied" ----------
    #        One Undo call restores to right before the 2nd apply (i.e. back to
    #        what the 1st apply produced - files still exist). A second Undo call,
    #        pointed explicitly at the 1st apply's own manifest, unwinds that too,
    #        landing on the true "before anything ran" state.
    & $undoScript -TargetRoot $targetRoot -BackupRoot $backupRoot | Out-Null
    Assert-True (Test-Path -LiteralPath $machinePol) 'After one undo (of two applies), Machine Registry.pol still exists - restored to the state after the 1st apply, not wiped entirely'

    $firstManifestDir = $manifests | Sort-Object Name | Select-Object -First 1
    & $undoScript -TargetRoot $targetRoot -BackupDir $firstManifestDir.FullName | Out-Null
    Assert-True (-not (Test-Path -LiteralPath $machinePol)) 'After undoing both applies in order, Machine Registry.pol no longer exists (it did not exist before the very first apply)'
    Assert-True (-not (Test-Path -LiteralPath $nonAdminPol)) 'After undoing both applies in order, Non-Administrators Registry.pol no longer exists'

    # --- 5. Best-effort fallback rollback (-Force, simulating a lost manifest) --
    & $applyScript -TargetRoot $targetRoot -BackupRoot $backupRoot -SkipPrivileges | Out-Null
    # Simulate an unrelated, hand-added policy value already present in the file,
    # which the fallback path must NOT remove.
    $existing = @(Read-PolEntries -Path $nonAdminPol) | ForEach-Object {
        @{ KeyPath = $_.KeyPath; ValueName = $_.ValueName; Type = $(switch ($_.Type) { 4 {'DWord'} 1 {'String'} default {'Binary'} }); Data = $_.Data }
    }
    $existing += @{ KeyPath = 'Software\SomeoneElse\Unrelated'; ValueName = 'KeepMe'; Type = 'String'; Data = 'do not remove' }
    [System.IO.File]::WriteAllBytes($nonAdminPol, (ConvertTo-PolBytes -Entries $existing))

    & $undoScript -TargetRoot $targetRoot -BackupRoot $backupRoot -Force | Out-Null

    Assert-True (Test-Path -LiteralPath $nonAdminPol) 'After -Force fallback undo, Non-Administrators Registry.pol still exists (an unrelated entry remained)'
    $afterFallback = @(Read-PolEntries -Path $nonAdminPol)
    $keptUnrelated = $afterFallback | Where-Object { $_.ValueName -eq 'KeepMe' }
    Assert-True ($null -ne $keptUnrelated) 'Fallback undo preserved the unrelated hand-added entry'
    $stillHasDisableCmd = $afterFallback | Where-Object { $_.ValueName -eq 'DisableCMD' }
    Assert-True ($null -eq $stillHasDisableCmd) 'Fallback undo removed the catalog''s own DisableCMD entry'

} finally {
    Remove-Item -LiteralPath $scratchRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failures -gt 0) {
    Write-Host "$failures assertion(s) FAILED." -ForegroundColor Red
    exit 1
} else {
    Write-Host 'All Apply/Undo end-to-end assertions passed.' -ForegroundColor Green
    exit 0
}
