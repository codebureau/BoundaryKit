<#
.SYNOPSIS
    Imports an AppLocker policy XML file on THIS machine via Set-AppLockerPolicy, with
    prerequisite checks and a confirmation prompt. This is the one script in this folder
    that actually changes local policy - run it only on the target child's PC, never on
    a development machine.

.DESCRIPTION
    Thin, careful wrapper around Set-AppLockerPolicy:
      1. Confirms it's running elevated (AppLocker policy changes require admin).
      2. Checks the Application Identity service (AppIDSvc) - AppLocker enforcement
         (including audit logging) does nothing without it running.
      3. Warns if the file still contains the %%CHILD_GROUP_SID%% placeholder (i.e. you
         forgot to run Prepare-AppLockerPolicy.ps1 first) and refuses to continue.
      4. Shows a summary of what will be applied (collections + enforcement modes) and
         asks for confirmation before calling Set-AppLockerPolicy, unless -Force is used.
      5. Applies with -Merge:$false (replace, not merge) by default, matching this
         project's "one authoritative policy file" model - pass -Merge to layer instead.

    Deliberately NOT run by the Developer pass that authored this policy - see
    hardening/applocker/README.md. Verification of THIS script was limited to reading it,
    linting/parsing it, and Test-AppLockerPolicy simulation of the policy XML it wraps;
    actually running it against a machine's live AppLocker configuration needs the real
    target PC and Matt's own hands, per this project's rules.

.PARAMETER XmlPolicy
    Path to the resolved policy XML to apply (e.g. policy-audit.resolved.xml from
    Prepare-AppLockerPolicy.ps1, or policy-rollback-disable.xml).

.PARAMETER Merge
    Merge with the currently applied policy instead of replacing it. Default: off
    (replace). Rollback specifically depends on replace semantics - do not pass -Merge
    when applying policy-rollback-disable.xml.

.PARAMETER Force
    Skip the confirmation prompt. Not recommended for first-time application.

.EXAMPLE
    .\Deploy-AppLockerPolicy.ps1 -XmlPolicy ..\policy-audit.resolved.xml
    Reviews prerequisites, shows a summary, asks to confirm, then applies audit-mode policy.

.EXAMPLE
    .\Deploy-AppLockerPolicy.ps1 -XmlPolicy ..\policy-rollback-disable.xml -Force
    Immediately rolls back to no AppLocker restriction, no prompt.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param(
    [Parameter(Mandatory = $true)]
    [string]$XmlPolicy,

    [switch]$Merge,

    [switch]$Force
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $XmlPolicy)) {
    throw "Policy file not found: $XmlPolicy"
}

# 1. Elevation check.
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "This must be run from an elevated (Run as Administrator) PowerShell session - AppLocker policy changes require it."
}

# 2. Application Identity service check - AppLocker (audit or enforced) is inert without it.
$svc = Get-Service -Name "AppIDSvc" -ErrorAction SilentlyContinue
if (-not $svc) {
    throw "Application Identity service (AppIDSvc) was not found on this machine."
}
if ($svc.Status -ne "Running") {
    Write-Warning "AppIDSvc is currently '$($svc.Status)'. AppLocker will not enforce or log anything until it's running. Start it with: Start-Service AppIDSvc (and set it to Automatic: Set-Service AppIDSvc -StartupType Automatic)"
    if (-not $Force) {
        $go = Read-Host "Continue applying the policy anyway? (y/N)"
        if ($go -ne "y") { Write-Host "Aborted."; return }
    }
}

# 3. Refuse an unresolved placeholder file outright - this is not a warning, it's a hard stop.
$content = Get-Content -LiteralPath $XmlPolicy -Raw
if ($content -match [regex]::Escape('%%CHILD_GROUP_SID%%')) {
    throw "This policy file still contains the %%CHILD_GROUP_SID%% placeholder. Run Prepare-AppLockerPolicy.ps1 first and pass its output here - do not edit the placeholder by hand."
}

# 4. Summarise what's about to be applied.
[xml]$doc = $content
Write-Host "`nAbout to apply: $XmlPolicy" -ForegroundColor Cyan
Write-Host "Mode: $(if ($Merge) { 'MERGE with current policy' } else { 'REPLACE current policy entirely' })" -ForegroundColor Cyan
$doc.AppLockerPolicy.RuleCollection | ForEach-Object {
    $ruleCount = ($_.SelectNodes("*[local-name()='FilePathRule' or local-name()='FilePublisherRule' or local-name()='FileHashRule']")).Count
    Write-Host ("  {0,-8} EnforcementMode={1,-14} Rules={2}" -f $_.Type, $_.EnforcementMode, $ruleCount)
}

if (-not $Force) {
    $go = Read-Host "`nApply this policy now? (y/N)"
    if ($go -ne "y") { Write-Host "Aborted, nothing applied."; return }
}

if ($PSCmdlet.ShouldProcess("local AppLocker policy", "Set-AppLockerPolicy -XmlPolicy $XmlPolicy")) {
    if ($Merge) {
        Set-AppLockerPolicy -XmlPolicy $XmlPolicy -Merge
    } else {
        Set-AppLockerPolicy -XmlPolicy $XmlPolicy
    }
    Write-Host "Applied. Verify with: Get-AppLockerPolicy -Local -Xml" -ForegroundColor Green
    Write-Host "If anything looks wrong: .\Deploy-AppLockerPolicy.ps1 -XmlPolicy ..\policy-rollback-disable.xml -Force" -ForegroundColor Yellow
}
