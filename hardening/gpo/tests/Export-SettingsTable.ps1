<#
    .SYNOPSIS
    Prints the GpoSettings.psd1 + PrivilegeSettings.psd1 catalogs as Markdown, for
    pasting into README.md. Not run automatically - the README is generated content
    reviewed and committed like any other doc; this script exists so the table can be
    regenerated (and checked for drift) whenever the catalog changes, instead of the
    doc and the applied policy silently disagreeing.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$gpo = (Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot '..\lib\GpoSettings.psd1')).Settings
$priv = (Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot '..\lib\PrivilegeSettings.psd1')).Settings

function Format-Prose {
    param([string]$Text)
    ($Text -replace '\r?\n', ' ').Trim() -replace '\s+', ' '
}

foreach ($issue in ($gpo.Issue + $priv.Issue | Sort-Object -Unique)) {
    "### Sub-issue #$issue"
    ""
    foreach ($s in ($gpo | Where-Object { $_.Issue -eq $issue })) {
        "**$($s.Id) - $($s.Title)** (scope: $($s.Scope))"
        ""
        "*Why:* $(Format-Prose $s.Why)"
        ""
        "*Registry values:*"
        foreach ($e in $s.Entries) {
            $hive = if ($s.Scope -eq 'Machine') { 'HKLM' } else { 'HKCU' }
            "- ``$hive\$($e.KeyPath)`` -> ``$($e.ValueName)`` ($($e.Type)) = ``$($e.Data)``"
        }
        ""
        "*Verify:* $(Format-Prose $s.Verify)"
        ""
        "*Confidence:* $(Format-Prose $s.Confidence)"
        ""
    }
    foreach ($s in ($priv | Where-Object { $_.Issue -eq $issue })) {
        "**$($s.Id) - $($s.DisplayName)** (User Rights Assignment, via secedit; machine-wide by nature, admin exempted via group membership)"
        ""
        "*Why:* $(Format-Prose $s.Why)"
        ""
        "*Change:* remove $($s.RemoveSids -join ', ') from ``$($s.Privilege)`` if present; keep $($s.KeepSids -join ', ')."
        ""
        "*Verify:* $(Format-Prose $s.Verify)"
        ""
        "*Confidence:* $(Format-Prose $s.Confidence)"
        ""
    }
}
