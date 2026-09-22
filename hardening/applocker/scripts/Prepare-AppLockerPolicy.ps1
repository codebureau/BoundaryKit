<#
.SYNOPSIS
    Resolves the %%CHILD_GROUP_SID%% placeholder in an AppLocker policy XML file to a
    real SID and writes a new, ready-to-import file. Never modifies local policy.

.DESCRIPTION
    hardening/applocker/policy-audit.xml is checked into git with the child account's
    group SID left as the literal placeholder token %%CHILD_GROUP_SID%%, because GitHub
    issue #15 "Account structure" may not be done yet and the real SID can't be known in
    advance (it's generated locally when the group is created).

    This script does the substitution ONLY. It reads a source policy file, resolves the
    -GroupName (default: BoundaryKit-Child) to its SID via the local SAM, replaces every
    occurrence of the placeholder, and writes the result to -OutFile. It never calls
    Set-AppLockerPolicy and never touches the machine's actual AppLocker configuration -
    see Deploy-AppLockerPolicy.ps1 (and hardening/applocker/README.md) for that step,
    which is a separate, deliberate action Matt runs on the target PC.

.PARAMETER PolicyPath
    Source policy XML containing the %%CHILD_GROUP_SID%% placeholder.
    Default: ..\policy-audit.xml (relative to this script).

.PARAMETER OutFile
    Where to write the resolved policy. Default: <PolicyPath> with ".resolved.xml"
    appended before the extension, next to the source file.

.PARAMETER GroupName
    The local group the child account belongs to. Default: BoundaryKit-Child.
    If issue #15 lands with a different name, pass it here rather than editing the
    policy file's placeholder text.

.EXAMPLE
    .\Prepare-AppLockerPolicy.ps1
    Resolves BoundaryKit-Child's SID and writes policy-audit.resolved.xml next to the source.

.EXAMPLE
    .\Prepare-AppLockerPolicy.ps1 -GroupName "BoundaryKit-Restricted" -OutFile C:\Temp\policy-ready.xml
#>
[CmdletBinding()]
param(
    [string]$PolicyPath = (Join-Path $PSScriptRoot "..\policy-audit.xml"),
    [string]$OutFile,
    [string]$GroupName = "BoundaryKit-Child"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $PolicyPath)) {
    throw "Policy file not found: $PolicyPath"
}

if (-not $OutFile) {
    $dir = Split-Path -Parent $PolicyPath
    $name = [System.IO.Path]::GetFileNameWithoutExtension($PolicyPath)
    $ext = [System.IO.Path]::GetExtension($PolicyPath)
    $OutFile = Join-Path $dir "$name.resolved$ext"
}

Write-Host "Resolving local group '$GroupName' to a SID..." -ForegroundColor Cyan
try {
    $sid = (New-Object System.Security.Principal.NTAccount($GroupName)).Translate([System.Security.Principal.SecurityIdentifier]).Value
} catch {
    throw "Could not resolve local group '$GroupName' to a SID. Has issue #15 (Account structure) been completed on this machine, and does the group exist under this exact name? Original error: $($_.Exception.Message)"
}
Write-Host "  $GroupName -> $sid" -ForegroundColor Green

$content = Get-Content -LiteralPath $PolicyPath -Raw
$placeholderCount = ([regex]::Matches($content, [regex]::Escape('%%CHILD_GROUP_SID%%'))).Count
if ($placeholderCount -eq 0) {
    Write-Warning "No '%%CHILD_GROUP_SID%%' placeholders found in $PolicyPath - nothing to substitute. Writing an unchanged copy anyway."
}

$resolved = $content -replace [regex]::Escape('%%CHILD_GROUP_SID%%'), $sid
Set-Content -LiteralPath $OutFile -Value $resolved -Encoding UTF8

Write-Host "Wrote resolved policy ($placeholderCount placeholder(s) replaced) to: $OutFile" -ForegroundColor Green
Write-Host "This file is NOT applied to anything. Review it, then see hardening/applocker/README.md for the audit-mode import step." -ForegroundColor Yellow
