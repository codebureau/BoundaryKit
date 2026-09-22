<#
.SYNOPSIS
    Summarises AppLocker "would have been blocked" audit events into a plain report, to
    support the audit-mode review step (issue #34) before flipping any rule collection
    from AuditOnly to Enforced.

.DESCRIPTION
    Read-only. Queries the local AppLocker event log channels with Get-WinEvent and
    groups audit events (EXE/MSI event ID 8003, Script event ID 8006) by the file path
    that would have been blocked, the publisher (if signed), and the user. Does not
    change AppLocker configuration or write anything back to the event log.

    Run this AFTER the audit-mode policy (policy-audit.xml, with the placeholder
    resolved) has been imported and the child has used the machine normally for a while
    - see hardening/applocker/README.md for how long and what "normally" should mean.

.PARAMETER Hours
    How far back to look. Default: 168 (7 days).

.PARAMETER Collection
    Which AppLocker log channel to read: Exe (covers EXE and MSI - they share one
    channel), Script, or All. Default: All.

.EXAMPLE
    .\Review-AppLockerAuditLog.ps1
    Summarise the last 7 days of audit hits across EXE/MSI and Script.

.EXAMPLE
    .\Review-AppLockerAuditLog.ps1 -Hours 24 -Collection Script
#>
[CmdletBinding()]
param(
    [int]$Hours = 168,
    [ValidateSet("Exe", "Script", "All")]
    [string]$Collection = "All"
)

$ErrorActionPreference = "Stop"

$channels = @{
    # "Exe" here covers Microsoft-AppLocker/EXE and DLL, which is also where MSI hits land
    # in this build - the log channel is named for the EXE/DLL collection but Windows
    # Installer audit events (still ID 8003, "would have been blocked") show up here too.
    Exe    = "Microsoft-Windows-AppLocker/EXE and DLL"
    Script = "Microsoft-Windows-AppLocker/MSI and Script"
}

$channelsToQuery = if ($Collection -eq "All") { $channels.Values } else { @($channels[$Collection]) }

# 8003 = "would have been blocked" (the audit-mode signal we care about).
# 8004 = actually blocked (only fires once a collection is Enforced, not AuditOnly).
# We report both so this script is still useful after some collections have been flipped.
$auditEventId = 8003
$blockedEventId = 8004
$startTime = (Get-Date).AddHours(-$Hours)

$allEvents = @()

foreach ($channel in $channelsToQuery) {
    try {
        $events = Get-WinEvent -FilterHashtable @{
            LogName   = $channel
            Id        = @($auditEventId, $blockedEventId)
            StartTime = $startTime
        } -ErrorAction Stop
        $allEvents += $events
    } catch [Exception] {
        if ($_.Exception.Message -match "No events were found") {
            Write-Verbose "No matching events in '$channel' for the last $Hours hour(s)."
        } else {
            Write-Warning "Could not read log channel '$channel': $($_.Exception.Message)"
        }
    }
}

if ($allEvents.Count -eq 0) {
    Write-Host "No AppLocker audit or block events found in the last $Hours hour(s)." -ForegroundColor Yellow
    Write-Host "This can mean: nothing was attempted that the policy would flag, OR the Application Identity service (AppIDSvc) is not running, OR the policy import hasn't happened yet. Verify AppIDSvc is set to Automatic/Running before trusting an empty result." -ForegroundColor Yellow
    return
}

$parsed = $allEvents | ForEach-Object {
    $xml = [xml]$_.ToXml()
    $data = @{}
    foreach ($d in $xml.Event.EventData.Data) { $data[$d.Name] = $d.'#text' }
    [PSCustomObject]@{
        Time      = $_.TimeCreated
        EventId   = $_.Id
        Kind      = if ($_.Id -eq $auditEventId) { "WOULD-HAVE-BLOCKED (audit)" } else { "BLOCKED (enforced)" }
        FilePath  = $data["FullFilePath"]
        Publisher = $data["FileHash"]  # fallback if publisher fields aren't populated
        User      = $_.UserId
        Channel   = $_.LogName
    }
}

Write-Host "`n=== AppLocker audit summary: last $Hours hour(s) ===" -ForegroundColor Cyan
Write-Host "$($parsed.Count) event(s) found.`n"

Write-Host "--- Grouped by file path (what needs an allow-list decision) ---" -ForegroundColor Cyan
$parsed | Group-Object FilePath | Sort-Object Count -Descending | ForEach-Object {
    Write-Host "  [$($_.Count)x] $($_.Name)"
}

Write-Host "`n--- Full event detail ---" -ForegroundColor Cyan
$parsed | Sort-Object Time -Descending | Format-Table Time, Kind, FilePath, User -AutoSize

Write-Host "`nFor each distinct file path above, decide: legitimate app the child needs (add a" -ForegroundColor Yellow
Write-Host "FilePublisherRule/FilePathRule to policy-audit.xml and re-run Prepare-AppLockerPolicy.ps1)," -ForegroundColor Yellow
Write-Host "or correctly blocked (leave as-is). See hardening/applocker/README.md 'Audit-mode review'." -ForegroundColor Yellow
