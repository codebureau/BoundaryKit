<#
    .SYNOPSIS
    Applies BoundaryKit's Local Group Policy lockdown (GitHub issue #22 and sub-issues
    #23-#28): disables CMD/PowerShell script execution, Registry Editor, Task Manager,
    selected Control Panel/Settings pages, the Microsoft Store, removable storage, and
    changing the system clock/time zone or adding accounts - scoped, wherever Windows
    allows it, to the child's Non-Administrators account only, so the parent admin
    account is never restricted.

    .DESCRIPTION
    Reads the setting catalog in lib\GpoSettings.psd1 (Administrative Template /
    Registry.pol settings) and lib\PrivilegeSettings.psd1 (User Rights Assignment,
    applied via secedit.exe), and:

      1. Backs up every container's current Registry.pol/GPT.INI and the current
         User Rights Assignment export, verbatim, before changing anything.
      2. Builds new Registry.pol files for the Machine and Non-Administrators local
         GPO containers from the catalog, using the pure-PowerShell PReg writer in
         lib\PolFile.psm1 (no external tool/binary dependency).
      3. Tightens SeTimeZonePrivilege/SeSystemtimePrivilege via a minimal, targeted
         secedit import that only touches the specific privilege lines being changed.
      4. Forces a policy refresh (gpupdate /force).

    Every step that would touch a real file is gated behind PowerShell's built-in
    -WhatIf/-Confirm support (SupportsShouldProcess). Steps that would touch the real
    registry-policy engine (secedit.exe, gpupdate.exe) additionally only run when
    -TargetRoot resolves to the machine's actual Windows directory - pointing
    -TargetRoot at a scratch directory (see tests\) exercises the entire file-writing
    pipeline without ever calling either executable or touching a real GPO.

    .PARAMETER TargetRoot
    Root to treat as "the Windows directory". Defaults to the real $env:WinDir.
    Override with a scratch directory for a dry run / test (see tests\Test-*.ps1).

    .PARAMETER BackupRoot
    Where per-run backups are written. Defaults to hardening\gpo\backups (gitignored).
    Point this at removable/external storage if you want the rollback baseline kept
    outside the repo working tree.

    .PARAMETER SkipPrivileges
    Skip the secedit-based User Rights Assignment step entirely (GPO-28b/28c). Useful
    to apply just the Registry.pol settings first and review before touching secedit.

    .PARAMETER SkipGpUpdate
    Skip the final gpupdate /force call, so the written files can be reviewed before
    a refresh forces them onto any already-logged-in session.

    .EXAMPLE
    # Dry run - shows exactly what would be written, changes nothing:
    .\Apply-GpoLockdown.ps1 -WhatIf

    .EXAMPLE
    # Real run on the target PC, as the parent admin, from an elevated PowerShell:
    .\Apply-GpoLockdown.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$TargetRoot = $env:WinDir,
    [string]$BackupRoot = (Join-Path $PSScriptRoot 'backups'),
    [switch]$SkipPrivileges,
    [switch]$SkipGpUpdate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib\PolFile.psm1') -Force
. (Join-Path $PSScriptRoot 'lib\GpoLockdown.Common.ps1')

$gpoSettings       = (Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot 'lib\GpoSettings.psd1')).Settings
$privilegeSettings = (Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot 'lib\PrivilegeSettings.psd1')).Settings

$paths     = Get-GpoContainerPaths -TargetRoot $TargetRoot
$isRealRun = Test-IsRealTargetRoot -TargetRoot $TargetRoot

