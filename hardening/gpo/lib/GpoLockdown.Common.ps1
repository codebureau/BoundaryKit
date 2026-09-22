# GpoLockdown.Common.ps1
#
# Shared helpers for Apply-GpoLockdown.ps1 and Undo-GpoLockdown.ps1. Dot-sourced by
# both, not a module, so it can freely share functions without an install step.
#
# Every path in this file is derived from -TargetRoot, which defaults to $env:WinDir
# (the real Windows directory) but can be pointed at a scratch directory for dry-run
# testing (see hardening/gpo/tests/). Nothing in this file calls out to secedit.exe or
# gpupdate.exe directly - those live in Apply-GpoLockdown.ps1's Set-PrivilegeRestrictions
# and Invoke-PolicyRefresh, gated on IsRealRun, so it is obvious from a diff/review
# which functions can touch a real machine and which only ever touch files.

Set-StrictMode -Version Latest

# The well-known SID for the built-in local "Users" group, which is exactly the set
# of accounts the Multiple Local Group Policy (MLGPO) "Non-Administrators" container
# applies to - i.e. every local account that is not a member of Administrators.
$script:NonAdminSid = 'S-1-5-32-545'

function Get-GpoContainerPaths {
    <#
        .SYNOPSIS
        Resolves the on-disk paths for the Machine and Non-Administrators local GPO
        containers under a given Windows-directory root.
    #>
    param(
        [Parameter(Mandatory)] [string]$TargetRoot
    )

    $groupPolicyRoot = Join-Path $TargetRoot 'System32\GroupPolicy'
    $nonAdminRoot     = Join-Path $TargetRoot "System32\GroupPolicyUsers\$script:NonAdminSid"

    [pscustomobject]@{
        MachinePolDir   = Join-Path $groupPolicyRoot 'Machine'
        MachinePolPath  = Join-Path $groupPolicyRoot 'Machine\Registry.pol'
        MachineGptIni   = Join-Path $groupPolicyRoot 'GPT.INI'
        NonAdminPolDir  = Join-Path $nonAdminRoot 'User'
        NonAdminPolPath = Join-Path $nonAdminRoot 'User\Registry.pol'
        NonAdminGptIni  = Join-Path $nonAdminRoot 'GPT.INI'
        NonAdminRoot    = $nonAdminRoot
    }
}

function Test-IsRealTargetRoot {
    <#
        .SYNOPSIS
        True only when -TargetRoot is the machine's actual Windows directory - i.e.
        this run would touch the real system, not a scratch/test directory.
    #>
    param([Parameter(Mandatory)] [string]$TargetRoot)
    return ([System.IO.Path]::GetFullPath($TargetRoot).TrimEnd('\') -eq
            [System.IO.Path]::GetFullPath($env:WinDir).TrimEnd('\'))
}

function Backup-PolContainer {
    <#
        .SYNOPSIS
        Copies a container's current Registry.pol (and GPT.INI, if present) into the
        backup directory verbatim, byte-for-byte, before anything is changed. Records
        whether the files existed at all, since "didn't exist" is itself meaningful
        state that Undo-GpoLockdown.ps1 needs to restore to (delete, not overwrite).
    #>
    param(
        [Parameter(Mandatory)] [string]$Name,          # 'Machine' or 'NonAdminUser'
        [Parameter(Mandatory)] [string]$PolPath,
        [Parameter(Mandatory)] [string]$GptIniPath,
        [Parameter(Mandatory)] [string]$BackupDir
    )

    $destDir = Join-Path $BackupDir $Name
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null

    $result = [ordered]@{
        Name            = $Name
        PolExisted      = $false
        PolBackupPath   = $null
        GptIniExisted   = $false
        GptIniBackupPath = $null
    }

    if (Test-Path -LiteralPath $PolPath) {
        $dest = Join-Path $destDir 'Registry.pol'
        Copy-Item -LiteralPath $PolPath -Destination $dest -Force
        $result.PolExisted = $true
        $result.PolBackupPath = $dest
    }

    if (Test-Path -LiteralPath $GptIniPath) {
        $dest = Join-Path $destDir 'GPT.INI'
        Copy-Item -LiteralPath $GptIniPath -Destination $dest -Force
        $result.GptIniExisted = $true
        $result.GptIniBackupPath = $dest
    }

    return [pscustomobject]$result
}

function Update-GptIniVersion {
    <#
        .SYNOPSIS
        Bumps the Version= line of an existing GPT.INI in place, leaving every other
        line untouched. Never creates a GPT.INI that doesn't already exist - this
        script only ever updates local GPO containers Windows (or a one-time manual
        MMC step, for the Non-Administrators container) has already created.
        Best-effort: failures here are logged as warnings, not fatal, since
        `gpupdate /force` reprocesses policy regardless of the version stamp.
    #>
    param([Parameter(Mandatory)] [string]$GptIniPath)

    if (-not (Test-Path -LiteralPath $GptIniPath)) {
        Write-Warning "GPT.INI not found at '$GptIniPath' - skipping version bump (gpupdate /force will still reprocess policy)."
        return
    }

    try {
        $lines = Get-Content -LiteralPath $GptIniPath
        $found = $false
        $newLines = foreach ($line in $lines) {
            if ($line -match '^\s*Version\s*=\s*(\d+)\s*$') {
                $found = $true
                "Version=$([int]$Matches[1] + 1)"
            } else {
                $line
            }
        }
        if (-not $found) {
            $newLines += 'Version=1'
        }
        Set-Content -LiteralPath $GptIniPath -Value $newLines -Encoding ASCII
    } catch {
        Write-Warning "Could not update Version in '$GptIniPath': $($_.Exception.Message)"
    }
}

function New-ApplyManifest {
    <#
        .SYNOPSIS
        Writes the JSON manifest Undo-GpoLockdown.ps1 reads to restore exactly what
        was here before Apply-GpoLockdown.ps1 ran.
    #>
    param(
        [Parameter(Mandatory)] [string]$BackupDir,
        [Parameter(Mandatory)] [string]$TargetRoot,
        [Parameter(Mandatory)] [array]$ContainerBackups,
        [Parameter(Mandatory)] [array]$AppliedSettingIds,
        [array]$PrivilegeChanges = @()
    )

    $manifest = [ordered]@{
        SchemaVersion  = 1
        TimestampUtc   = (Get-Date).ToUniversalTime().ToString('o')
        TargetRoot     = $TargetRoot
        ContainerBackups = $ContainerBackups
        AppliedSettingIds = $AppliedSettingIds
        PrivilegeChanges  = $PrivilegeChanges
    }

    $path = Join-Path $BackupDir 'manifest.json'
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Get-LatestManifest {
    <#
        .SYNOPSIS
        Finds the most recent manifest.json under a backups root (Undo's default
        source, when no explicit -BackupDir is given).
    #>
    param([Parameter(Mandatory)] [string]$BackupRoot)

    if (-not (Test-Path -LiteralPath $BackupRoot)) { return $null }

    Get-ChildItem -LiteralPath $BackupRoot -Directory |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName 'manifest.json' } |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1
}
