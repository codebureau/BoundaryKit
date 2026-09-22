# GpoSettings.psd1
#
# The single source of truth for every Administrative Template (Registry.pol-based)
# setting this lockdown applies. Apply-GpoLockdown.ps1 reads this file to build the
# Registry.pol files; hardening/gpo/README.md's settings table is generated from the
# same data so the doc and the applied policy cannot drift apart.
#
# Note: this file is loaded with Import-PowerShellDataFile, which only understands a
# restricted subset of PowerShell (no string concatenation with '+', no variables, no
# method calls) - that's why the long prose fields below are here-strings rather than
# '...' + '...' concatenation, and why the root of this file is a hashtable (`Settings`
# key) rather than a bare array: Import-PowerShellDataFile silently returns only the
# FIRST element if the file root is an array of hashtables instead of a hashtable -
# confirmed against a scratch file in this pass (see hardening/gpo/tests/).
#
# Schema (one array element per logical setting, possibly several registry entries):
#   Id          short stable id, referenced from README/rollback notes
#   Issue       the GitHub sub-issue this implements (23-28)
#   Title       human title
#   Scope       'NonAdminUser' -> written to the child-only Non-Administrators local
#                                  GPO container; does not affect the parent admin.
#               'Machine'      -> written to Computer Configuration; applies to
#                                  every account on the PC, admin included.
#   Why         what this closes and why it matters for the threat model (intentional
#               bypass by the child; see docs/adr/0001). Multi-line here-string;
#               rendered as one paragraph (line breaks collapsed to spaces) by the doc
#               generator.
#   Verify      how to check it actually applied, on the real PC.
#   Confidence  how sure this pass is the registry path/value is correct -
#               'High' = well-documented, widely-referenced ADMX-backed policy;
#               'Medium' = documented but with a caveat spelled out in Why/Verify.
#   Entries     array of @{ KeyPath; ValueName; Type; Data } - one per registry value
#               this setting writes. KeyPath is relative to the hive root (HKLM for
#               Machine scope, HKCU for NonAdminUser scope).