function Set-PrivilegeRestrictions {
    <#
        .SYNOPSIS
        Tightens User Rights Assignment via a minimal, targeted secedit import.
        Reads the machine's CURRENT effective holder list for each privilege in the
        catalog first, and only removes a SID that is actually present - it never
        assumes a default. Refuses to proceed (throws) if a privilege's required
        KeepSids would not survive the edit, rather than silently dropping one.

        NOT executed against this dev machine at any point in this pass - reviewed
        and reasoned through, but the secedit.exe calls only ever run when IsRealRun
        is true, on the real target PC. The [Privilege Rights] parsing logic (a pure
        text transform, no secedit.exe involved) is covered by
        tests\Test-PrivilegeParsing.ps1 against a fabricated sample .inf.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [array]$Settings,
        [Parameter(Mandatory)] [string]$BackupDir
    )

    $exportPath = Join-Path $BackupDir 'secedit-before.inf'
    $applyPath  = Join-Path $BackupDir 'secedit-apply.inf'
    $dbPath     = Join-Path $env:TEMP 'boundarykit-gpo-secedit.sdb'

    if (-not $PSCmdlet.ShouldProcess('Local Security Policy (User Rights Assignment)', 'secedit /export then targeted /configure')) {
        return @()
    }

    secedit.exe /export /cfg $exportPath /areas USER_RIGHTS | Out-Null
    if (-not (Test-Path -LiteralPath $exportPath)) {
        throw 'secedit /export did not produce the expected file - aborting privilege changes without applying anything.'
    }

    $currentByPrivilege = Read-PrivilegeRightsFromInf -Path $exportPath
    $changes = @()
    $linesToWrite = @()

    foreach ($setting in $Settings) {
        $priv = $setting.Privilege
        $currentSids = $currentByPrivilege[$priv]
        if ($null -eq $currentSids) {
            Write-Warning "Privilege '$priv' was not found in the exported security template - skipping (see hardening/gpo/README.md)."
            continue
        }

        $newSids = $currentSids | Where-Object { $_ -notin $setting.RemoveSids }

        foreach ($mustKeep in $setting.KeepSids) {
            if ($mustKeep -notin $newSids) {
                throw "Refusing to apply '$priv': removing the configured SIDs would also drop required SID '$mustKeep' (would remove admin/system access). No changes made for this privilege."
            }
        }

        if (@(Compare-Object $currentSids $newSids -SyncWindow 0).Count -eq 0) {
            Write-Verbose "Privilege '$priv' already matches the desired holder list - no change needed."
            continue
        }

        $sidList = ($newSids | ForEach-Object { "*$_" }) -join ','
        $linesToWrite += "$priv = $sidList"
        $changes += [pscustomobject]@{
            Privilege = $priv
            Before    = $currentSids
            After     = $newSids
        }
    }

    if ($linesToWrite.Count -eq 0) {
        Write-Verbose 'No privilege changes needed.'
        return $changes
    }

    @(
        '[Unicode]'
        'Unicode=yes'
        '[Version]'
        'signature="$CHICAGO$"'
        'Revision=1'
        '[Privilege Rights]'
        $linesToWrite
    ) | Set-Content -LiteralPath $applyPath -Encoding Unicode

    secedit.exe /configure /db $dbPath /cfg $applyPath /areas USER_RIGHTS | Out-Null

    return $changes
}

function Read-PrivilegeRightsFromInf {
    <#
        .SYNOPSIS
        Parses the [Privilege Rights] section of a secedit-exported .inf into a
        @{ PrivilegeName = @('S-1-...', ...) } map. Pure text processing - no
        secedit.exe call - so it is independently testable against a fabricated
        sample file (tests\Test-PrivilegeParsing.ps1).
    #>
    param([Parameter(Mandatory)] [string]$Path)

    $lines = Get-Content -LiteralPath $Path -Encoding Unicode
    $inSection = $false
    $map = @{}

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^\[(.+)\]$') {
            $inSection = ($Matches[1] -eq 'Privilege Rights')
            continue
        }
        if (-not $inSection -or $trimmed -eq '') { continue }

        $parts = $trimmed -split '=', 2
        if ($parts.Count -ne 2) { continue }

        $name = $parts[0].Trim()
        $sids = $parts[1].Trim() -split ',' |
            ForEach-Object { $_.Trim().TrimStart('*') } |
            Where-Object { $_ -ne '' }

        $map[$name] = @($sids)
    }

    return $map
}

function Write-GroupedPolFile {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$Scope,
        [Parameter(Mandatory)] [string]$PolPath,
        [Parameter(Mandatory)] [string]$PolDir,
        [Parameter(Mandatory)] [array]$Settings
    )

    $entries = foreach ($setting in ($Settings | Where-Object { $_.Scope -eq $Scope })) {
        $setting.Entries
    }
    if (@($entries).Count -eq 0) {
        Write-Verbose "No settings for scope '$Scope' - nothing to write."
        return
    }

    $bytes = ConvertTo-PolBytes -Entries $entries

    if ($PSCmdlet.ShouldProcess($PolPath, "Write Registry.pol ($(@($entries).Count) entries, scope $Scope)")) {
        New-Item -ItemType Directory -Path $PolDir -Force | Out-Null
        [System.IO.File]::WriteAllBytes($PolPath, $bytes)
    }
}

