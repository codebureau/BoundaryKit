<#
    .SYNOPSIS
    Rolls back BoundaryKit's Local Group Policy lockdown (see Apply-GpoLockdown.ps1).

    .DESCRIPTION
    Two rollback strategies, tried in this order:

      1. Snapshot restore (preferred, used whenever a manifest is available). Restores
         the exact Registry.pol/GPT.INI bytes that existed immediately before the
         matching Apply-GpoLockdown.ps1 run, and restores the full pre-apply User
         Rights Assignment export via secedit. This is a real, exact undo - not just
         "delete what we think we added" - and is the reason Apply-GpoLockdown.ps1
         always backs up first.

      2. Best-effort targeted removal (fallback, used only with -Force or when no
         manifest can be found). Removes exactly the registry values listed in
         lib\GpoSettings.psd1 from each container's current Registry.pol, leaving any
         other entries in that file untouched, then leaves User Rights Assignment
         alone (there is no safe generic way to "subtract" a privilege change without
         a snapshot - see the warning this mode prints).

    In both cases, the parent admin account was never the one being restricted by
    these NonAdminUser-scope settings in the first place; this script exists for the
    Machine-scope settings (Store, SmartScreen, PowerShell execution policy) and for
    undoing the lockdown for the child account, or recovering from a mistake.

    .PARAMETER TargetRoot
    Root to treat as "the Windows directory". Defaults to the real $env:WinDir.

    .PARAMETER BackupDir
    A specific backup directory (as created by Apply-GpoLockdown.ps1) to restore
    from. Defaults to the most recent one under -BackupRoot.

    .PARAMETER BackupRoot
    Where Apply-GpoLockdown.ps1's backups live. Defaults to hardening\gpo\backups.

    .PARAMETER Force
    Use the best-effort targeted-removal fallback even if a manifest is available.
    Required (in place of a manifest) if no backup can be found at all.

    .EXAMPLE
    .\Undo-GpoLockdown.ps1 -WhatIf

    .EXAMPLE
    .\Undo-GpoLockdown.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$TargetRoot = $env:WinDir,
    [string]$BackupDir,
    [string]$BackupRoot = (Join-Path $PSScriptRoot 'backups'),
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib\PolFile.psm1') -Force
. (Join-Path $PSScriptRoot 'lib\GpoLockdown.Common.ps1')

$paths     = Get-GpoContainerPaths -TargetRoot $TargetRoot
$isRealRun = Test-IsRealTargetRoot -TargetRoot $TargetRoot

function Restore-Container {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [pscustomobject]$Backup,
        [Parameter(Mandatory)] [string]$PolPath,
        [Parameter(Mandatory)] [string]$PolDir,
        [Parameter(Mandatory)] [string]$GptIniPath
    )

    if ($Backup.PolExisted) {
        if ($PSCmdlet.ShouldProcess($PolPath, 'Restore Registry.pol from backup')) {
            New-Item -ItemType Directory -Path $PolDir -Force | Out-Null
            Copy-Item -LiteralPath $Backup.PolBackupPath -Destination $PolPath -Force
        }
    } elseif (Test-Path -LiteralPath $PolPath) {
        if ($PSCmdlet.ShouldProcess($PolPath, 'Remove Registry.pol (did not exist before Apply-GpoLockdown.ps1 ran)')) {
            Remove-Item -LiteralPath $PolPath -Force
        }
    }

    if ($Backup.GptIniExisted) {
        if ($PSCmdlet.ShouldProcess($GptIniPath, 'Restore GPT.INI from backup')) {
            Copy-Item -LiteralPath $Backup.GptIniBackupPath -Destination $GptIniPath -Force
        }
    }
}

function Remove-CatalogEntriesFromContainer {
    <#
        .SYNOPSIS
        Best-effort fallback: rewrites a container's Registry.pol with every entry
        that matches (KeyPath, ValueName) in lib\GpoSettings.psd1 removed, leaving
        any other entries already in that file untouched.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$PolPath,
        [Parameter(Mandatory)] [array]$CatalogEntries
    )

    if (-not (Test-Path -LiteralPath $PolPath)) {
        Write-Verbose "$PolPath does not exist - nothing to remove."
        return
    }

    $existing = Read-PolEntries -Path $PolPath
    $toRemove = $CatalogEntries | ForEach-Object { "$($_.KeyPath)|$($_.ValueName)" }
    $keep = $existing | Where-Object { "$($_.KeyPath)|$($_.ValueName)" -notin $toRemove }

    $removedCount = @($existing).Count - @($keep).Count
    Write-Host "  $PolPath - removing $removedCount of $(@($existing).Count) entries, keeping $(@($keep).Count) unrelated entries."

    if ($PSCmdlet.ShouldProcess($PolPath, "Rewrite Registry.pol without this catalog's $removedCount entries")) {
        if (@($keep).Count -eq 0) {
            Remove-Item -LiteralPath $PolPath -Force
        } else {
            $entries = $keep | ForEach-Object {
                @{ KeyPath = $_.KeyPath; ValueName = $_.ValueName; Type = $(
                        switch ($_.Type) { 4 { 'DWord' } 11 { 'QWord' } 1 { 'String' } 2 { 'ExpandString' } 7 { 'MultiString' } default { 'Binary' }
                    }); Data = $_.Data }
            }
            $bytes = ConvertTo-PolBytes -Entries $entries
            [System.IO.File]::WriteAllBytes($PolPath, $bytes)
        }
    }
}

