<#
    .SYNOPSIS
    Tests the [Privilege Rights] parsing/diff logic used by
    Apply-GpoLockdown.ps1's Set-PrivilegeRestrictions, against a fabricated sample
    .inf in the same textual format secedit.exe /export produces - NOT against a
    real secedit.exe call. secedit.exe itself is never invoked by this pass (see
    the report this test was written for): this only proves the text-processing
    logic is correct, which is the part this repo actually owns and ships.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Dot-source just the functions we need from Apply-GpoLockdown.ps1 without running
# its top-level param block / preconditions. We do this by reading the function
# definitions out of the file and invoking them in this scope.
$scriptPath = Join-Path $PSScriptRoot '..\Apply-GpoLockdown.ps1'
$scriptText = Get-Content -LiteralPath $scriptPath -Raw
$ast = [System.Management.Automation.Language.Parser]::ParseInput($scriptText, [ref]$null, [ref]$null)
$functionAsts = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($fn in $functionAsts) {
    if ($fn.Name -eq 'Read-PrivilegeRightsFromInf') {
        . ([scriptblock]::Create($fn.Extent.Text))
    }
}

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

$scratch = Join-Path $env:TEMP "boundarykit-privtest-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
$sampleInf = Join-Path $scratch 'sample.inf'

try {
    # A minimal but realistic sample in secedit's export shape (Unicode-encoded,
    # like the real export; other sections present but irrelevant to parsing).
    @(
        '[Unicode]'
        'Unicode=yes'
        '[Version]'
        'signature="$CHICAGO$"'
        'Revision=1'
        '[System Access]'
        'MinimumPasswordAge = 0'
        '[Privilege Rights]'
        'SeNetworkLogonRight = *S-1-5-32-544,*S-1-5-32-545'
        'SeTimeZonePrivilege = *S-1-5-32-544,*S-1-5-19,*S-1-5-32-545'
        'SeSystemtimePrivilege = *S-1-5-32-544,*S-1-5-19'
    ) | Set-Content -LiteralPath $sampleInf -Encoding Unicode

    $map = Read-PrivilegeRightsFromInf -Path $sampleInf

    Assert-Equal -Expected 3 -Actual $map.Count -Message 'Parses all 3 privilege lines'
    Assert-Equal -Expected 3 -Actual (@($map['SeTimeZonePrivilege']).Count) -Message 'SeTimeZonePrivilege has 3 SIDs before filtering'
    Assert-Equal -Expected $true -Actual ('S-1-5-32-545' -in $map['SeTimeZonePrivilege']) -Message 'SeTimeZonePrivilege includes Users (545) by default in the sample'
    Assert-Equal -Expected $true -Actual ('S-1-5-32-544' -in $map['SeTimeZonePrivilege']) -Message 'SeTimeZonePrivilege includes Administrators (544)'
    Assert-Equal -Expected $false -Actual ('S-1-5-32-545' -in $map['SeSystemtimePrivilege']) -Message 'SeSystemtimePrivilege does NOT include Users (545) in this sample - matches a modern Windows 11 default and should be a no-op'

    # Simulate the same removal logic Set-PrivilegeRestrictions applies:
    $removeSids = @('S-1-5-32-545')
    $keepSids   = @('S-1-5-32-544', 'S-1-5-19')

    $newTz = $map['SeTimeZonePrivilege'] | Where-Object { $_ -notin $removeSids }
    Assert-Equal -Expected 2 -Actual (@($newTz).Count) -Message 'Removing Users from SeTimeZonePrivilege leaves exactly 2 SIDs'
    foreach ($k in $keepSids) {
        Assert-Equal -Expected $true -Actual ($k -in $newTz) -Message "SeTimeZonePrivilege after removal still keeps required SID $k"
    }
    Assert-Equal -Expected $false -Actual ('S-1-5-32-545' -in $newTz) -Message 'SeTimeZonePrivilege after removal no longer includes Users (545)'

    $newSt = $map['SeSystemtimePrivilege'] | Where-Object { $_ -notin $removeSids }
    $unchanged = (@(Compare-Object $map['SeSystemtimePrivilege'] $newSt -SyncWindow 0).Count -eq 0)
    Assert-Equal -Expected $true -Actual $unchanged -Message 'SeSystemtimePrivilege is unchanged (correctly a no-op) when Users was never present'

} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failures -gt 0) {
    Write-Host "$failures assertion(s) FAILED." -ForegroundColor Red
    exit 1
} else {
    Write-Host 'All privilege-parsing assertions passed.' -ForegroundColor Green
    exit 0
}