# --- 1. Preconditions -------------------------------------------------------------

if (-not (Test-Path -LiteralPath $paths.NonAdminGptIni)) {
    throw @"
The Non-Administrators local GPO container does not exist yet at:
  $($paths.NonAdminRoot)

This is a one-time, manual setup step (Windows only creates this container through
its own UI - see hardening/gpo/README.md, "One-time setup" section, for the exact
steps: build an MMC console with the Group Policy Object Editor snap-in scoped to
Local Computer\Non-Administrators, and save it once). This script deliberately does
not fabricate this container from scratch, so that its structure is guaranteed to be
one Windows itself created and recognises.

Run the one-time setup, then re-run this script.
"@
}

New-Item -ItemType Directory -Path $paths.MachinePolDir -Force -ErrorAction SilentlyContinue | Out-Null

# --- 2. Backup ----------------------------------------------------------------------

$stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir = Join-Path $BackupRoot $stamp

if ($PSCmdlet.ShouldProcess($backupDir, 'Create backup directory')) {
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
}

$containerBackups = @()
if (Test-Path -LiteralPath $backupDir) {
    $containerBackups += Backup-PolContainer -Name 'Machine' -PolPath $paths.MachinePolPath -GptIniPath $paths.MachineGptIni -BackupDir $backupDir
    $containerBackups += Backup-PolContainer -Name 'NonAdminUser' -PolPath $paths.NonAdminPolPath -GptIniPath $paths.NonAdminGptIni -BackupDir $backupDir
    Write-Host "Backed up current policy state to: $backupDir"
} else {
    Write-Host "(-WhatIf) Would back up current policy state to: $backupDir"
}

# --- 3. Write Registry.pol files -----------------------------------------------------

Write-GroupedPolFile -Scope 'Machine' -PolPath $paths.MachinePolPath -PolDir $paths.MachinePolDir -Settings $gpoSettings
Write-GroupedPolFile -Scope 'NonAdminUser' -PolPath $paths.NonAdminPolPath -PolDir $paths.NonAdminPolDir -Settings $gpoSettings

if ($PSCmdlet.ShouldProcess($paths.MachineGptIni, 'Bump GPT.INI version')) {
    Update-GptIniVersion -GptIniPath $paths.MachineGptIni
}
if ($PSCmdlet.ShouldProcess($paths.NonAdminGptIni, 'Bump GPT.INI version')) {
    Update-GptIniVersion -GptIniPath $paths.NonAdminGptIni
}

# --- 4. User Rights Assignment (secedit) --------------------------------------------

$privilegeChanges = @()
if (-not $SkipPrivileges) {
    if ($isRealRun) {
        $privilegeChanges = Set-PrivilegeRestrictions -Settings $privilegeSettings -BackupDir $backupDir
    } else {
        Write-Host "TargetRoot is not the real Windows directory - skipping secedit (would run Set-PrivilegeRestrictions on a real run)."
    }
} else {
    Write-Host 'Skipping privilege restrictions (-SkipPrivileges).'
}

# --- 5. Refresh policy ----------------------------------------------------------------

if (-not $SkipGpUpdate) {
    if ($isRealRun) {
        if ($PSCmdlet.ShouldProcess('Local Group Policy', 'gpupdate /force')) {
            gpupdate.exe /force | Out-Null
        }
    } else {
        Write-Host 'TargetRoot is not the real Windows directory - skipping gpupdate (would run gpupdate.exe /force on a real run).'
    }
} else {
    Write-Host 'Skipping gpupdate (-SkipGpUpdate) - re-run without it, or run `gpupdate /force` yourself, to make these settings take effect.'
}

# --- 6. Manifest for rollback -----------------------------------------------------

$appliedIds = $gpoSettings | ForEach-Object { $_.Id }
if (Test-Path -LiteralPath $backupDir) {
    $manifestPath = New-ApplyManifest -BackupDir $backupDir -TargetRoot $TargetRoot `
        -ContainerBackups $containerBackups -AppliedSettingIds $appliedIds -PrivilegeChanges $privilegeChanges
    Write-Host "Manifest written: $manifestPath"
}

Write-Host ''
Write-Host "Applied $($gpoSettings.Count) Registry.pol settings and $($privilegeChanges.Count) privilege change(s)."
Write-Host 'See hardening/gpo/README.md for per-setting verification steps, and Undo-GpoLockdown.ps1 to roll back.'