# --- Locate a manifest, unless -Force says to skip straight to best-effort mode ----

$manifestPath = $null
if (-not $Force) {
    if ($BackupDir) {
        $candidate = Join-Path $BackupDir 'manifest.json'
        if (Test-Path -LiteralPath $candidate) { $manifestPath = $candidate }
    } else {
        $manifestPath = Get-LatestManifest -BackupRoot $BackupRoot
    }
}

if ($manifestPath) {
    Write-Host "Restoring from snapshot: $manifestPath"
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

    $machineBackup    = $manifest.ContainerBackups | Where-Object { $_.Name -eq 'Machine' }
    $nonAdminBackup   = $manifest.ContainerBackups | Where-Object { $_.Name -eq 'NonAdminUser' }

    if ($machineBackup) {
        Restore-Container -Backup $machineBackup -PolPath $paths.MachinePolPath -PolDir $paths.MachinePolDir -GptIniPath $paths.MachineGptIni
    }
    if ($nonAdminBackup) {
        Restore-Container -Backup $nonAdminBackup -PolPath $paths.NonAdminPolPath -PolDir $paths.NonAdminPolDir -GptIniPath $paths.NonAdminGptIni
    }

    if ($manifest.PrivilegeChanges -and @($manifest.PrivilegeChanges).Count -gt 0) {
        $backupInfDir = Split-Path -Parent $manifestPath
        $beforeInf = Join-Path $backupInfDir 'secedit-before.inf'
        if (Test-Path -LiteralPath $beforeInf) {
            if ($isRealRun) {
                if ($PSCmdlet.ShouldProcess('Local Security Policy (User Rights Assignment)', "Restore from $beforeInf")) {
                    $dbPath = Join-Path $env:TEMP 'boundarykit-gpo-secedit-undo.sdb'
                    secedit.exe /configure /db $dbPath /cfg $beforeInf /areas USER_RIGHTS | Out-Null
                }
            } else {
                Write-Host "TargetRoot is not the real Windows directory - skipping secedit restore (would run on a real run)."
            }
        } else {
            Write-Warning "Privilege changes were recorded in the manifest but no secedit-before.inf backup was found at '$beforeInf' - User Rights Assignment was NOT rolled back. Restore it manually via secpol.msc (User Rights Assignment)."
        }
    }
} else {
    Write-Warning 'No backup manifest found - using best-effort targeted removal instead of an exact snapshot restore. User Rights Assignment (time zone / system time privileges) will NOT be touched by this fallback; check secpol.msc manually if Set-PrivilegeRestrictions ever ran.'

    $gpoSettings = (Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot 'lib\GpoSettings.psd1')).Settings
    $machineEntries   = $gpoSettings | Where-Object { $_.Scope -eq 'Machine' } | ForEach-Object { $_.Entries }
    $nonAdminEntries  = $gpoSettings | Where-Object { $_.Scope -eq 'NonAdminUser' } | ForEach-Object { $_.Entries }

    Write-Host 'Machine container:'
    Remove-CatalogEntriesFromContainer -PolPath $paths.MachinePolPath -CatalogEntries $machineEntries
    Write-Host 'Non-Administrators container:'
    Remove-CatalogEntriesFromContainer -PolPath $paths.NonAdminPolPath -CatalogEntries $nonAdminEntries
}

# --- Refresh policy -------------------------------------------------------------------

if ($isRealRun) {
    if ($PSCmdlet.ShouldProcess('Local Group Policy', 'gpupdate /force')) {
        gpupdate.exe /force | Out-Null
    }
} else {
    Write-Host 'TargetRoot is not the real Windows directory - skipping gpupdate (would run gpupdate.exe /force on a real run).'
}

Write-Host ''
Write-Host 'Rollback complete. Verify with `gpresult /r` and by re-checking a couple of the settings in hardening/gpo/README.md.'