@{
    Settings = @(
        @{
            Id         = 'GPO-23a'
            Issue      = 23
            Title      = 'Disable Command Prompt'
            Scope      = 'NonAdminUser'
            Why        = @'
Cmd.exe is a general-purpose escape hatch: it can run arbitrary commands, batch
scripts, and reach most of what AppLocker is meant to block. "Prevent access to the
command prompt" set to 2 also blocks .bat/.cmd processing via cmd.exe, not just the
interactive shell.
'@
            Verify     = 'As the child account, open cmd.exe (Start menu or Win+R). Expect: "The command prompt has been disabled by your administrator."'
            Confidence = 'High - documented ADMX (System.admx, policy "DisableCMD").'
            Entries    = @(
                @{ KeyPath = 'Software\Policies\Microsoft\Windows\System'; ValueName = 'DisableCMD'; Type = 'DWord'; Data = 2 }
            )
        }
        @{
            Id         = 'GPO-23b'
            Issue      = 23
            Title      = 'Restrict PowerShell script execution'
            Scope      = 'Machine'
            Why        = @'
Sets the machine-wide PowerShell execution policy to Restricted (no .ps1 scripts run
at all, from any account). Documented as a known partial control: there is no
Administrative Template "prevent access to PowerShell" equivalent to DisableCMD - this
setting stops script execution but not the interactive powershell.exe host itself.
Blocking the executable from launching at all is AppLocker's job (MVP1 critical path
step 6, tracked separately) - that gap is intentional, not an oversight.
'@
            Verify     = 'As any account, run `Get-ExecutionPolicy -List`; the MachinePolicy scope should read Restricted. Confirm a .ps1 file refuses to run.'
            Confidence = 'Medium - documented ADMX ("Turn on Script Execution", PowerShellExecutionPolicy.admx), but it is Computer-Configuration-only (no per-user equivalent exists), so it also restricts the parent admin''s script execution machine-wide. Reversible; flagged in README as a trade-off.'
            Entries    = @(
                @{ KeyPath = 'Software\Policies\Microsoft\Windows\PowerShell'; ValueName = 'EnableScripts'; Type = 'DWord'; Data = 0 }
            )
        }
        @{
            Id         = 'GPO-24a'
            Issue      = 24
            Title      = 'Disable Registry Editor'
            Scope      = 'NonAdminUser'
            Why        = @'
Regedit.exe (and the reg.exe CLI, and scripted registry edits via .reg double-click)
is how several of these same lockdown settings could otherwise be flipped back. Value
1 (rather than the silent value 2) shows a message when blocked, keeping the block
visible rather than mysteriously silent - fits the household's "joint engineering, not
punishment" framing.
'@
            Verify     = 'As the child account, run regedit.exe. Expect: "Registry editing has been disabled by your administrator."'
            Confidence = 'High - documented ADMX (System.admx, policy "DisableRegistryTools").'
            Entries    = @(
                @{ KeyPath = 'Software\Policies\Microsoft\Windows\System'; ValueName = 'DisableRegistryTools'; Type = 'DWord'; Data = 1 }
            )
        }
        @{
            Id         = 'GPO-24b'
            Issue      = 24
            Title      = 'Disable Task Manager'
            Scope      = 'NonAdminUser'
            Why        = @'
Task Manager can end the monitoring tool's process (MVP2) and is a normal place to
poke around for ways to interfere with restrictions. Note this value lives under a
different, legacy key path than most of the other System.admx settings above - a
known Windows quirk, not a typo.
'@
            Verify     = 'As the child account, press Ctrl+Shift+Esc or Ctrl+Alt+Del -> Task Manager. Expect: "Task Manager has been disabled by your administrator."'
            Confidence = 'High - long-documented policy, widely referenced.'
            Entries    = @(
                @{ KeyPath = 'Software\Microsoft\Windows\CurrentVersion\Policies\System'; ValueName = 'DisableTaskMgr'; Type = 'DWord'; Data = 1 }
            )
        }
        @{
            Id         = 'GPO-25a'
            Issue      = 25
            Title      = 'Hide User Accounts and Date/Time Control Panel applets'
            Scope      = 'NonAdminUser'
            Why        = @'
Legacy Control Panel still offers a path to some of the same settings as Settings app
pages. Hidden rather than the blanket "Prohibit access to Control Panel" - keeps the
rest of Control Panel (e.g. Ease of Access, Sound) usable, matching the "selectively"
scope of this sub-issue.
'@
            Verify     = 'As the child account, open Control Panel. "User Accounts" and "Date and Time" should not be listed.'
            Confidence = 'High - documented ADMX (ControlPanel.admx, policy "DisallowCpl").'
            Entries    = @(
                @{ KeyPath = 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; ValueName = 'DisallowCpl'; Type = 'DWord'; Data = 1 }
                @{ KeyPath = 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\DisallowCpl'; ValueName = '1'; Type = 'String'; Data = 'Microsoft.UserAccounts' }
                @{ KeyPath = 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\DisallowCpl'; ValueName = '2'; Type = 'String'; Data = 'Microsoft.DateAndTime' }
            )
        }
        @{
            Id         = 'GPO-25b'
            Issue      = 25
            Title      = 'Hide the Settings pages that add accounts or change the clock'
            Scope      = 'NonAdminUser'
            Why        = @'
Modern Settings app equivalents of the Control Panel applets above: "Family & other
users" and "Email & accounts" both have "Add account" affordances; "Date & time" is
the immersive-UI clock page. Deliberately narrow - only the pages with an actual
add-account or change-clock affordance are hidden, not the whole Settings app or
unrelated pages like sign-in options, so the child can still manage e.g. their own PIN.
'@
            Verify     = 'As the child account, open Settings > Accounts; "Family & other users" and "Email & accounts" should be missing, as should Settings > Time & language > Date & time. Typing `start ms-settings:dateandtime` should bounce to the Settings home page.'
            Confidence = 'High - documented policy (Explorer.admx, "Settings Page Visibility"); page ids taken from the published ms-settings URI list.'
            Entries    = @(
                @{ KeyPath = 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; ValueName = 'SettingsPageVisibility'; Type = 'String'; Data = 'hide:dateandtime;otherusers;emailandaccounts' }
            )
        }
        @{
            Id         = 'GPO-26a'
            Issue      = 26
            Title      = 'Turn off the Microsoft Store'
            Scope      = 'Machine'
            Why        = @'
README's account structure explicitly says "No Microsoft Store access". Store-only
ADMX policy, Computer-Configuration-only, so it also removes Store access for the
admin account on this machine - acceptable since this is a dedicated child PC and the
setting is trivially reversible.
'@
            Verify     = 'As any account, try to open the Store app; it should refuse to launch or show a policy-restricted message.'
            Confidence = 'High - documented ADMX (WindowsStore.admx, "RemoveWindowsStore"). Some references report this is not fully enforced against a signed-in Microsoft account on Pro editions in every Windows build - treat as one layer, not the only one (Smart App Control, step 4, and the account itself being local-only, are the others).'
            Entries    = @(
                @{ KeyPath = 'Software\Policies\Microsoft\WindowsStore'; ValueName = 'RemoveWindowsStore'; Type = 'DWord'; Data = 1 }
            )
        }
        @{
            Id         = 'GPO-26b'
            Issue      = 26
            Title      = 'Block unrecognised/unsigned apps via SmartScreen'
            Scope      = 'Machine'
            Why        = @'
Belt-and-suspenders behind Smart App Control (step 4, already Strict): SmartScreen's
app/file reputation check additionally blocks (not just warns on) unrecognised apps
and files, and is a GPO-level setting the child cannot toggle off from Windows
Security, unlike the interactive SmartScreen setting.
'@
            Verify     = 'As the child account, download and try to run an unsigned/unrecognised .exe. Expect it to be blocked outright, not just shown a "Run anyway" prompt.'
            Confidence = 'Medium - documented ADMX (Explorer.admx, "Configure Windows Defender SmartScreen", registry path per admx.help); applied at Machine scope for reliability rather than the User-Configuration duplicate of this policy, whose exact precedence behaviour on this Windows build was not independently confirmed in this pass - verify on the real machine.'
            Entries    = @(
                @{ KeyPath = 'Software\Policies\Microsoft\Windows\System'; ValueName = 'EnableSmartScreen'; Type = 'DWord'; Data = 1 }
                @{ KeyPath = 'Software\Policies\Microsoft\Windows\System'; ValueName = 'ShellSmartScreenLevel'; Type = 'String'; Data = 'Block' }
            )
        }
        @{
            Id         = 'GPO-26c'
            Issue      = 26
            Title      = 'Hide "Apps & features" / "Programs and Features"'
            Scope      = 'NonAdminUser'
            Why        = @'
Reduces self-service install/uninstall surface for the child account. Defense-in-depth
alongside AppLocker (step 6), which is the authoritative execution blocker for
unapproved software - this only removes the convenient UI, it is not itself a
security boundary.
'@
            Verify     = 'As the child account, Settings > Apps > Installed apps and the Control Panel "Programs and Features" applet should both be hidden/inaccessible.'
            Confidence = 'High - documented policy (same DisallowCpl mechanism as GPO-25a, applied to a different applet).'
            Entries    = @(
                @{ KeyPath = 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\DisallowCpl'; ValueName = '3'; Type = 'String'; Data = 'Microsoft.ProgramsAndFeatures' }
            )
        }
        @{
            Id         = 'GPO-27a'
            Issue      = 27
            Title      = 'Deny all removable storage access'
            Scope      = 'NonAdminUser'
            Why        = @'
Closes the most obvious bypass for the download-control goal: copying a blocked file
type in via USB instead of downloading it, or relocating files to dodge the monitor.
Deliberately applied at User (Non-Administrators) scope only, not also at Computer
scope, both to keep the parent admin's USB drives working and to avoid the exact
Computer-vs-User policy conflict Microsoft's own guidance warns about when the same
setting is set at both levels at once.
'@
            Verify     = 'As the child account, insert a USB flash drive; it should not mount / should be denied access. As the parent admin, the same drive should work normally.'
            Confidence = 'Medium-High - documented ADMX (RemovableStorageAdmin.admx, "All Removable Storage classes: Deny all access" / value "Deny_All"), confirmed to exist at both HKLM and HKCU by multiple independent references; the User-Configuration variant''s exact behaviour was not exercised against a real Group Policy engine in this pass.'
            Entries    = @(
                @{ KeyPath = 'Software\Policies\Microsoft\Windows\RemovableStorageDevices'; ValueName = 'Deny_All'; Type = 'DWord'; Data = 1 }
            )
        }
        @{
            Id         = 'GPO-28a'
            Issue      = 28
            Title      = 'Block launching restricted executables from Explorer (defense-in-depth)'
            Scope      = 'NonAdminUser'
            Why        = @'
Covers tools relevant to the tamper/bypass concern that are not already blocked by a
dedicated policy above: netplwiz (account management UI) and mmc.exe (hosts
lusrmgr.msc, secpol.msc, gpedit.msc, services.msc - none of which the child account
needs). cmd.exe/powershell.exe/powershell_ise.exe/pwsh.exe are included too, layered on
top of DisableCMD and the execution-policy restriction above. regedit.exe and
taskmgr.exe are deliberately left out - DisableRegistryTools and DisableTaskMgr already
block them more strongly (including non-Explorer launch paths), so listing them here
would be redundant. Known limitation: "Don't run specified Windows applications" only
intercepts launches started via Explorer (Start menu, Run box, desktop icons) - a
renamed copy of the executable, or one launched from a script/other process, is not
caught. It is a UI-level speed bump, not a security boundary - AppLocker (step 6) is
the boundary.
'@
            Verify     = 'As the child account, try Start menu / Win+R for netplwiz, mmc, cmd, powershell. Expect: "This operation has been cancelled due to restrictions in effect on this computer."'
            Confidence = 'High - documented ADMX (Explorer.admx, "Don''t run specified Windows applications" / DisallowRun), well-known limitations as noted above.'
            Entries    = @(
                @{ KeyPath = 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; ValueName = 'DisallowRun'; Type = 'DWord'; Data = 1 }
                @{ KeyPath = 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\DisallowRun'; ValueName = '1'; Type = 'String'; Data = 'cmd.exe' }
                @{ KeyPath = 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\DisallowRun'; ValueName = '2'; Type = 'String'; Data = 'powershell.exe' }
                @{ KeyPath = 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\DisallowRun'; ValueName = '3'; Type = 'String'; Data = 'powershell_ise.exe' }
                @{ KeyPath = 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\DisallowRun'; ValueName = '4'; Type = 'String'; Data = 'pwsh.exe' }
                @{ KeyPath = 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\DisallowRun'; ValueName = '5'; Type = 'String'; Data = 'netplwiz.exe' }
                @{ KeyPath = 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\DisallowRun'; ValueName = '6'; Type = 'String'; Data = 'mmc.exe' }
            )
        }
    )
}
