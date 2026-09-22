<#
.SYNOPSIS
    Rolls back BoundaryKit's Microsoft Edge hardening policies (see apply-edge-policies.ps1).

.DESCRIPTION
    Removes exactly the registry values that apply-edge-policies.ps1 sets, under
    HKLM\SOFTWARE\Policies\Microsoft\Edge. Removing a policy value (rather than setting it
    to some "off" number) returns Edge to "Not Configured" for that policy, i.e. the
    ordinary consumer default (downloads/dev tools/extensions/InPrivate all available,
    no SafeSearch enforcement, sign-in/guest/profile creation available).

    This script only removes the specific value names it (or apply-edge-policies.ps1) is
    responsible for. It does not delete the parent Edge policy key wholesale, so it is
    safe to run even if other tooling later adds unrelated Edge policies to the same key.

    The parent admin account is never affected by any of this - these are Edge browser
    policies only, not Windows account/OS policies, so rollback always leaves the parent
    (and child) Windows accounts and login intact.

.EXAMPLE
    # Dry run - shows what would be removed, changes nothing
    .\rollback-edge-policies.ps1 -WhatIf

.EXAMPLE
    # Roll back for real (requires an elevated/Administrator PowerShell session)
    .\rollback-edge-policies.ps1
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param()

$ErrorActionPreference = 'Stop'

$edgePolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
$extensionBlocklistKey = Join-Path $edgePolicyKey 'ExtensionInstallBlocklist'

$currentPrincipal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "This script writes to HKLM and must be run from an elevated (Administrator) PowerShell session."
}

$valueNames = @(
    'DownloadRestrictions',
    'DeveloperToolsAvailability',
    'InPrivateModeAvailability',
    'ForceBingSafeSearch',
    'ForceGoogleSafeSearch',
    'SmartScreenEnabled',
    'SmartScreenPuaEnabled',
    'BrowserSignin',
    'BrowserGuestModeEnabled',
    'BrowserAddProfileEnabled'
)

if (Test-Path $edgePolicyKey) {
    foreach ($name in $valueNames) {
        $exists = Get-ItemProperty -Path $edgePolicyKey -Name $name -ErrorAction SilentlyContinue
        if ($exists) {
            if ($PSCmdlet.ShouldProcess("$edgePolicyKey\$name", 'Remove value')) {
                Remove-ItemProperty -Path $edgePolicyKey -Name $name -ErrorAction SilentlyContinue
            }
        }
    }
} else {
    Write-Host "$edgePolicyKey does not exist - nothing to roll back at the top level." -ForegroundColor Yellow
}

if (Test-Path $extensionBlocklistKey) {
    if ($PSCmdlet.ShouldProcess($extensionBlocklistKey, 'Remove subkey (extension blocklist)')) {
        Remove-Item -Path $extensionBlocklistKey -Recurse -Force
    }
} else {
    Write-Host "$extensionBlocklistKey does not exist - nothing to roll back there." -ForegroundColor Yellow
}

if ($WhatIfPreference) {
    Write-Host "`nDry run only - nothing was changed. Re-run without -WhatIf to roll back." -ForegroundColor Yellow
    return
}

Write-Host "`nRolled back BoundaryKit Edge policy values. Restart Edge for the change to take effect." -ForegroundColor Green
Write-Host "Verify at edge://policy that these policy names no longer appear (or show 'Not set')." -ForegroundColor Yellow
