<#
.SYNOPSIS
    Applies BoundaryKit's Microsoft Edge hardening policies (GitHub issue #35, sub-issues #36-#38).

.DESCRIPTION
    Sets the Microsoft Edge Chromium policy registry values under
    HKLM\SOFTWARE\Policies\Microsoft\Edge that:
      - disable downloads, developer tools, extensions, and InPrivate mode (#36)
      - force SafeSearch and reinforce blocking of executable/PUA downloads (#37)
      - disable Edge sign-in, guest mode, and profile creation/switching (#38)

    These are the same Chromium/Edge "Administrative Templates" policies that Local Group
    Policy (gpedit.msc) writes to this same registry hive - setting the registry values
    directly has an identical effect to applying the ADMX policy via gpedit on a
    non-domain-joined machine, and is what this project's local-GPO-only setup uses
    throughout (see docs/adr/0001-mvp1-scope-and-critical-path.md and README.md).

    Deliberately EXCLUDED (see docs/adr/0001-mvp1-scope-and-critical-path.md):
      - Force Family Safety mode (inert without Family Safety enrollment, which is deferred)
      - Website allow/deny list (content filtering, not bypass-prevention; deferred)

    This script is idempotent and non-destructive: re-running it simply re-asserts the
    same values. It supports -WhatIf/-Confirm (standard PowerShell ShouldProcess) for a
    dry run before committing any change.

.PARAMETER WhatIf
    Show what would change without changing anything (built-in common parameter).

.EXAMPLE
    # Dry run - shows every value that would be written, changes nothing
    .\apply-edge-policies.ps1 -WhatIf

.EXAMPLE
    # Apply for real (requires an elevated/Administrator PowerShell session)
    .\apply-edge-policies.ps1

.NOTES
    Requires an elevated (Administrator) PowerShell session because it writes to HKLM.
    Rollback: run .\rollback-edge-policies.ps1 (see also edge-policies-rollback.reg).
    Full policy reference and rationale: hardening/edge/README.md
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param()

$ErrorActionPreference = 'Stop'

$edgePolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
$extensionBlocklistKey = Join-Path $edgePolicyKey 'ExtensionInstallBlocklist'

# --- Guard: must be elevated, since HKLM writes fail silently-ish otherwise ---
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "This script writes to HKLM and must be run from an elevated (Administrator) PowerShell session."
}

# --- DWORD (integer/boolean) policy values, all under HKLM\SOFTWARE\Policies\Microsoft\Edge ---
# Each entry: Name = exact ADMX/registry policy name; Value = REG_DWORD; Comment = what it does.
#
# NOTE on DownloadRestrictions: Matt confirmed 2026-09-22 (MVP1 hardening artifact review)
# on 2 (BlockPotentiallyDangerousDownloads) rather than 3 (BlockAllDownloads) - ordinary
# downloads (e.g. homework PDFs) go through; SmartScreen-flagged/dangerous file types are
# still blocked. See README.md "Judgment calls" for the reasoning and the stricter alternative.
$dwordPolicies = [ordered]@{
    # --- #36: downloads, dev tools, extensions, InPrivate mode ---
    'DownloadRestrictions'        = 2  # BlockPotentiallyDangerousDownloads
    'DeveloperToolsAvailability'  = 2  # DeveloperToolsDisallowed
    'InPrivateModeAvailability'   = 1  # Disabled

    # --- #37: SafeSearch + executable/PUA download blocking (defense-in-depth alongside
    #          DownloadRestrictions=3 above; keeps SafeSearch/SmartScreen enforced even if
    #          DownloadRestrictions is ever loosened) ---
    'ForceBingSafeSearch'         = 2  # BingSafeSearchStrictMode (Edge's default search engine)
    'ForceGoogleSafeSearch'       = 1  # true - enforced if the user ever switches/visits Google
    'SmartScreenEnabled'          = 1  # true - baseline phishing/malware protection
    'SmartScreenPuaEnabled'       = 1  # true - blocks potentially-unwanted-app downloads

    # --- #38: disable Edge sign-in and profile switching ---
    'BrowserSignin'               = 0  # Disable - no signing in to a Microsoft/work account
    'BrowserGuestModeEnabled'     = 0  # false - no guest browsing profile
    'BrowserAddProfileEnabled'    = 0  # false - no creating additional profiles to switch to
}

function Set-EdgePolicyDword {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Value
    )
    if ($PSCmdlet.ShouldProcess("$Path\$Name", "Set REG_DWORD = $Value")) {
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
    }
}

if ($PSCmdlet.ShouldProcess($edgePolicyKey, 'Create registry key if missing')) {
    if (-not (Test-Path $edgePolicyKey)) {
        New-Item -Path $edgePolicyKey -Force | Out-Null
    }
}

foreach ($name in $dwordPolicies.Keys) {
    Set-EdgePolicyDword -Path $edgePolicyKey -Name $name -Value $dwordPolicies[$name]
}

# --- ExtensionInstallBlocklist: multi-value list policy, one REG_SZ per numbered value ---
# A single "*" entry blocks ALL extensions (no allowlist is configured, so nothing is exempt).
if ($PSCmdlet.ShouldProcess($extensionBlocklistKey, 'Create subkey if missing')) {
    if (-not (Test-Path $extensionBlocklistKey)) {
        New-Item -Path $extensionBlocklistKey -Force | Out-Null
    }
}
if ($PSCmdlet.ShouldProcess("$extensionBlocklistKey\1", 'Set REG_SZ = "*" (block all extensions)')) {
    New-ItemProperty -Path $extensionBlocklistKey -Name '1' -Value '*' -PropertyType String -Force | Out-Null
}

if ($WhatIfPreference) {
    Write-Host "`nDry run only - nothing was changed. Re-run without -WhatIf to apply." -ForegroundColor Yellow
    return
}

# --- Read back and print what's actually set, for verification ---
Write-Host "`nApplied Edge policy values under $edgePolicyKey :" -ForegroundColor Green
foreach ($name in $dwordPolicies.Keys) {
    $actual = (Get-ItemProperty -Path $edgePolicyKey -Name $name -ErrorAction SilentlyContinue).$name
    Write-Host ("  {0,-28} = {1}" -f $name, $actual)
}
$blocklistActual = (Get-ItemProperty -Path $extensionBlocklistKey -Name '1' -ErrorAction SilentlyContinue).'1'
Write-Host ("  {0,-28} = {1}" -f 'ExtensionInstallBlocklist\1', $blocklistActual)

Write-Host "`nRestart Microsoft Edge (or sign out/in) for policies to take full effect." -ForegroundColor Yellow
Write-Host "Verify in the browser at edge://policy (click Reload policies)." -ForegroundColor Yellow
Write-Host "Rollback: .\rollback-edge-policies.ps1  (or import edge-policies-rollback.reg)" -ForegroundColor Yellow
